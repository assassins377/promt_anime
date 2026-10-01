defmodule Anime.AccountsTest do
  use Anime.DataCase
  alias Anime.Accounts
  alias Anime.Accounts.{User, UserToken, Tokens}

  test "registration stores bcrypt and consent, never plaintext credentials" do
    u = user()
    assert u.password == nil
    assert Bcrypt.verify_pass("InitialExample123", u.hashed_password)
    assert u.consent_version == "2026-01-01"
    assert u.role.code == "user"
    assert u.email_confirmed_at == nil
    assert Repo.aggregate(Oban.Job, :count) == 1
    job = Repo.one!(Oban.Job)
    assert Map.keys(job.args) |> Enum.sort() == ~w(locale token_id)
  end

  test "email and nick are case insensitive, role cannot be supplied" do
    first = user(%{"email" => "TeSt@example.com", "nick" => "ReaderName", "role_id" => "5"})
    assert first.email == "test@example.com"
    assert first.role.code == "user"

    assert {:error, %Ecto.Changeset{}} =
             Accounts.register(attrs(%{"email" => "TEST@example.com"}), meta())

    assert {:error, %Ecto.Changeset{}} =
             Accounts.register(attrs(%{"nick" => "readername"}), meta())
  end

  for {key, value} <- [
        {"nick", "admin"},
        {"password", "12345"},
        {"password", "Onlyletterslong"},
        {"consent", "false"},
        {"email", "bad"}
      ] do
    test "invalid registration #{key}=#{value} is rejected" do
      assert {:error, %Ecto.Changeset{}} =
               Accounts.register(attrs(%{unquote(key) => unquote(value)}), meta())

      assert Repo.aggregate(User, :count) == 0
    end
  end

  test "byte limit protects bcrypt from truncating unicode" do
    a =
      attrs(%{
        "password" => String.duplicate("я", 40) <> "1",
        "password_confirmation" => String.duplicate("я", 40) <> "1"
      })

    refute User.registration_changeset(%User{}, a).valid?
  end

  test "registration disabled rejects direct context call" do
    Repo.get_by!(Anime.Settings.Setting, key: "registration_enabled")
    |> Ecto.Changeset.change(value: "false")
    |> Repo.update!()

    assert {:error, :registration_disabled} = Accounts.register(attrs(), meta())
  end

  test "authentication supports nickname and email and counts failed attempts" do
    u = user()
    assert {:ok, _} = Accounts.authenticate(String.upcase(u.nick), "InitialExample123", meta())
    assert {:ok, _} = Accounts.authenticate(u.email, "InitialExample123", meta())

    for _ <- 1..5,
        do: assert({:error, :invalid_credentials} = Accounts.authenticate(u.email, "bad", meta()))

    assert {:error, :rate_limited} = Accounts.authenticate(u.email, "InitialExample123", meta())
  end

  test "blocked user cannot sign in, even owner" do
    u = role_user("owner")
    Repo.update!(Ecto.Changeset.change(u, status: :blocked))

    assert {:error, :invalid_credentials} =
             Accounts.authenticate(u.email, "InitialExample123", meta())

    assert {:error, :forbidden} = Accounts.create_session(u, false, meta())
  end

  test "an expired login block is not extended by counters from an old window" do
    u = user()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO rate_limit_counters
        (scope, subject, window_seconds, window_started_at, count, blocked_until, inserted_at, updated_at)
      VALUES ('login', $1, 900,
        (to_timestamp(floor(extract(epoch from now())/900)*900) AT TIME ZONE 'UTC') - interval '1 hour',
        5, now() - interval '1 minute', now(), now())
      """,
      [Jason.encode!([u.email, meta().ip])]
    )

    for _ <- 1..2 do
      assert {:error, :invalid_credentials} = Accounts.authenticate(u.email, "bad", meta())
    end

    assert {:ok, _} = Accounts.authenticate(u.email, "InitialExample123", meta())
  end

  test "session hash differs from bearer; expiry and revocation checked" do
    u = user()
    {:ok, {raw, remember}} = Accounts.create_session(u, true, meta())
    t = Tokens.find(raw, [:session])
    assert byte_size(t.token) == 32
    refute t.token == raw
    assert Tokens.user(raw).id == u.id
    assert Tokens.find(remember, [:remember_me])
    Repo.update!(Ecto.Changeset.change(t, expires_at: DateTime.add(DateTime.utc_now(), -1)))
    refute Tokens.user(raw)
    Tokens.revoke(remember)
    refute Tokens.find(remember, [:remember_me])
  end

  test "confirmation is purpose bound, one-use, and matches current email" do
    u = user()
    t = Repo.one!(from t in UserToken, where: t.user_id == ^u.id and t.context == :confirm)
    raw = Base.url_encode64(Tokens.mail_bytes(t), padding: false)
    refute Tokens.find(raw, [:reset_password])
    assert {:ok, confirmed} = Accounts.confirm(raw)
    assert confirmed.email_confirmed_at
    assert {:error, :invalid_token} = Accounts.confirm(raw)
  end

  test "reset password revokes all sessions and cannot be replayed" do
    u = user()
    {:ok, {raw, remember}} = Accounts.create_session(u, true, meta())
    :ok = Accounts.request_reset(u.email)

    token =
      Repo.one!(from t in UserToken, where: t.user_id == ^u.id and t.context == :reset_password)

    reset = Base.url_encode64(Tokens.mail_bytes(token), padding: false)
    attrs = %{"password" => "ChangedExample456", "password_confirmation" => "ChangedExample456"}
    assert {:ok, _} = Accounts.reset_password(reset, attrs)
    refute Tokens.user(raw)
    refute Tokens.find(remember, [:remember_me])
    assert {:error, :invalid_token} = Accounts.reset_password(reset, attrs)
    assert {:ok, _} = Accounts.authenticate(u.email, "ChangedExample456", meta())
  end

  test "mail job reconstructs token but drops consumed token" do
    u = user()
    job = Repo.one!(Oban.Job)
    assert :ok = Anime.Workers.Mail.perform(job)
    token = Repo.get!(UserToken, job.args["token_id"])
    Accounts.confirm(Base.url_encode64(Tokens.mail_bytes(token), padding: false))
    assert :ok = Anime.Workers.Mail.perform(job)
    assert Repo.get!(User, u.id).email_confirmed_at
  end

  test "foreign session cannot be revoked" do
    u = user()
    v = user()
    {:ok, {raw, _}} = Accounts.create_session(v, false, meta())
    token = Tokens.find(raw, [:session])
    assert {:ok, _} = Accounts.revoke_session(u, token.id)
    assert Tokens.user(raw).id == v.id
  end

  test "fixed windows of different lengths have distinct rows" do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Anime.RateLimits.consume("register", "ip:198.51.100.5", [{3600, 3}, {86400, 10}])
             end)

    %{rows: [[n]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(*) FROM rate_limit_counters WHERE subject=$1",
        ["ip:198.51.100.5"]
      )

    assert n == 2
  end
end
