defmodule AnimeWeb.AdminListStatesTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.Access.{Role, Roles, Permission, RolePermission}
  alias AnimeWeb.AdminComponents

  test "empty state ignores paging/sort and fixed scope, and preserves scope when resetting" do
    for locale <- ~w(ru en) do
      Gettext.put_locale(AnimeWeb.Gettext, locale)

      base = %{
        "tab" => "activity",
        "user_id" => "123",
        "page" => "9",
        "sort" => "id",
        "dir" => "asc"
      }

      html =
        render_component(&AdminComponents.admin_empty/1,
          query: base,
          path: "/admin/users/123",
          fixed: ["user_id"]
        )

      assert html =~ ~s(data-filtered="false")
      refute html =~ "data-phx-link"
      assert html =~ if(locale == "ru", do: "Записей пока нет", else: "No records yet")

      html =
        render_component(&AdminComponents.admin_empty/1,
          query: Map.put(base, "ip", "192.0.2.1"),
          path: "/admin/users/123",
          fixed: ["user_id"]
        )

      assert html =~ ~s(data-filtered="true")
      assert html =~ ~s(href="/admin/users/123?tab=activity&amp;user_id=123")
      assert html =~ if(locale == "ru", do: "Сбросить фильтры", else: "Reset filters")
      refute html =~ "page="
      refute html =~ "ip="
    end
  end

  test "creation slot is offered only for the genuinely empty unfiltered state" do
    create = [
      %{
        __slot__: :create,
        inner_block: fn _, _ -> Phoenix.HTML.raw("<button>Create role</button>") end
      }
    ]

    html =
      render_component(&AdminComponents.admin_empty/1,
        query: %{},
        path: "/admin/roles",
        create: create
      )

    assert html =~ "Create role"

    html =
      render_component(&AdminComponents.admin_empty/1,
        query: %{"q" => "missing"},
        path: "/admin/roles",
        create: create
      )

    refute html =~ "Create role"
    assert html =~ "data-phx-link"
  end

  test "filtered lists retain headers, filters, counter and pagination without fake rows", %{
    conn: conn
  } do
    owner = role_user("owner")
    c = login_conn(conn, owner)

    for {path, table, filter} <- [
          {"/admin/users?q=zzzNoMatchingRecordzzz", "users-table", "users-filter"},
          {"/admin/users/blocked?q=zzzNoMatchingRecordzzz", "users-table", "users-filter"},
          {"/admin/roles?q=zzzNoMatchingRecordzzz", "roles-table", "admin-filters"},
          {"/admin/roles/permissions?q=zzzNoMatchingRecordzzz", "permissions-table",
           "admin-filters"},
          {"/admin/users/activity?ip=192.0.2.255", "activity-table", "activity-filter"}
        ] do
      {:ok, view, _} = live(c, path)

      assert has_element?(
               view,
               ".admin-empty[data-filtered=true]",
               "Под текущие фильтры ничего не подошло"
             )

      assert has_element?(view, "##{table} thead th")
      refute has_element?(view, "##{table} tbody tr")
      assert has_element?(view, "##{filter}")
      assert has_element?(view, ".admin-list-heading .admin-list-count", "Найдено: 0")
      assert has_element?(view, ".admin-pagination")

      assert has_element?(
               view,
               ".admin-list-scroll[tabindex='0'][role=region][aria-label] ##{table}"
             )

      assert has_element?(view, ".admin-empty a[data-phx-link=patch]", "Сбросить фильтры")
    end
  end

  test "blocked registry with no rows is not presented as a failed search", %{conn: conn} do
    {:ok, view, _} =
      live(login_conn(conn, role_user("owner")), "/admin/users/blocked?sort=id&dir=asc&page=12")

    assert has_element?(view, ".admin-empty[data-filtered=false]", "Записей пока нет")
    refute has_element?(view, ".admin-empty a")
    refute has_element?(view, ".admin-empty button")
    assert has_element?(view, "#select-page[disabled]")
    view |> form("#admin-locale", locale: "en") |> render_change()
    assert has_element?(view, ".admin-empty", "No records yet")
    assert has_element?(view, ".admin-list-heading .admin-list-count", "Found: 0")
  end

  test "resetting a failed user search restores the registry and removes sort and page", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()

    {:ok, view, _} =
      live(
        login_conn(conn, owner),
        "/admin/users?q=zzzNoMatchingRecordzzz&sort=nick&dir=asc&page=12"
      )

    view |> element(".admin-empty a") |> render_click()
    assert_patch(view, "/admin/users")
    render_async(view, 2000)
    assert has_element?(view, "#user-#{target.id}")
    refute has_element?(view, ".admin-empty")
    refute has_element?(view, ".bulk-actions")
  end

  test "activity reset within a card cannot widen the fixed user scope", %{conn: conn} do
    owner = role_user("owner")
    target = user()

    {:ok, view, _} =
      live(login_conn(conn, owner), "/admin/users/#{target.id}?tab=activity&ip=192.0.2.255")

    assert has_element?(view, ".admin-empty[data-filtered=true]")
    view |> element(".admin-empty a") |> render_click()
    assert_patch(view, "/admin/users/#{target.id}?tab=activity&user_id=#{target.id}")
    render_async(view, 2000)
    assert has_element?(view, "input[name='filters[user_id]'][value='#{target.id}'][readonly]")
    assert has_element?(view, ".admin-list-heading h2", "История активности")
    refute has_element?(view, ".admin-empty")
  end

  test "fixed empty activity is unfiltered even though its user ID lives in the query", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()
    Repo.delete_all(from a in Anime.Audit, where: a.user_id == ^target.id)

    {:ok, view, _} =
      live(login_conn(conn, owner), "/admin/users/#{target.id}?tab=activity&sort=id&dir=desc")

    assert has_element?(view, ".admin-empty[data-filtered=false]", "Записей пока нет")
    refute has_element?(view, ".admin-empty a")
    assert has_element?(view, "#activity-table thead")
  end

  test "empty-state translation switches in place and reset links keep their targets", %{
    conn: conn
  } do
    {:ok, view, _} =
      live(
        login_conn(conn, role_user("owner")),
        "/admin/roles/permissions?q=zzzNoMatchingRecordzzz"
      )

    view |> form("#admin-locale", locale: "en") |> render_change()
    assert has_element?(view, ".admin-empty", "No records match the current filters")
    assert has_element?(view, ".admin-empty a[href='/admin/roles/permissions']", "Reset filters")
    assert has_element?(view, "#admin-filters input[value=zzzNoMatchingRecordzzz]")
  end

  test "role actions are labelled icons and the primary create button resets only the form", %{
    conn: conn
  } do
    owner = role_user("owner")
    {:ok, id} = Roles.create(owner, %{code: "icons", name: "Icon role"})
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/roles?q=Icon")

    assert has_element?(
             view,
             "#role-#{id} .row-actions button[title='Изменить'][aria-label='Изменить: Icon role'] span[aria-hidden=true]"
           )

    assert has_element?(
             view,
             "#role-#{id} .row-actions button[title='Удалить'][aria-label='Удалить: Icon role']"
           )

    refute has_element?(view, "#role-#{id} .row-actions button", "Изменить")
    view |> element("#role-#{id} button[phx-click=edit]") |> render_click()
    assert has_element?(view, "#role-form input[value=icons]")
    before = Repo.aggregate(Role, :count)
    view |> element(".admin-list-primary button") |> render_click()
    assert has_element?(view, "#role_code:not([value]), #role_code[value='']")
    assert has_element?(view, "#admin-filters input[value=Icon]")
    assert Repo.aggregate(Role, :count) == before
    refute has_element?(view, ".admin-empty")
  end

  test "create action is hidden and direct creation is denied without permission", %{
    conn: conn
  } do
    admin = role_user("admin")
    {:ok, readonly, _} = live(login_conn(conn, admin), "/admin/roles?q=zzzNoMatchingRecordzzz")
    refute has_element?(readonly, ".admin-list-primary")
    refute has_element?(readonly, ".admin-empty button")
    render_click(readonly, "new")
    assert has_element?(readonly, "[role=alert]", "Недостаточно прав")
    refute has_element?(readonly, "#role-form")
  end

  test "direct creation rechecks revoked grants and retains the current draft", %{conn: conn} do
    owner = role_user("owner")
    actor = user()

    {:ok, _} =
      Roles.update_matrix(owner, actor.role_id, [
        "admin.panel.access",
        "roles.role.view",
        "roles.role.edit",
        "roles.role.create"
      ])

    {:ok, id} = Roles.create(owner, %{code: "retained", name: "Retained"})
    {:ok, view, _} = live(login_conn(conn, actor), "/admin/roles")
    view |> element("#role-#{id} button[phx-click=edit]") |> render_click()
    permission = Repo.get_by!(Permission, code: "roles.role.create")

    Repo.delete_all(
      from rp in RolePermission,
        where: rp.role_id == ^actor.role_id and rp.permission_id == ^permission.id
    )

    render_click(view, "new")
    assert has_element?(view, "[role=alert]", "Недостаточно прав")
    assert has_element?(view, "#role_code[value=retained]")
  end
end
