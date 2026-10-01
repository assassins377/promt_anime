defmodule Anime.Accounts do
  import Ecto.Query
  alias Anime.{Repo, Audit, RateLimits}
  alias Anime.Accounts.{User, UserToken, Tokens}
  alias Anime.Access.Role

  defdelegate change_nick(actor, attrs, meta \\ %{}), to: Anime.Accounts.Lifecycle

  defdelegate request_email_change(actor, password, attrs, meta \\ %{}),
    to: Anime.Accounts.Lifecycle

  defdelegate pending_email(actor), to: Anime.Accounts.Lifecycle
  defdelegate resend_email_change(actor), to: Anime.Accounts.Lifecycle
  defdelegate cancel_email_change(actor), to: Anime.Accounts.Lifecycle
  defdelegate request_deletion(actor, password, nick, meta \\ %{}), to: Anime.Accounts.Lifecycle
  defdelegate restore_account(raw, meta \\ %{}), to: Anime.Accounts.Lifecycle

  def register(attrs, meta) do
    cs = User.registration_changeset(%User{}, attrs)

    cond do
      not Anime.Settings.get("registration_enabled", false) ->
        {:error, :registration_disabled}

      not cs.valid? ->
        {:error, cs}

      not mx_valid?(Ecto.Changeset.get_field(cs, :email)) ->
        {:error, Ecto.Changeset.add_error(cs, :email, "has no mail server")}

      true ->
        Repo.transaction(fn ->
          RateLimits.consume("register", "ip:" <> meta.ip, [{3600, 3}, {86400, 10}])
          nick_lock(Ecto.Changeset.get_field(cs, :nick))

          if nick_taken?(Ecto.Changeset.get_field(cs, :nick)),
            do: Repo.rollback(Ecto.Changeset.add_error(cs, :nick, "has already been taken"))

          role = Repo.get_by!(Role, code: Anime.Settings.get("registration_default_role", "user"))

          cs =
            cs
            |> User.hash_password()
            |> Ecto.Changeset.change(
              role_id: role.id,
              consent_accepted_at: DateTime.utc_now(),
              consent_version: Anime.Settings.get("legal_version")
            )

          case Repo.insert(cs) do
            {:ok, user} ->
              enqueue_token(user, :confirm)
              Audit.record(Repo.preload(user, :role), "register", "User", user.id, :success, meta)
              user

            {:error, cs} ->
              Repo.rollback(cs)
          end
        end)
    end
  end

  def authenticate(login, password, meta) when is_binary(login) and is_binary(password) do
    entered_login = login |> String.trim() |> String.slice(0, 254)
    login = String.downcase(entered_login)
    meta = audit_meta(meta)

    # Serialize attempts for an IP. The count is committed on invalid credentials, not rolled back.
    Repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "login:" <> meta.ip
      ])

      subjects = [Jason.encode!([login, meta.ip]), "ip:" <> meta.ip]

      %{rows: blocked_scopes} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT DISTINCT scope FROM rate_limit_counters WHERE scope IN ('login','login_ip') AND subject=ANY($1) AND blocked_until>now() ORDER BY scope",
          [subjects]
        )

      if blocked_scopes != [] do
        Anime.Log.emit(:rate_limited)
        observe_login_limits(blocked_scopes)
        Repo.rollback(:rate_limited)
      end

      RateLimits.consume("login_ip", "ip:" <> meta.ip, [{900, 50}])

      RateLimits.consume("login", Jason.encode!([login, meta.ip]), [
        {900, Anime.Settings.get("security_login_attempts", 5)}
      ])

      user = Repo.get_by(User, email: login) || Repo.get_by(User, nick: login)
      valid = valid_password?(user, password)

      if valid && User.active?(user) do
        RateLimits.reset_login(login, meta.ip)
        # Successful logins do not count toward failed-IP limits.
        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE rate_limit_counters SET count=GREATEST(count-1,0) WHERE scope='login_ip' AND subject=$1 AND window_started_at=to_timestamp(floor(extract(epoch from now())/900)*900) AT TIME ZONE 'UTC'",
          ["ip:" <> meta.ip]
        )

        Audit.record(Repo.preload(user, :role), "login", "User", user.id, :success, meta)
        {:ok, user}
      else
        %{num_rows: blocked_count, rows: activated_scopes} =
          Ecto.Adapters.SQL.query!(
            Repo,
            """
            UPDATE rate_limit_counters SET blocked_until=now()+($3*interval '1 second')
            WHERE ((scope='login' AND subject=$1 AND count >= $4)
               OR (scope='login_ip' AND subject=$2 AND count >= 50))
              AND window_seconds=900
              AND window_started_at=to_timestamp(floor(extract(epoch from now())/900)*900) AT TIME ZONE 'UTC'
            RETURNING scope
            """,
            [
              Jason.encode!([login, meta.ip]),
              "ip:" <> meta.ip,
              Anime.Settings.get("security_login_block_minutes", 15) * 60,
              Anime.Settings.get("security_login_attempts", 5)
            ]
          )

        Audit.record(
          nil,
          "login",
          "User",
          nil,
          :denied,
          Map.put(meta, :actor_label, entered_login)
        )

        if blocked_count > 0 do
          Anime.Log.emit(:rate_limited)
          observe_login_limits(activated_scopes)
          record_login_limit(entered_login, meta)
        end

        {:error, :invalid_credentials}
      end
    end)
    |> unwrap()
    |> then(fn result ->
      # A rejected transaction rolls back its writes. Persist the limit event afterwards.
      if result == {:error, :rate_limited}, do: record_login_limit(entered_login, meta)
      result
    end)
  end

  def authenticate(_, _, _), do: {:error, :invalid_credentials}

  # One observation per distinct triggered limit, not per matching window or
  # failed audit write. Two simultaneous limits legitimately affect two series.
  defp observe_login_limits(rows) do
    rows
    |> Enum.uniq()
    |> Enum.each(fn [scope] ->
      :telemetry.execute([:anime, :rate_limit, :rejected], %{count: 1}, %{scope: scope})
    end)
  end

  def valid_password?(%User{hashed_password: hash}, p)
      when is_binary(hash) and is_binary(p) and byte_size(p) <= 72,
      do: Bcrypt.verify_pass(p, hash)

  def valid_password?(_, _),
    do:
      (
        Bcrypt.no_user_verify()
        false
      )

  def create_session(user, remember, meta) do
    Repo.transaction(fn ->
      fresh = Repo.one!(from u in User, where: u.id == ^user.id, lock: "FOR UPDATE")
      unless User.active?(fresh), do: Repo.rollback(:forbidden)

      {Tokens.issue(fresh, :session, meta),
       if(remember, do: Tokens.issue(fresh, :remember_me, meta))}
    end)
  end

  def restore_session(remember_token, meta) do
    Repo.transaction(fn ->
      token = Tokens.find(remember_token, [:remember_me])
      unless token, do: Repo.rollback(:invalid_session)
      u = lock_active!(token.user_id)

      # Revocation may have committed while this request waited for the account lock.
      current = Tokens.find(remember_token, [:remember_me])
      unless current && current.user_id == u.id, do: Repo.rollback(:invalid_session)

      current
      |> Ecto.Changeset.change(last_used_at: DateTime.utc_now())
      |> Repo.update!()

      Tokens.issue(u, :session, meta)
    end)
  end

  def logout(session_token, remember_token, meta \\ %{}) do
    Repo.transaction(fn ->
      token =
        Tokens.find(session_token, [:session]) || Tokens.find(remember_token, [:remember_me])

      if token do
        u = Repo.one(from u in User, where: u.id == ^token.user_id, lock: "FOR UPDATE")

        # Recheck under the same account lock as session creation/revocation. Never revoke
        # a remember-me credential belonging to a different account in a stale browser.
        ids =
          [Tokens.find(session_token, [:session]), Tokens.find(remember_token, [:remember_me])]
          |> Enum.filter(&(&1 && u && &1.user_id == u.id))
          |> Enum.map(& &1.id)

        if ids != [] do
          Repo.delete_all(from t in UserToken, where: t.id in ^ids and t.user_id == ^u.id)
          Audit.record(Repo.preload(u, :role), "logout", "User", u.id, :success, audit_meta(meta))
          u
        end
      end
    end)
    |> disconnect_result()
  end

  def request_reset(email, meta \\ %{})

  def request_reset(email, meta) when is_binary(email) do
    email = email |> String.trim() |> String.downcase() |> String.slice(0, 254)

    result =
      Repo.transaction(fn ->
        RateLimits.consume("password_reset", "email:" <> email, [{60, 1}, {86400, 5}])

        if user = Repo.get_by(User, email: email) do
          if User.active?(user), do: enqueue_token(user, :reset_password)
        end

        # This is an anonymous request, not proof of the account's identity. Keep the
        # same audit shape for existing, blocked and unknown addresses; never store the email.
        Audit.record(nil, "password_reset_request", "User", nil, :success, audit_meta(meta))
        :ok
      end)

    if result == {:error, :rate_limited},
      do: Audit.record(nil, "password_reset_request", "User", nil, :denied, audit_meta(meta))

    :ok
  end

  def request_reset(_, _), do: :ok

  def confirm(raw, meta \\ %{}) do
    case Tokens.find(raw, [:change_email]) do
      nil -> confirm_registration(raw, meta)
      _ -> Anime.Accounts.Lifecycle.confirm_email_change(raw, meta)
    end
  end

  defp confirm_registration(raw, meta) do
    Repo.transaction(fn ->
      token = Tokens.find(raw, [:confirm]) || Repo.rollback(:invalid_token)
      u = Repo.one!(from u in User, where: u.id == ^token.user_id, lock: "FOR UPDATE")

      unless User.active?(u) && u.email == token.sent_to && Tokens.find(raw, [:confirm]),
        do: Repo.rollback(:invalid_token)

      user = u |> Ecto.Changeset.change(email_confirmed_at: DateTime.utc_now()) |> Repo.update!()
      Repo.delete_all(from t in UserToken, where: t.user_id == ^u.id and t.context == :confirm)
      Audit.record(Repo.preload(u, :role), "email_confirm", "User", u.id, :success, meta)
      user
    end)
  end

  def resend(user) do
    Repo.transaction(fn ->
      u = lock_active!(user.id)
      RateLimits.consume("confirm_resend", "user:" <> to_string(u.id), [{60, 1}, {86400, 5}])
      if is_nil(u.email_confirmed_at), do: enqueue_token(u, :confirm)
      :ok
    end)
  end

  def reset_password(raw, attrs, meta \\ %{}) do
    result =
      Repo.transaction(fn ->
        token = Tokens.find(raw, [:reset_password]) || Repo.rollback(:invalid_token)
        u = lock_active!(token.user_id)

        unless Tokens.find(raw, [:reset_password]) && token.sent_to == u.email,
          do: Repo.rollback(:invalid_token)

        change_password!(u, attrs, nil, meta)
      end)

    disconnect_result(result)
  end

  def change_password(actor, current, attrs, keep_session \\ nil, meta \\ %{}) do
    result =
      Repo.transaction(fn ->
        u = lock_active!(actor.id)
        unless valid_password?(u, current), do: Repo.rollback(:invalid_password)
        change_password!(u, attrs, keep_session, meta)
      end)

    disconnect_result(result)
  end

  defp change_password!(u, attrs, keep_session, meta) do
    cs = User.password_changeset(u, attrs)
    if valid_password?(u, Map.get(attrs, "password")), do: Repo.rollback(:same_password)

    case cs
         |> User.hash_password()
         |> Ecto.Changeset.put_change(:must_change_password, false)
         |> Repo.update() do
      {:ok, updated} ->
        keep = Tokens.find(keep_session, [:session])
        query = from t in UserToken, where: t.user_id == ^u.id

        query =
          if keep && keep.user_id == u.id,
            do: from(t in query, where: t.id != ^keep.id),
            else: query

        Repo.delete_all(query)

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM rate_limit_counters WHERE scope='login' AND (subject::jsonb->>0 = $1 OR subject::jsonb->>0 = $2)",
          [String.downcase(u.email), String.downcase(u.nick)]
        )

        event =
          Audit.record(
            Repo.preload(u, :role),
            "password_change",
            "User",
            u.id,
            :success,
            audit_meta(meta)
          )

        %{
          user_id: u.id,
          audit_id: event.id,
          kind: "password_changed",
          locale: to_string(u.locale)
        }
        |> Anime.Workers.Mail.new()
        |> Oban.insert!()

        updated

      {:error, cs} ->
        Repo.rollback(cs)
    end
  end

  def update_preferences(actor, attrs, meta \\ %{}) do
    Repo.transaction(fn ->
      u = lock_active!(actor.id)

      cs =
        u
        |> Ecto.Changeset.cast(attrs, [:locale, :show_bookmarks_public])
        |> Ecto.Changeset.validate_required([:locale, :show_bookmarks_public])

      case Repo.update(cs) do
        {:ok, updated} ->
          for {field, action} <- [
                locale: "locale_change",
                show_bookmarks_public: "preferences_change"
              ],
              Map.has_key?(cs.changes, field) do
            Audit.record(
              Repo.preload(u, :role),
              action,
              "User",
              u.id,
              :success,
              Map.merge(audit_meta(meta), %{
                old_value: %{field => Map.fetch!(u, field)},
                new_value: %{field => Map.fetch!(updated, field)}
              })
            )
          end

          updated

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  end

  # Only the public projection leaves this boundary, including for staff viewers.
  def public_profile(nick, viewer \\ nil) when is_binary(nick) do
    query = from u in User, where: u.nick == ^nick

    query =
      if Anime.Access.allowed?(viewer, "users.user.view"),
        do: query,
        else: from(u in query, where: u.status == :active and not u.deletion_requested)

    Repo.one(
      from u in query,
        join: r in assoc(u, :role),
        select: %{
          nick: u.nick,
          registered_at: u.inserted_at,
          show_bookmarks_public: u.show_bookmarks_public,
          restricted: u.status != :active or u.deletion_requested,
          role_badge: fragment("CASE WHEN ? THEN ? ELSE NULL END", r.show_badge, r.name)
        }
    )
  end

  def sessions(actor, current_token \\ nil) do
    current = Tokens.find(current_token, [:session])
    current_id = if current && current.user_id == actor.id, do: current.id

    if User.active?(Repo.get(User, actor.id)) do
      Repo.all(
        from t in UserToken,
          where:
            t.user_id == ^actor.id and t.context in [:session, :remember_me] and
              t.expires_at > ^DateTime.utc_now(),
          order_by: [desc: t.inserted_at, desc: t.id],
          select: %{
            id: t.id,
            context: t.context,
            ip: t.ip,
            user_agent: t.user_agent,
            last_used_at: t.last_used_at,
            inserted_at: t.inserted_at
          }
      )
      |> Enum.map(&Map.put(&1, :current?, &1.id == current_id))
    else
      []
    end
  end

  def revoke_session(actor, id, meta \\ %{}) do
    result =
      Repo.transaction(fn ->
        u = lock_active!(actor.id)

        {count, _} =
          Repo.delete_all(
            from t in UserToken,
              where: t.user_id == ^u.id and t.id == ^id and t.context in [:session, :remember_me]
          )

        if count > 0 do
          Audit.record(Repo.preload(u, :role), "session_revoke", "UserToken", id, :success, meta)
        end

        u
      end)

    disconnect_result(result)
  end

  def revoke_other_sessions(actor, current_token, meta \\ %{}) do
    Repo.transaction(fn ->
      u = lock_active!(actor.id)
      current = Tokens.find(current_token, [:session])

      unless current && current.user_id == u.id, do: Repo.rollback(:invalid_session)

      # Remember-me credentials must not be able to resurrect revoked sessions.
      {count, _} =
        Repo.delete_all(
          from t in UserToken,
            where:
              t.user_id == ^u.id and t.context in [:session, :remember_me] and t.id != ^current.id
        )

      if count > 0 do
        Audit.record(
          Repo.preload(u, :role),
          "session_revoke_others",
          "User",
          u.id,
          :success,
          Map.put(meta, :new_value, %{revoked_count: count})
        )
      end

      u
    end)
    |> disconnect_result()
  end

  defp disconnect_result({:ok, %User{} = u} = result) do
    Phoenix.PubSub.broadcast(Anime.PubSub, "user:#{u.id}:access", :access_changed)
    result
  end

  defp disconnect_result(result), do: result

  defp audit_meta(meta), do: Map.take(meta, [:ip])

  defp record_login_limit(login, meta) do
    Audit.record(
      nil,
      "login_rate_limited",
      "User",
      nil,
      :denied,
      Map.put(meta, :actor_label, login)
    )
  end

  def lock_active!(id) do
    u = Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE")
    unless User.active?(u), do: Repo.rollback(:forbidden)
    u
  end

  defp enqueue_token(user, context) do
    %{token_id: id} = Tokens.issue(user, context)
    %{token_id: id, locale: to_string(user.locale)} |> Anime.Workers.Mail.new() |> Oban.insert!()
  end

  def nick_taken?(nick),
    do: Repo.exists?(from u in User, where: u.nick == ^nick or u.previous_nick == ^nick)

  def nick_lock(nick),
    do:
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "nick:" <> String.downcase(nick)
      ])

  defp unwrap({:ok, value}), do: value
  defp unwrap(other), do: other

  defp mx_valid?(email) do
    if Application.get_env(:anime, :mx_lookup, true) do
      Anime.Accounts.EmailDomain.valid?(email)
    else
      true
    end
  end
end
