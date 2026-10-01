defmodule Anime.Accounts.Lifecycle do
  @moduledoc "Account changes serialized against current database state, never socket assigns."
  import Ecto.Query
  alias Ecto.Changeset, as: CS
  alias Anime.{Repo, Accounts, Audit, RateLimits}
  alias Anime.Accounts.{User, UserToken, Tokens}
  alias Anime.Access.Role
  @reservation_seconds 30 * 86400

  def change_nick(actor, attrs, meta \\ %{}) do
    Repo.transaction(fn ->
      u = lock_editable!(actor.id)
      cs = User.nick_changeset(u, attrs)
      unless cs.valid?, do: Repo.rollback(cs)
      nick = CS.get_field(cs, :nick)
      if String.downcase(nick) == String.downcase(u.nick), do: Repo.rollback(:unchanged)
      now = DateTime.utc_now()

      if u.nick_changed_at && DateTime.diff(now, u.nick_changed_at) < @reservation_seconds,
        do: Repo.rollback(:nick_cooldown)

      [u.nick, nick]
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.each(&Accounts.nick_lock/1)

      if Accounts.nick_taken?(nick),
        do: Repo.rollback(CS.add_error(cs, :nick, "has already been taken"))

      updated =
        cs
        |> CS.change(
          previous_nick: u.nick,
          previous_nick_until: DateTime.add(now, @reservation_seconds),
          nick_changed_at: now
        )
        |> update!()

      Audit.record(
        Repo.preload(u, :role),
        "nick_change",
        "User",
        u.id,
        :success,
        Map.merge(meta, %{old_value: %{nick: u.nick}, new_value: %{nick: updated.nick}})
      )

      updated
    end)
    |> notify()
  end

  def request_email_change(actor, password, attrs, meta \\ %{}) do
    Repo.transaction(fn ->
      u = lock_editable!(actor.id)
      unless Accounts.valid_password?(u, password), do: Repo.rollback(:invalid_password)
      cs = User.email_changeset(u, attrs)
      unless cs.valid?, do: Repo.rollback(cs)
      email = CS.get_field(cs, :email)
      if email == u.email, do: Repo.rollback(:unchanged)

      if Repo.exists?(from a in User, where: a.email == ^email),
        do: Repo.rollback(CS.add_error(cs, :email, "has already been taken"))

      limit_mail!(u)
      remove_email_tokens!(u)
      queue_token!(u, :change_email, %{sent_to: email})

      audit =
        Audit.record(
          Repo.preload(u, :role),
          "email_change_request",
          "User",
          u.id,
          :success,
          Map.merge(meta, %{old_value: %{email: u.email}, new_value: %{email: email}})
        )

      # Only a record ID is queued. The notice's original recipient is frozen in the audit record.
      %{audit_id: audit.id, kind: "email_change_notice", locale: to_string(u.locale)}
      |> Anime.Workers.Mail.new()
      |> Oban.insert!()

      u
    end)
  end

  def pending_email(actor) do
    Repo.one(
      from t in UserToken,
        join: u in User,
        on: u.id == t.user_id,
        where:
          t.user_id == ^actor.id and t.context == :change_email and
            t.expires_at > ^DateTime.utc_now() and u.status == :active and
            not u.deletion_requested,
        select: %{sent_to: t.sent_to, expires_at: t.expires_at}
    )
  end

  def resend_email_change(actor) do
    Repo.transaction(fn ->
      u = lock_editable!(actor.id)
      pending = pending_email(u) || Repo.rollback(:no_pending_email)
      limit_mail!(u)
      remove_email_tokens!(u)
      queue_token!(u, :change_email, %{sent_to: pending.sent_to})
      u
    end)
  end

  def cancel_email_change(actor) do
    Repo.transaction(fn ->
      u = lock_editable!(actor.id)
      remove_email_tokens!(u)
      u
    end)
  end

  def confirm_email_change(raw, meta \\ %{}) do
    Repo.transaction(fn ->
      token = Tokens.find(raw, [:change_email]) || Repo.rollback(:invalid_token)
      u = lock_editable!(token.user_id)
      unless Tokens.find(raw, [:change_email]), do: Repo.rollback(:invalid_token)

      updated =
        User.email_changeset(u, %{email: token.sent_to})
        |> CS.change(email_confirmed_at: DateTime.utc_now())
        |> update!()

      # Password-reset and confirmation links for the former address must not survive.
      Repo.delete_all(from t in UserToken, where: t.user_id == ^u.id)

      Audit.record(
        Repo.preload(u, :role),
        "email_change_confirm",
        "User",
        u.id,
        :success,
        Map.merge(meta, %{
          old_value: %{email: u.email},
          new_value: %{email: updated.email}
        })
      )

      updated
    end)
    |> notify()
  end

  def request_deletion(actor, password, nick, meta \\ %{}) do
    Repo.transaction(fn ->
      owner_lock!()
      u = lock_editable!(actor.id)
      unless Accounts.valid_password?(u, password), do: Repo.rollback(:invalid_password)
      unless is_binary(nick) && nick == u.nick, do: Repo.rollback(:nickname_mismatch)
      protect_last_owner!(u)

      updated =
        u
        |> CS.change(deletion_requested: true, deletion_requested_at: DateTime.utc_now())
        |> Repo.update!()

      Repo.delete_all(from t in UserToken, where: t.user_id == ^u.id)
      queue_token!(updated, :delete_cancel)
      Audit.record(Repo.preload(u, :role), "account_delete_request", "User", u.id, :success, meta)
      updated
    end)
    |> notify()
  end

  def restore_account(raw, meta \\ %{}) do
    Repo.transaction(fn ->
      owner_lock!()
      token = Tokens.find(raw, [:delete_cancel]) || Repo.rollback(:invalid_token)
      u = Repo.one(from u in User, where: u.id == ^token.user_id, lock: "FOR UPDATE")

      unless u && u.deletion_requested && u.deletion_requested_at &&
               DateTime.diff(DateTime.utc_now(), u.deletion_requested_at) < @reservation_seconds &&
               Tokens.find(raw, [:delete_cancel]),
             do: Repo.rollback(:invalid_token)

      updated =
        u |> CS.change(deletion_requested: false, deletion_requested_at: nil) |> Repo.update!()

      Repo.delete_all(
        from t in UserToken, where: t.user_id == ^u.id and t.context == :delete_cancel
      )

      # Restoring does not lift an administrative block or recreate any session.
      Audit.record(Repo.preload(u, :role), "account_delete_cancel", "User", u.id, :success, meta)
      updated
    end)
  end

  def delete_due_account(id) do
    Repo.transaction(fn ->
      owner_lock!()
      u = Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE")

      if u && u.deletion_requested && u.deletion_requested_at &&
           DateTime.diff(DateTime.utc_now(), u.deletion_requested_at) >= @reservation_seconds do
        protect_last_owner!(u)
        # Avatar storage is a later queue: fail closed if unexpected external objects exist.
        if u.avatar_key_320 || u.avatar_key_80, do: Repo.rollback(:avatar_cleanup_not_implemented)
        Audit.record(Repo.preload(u, :role), "account_delete_final", "User", u.id, :success)
        label = "deleted-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

        Repo.update_all(from(a in Audit, where: a.user_id == ^u.id),
          set: [user_id: nil, actor_label: label]
        )

        Repo.delete!(u)
        :deleted
      else
        :not_due
      end
    end)
  end

  def next_nick_change(%User{nick_changed_at: nil}), do: nil
  def next_nick_change(%User{nick_changed_at: at}), do: DateTime.add(at, @reservation_seconds)

  # Share this guard/lock with future role changes, blocking and owner creation.
  def owner_lock!, do: Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(7317, 1)", [])

  defp protect_last_owner!(u) do
    if Repo.get!(Role, u.role_id).code == "owner" &&
         not Repo.exists?(
           from a in User,
             join: r in Role,
             on: r.id == a.role_id,
             where:
               r.code == "owner" and a.id != ^u.id and a.status == :active and
                 not a.deletion_requested
         ),
       do: Repo.rollback(:last_owner)
  end

  defp lock_editable!(id) do
    u = Accounts.lock_active!(id)
    if u.must_change_password, do: Repo.rollback(:password_change_required)
    u
  end

  defp limit_mail!(u),
    do: RateLimits.consume("confirm_resend", "user:" <> to_string(u.id), [{60, 1}, {86400, 5}])

  defp remove_email_tokens!(u),
    do:
      Repo.delete_all(
        from t in UserToken, where: t.user_id == ^u.id and t.context == :change_email
      )

  defp queue_token!(u, context, meta \\ %{}) do
    %{token_id: id} = Tokens.issue(u, context, meta)
    %{token_id: id, locale: to_string(u.locale)} |> Anime.Workers.Mail.new() |> Oban.insert!()
  end

  defp update!(cs) do
    case Repo.update(cs) do
      {:ok, u} -> u
      {:error, cs} -> Repo.rollback(cs)
    end
  end

  defp notify({:ok, u} = result) do
    Phoenix.PubSub.broadcast(Anime.PubSub, "user:#{u.id}:access", :access_changed)
    result
  end

  defp notify(result), do: result
end
