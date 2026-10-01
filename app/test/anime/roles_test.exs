defmodule Anime.RolesTest do
  use Anime.DataCase
  alias Anime.{Access, Seeds, Audit}
  alias Anime.Access.{Roles, Role, Permission, RolePermission, Catalog}
  alias Anime.Settings.Setting

  test "seed preserves revoked system grants, added grants, names, badges and default choice" do
    owner = role_user("owner")
    r = Repo.get_by!(Role, code: "user")
    assert {:ok, _} = Roles.update_matrix(owner, r.id, ["admin.panel.access"])
    assert {:ok, _} = Roles.edit(owner, r.id, %{name: "Readers", show_badge: true})
    {:ok, id} = Roles.create(owner, %{code: "newcomer", name: "Newcomer"})
    assert {:ok, _} = Roles.default(owner, id)
    assert {:ok, _} = Seeds.defaults()
    assert Access.codes_for_role(r) == ["admin.panel.access"]
    assert Repo.get!(Role, r.id).name == "Readers"
    assert Repo.get!(Role, r.id).show_badge
    assert Repo.get!(Role, id).is_default
    assert Anime.Settings.get("registration_default_role") == "newcomer"
    assert Repo.aggregate(from(r in Role, where: r.is_default), :count) == 1
    assert Repo.aggregate(Permission, :count) == 99
  end

  test "seed adds canonical grants only for newly inserted permissions and roles" do
    owner = role_user("owner")
    r = Repo.get_by!(Role, code: "user")
    Roles.update_matrix(owner, r.id, [])
    p = Repo.get_by!(Permission, code: "blog.post.view")
    Repo.delete_all(from rp in RolePermission, where: rp.permission_id == ^p.id)
    Repo.delete!(p)
    assert {:ok, _} = Seeds.defaults()
    assert Access.codes_for_role(r) == []
    editor = Repo.get_by!(Role, code: "content_editor")
    assert "blog.post.view" in Access.codes_for_role(editor)
    Repo.delete!(editor)
    assert {:ok, _} = Seeds.defaults()

    assert Enum.sort(Access.codes_for_role(Repo.get_by!(Role, code: "content_editor"))) ==
             Enum.sort(Catalog.role_codes("content_editor"))
  end

  test "custom role lifecycle only accepts editable fields and maintains default setting on rename" do
    owner = role_user("owner")
    before = Repo.aggregate(Role, :max, :position)

    {:ok, id} =
      Roles.create(owner, %{
        code: "helpers",
        name: "Helpers",
        system: true,
        position: -1,
        is_default: true
      })

    r = Repo.get!(Role, id)
    refute r.system
    refute r.is_default
    assert r.position == before + 1
    assert Access.codes_for_role(r) == []
    assert {:ok, _} = Roles.default(owner, id)
    assert {:error, :default_role} = Roles.delete(owner, id)
    assert {:ok, _} = Roles.edit(owner, id, %{code: "trusted", name: "Trusted", show_badge: true})
    assert Anime.Settings.get("registration_default_role") == "trusted"
    user_role = Repo.get_by!(Role, code: "user")
    assert {:ok, _} = Roles.default(owner, user_role.id)
    assert {:ok, _} = Roles.delete(owner, id)
    refute Repo.get(Role, id)

    assert Repo.aggregate(
             from(a in Audit, where: a.action == "roles.role.delete" and a.result == :success),
             :count
           ) == 1
  end

  test "system role code, owner and roles in use are protected" do
    owner = role_user("owner")
    user_role = Repo.get_by!(Role, code: "user")
    assert {:error, :system_role} = Roles.delete(owner, user_role.id)
    assert {:error, :system_code} = Roles.edit(owner, user_role.id, %{code: "other"})
    assert {:error, :protected_owner} = Roles.edit(owner, owner.role_id, %{name: "Renamed"})
    assert {:error, :protected_owner} = Roles.default(owner, owner.role_id)
    assert {:error, :protected_owner} = Roles.delete(owner, owner.role_id)
    {:ok, id} = Roles.create(owner, %{code: "assigned", name: "Assigned"})
    u = user()
    Repo.update!(Ecto.Changeset.change(u, role_id: id))
    assert {:error, :role_in_use} = Roles.delete(owner, id)
    assert Repo.get(Role, id)
  end

  test "invalid and duplicate role codes do not create records" do
    owner = role_user("owner")

    for code <- ["Bad Code", "user", "", "<script>"] do
      assert {:error, %Ecto.Changeset{}} = Roles.create(owner, %{code: code, name: "Test"})
    end

    assert Repo.aggregate(Role, :count) == 5
  end

  test "read and write context entrypoints deny unauthorized actors" do
    u = user()
    assert {:error, :forbidden} = Roles.list(u)
    assert {:error, :forbidden} = Roles.permissions(u)
    assert {:error, :forbidden} = Roles.matrix(u)
    assert {:error, :forbidden} = Roles.create(u, %{code: "no", name: "No"})
    assert {:error, :forbidden} = Roles.edit(u, u.role_id, %{name: "No"})
    assert {:error, :forbidden} = Roles.default(u, u.role_id)
    assert {:error, :forbidden} = Roles.delete(u, u.role_id)
    assert Repo.aggregate(Role, :count) == 5
  end

  test "multi-role matrix update is atomic, validates every column, and publishes after success" do
    owner = role_user("owner")
    u = user()
    a = Repo.get_by!(Role, code: "user")
    b = Repo.get_by!(Role, code: "comment_moderator")
    before = Access.codes_for_role(a)

    assert {:error, :unknown_permission} =
             Roles.update_matrices(owner, [{a.id, []}, {b.id, ["not.a.permission"]}])

    assert Access.codes_for_role(a) == before

    refute Repo.exists?(
             from x in Audit, where: x.action == "roles.matrix.edit" and x.result == :success
           )

    Phoenix.PubSub.subscribe(Anime.PubSub, "user:#{u.id}:access")
    assert {:ok, ids} = Roles.update_matrices(owner, [{a.id, []}, {b.id, []}])
    assert Enum.sort(ids) == Enum.sort([a.id, b.id])
    assert_receive :access_changed

    assert Repo.aggregate(
             from(x in Audit, where: x.action == "roles.matrix.edit" and x.result == :success),
             :count
           ) == 2
  end

  test "stale matrix and duplicate columns cannot overwrite a committed edit" do
    owner = role_user("owner")
    {:ok, data} = Roles.matrix(owner)
    r = Repo.get_by!(Role, code: "user")
    assert {:ok, _} = Roles.update_matrix(owner, r.id, [])

    assert {:error, :stale_matrix} =
             Roles.update_matrices(owner, [{r.id, ["video.watch.play"]}], data.grants)

    assert {:error, :invalid_changes} = Roles.update_matrices(owner, [{r.id, []}, {r.id, []}])
    assert {:error, :not_found} = Roles.update_matrices(owner, [{9_999_999, []}])
    assert Access.codes_for_role(r) == []
  end

  test "delegated editor cannot grant missing rights or remove their own rights" do
    owner = role_user("owner")
    editor = user()
    grants = ["roles.matrix.edit", "roles.role.edit"]
    Roles.update_matrix(owner, editor.role_id, grants)
    assert {:error, :self_permission_removal} = Roles.update_matrix(editor, editor.role_id, [])
    target = Repo.get_by!(Role, code: "content_editor")
    assert {:error, :cannot_grant} = Roles.update_matrix(editor, target.id, ["users.user.delete"])
    assert {:error, :cannot_grant} = Roles.default(editor, target.id)
    assert Enum.sort(Access.permissions(editor)) == Enum.sort(grants)
    Roles.update_matrix(owner, editor.role_id, [])
    assert {:error, :forbidden} = Roles.update_matrix(editor, target.id, [])
  end

  test "registration follows the default role changed in the same transaction" do
    owner = role_user("owner")
    {:ok, id} = Roles.create(owner, %{code: "newcomers", name: "Newcomers"})
    assert {:ok, _} = Roles.default(owner, id)
    assert user().role_id == id
    assert Repo.get_by!(Setting, key: "registration_default_role").value == "newcomers"
  end

  test "web mutation rechecks panel and screen rights under the transaction lock" do
    owner = role_user("owner")
    u = user()
    grants = ["roles.role.create", "roles.role.view"]
    Roles.update_matrix(owner, u.role_id, grants)
    meta = %{required_permissions: ["admin.panel.access", "roles.role.view"]}
    assert {:error, :forbidden} = Roles.create(u, %{code: "blocked_panel", name: "Denied"}, meta)
    refute Repo.get_by(Role, code: "blocked_panel")
    Roles.update_matrix(owner, u.role_id, ["admin.panel.access" | grants])
    assert {:ok, _} = Roles.create(u, %{code: "allowed_panel", name: "Allowed"}, meta)
  end
end
