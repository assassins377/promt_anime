defmodule Anime.AccessTest do
  use Anime.DataCase
  alias Anime.Access
  alias Anime.Access.{Catalog, Role, Permission}

  test "seed is idempotent and all canonical permission sets match" do
    assert length(Catalog.codes()) == 99
    assert Repo.aggregate(Permission, :count) == 99
    assert {:ok, _} = Anime.Seeds.defaults()
    assert Repo.aggregate(Permission, :count) == 99

    for {code, count} <- [
          {"user", 1},
          {"comment_moderator", 17},
          {"content_editor", 38},
          {"admin", 92},
          {"owner", 99}
        ] do
      role = Repo.get_by!(Role, code: code)
      assert length(Access.codes_for_role(role)) == count
    end
  end

  for {code, _} <- Catalog.permissions() do
    test "protected context rejects guest for #{code} before executing" do
      ref = make_ref()

      assert {:error, :forbidden} =
               Access.protect(nil, unquote(code), "Test", nil, fn _ -> send(self(), ref) end)

      refute_received ^ref
    end
  end

  test "owner bypass requires active current user" do
    u = role_user("owner")
    assert Access.allowed?(u, "future.action.allowed")
    Repo.update!(Ecto.Changeset.change(u, status: :blocked))
    refute Access.allowed?(u, "future.action.allowed")

    assert {:error, :forbidden} =
             Access.protect(u, "users.user.edit", "User", 1, fn _ -> :never end)
  end

  test "a deleted owner's stale struct never authorizes or executes a protected operation" do
    owner = role_user("owner")
    Repo.delete!(owner)
    refute Access.allowed?(owner, "users.user.edit")
    assert Access.permissions(owner) == []
    called = make_ref()

    assert {:error, :forbidden} =
             Access.protect(owner, "users.user.edit", "User", nil, fn _ ->
               send(self(), called)
             end)

    refute_received ^called
    assert Repo.aggregate(Anime.Accounts.User, :count) == 0
    audit = Repo.one!(from a in Anime.Audit, where: a.action == "users.user.edit")
    assert audit.result == :denied
    assert audit.user_id == nil
    assert audit.actor_label == "guest"
    assert audit.role_code == nil
    refute inspect(audit) =~ owner.nick
  end

  test "denial audit uses the current account identity, not a stale struct" do
    u = user()
    Repo.update!(Ecto.Changeset.change(u, nick: "renamed_reader"))

    assert {:error, :forbidden} =
             Access.protect(u, "users.user.edit", "User", nil, fn _ -> :never end)

    audit = Repo.one!(from a in Anime.Audit, where: a.action == "users.user.edit")
    assert audit.user_id == u.id
    assert audit.actor_label == "renamed_reader"
    assert audit.role_code == "user"
    assert audit.result == :denied
  end

  test "matrix forbids editing owner and atomically revokes a permission" do
    owner = role_user("owner")
    user_role = Repo.get_by!(Role, code: "user")
    assert {:error, :protected_owner} = Access.update_matrix(owner, owner.role_id, [])

    assert {:error, :unknown_permission} =
             Access.update_matrix(owner, user_role.id, ["made.up.permission"])

    assert Access.codes_for_role(user_role) == ["video.watch.play"]
    assert {:ok, _} = Access.update_matrix(owner, user_role.id, [])
    assert Access.codes_for_role(user_role) == []
  end

  test "ordinary user cannot call matrix function directly" do
    u = user()
    assert {:error, :forbidden} = Access.update_matrix(u, u.role_id, Catalog.codes())
    assert Access.permissions(u) == ["video.watch.play"]
  end
end
