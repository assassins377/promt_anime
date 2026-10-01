defmodule AnimeWeb.AdminMatrixFiltersTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.Access.{Role, Roles, Permission, RolePermission}

  test "matrix restores filters from a direct URL and produces bounded patch URLs", %{conn: conn} do
    owner = role_user("owner")
    role = Repo.get_by!(Role, code: "user")
    path = "/admin/roles/matrix?group=video&q=video.watch&role=#{role.id}"
    {:ok, view, _} = live(login_conn(conn, owner), path)
    assert has_element?(view, "input[name=q][value='video.watch']")
    assert has_element?(view, "select[name=group] option[value=video][selected]")
    assert has_element?(view, "select[name=role] option[value='#{role.id}'][selected]")
    assert has_element?(view, "tr:not([hidden]) code", "video.watch.play")
    refute has_element?(view, "tr:not([hidden]) code", "users.user.view")
    assert has_element?(view, "thead th:not([hidden])", "Пользователь")
    refute has_element?(view, "thead th:not([hidden])", "Владелец")

    view
    |> form("#admin-filters", %{q: "  roles.matrix  ", group: "roles", role: ""})
    |> render_change()

    assert_patch(view, "/admin/roles/matrix?group=roles&q=roles.matrix")
    render_async(view, 2000)
    assert has_element?(view, "tr:not([hidden]) code", "roles.matrix.edit")
    view |> element(".filter-chips a[data-filter=q]") |> render_click()
    assert_patch(view, "/admin/roles/matrix?group=roles")
    render_async(view, 2000)
    view |> element(".reset-filters") |> render_click()
    assert_patch(view, "/admin/roles/matrix")
    render_async(view, 2000)
    refute has_element?(view, ".filter-chips")
    render_patch(view, path)
    render_async(view, 2000)
    assert has_element?(view, "input[name=q][value='video.watch']")
  end

  test "patches, chip reset and locale switching preserve pending draft without database writes",
       %{conn: conn} do
    owner = role_user("owner")
    role = Repo.get_by!(Role, code: "user")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/roles/matrix")
    render_change(view, "change", %{"grants" => %{to_string(role.id) => [""]}})
    view |> form("#matrix-form") |> render_submit()
    assert has_element?(view, "#matrix-confirm code", "video.watch.play")
    render_change(view, "filter", %{"group" => "users", "role" => to_string(owner.role_id)})
    assert_patch(view, "/admin/roles/matrix?group=users&role=#{owner.role_id}")
    render_async(view, 2000)
    view |> form("#admin-locale", locale: "en") |> render_change()
    assert has_element?(view, "#matrix-confirm", "Watch public video")
    assert has_element?(view, "#matrix-confirm", "User")
    view |> element(".reset-filters") |> render_click()
    assert_patch(view, "/admin/roles/matrix")
    render_async(view, 2000)
    assert has_element?(view, "#matrix-confirm code", "video.watch.play")

    refute has_element?(
             view,
             "input[name='grants[#{role.id}][]'][value='video.watch.play'][checked]"
           )

    assert Anime.Access.codes_for_role(role) == ["video.watch.play"]
    view |> element("#save-matrix") |> render_click()
    assert Anime.Access.codes_for_role(role) == []
  end

  test "hidden columns remain submitted and filtering never wipes another role's grants", %{
    conn: conn
  } do
    owner = role_user("owner")
    role = Repo.get_by!(Role, code: "user")
    editor = Repo.get_by!(Role, code: "content_editor")
    before = Anime.Access.codes_for_role(editor)
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/roles/matrix?role=#{role.id}")
    render_change(view, "change", %{"grants" => %{to_string(role.id) => [""]}})
    view |> form("#matrix-form") |> render_submit()
    view |> element("#save-matrix") |> render_click()
    assert Anime.Access.codes_for_role(editor) == before
    assert Anime.Access.codes_for_role(role) == []
  end

  test "malformed filters and nonexistent roles are ignored, unrelated fields never enter URL", %{
    conn: conn
  } do
    owner = role_user("owner")

    {:ok, view, _} =
      live(
        login_conn(conn, owner),
        "/admin/roles/matrix?q[]=bad&group[]=video&role=9223372036854775808"
      )

    refute has_element?(view, ".filter-chips")

    render_change(view, "filter", %{
      "q" => %{"x" => "bad"},
      "group" => "forged",
      "role" => "999999999",
      "grants" => ["admin.panel.access"],
      "page" => "3"
    })

    assert_patch(view, "/admin/roles/matrix")
    render_async(view, 2000)
    refute has_element?(view, ".filter-chips")
    render_change(view, "filter", %{"q" => "x"})
    assert_patch(view, "/admin/roles/matrix")
    render_async(view, 2000)
    render_change(view, "filter", %{"q" => String.duplicate("x", 120)})
    assert_patch(view, "/admin/roles/matrix?q=" <> String.duplicate("x", 100))
    render_async(view, 2000)
  end

  test "direct query patches and filter events recheck revoked permission without PubSub", %{
    conn: conn
  } do
    owner = role_user("owner")
    actor = user()

    {:ok, _} =
      Roles.update_matrix(owner, actor.role_id, ["admin.panel.access", "roles.matrix.edit"])

    {:ok, view, _} = live(login_conn(conn, actor), "/admin/roles/matrix?group=video")
    permission = Repo.get_by!(Permission, code: "roles.matrix.edit")

    Repo.delete_all(
      from(rp in RolePermission,
        where: rp.role_id == ^actor.role_id and rp.permission_id == ^permission.id
      )
    )

    render_patch(view, "/admin/roles/matrix?group=users")
    render_async(view, 2000)
    assert has_element?(view, "[role=alert]", "Недостаточно прав")
    assert has_element?(view, "select[name=group] option[value=video][selected]")
    render_change(view, "filter", %{"group" => "billing"})
    refute has_element?(view, "select[name=group] option[value=billing][selected]")
  end
end
