defmodule AnimeWeb.RolesTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.Access.{Roles, Role, Permission, RolePermission}
  alias Anime.Accounts.Tokens

  for path <- ["/admin/roles", "/admin/roles/permissions", "/admin/roles/matrix"] do
    test "#{path} rejects guest and ordinary user", %{conn: conn} do
      assert redirected_to(get(conn, unquote(path))) == "/login"
      assert {:error, {:redirect, %{to: "/403"}}} = live(login_conn(conn, user()), unquote(path))
    end
  end

  test "admin has read-only roles and permissions but cannot mount matrix", %{conn: conn} do
    u = role_user("admin")
    c = login_conn(conn, u)
    {:ok, view, _} = live(c, "/admin/roles")
    assert has_element?(view, "#roles-table")
    refute has_element?(view, "#role-form")
    render_change(view, "validate", %{"role" => %{"code" => "forged", "name" => "Forged"}})
    render_click(view, "edit", %{"id" => to_string(u.role_id)})
    render_click(view, "prepare", %{"id" => to_string(u.role_id), "action" => "delete"})
    refute has_element?(view, "#role-confirm")
    render_submit(view, "save", %{"role" => %{"code" => "forged", "name" => "Forged"}})
    refute Repo.get_by(Role, code: "forged")

    assert render(view) =~
             "Недостаточно прав для этого действия. Проверьте доступ или обратитесь к владельцу сайта."

    {:ok, permissions, _} = live(c, "/admin/roles/permissions")
    assert has_element?(permissions, "#permissions-table")
    assert {:error, {:redirect, %{to: "/403"}}} = live(c, "/admin/roles/matrix")

    assert Repo.exists?(
             from a in Anime.Audit, where: a.action == "roles.matrix.edit" and a.result == :denied
           )
  end

  test "owner creates, edits, sets default and deletes custom roles through confirmed actions", %{
    conn: conn
  } do
    owner = role_user("owner")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/roles")
    view |> form("#role-form", role: %{code: "helpers", name: "Helpers"}) |> render_submit()
    render_async(view, 2000)
    r = Repo.get_by!(Role, code: "helpers")
    assert has_element?(view, "#role-#{r.id}", "Helpers")
    view |> element("#role-#{r.id} button[phx-click=edit]") |> render_click()

    view
    |> form("#role-form", role: %{name: "New helpers", show_badge: "true"})
    |> render_submit()

    render_async(view, 2000)

    assert Repo.get!(Role, r.id).name == "New helpers"
    assert Repo.get!(Role, r.id).show_badge
    view |> element("#role-#{r.id} button[phx-value-action=default]") |> render_click()
    refute Repo.get!(Role, r.id).is_default
    view |> element("#confirm-role-action") |> render_click()
    render_async(view, 2000)
    assert Repo.get!(Role, r.id).is_default
    user_role = Repo.get_by!(Role, code: "user")
    view |> element("#role-#{user_role.id} button[phx-value-action=default]") |> render_click()
    view |> element("#confirm-role-action") |> render_click()
    render_async(view, 2000)
    view |> element("#role-#{r.id} button[phx-value-action=delete]") |> render_click()
    assert Repo.get(Role, r.id)
    view |> element("#confirm-role-action") |> render_click()
    render_async(view, 2000)
    refute Repo.get(Role, r.id)
  end

  test "a role saved in one tab also refreshes the other tab", %{conn: conn} do
    owner = role_user("owner")
    conn = login_conn(conn, owner)
    {:ok, editor, _} = live(conn, "/admin/roles")
    {:ok, observer, _} = live(conn, "/admin/roles")
    editor |> form("#role-form", role: %{code: "helpers", name: "Helpers"}) |> render_submit()
    render_async(editor, 2000)
    render(observer)
    render_async(observer, 2000)
    role = Repo.get_by!(Role, code: "helpers")
    assert has_element?(editor, "#role-#{role.id}", "Helpers")
    assert has_element?(observer, "#role-#{role.id}", "Helpers")
  end

  test "matrix stages multiple roles, cancels without writes and saves once per role", %{
    conn: conn
  } do
    owner = role_user("owner")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/roles/matrix")
    r = Repo.get_by!(Role, code: "user")
    editor = Repo.get_by!(Role, code: "content_editor")

    assert has_element?(
             view,
             "input[name='grants[#{owner.role_id}][]'][value='video.watch.play'][disabled][checked]"
           )

    render_change(view, "change", %{
      "grants" => %{to_string(r.id) => [""], to_string(editor.id) => ["admin.panel.access"]}
    })

    view |> form("#matrix-form") |> render_submit()
    assert has_element?(view, "#matrix-confirm")
    assert Anime.Access.codes_for_role(r) == ["video.watch.play"]
    view |> element("button[phx-click=reset]") |> render_click()
    refute has_element?(view, "#matrix-confirm")
    render_change(view, "change", %{"grants" => %{to_string(r.id) => [""]}})
    view |> form("#matrix-form") |> render_submit()
    view |> element("#save-matrix") |> render_click()
    assert Anime.Access.codes_for_role(r) == []
    assert render(view) =~ "Матрица сохранена"
    assert length(Anime.Access.codes_for_role(editor)) == 38

    assert Repo.aggregate(
             from(a in Anime.Audit,
               where: a.action == "roles.matrix.edit" and a.result == :success
             ),
             :count
           ) == 1
  end

  test "stale form is refused and retains committed matrix", %{conn: conn} do
    owner = role_user("owner")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/roles/matrix")
    r = Repo.get_by!(Role, code: "user")
    render_change(view, "change", %{"grants" => %{to_string(r.id) => ["admin.panel.access"]}})
    assert {:ok, _} = Roles.update_matrix(owner, r.id, [])
    view |> form("#matrix-form") |> render_submit()
    view |> element("#save-matrix") |> render_click()

    assert render(view) =~
             "Матрица прав изменилась в другом окне. Отмените черновик, перечитайте матрицу и внесите изменения заново."

    assert Anime.Access.codes_for_role(r) == []
  end

  test "revoked session cannot submit staged role creation", %{conn: conn} do
    owner = role_user("owner")
    c = login_conn(conn, owner)
    {:ok, view, _} = live(c, "/admin/roles")
    Tokens.revoke(get_session(c, :user_token))
    render_submit(view, "save", %{"role" => %{"code" => "unauthorized", "name" => "No"}})
    refute Repo.get_by(Role, code: "unauthorized")

    assert render(view) =~
             "Недостаточно прав для этого действия. Проверьте доступ или обратитесь к владельцу сайта."
  end

  test "permission removal rejects direct events even without PubSub delivery", %{conn: conn} do
    owner = role_user("owner")
    u = user()
    grants = ["admin.panel.access", "roles.role.view", "roles.role.create", "roles.matrix.edit"]
    Roles.update_matrix(owner, u.role_id, grants)
    c = login_conn(conn, u)
    {:ok, view, _} = live(c, "/admin/roles/matrix")
    target = Repo.get_by!(Role, code: "content_editor")
    render_change(view, "change", %{"grants" => %{to_string(target.id) => [""]}})
    view |> form("#matrix-form") |> render_submit()
    permission = Repo.get_by!(Permission, code: "roles.matrix.edit")

    Repo.delete_all(
      from rp in RolePermission,
        where: rp.role_id == ^u.role_id and rp.permission_id == ^permission.id
    )

    view |> element("#save-matrix") |> render_click()

    assert render(view) =~
             "Недостаточно прав для этого действия. Проверьте доступ или обратитесь к владельцу сайта."

    assert length(Anime.Access.codes_for_role(target)) == 38
  end

  test "role change message closes an open admin page", %{conn: conn} do
    owner = role_user("owner")
    admin = role_user("admin")
    {:ok, view, _} = live(login_conn(conn, admin), "/admin/roles")
    assert {:ok, _} = Roles.update_matrix(owner, admin.role_id, [])
    assert_redirect(view, "/")
  end

  test "permission search is read-only", %{conn: conn} do
    admin = role_user("admin")
    {:ok, view, _} = live(login_conn(conn, admin), "/admin/roles/permissions")

    view
    |> form("form[phx-change=filter]", %{q: "roles.matrix", group: "roles"})
    |> render_change()

    render_async(view, 2000)

    assert has_element?(view, "#permissions-table td", "roles.matrix.edit")
    refute has_element?(view, "#permissions-table td", "video.watch.play")
    assert Repo.aggregate(Permission, :count) == 99
  end

  test "admin routes all declare a permission known to the catalog" do
    for route <- AnimeWeb.Router.__routes__(),
        String.starts_with?(route.path, "/admin"),
        {view, _, _, _} <- [route.metadata[:phoenix_live_view]] do
      assert view.__admin_permission__() in Anime.Access.Catalog.codes()
    end
  end

  test "admin screen chrome follows the user's English locale", %{conn: conn} do
    owner = role_user("owner") |> Ecto.Changeset.change(locale: :en) |> Repo.update!()
    c = login_conn(conn, owner)
    {:ok, view, html} = live(c, "/admin/roles")
    assert html =~ "Create role"
    assert has_element?(view, "h1", "Roles")
    {:ok, matrix, _} = live(c, "/admin/roles/matrix")
    assert has_element?(matrix, "h1", "Permission matrix")
  end
end
