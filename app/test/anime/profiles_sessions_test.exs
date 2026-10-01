defmodule Anime.ProfilesSessionsTest do
  use Anime.DataCase
  alias Anime.Accounts
  alias Anime.Accounts.{Tokens, UserToken}

  test "public projection is an allowlist, including for privileged viewers" do
    u = user()
    profile = Accounts.public_profile(String.upcase(u.nick))

    assert Enum.sort(Map.keys(profile)) ==
             Enum.sort([:nick, :registered_at, :show_bookmarks_public, :restricted, :role_badge])

    assert profile.nick == u.nick
    assert profile.registered_at == u.inserted_at
    assert profile.role_badge == nil
    refute profile.restricted
    assert Accounts.public_profile("missing_reader") == nil

    staff = role_user("comment_moderator")
    assert Accounts.public_profile(staff.nick).role_badge == staff.role.name
    assert Accounts.public_profile(u.nick, staff) == profile
  end

  test "hidden profiles require fresh permission, not a stale privileged actor" do
    target = user()
    viewer = role_user("comment_moderator")
    Repo.update!(Ecto.Changeset.change(target, status: :blocked))
    refute Accounts.public_profile(target.nick)
    assert Accounts.public_profile(target.nick, viewer).restricted
    Repo.update!(Ecto.Changeset.change(viewer, role_id: target.role_id))
    refute Accounts.public_profile(target.nick, viewer)

    Repo.update!(Ecto.Changeset.change(target, status: :active, deletion_requested: true))
    refute Accounts.public_profile(target.nick)
  end

  test "bookmark visibility is read fresh and cannot enable other private fields" do
    u = user()
    assert {:ok, _} = Accounts.update_preferences(u, %{"show_bookmarks_public" => "false"})
    refute Accounts.public_profile(u.nick).show_bookmarks_public
    assert {:ok, _} = Accounts.update_preferences(u, %{"show_bookmarks_public" => "true"})
    assert Accounts.public_profile(u.nick).show_bookmarks_public
  end

  test "session listing excludes expired, confirmation, foreign and revoked sessions" do
    u = user()
    other = user()
    {:ok, {current, remember}} = Accounts.create_session(u, true, meta())
    {:ok, {expired, _}} = Accounts.create_session(u, false, meta())
    {:ok, {foreign, _}} = Accounts.create_session(other, false, meta())

    Tokens.find(expired, [:session])
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    sessions = Accounts.sessions(u, current)
    assert length(sessions) == 2
    assert Enum.count(sessions, & &1.current?) == 1
    assert Enum.find(sessions, & &1.current?).id == Tokens.find(current, [:session]).id
    assert Enum.any?(sessions, &(&1.id == Tokens.find(remember, [:remember_me]).id))
    refute Enum.any?(Accounts.sessions(u, foreign), & &1.current?)
    refute Enum.any?(Accounts.sessions(u, remember), & &1.current?)
    refute Enum.any?(sessions, &Map.has_key?(&1, :token))

    Tokens.revoke(current)
    refute Enum.any?(Accounts.sessions(u, current), & &1.current?)
    Repo.update!(Ecto.Changeset.change(u, status: :blocked))
    assert Accounts.sessions(u, current) == []
  end

  test "bulk revoke preserves exactly current session, mail tokens and other users" do
    u = user()
    other = user()
    {:ok, {current, remember}} = Accounts.create_session(u, true, meta())
    {:ok, {remote, remote_remember}} = Accounts.create_session(u, true, meta())
    {:ok, {foreign, _}} = Accounts.create_session(other, false, meta())

    confirmation =
      Repo.one!(from t in UserToken, where: t.user_id == ^u.id and t.context == :confirm)

    Phoenix.PubSub.subscribe(Anime.PubSub, "user:#{u.id}:access")

    assert {:ok, _} = Accounts.revoke_other_sessions(u, current, meta())
    assert_receive :access_changed
    assert Tokens.user(current).id == u.id
    assert Tokens.user(foreign).id == other.id
    refute Tokens.user(remote)
    refute Tokens.find(remember, [:remember_me])
    refute Tokens.find(remote_remember, [:remember_me])
    assert Repo.get(UserToken, confirmation.id)
    assert length(Accounts.sessions(u, current)) == 1
    audit = Repo.one!(from a in Anime.Audit, where: a.action == "session_revoke_others")
    assert audit.new_value == %{"revoked_count" => 3}
    refute Jason.encode!(audit.new_value) =~ current
  end

  test "bulk revoke rejects missing, expired, remember-me and foreign keep tokens atomically" do
    u = user()
    other = user()
    {:ok, {current, remember}} = Accounts.create_session(u, true, meta())
    {:ok, {foreign, _}} = Accounts.create_session(other, false, meta())
    {:ok, {expired, _}} = Accounts.create_session(u, false, meta())

    Tokens.find(expired, [:session])
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    for raw <- [nil, "bad", foreign, remember, expired] do
      assert {:error, :invalid_session} = Accounts.revoke_other_sessions(u, raw)
      assert Tokens.user(current)
      assert Tokens.find(remember, [:remember_me])
    end

    assert Repo.aggregate(
             from(a in Anime.Audit, where: a.action == "session_revoke_others"),
             :count
           ) == 0

    Repo.update!(Ecto.Changeset.change(u, deletion_requested: true))
    assert {:error, :forbidden} = Accounts.revoke_other_sessions(u, current)
  end

  test "single revocation checks ownership and context, audits only actual changes" do
    u = user()
    other = user()
    {:ok, {own, _}} = Accounts.create_session(u, false, meta())
    {:ok, {foreign, _}} = Accounts.create_session(other, false, meta())

    confirmation =
      Repo.one!(from t in UserToken, where: t.user_id == ^u.id and t.context == :confirm)

    assert {:ok, _} = Accounts.revoke_session(u, Tokens.find(foreign, [:session]).id)
    assert {:ok, _} = Accounts.revoke_session(u, confirmation.id)
    assert Tokens.user(foreign)
    assert Repo.get(UserToken, confirmation.id)

    assert Repo.aggregate(from(a in Anime.Audit, where: a.action == "session_revoke"), :count) ==
             0

    assert {:ok, _} = Accounts.revoke_session(u, Tokens.find(own, [:session]).id, meta())
    refute Tokens.user(own)

    assert Repo.aggregate(from(a in Anime.Audit, where: a.action == "session_revoke"), :count) ==
             1
  end

  test "remember-me restoration records use without renewing its expiry and rejects revocation" do
    u = user()
    {:ok, {current, remember}} = Accounts.create_session(u, true, meta())
    token = Tokens.find(remember, [:remember_me])
    assert {:ok, restored} = Accounts.restore_session(remember, meta())
    assert Tokens.user(restored).id == u.id
    used = Tokens.find(remember, [:remember_me])
    assert used.expires_at == token.expires_at
    assert DateTime.compare(used.last_used_at, token.last_used_at) in [:eq, :gt]
    assert {:error, :invalid_session} = Accounts.restore_session(current, meta())
    assert {:ok, _} = Accounts.revoke_other_sessions(u, current)
    assert {:error, :invalid_session} = Accounts.restore_session(remember, meta())
    assert length(Accounts.sessions(u)) == 1
  end
end
