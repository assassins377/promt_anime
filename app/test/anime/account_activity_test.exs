defmodule Anime.AccountActivityTest do
  use Anime.DataCase
  alias Anime.{Accounts, Audit}
  alias Anime.Accounts.{Activity, Tokens, User, UserToken}

  @ip "203.0.113.26"
  @meta %{ip: @ip, old_value: %{password: "must-not-be-stored"}, new_value: %{token: "secret"}}
  @password %{"password" => "ChangedExample456", "password_confirmation" => "ChangedExample456"}

  defp events(action), do: Repo.all(from a in Audit, where: a.action == ^action, order_by: a.id)

  defp assert_private(event) do
    assert event.ip == @ip
    assert event.old_value == nil
    assert event.new_value == nil
  end

  test "login records identity only after authentication and keeps failure shapes uniform" do
    u = user()
    assert {:ok, _} = Accounts.authenticate(u.email, "InitialExample123", @meta)
    [success] = events("login")

    assert {success.user_id, success.actor_label, success.role_code, success.result} ==
             {u.id, u.nick, "user", :success}

    assert success.object_id == to_string(u.id)
    assert_private(success)

    for login <- [String.upcase(u.email), "UNKNOWN@example.com"] do
      assert {:error, :invalid_credentials} = Accounts.authenticate(login, "bad", @meta)
      entry = List.last(events("login"))
      assert entry.actor_label == login

      assert {entry.user_id, entry.object_id, entry.role_code, entry.result} ==
               {nil, nil, nil, :denied}

      assert_private(entry)
    end

    assert events("login_rate_limited") == []
  end

  test "limit onset and rejected retries are retained without changing the lockout deadline" do
    u = user()
    for _ <- 1..5, do: Accounts.authenticate(u.nick, "bad", @meta)
    [limit] = events("login_rate_limited")
    assert_private(limit)
    assert limit.actor_label == u.nick
    assert limit.user_id == nil
    assert limit.result == :denied

    before =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count,blocked_until FROM rate_limit_counters WHERE scope='login' AND subject=$1",
        [Jason.encode!([u.nick, @ip])]
      ).rows

    assert {:error, :rate_limited} = Accounts.authenticate(u.nick, "InitialExample123", @meta)
    assert length(events("login_rate_limited")) == 2
    assert length(events("login")) == 5

    assert Ecto.Adapters.SQL.query!(
             Repo,
             "SELECT count,blocked_until FROM rate_limit_counters WHERE scope='login' AND subject=$1",
             [Jason.encode!([u.nick, @ip])]
           ).rows == before
  end

  test "the aggregate IP limit also produces a denied audit entry" do
    Repo.transaction(fn -> Anime.RateLimits.consume("login_ip", "ip:" <> @ip, [{900, 50}]) end)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE rate_limit_counters SET count=49 WHERE scope='login_ip' AND subject=$1",
      ["ip:" <> @ip]
    )

    assert {:error, :invalid_credentials} = Accounts.authenticate("unknown", "bad", @meta)
    assert length(events("login_rate_limited")) == 1
    assert {:error, :rate_limited} = Accounts.authenticate("another", "bad", @meta)
    assert length(events("login_rate_limited")) == 2
  end

  test "logout revokes only this browser's credentials and is idempotent" do
    u = user()
    {:ok, {current, remember}} = Accounts.create_session(u, true, meta())
    {:ok, {other, other_remember}} = Accounts.create_session(u, true, meta())
    Phoenix.PubSub.subscribe(Anime.PubSub, "user:#{u.id}:access")
    assert {:ok, _} = Accounts.logout(current, remember, @meta)
    assert_receive :access_changed
    refute Tokens.find(current, [:session])
    refute Tokens.find(remember, [:remember_me])
    assert Tokens.find(other, [:session])
    assert Tokens.find(other_remember, [:remember_me])
    assert Repo.exists?(from t in UserToken, where: t.user_id == ^u.id and t.context == :confirm)
    [entry] = events("logout")
    assert {entry.user_id, entry.actor_label, entry.role_code} == {u.id, u.nick, "user"}
    assert_private(entry)
    assert {:ok, nil} = Accounts.logout(current, remember, @meta)
    assert events("logout") == [entry]
    refute_receive :access_changed
  end

  test "logout ignores foreign remember credentials and mail tokens" do
    u = user()
    other = user()
    {:ok, {current, _}} = Accounts.create_session(u, false, meta())
    {:ok, {other_session, other_remember}} = Accounts.create_session(other, true, meta())
    assert {:ok, _} = Accounts.logout(current, other_remember, @meta)
    assert Tokens.user(other_session)
    assert Tokens.find(other_remember, [:remember_me])
    mail = Tokens.issue(u, :reset_password)
    assert {:ok, nil} = Accounts.logout(mail.raw, mail.raw, @meta)
    assert Tokens.find(mail.raw, [:reset_password])
    assert {:ok, nil} = Accounts.logout("malformed", nil, @meta)
    assert length(events("logout")) == 1
  end

  test "logout accepts remember-only credentials and ignores expired sessions" do
    u = user()
    {:ok, {current, remember}} = Accounts.create_session(u, true, meta())

    Tokens.find(current, [:session])
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:ok, nil} = Accounts.logout(current, nil, @meta)
    assert events("logout") == []
    assert {:ok, _} = Accounts.logout(current, remember, @meta)
    assert length(events("logout")) == 1
    refute Tokens.find(remember, [:remember_me])
  end

  test "reset requests cannot be attributed to an account merely by knowing its email" do
    active = user()
    blocked = user() |> Ecto.Changeset.change(status: :blocked) |> Repo.update!()

    for email <- [active.email, blocked.email, "unknown@example.com"] do
      assert :ok = Accounts.request_reset(email, @meta)
    end

    assert length(events("password_reset_request")) == 3

    for entry <- events("password_reset_request") do
      assert {entry.user_id, entry.actor_label, entry.role_code, entry.object_id, entry.result} ==
               {nil, "guest", nil, nil, :success}

      assert_private(entry)
    end

    assert Repo.aggregate(from(t in UserToken, where: t.context == :reset_password), :count) == 1
    assert :ok = Accounts.request_reset(active.email, @meta)
    assert List.last(events("password_reset_request")).result == :denied
    assert Repo.aggregate(from(t in UserToken, where: t.context == :reset_password), :count) == 1
  end

  test "password reset audit commits with the change, has IP and cannot be replayed" do
    u = user()
    %{raw: raw} = Tokens.issue(u, :reset_password)
    assert {:error, _} = Accounts.reset_password(raw, %{"password" => "bad"}, @meta)
    assert events("password_change") == []
    assert Tokens.find(raw, [:reset_password])
    assert {:ok, _} = Accounts.reset_password(raw, @password, @meta)
    [entry] = events("password_change")
    assert {entry.user_id, entry.role_code, entry.result} == {u.id, "user", :success}
    assert_private(entry)
    assert {:error, :invalid_token} = Accounts.reset_password(raw, @password, @meta)
    assert events("password_change") == [entry]
  end

  test "authenticated password change retains the current session but not password values in audit" do
    u = user()
    {:ok, {current, remember}} = Accounts.create_session(u, true, meta())

    assert {:error, :invalid_password} =
             Accounts.change_password(u, "bad", @password, current, @meta)

    assert events("password_change") == []
    assert {:ok, _} = Accounts.change_password(u, "InitialExample123", @password, current, @meta)
    assert Tokens.user(current)
    refute Tokens.find(remember, [:remember_me])
    [entry] = events("password_change")
    assert_private(entry)
  end

  test "preferences audit contains only changed allowed fields, not submitted attributes" do
    u = user()

    attrs = %{
      "locale" => "en",
      "show_bookmarks_public" => "false",
      "hashed_password" => "leak",
      "role_id" => 99
    }

    assert {:ok, updated} = Accounts.update_preferences(u, attrs, @meta)
    assert updated.role_id == u.role_id
    [language] = events("locale_change")
    [privacy] = events("preferences_change")
    assert language.old_value == %{"locale" => "ru"}
    assert language.new_value == %{"locale" => "en"}
    assert privacy.old_value == %{"show_bookmarks_public" => true}
    assert privacy.new_value == %{"show_bookmarks_public" => false}
    assert language.ip == @ip
    assert privacy.ip == @ip
    assert language.role_code == "user"
    assert {:ok, _} = Accounts.update_preferences(u, attrs, @meta)
    assert events("locale_change") == [language]
    assert events("preferences_change") == [privacy]
    assert {:error, _} = Accounts.update_preferences(u, %{"locale" => "invalid"}, @meta)
    assert {:error, _} = Accounts.update_preferences(u, %{"locale" => nil}, @meta)
    assert events("locale_change") == [language]
    assert Repo.get!(User, u.id).locale == :en
  end

  test "the activity allowlist includes new real events without full values" do
    owner = role_user("owner")

    Accounts.update_preferences(
      owner,
      %{"locale" => "en", "show_bookmarks_public" => "false"},
      @meta
    )

    Accounts.request_reset(owner.email, @meta)
    {:ok, {raw, remember}} = Accounts.create_session(owner, true, meta())
    Accounts.logout(raw, remember, @meta)
    for _ <- 1..5, do: Accounts.authenticate(owner.email, "bad", @meta)

    actions =
      ~w(logout login_rate_limited password_reset_request locale_change preferences_change)

    for action <- actions do
      assert {:ok, page} = Activity.list(owner, %{"action" => [action]})
      assert page.count == 1
      [row] = page.rows
      assert row.action == action
      refute Map.has_key?(row, :old_value)
      refute Map.has_key?(row, :new_value)
    end
  end
end
