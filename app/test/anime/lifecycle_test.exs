defmodule Anime.LifecycleTest do
  use Anime.DataCase
  import Swoosh.TestAssertions
  alias Anime.{Accounts, Audit}
  alias Anime.Accounts.{User, Tokens, UserToken, Lifecycle}
  @password "InitialExample123"

  defp raw(u, context) do
    t = Repo.one!(from t in UserToken, where: t.user_id == ^u.id and t.context == ^context)
    Base.url_encode64(Tokens.mail_bytes(t), padding: false)
  end

  defp mail_job(u, context) do
    t = Repo.one!(from t in UserToken, where: t.user_id == ^u.id and t.context == ^context)
    Repo.one!(from j in Oban.Job, where: fragment("?->>'token_id'", j.args) == ^to_string(t.id))
  end

  test "nickname change reserves old nickname and cannot bypass cooldown with stale actor" do
    u = user()
    assert {:ok, changed} = Accounts.change_nick(u, %{"nick" => "new_reader"}, meta())
    assert changed.previous_nick == u.nick
    assert DateTime.diff(changed.previous_nick_until, changed.nick_changed_at) == 30 * 86400
    assert {:error, :nick_cooldown} = Accounts.change_nick(u, %{"nick" => "other_reader"})

    assert {:error, %Ecto.Changeset{}} =
             Accounts.register(attrs(%{"nick" => String.upcase(u.nick)}), meta())

    assert {:error, %Ecto.Changeset{}} =
             Accounts.change_nick(user(), %{"nick" => String.upcase(u.nick)})

    assert Repo.get!(User, u.id).nick == "new_reader"
  end

  test "same validation as registration and expired reservation is released by cleanup" do
    u = user()
    assert {:error, %Ecto.Changeset{}} = Accounts.change_nick(u, %{"nick" => "admin"})
    assert {:error, %Ecto.Changeset{}} = Accounts.change_nick(u, %{"nick" => "a!"})
    assert {:ok, changed} = Accounts.change_nick(u, %{"nick" => "next_reader"})

    Repo.update!(
      Ecto.Changeset.change(changed, previous_nick_until: DateTime.add(DateTime.utc_now(), -1))
    )

    assert :ok = Anime.Workers.ExpireAccounts.perform(%{})
    refute Accounts.nick_taken?(u.nick)
  end

  test "email remains unchanged until one-use confirmation, old-address tokens and sessions revoked" do
    u = user()
    {:ok, {session, remember}} = Accounts.create_session(u, true, meta())
    Accounts.request_reset(u.email)
    reset = raw(u, :reset_password)

    assert {:error, :invalid_password} =
             Accounts.request_email_change(u, "bad", %{email: "next@example.com"})

    assert {:ok, _} =
             Accounts.request_email_change(u, @password, %{email: "NEXT@example.com"}, meta())

    assert Repo.get!(User, u.id).email == u.email
    assert Accounts.pending_email(u).sent_to == "next@example.com"
    link = raw(u, :change_email)
    refute Tokens.find(link, [:confirm])
    assert {:ok, changed} = Accounts.confirm(link)
    assert changed.email == "next@example.com"
    assert changed.email_confirmed_at
    refute Tokens.user(session)
    refute Tokens.find(remember, [:remember_me])
    refute Tokens.find(reset, [:reset_password])
    assert {:error, :invalid_token} = Accounts.confirm(link)
    assert {:ok, _} = Accounts.authenticate(changed.email, @password, meta())
  end

  test "email confirmation rechecks uniqueness after another registration" do
    u = user()
    assert {:ok, _} = Accounts.request_email_change(u, @password, %{email: "claimed@example.com"})
    v = user(%{"email" => "claimed@example.com"})
    assert {:error, %Ecto.Changeset{}} = Accounts.confirm(raw(u, :change_email))
    assert Repo.get!(User, u.id).email == u.email
    assert Repo.get!(User, v.id).email == "claimed@example.com"
  end

  test "cancel or resend makes old email link inert, resend is rate limited" do
    u = user()
    {:ok, _} = Accounts.request_email_change(u, @password, %{email: "next@example.com"})
    old = raw(u, :change_email)
    stale_job = mail_job(u, :change_email)
    assert {:error, :rate_limited} = Accounts.resend_email_change(u)

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM rate_limit_counters WHERE scope='confirm_resend' AND subject=$1",
      ["user:#{u.id}"]
    )

    assert {:ok, _} = Accounts.resend_email_change(u)
    assert {:error, :invalid_token} = Accounts.confirm(old)
    current = raw(u, :change_email)
    assert {:ok, _} = Accounts.cancel_email_change(u)
    assert Accounts.pending_email(u) == nil
    assert {:error, :invalid_token} = Accounts.confirm(current)
    assert :ok = Anime.Workers.Mail.perform(stale_job)
    refute_email_sent()
  end

  test "mail recipients: new-address confirmation, old-address notice even after confirmation" do
    u = user()
    {:ok, _} = Accounts.request_email_change(u, @password, %{email: "next@example.com"})
    assert :ok = Anime.Workers.Mail.perform(mail_job(u, :change_email))
    assert_email_sent(to: [{"", "next@example.com"}])
    assert {:ok, _} = Accounts.confirm(raw(u, :change_email))

    notice =
      Repo.one!(
        from j in Oban.Job, where: fragment("?->>'kind'", j.args) == "email_change_notice"
      )

    assert Map.keys(notice.args) |> Enum.sort() == ~w(audit_id kind locale)
    assert :ok = Anime.Workers.Mail.perform(notice)
    assert_email_sent(to: [{"", u.email}])
  end

  test "deletion requires exact nick and password, invalidates sessions, mail still delivered" do
    u = user()
    {:ok, {session, remember}} = Accounts.create_session(u, true, meta())
    assert {:error, :invalid_password} = Accounts.request_deletion(u, "bad", u.nick)
    assert {:error, :nickname_mismatch} = Accounts.request_deletion(u, @password, "someone_else")
    assert {:ok, pending} = Accounts.request_deletion(u, @password, u.nick, meta())
    assert pending.deletion_requested
    refute Tokens.user(session)
    refute Tokens.find(remember, [:remember_me])
    assert {:error, :invalid_credentials} = Accounts.authenticate(u.email, @password, meta())

    assert {:error, :forbidden} =
             Accounts.request_email_change(u, @password, %{email: "other@example.com"})

    job = mail_job(u, :delete_cancel)
    assert :ok = Anime.Workers.Mail.perform(job)
    assert_email_sent(fn email -> email.text_body =~ "/account/restore/" end)
    link = raw(u, :delete_cancel)
    assert {:ok, restored} = Accounts.restore_account(link)
    refute restored.deletion_requested
    assert restored.deletion_requested_at == nil
    refute Tokens.user(session)
    assert {:error, :invalid_token} = Accounts.restore_account(link)
    assert {:ok, _} = Accounts.authenticate(u.email, @password, meta())
  end

  test "last active owner cannot request deletion" do
    owner = role_user("owner")
    assert {:error, :last_owner} = Accounts.request_deletion(owner, @password, owner.nick)
    second = role_user("owner")
    assert {:ok, _} = Accounts.request_deletion(owner, @password, owner.nick)
    assert {:error, :last_owner} = Accounts.request_deletion(second, @password, second.nick)
  end

  test "expired restoration cannot reverse deletion, premature worker is harmless, repeat is idempotent" do
    u = user()
    {:ok, _} = Accounts.request_deletion(u, @password, u.nick)
    link = raw(u, :delete_cancel)
    assert {:ok, :not_due} = Lifecycle.delete_due_account(u.id)
    pending = Repo.get!(User, u.id)

    Repo.update!(
      Ecto.Changeset.change(pending,
        deletion_requested_at: DateTime.add(DateTime.utc_now(), -31 * 86400)
      )
    )

    assert {:error, :invalid_token} = Accounts.restore_account(link)
    assert :ok = Anime.Workers.DeleteAccounts.perform(%{})
    refute Repo.get(User, u.id)
    assert {:ok, :not_due} = Lifecycle.delete_due_account(u.id)

    audits =
      Repo.all(
        from a in Audit, where: a.object_type == "User" and a.object_id == ^to_string(u.id)
      )

    assert length(audits) >= 3
    assert Enum.all?(audits, &is_nil(&1.user_id))
    assert Enum.all?(audits, &Regex.match?(~r/^deleted-[0-9a-f]{8}$/, &1.actor_label))
    assert Repo.aggregate(UserToken, :count) == 0
  end

  test "restoration leaves an administrator block intact and stops a stale cleanup" do
    u = user()
    {:ok, _} = Accounts.request_deletion(u, @password, u.nick)
    link = raw(u, :delete_cancel)
    Repo.update!(Ecto.Changeset.change(Repo.get!(User, u.id), status: :blocked))
    assert {:ok, restored} = Accounts.restore_account(link)
    assert restored.status == :blocked
    assert {:ok, :not_due} = Lifecycle.delete_due_account(u.id)
    assert {:error, :invalid_credentials} = Accounts.authenticate(u.email, @password, meta())
  end

  test "unexpected avatar blocks only its owner's cleanup" do
    u = user()
    v = user()

    for account <- [u, v] do
      {:ok, _} = Accounts.request_deletion(account, @password, account.nick)

      Repo.update!(
        Ecto.Changeset.change(Repo.get!(User, account.id),
          deletion_requested_at: DateTime.add(DateTime.utc_now(), -31 * 86400)
        )
      )
    end

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(User, u.id), avatar_key_320: "avatars/test-only")
    )

    assert {:error, :cleanup_incomplete} = Anime.Workers.DeleteAccounts.perform(%{})
    assert Repo.get!(User, u.id)
    refute Repo.get(User, v.id)
  end

  test "blocked or password-gated stale actor cannot change identity" do
    u = user()
    Repo.update!(Ecto.Changeset.change(u, must_change_password: true))
    assert {:error, :password_change_required} = Accounts.change_nick(u, %{nick: "changed_nick"})
    Repo.update!(Ecto.Changeset.change(Repo.get!(User, u.id), status: :blocked))
    assert {:error, :forbidden} = Accounts.change_nick(u, %{nick: "changed_nick"})
  end
end
