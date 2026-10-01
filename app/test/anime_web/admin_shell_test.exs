defmodule AnimeWeb.AdminShellTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.Access.{Roles, Role}
  alias Anime.Accounts.{User, Tokens}
  alias AnimeWeb.AdminQuery

  defp assert_rows(view, selector, count) do
    assert has_element?(view, "#{selector}:nth-child(#{count})")
    refute has_element?(view, "#{selector}:nth-child(#{count + 1})")
  end

  test "admin entry redirects to the first accessible implemented screen", %{conn: conn} do
    owner = role_user("owner")
    assert redirected_to(get(login_conn(conn, owner), "/admin")) == "/admin/dashboard"
    reader = user()
    {:ok, role_id} = Roles.create(owner, %{code: "activityonly", name: "Activity only"})
    Roles.update_matrix(owner, role_id, ["admin.panel.access", "users.activity.view"])
    reader = reader |> Ecto.Changeset.change(role_id: role_id) |> Repo.update!()
    c = login_conn(conn, reader)
    assert redirected_to(get(c, "/admin")) == "/admin/users/activity"
    {:ok, view, _} = live(c, "/admin/users/activity")
    assert has_element?(view, ".admin-sidebar a[href='/admin/users/activity']")
    refute has_element?(view, ".admin-sidebar a[href='/admin/users']")
    refute has_element?(view, ".admin-sidebar a[href='/admin/dashboard']")
    refute has_element?(view, ".admin-sidebar a[href='/admin/roles']")
    assert {:error, {:redirect, %{to: "/403"}}} = live(c, "/admin/users")
    Roles.update_matrix(owner, role_id, ["admin.panel.access"])
    assert redirected_to(get(c, "/admin")) == "/403"
  end

  test "all ready screens share a frame, active location and no public chrome", %{conn: conn} do
    owner = role_user("owner")
    c = login_conn(conn, owner)

    for {path, active} <- [
          {"/admin/dashboard", "/admin/dashboard"},
          {"/admin/users", "/admin/users"},
          {"/admin/users/blocked", "/admin/users/blocked"},
          {"/admin/users/activity", "/admin/users/activity"},
          {"/admin/users/#{owner.id}", "/admin/users"},
          {"/admin/roles", "/admin/roles"},
          {"/admin/roles/permissions", "/admin/roles/permissions"},
          {"/admin/roles/matrix", "/admin/roles/matrix"}
        ] do
      {:ok, view, _} = live(c, path)
      assert has_element?(view, "#admin-shell #admin-content")
      assert has_element?(view, ".admin-sidebar a[aria-current=page][href='#{active}']")
      assert has_element?(view, "#admin-mobile-menu")
      assert has_element?(view, "#admin-menu-button[aria-controls=admin-mobile-menu]")

      assert has_element?(
               view,
               "#admin-account-menu form[action='/logout'] input[name='_csrf_token']"
             )

      refute has_element?(view, "#site-header")
      refute has_element?(view, "footer")
      refute has_element?(view, ".admin-sidebar a[href='/admin/video']")
    end
  end

  test "locale changes in place with the route filters and permissions preserved", %{conn: conn} do
    owner = role_user("owner")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users?status[]=active")
    view |> form("#admin-locale", locale: "en") |> render_change()
    assert Repo.get!(User, owner.id).locale == :en
    assert has_element?(view, "h1", "Users")
    assert has_element?(view, ".filter-chips a[data-filter=status][data-value=active]")
    assert_push_event(view, "admin:locale", %{locale: "en"})
    assert page_title(view) =~ "Users"
    assert has_element?(view, ".admin-sidebar", "Roles and permissions")
    assert has_element?(view, "#admin-account-menu", "Visit site")
    render_change(view, "admin_locale", %{"locale" => "untrusted"})
    assert Repo.get!(User, owner.id).locale == :en
  end

  test "drawer and profile controls stay named when mobile CSS hides the nick", %{conn: conn} do
    owner = role_user("owner")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users")
    assert has_element?(view, "#admin-mobile-menu[aria-label='Администрирование']")
    assert has_element?(view, "#admin-menu-button[x-ref='menuButton']")
    assert has_element?(view, "#admin-content[x-ref='content'][tabindex='-1']")

    assert has_element?(
             view,
             "#admin-account-toggle[aria-label='Меню профиля: #{owner.nick}'][x-ref='trigger']"
           )

    assert has_element?(
             view,
             ".admin-account[x-data='publicDropdown'] #admin-account-menu[x-ref='panel']"
           )

    render_change(view, "admin_locale", %{"locale" => "en"})
    assert has_element?(view, "#admin-mobile-menu[aria-label='Administration']")
    assert has_element?(view, "#admin-account-toggle[aria-label='Profile menu: #{owner.nick}']")
  end

  test "revoked session cannot use the shared locale control", %{conn: conn} do
    owner = role_user("owner")
    c = login_conn(conn, owner)
    {:ok, view, _} = live(c, "/admin/roles")
    Tokens.revoke(get_session(c, :user_token))
    render_change(view, "admin_locale", %{"locale" => "en"})
    assert Repo.get!(User, owner.id).locale == :ru

    assert render(view) =~
             "Недостаточно прав для этого действия. Проверьте доступ или обратитесь к владельцу сайта."
  end

  test "locale change keeps the unsaved matrix draft and does not write grants", %{conn: conn} do
    owner = role_user("owner")
    role = Repo.get_by!(Role, code: "user")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/roles/matrix")
    render_change(view, "change", %{"grants" => %{to_string(role.id) => [""]}})
    view |> form("#admin-locale", locale: "en") |> render_change()
    assert has_element?(view, "h1", "Permission matrix")

    assert has_element?(
             view,
             "input[name='grants[#{role.id}][]'][value='video.watch.play']:not([checked])"
           )

    assert Anime.Access.codes_for_role(role) == ["video.watch.play"]
    view |> form("#matrix-form") |> render_submit()
    assert has_element?(view, "#matrix-confirm")
  end

  test "one chip removes one multiselect value, preserves sorting and clears selection", %{
    conn: conn
  } do
    owner = role_user("owner")

    {:ok, view, _} =
      live(
        login_conn(conn, owner),
        "/admin/users?sort=nick&dir=asc&status[]=active&status[]=blocked"
      )

    view |> element("#select-page") |> render_click()
    assert has_element?(view, "#bulk-actions")
    view |> element(".filter-chips a[data-filter=status][data-value=blocked]") |> render_click()
    assert_patch(view, "/admin/users?dir=asc&sort=nick&status[]=active")
    render_async(view, 2000)
    assert has_element?(view, ".filter-chips a[data-filter=status][data-value=active]")
    refute has_element?(view, "#bulk-actions")
    view |> element(".reset-filters") |> render_click()
    assert_patch(view, "/admin/users")
    render_async(view, 2000)
    refute has_element?(view, ".reset-filters")
  end

  test "role filters survive a fresh mount and pagination is performed in SQL", %{conn: conn} do
    owner = role_user("owner")
    now = DateTime.utc_now()

    Repo.insert_all(
      Role,
      for(
        n <- 1..51,
        do: %{
          code: "custom#{n}",
          name: "Custom #{n}",
          position: n + 100,
          system: false,
          is_default: false,
          show_badge: false,
          inserted_at: now,
          updated_at: now
        }
      )
    )

    c = login_conn(conn, owner)
    {:ok, view, _} = live(c, "/admin/roles?q=Custom")
    assert_rows(view, "#roles-table tbody tr", 50)
    view |> element(".admin-pagination a", "Далее") |> render_click()
    assert_patch(view, "/admin/roles?page=2&q=Custom")
    render_async(view, 2000)
    assert_rows(view, "#roles-table tbody tr", 1)
    {:ok, fresh, _} = live(c, "/admin/roles?page=2&q=Custom")
    assert has_element?(fresh, "#roles-table", "Custom 51")
    fresh |> element(".admin-pagination a", "Первая") |> render_click()
    assert_patch(fresh, "/admin/roles?q=Custom")
    render_async(fresh, 2000)
    fresh |> form("#admin-filters", q: "no-match") |> render_change()
    assert_patch(fresh, "/admin/roles?q=no-match")
    render_async(fresh, 2000)
    assert render(fresh) =~ "Под текущие фильтры ничего не подошло"
    assert has_element?(fresh, ".filter-chips a[data-filter=q]")
  end

  test "permission catalog pages and group filters are restored from the address", %{conn: conn} do
    owner = role_user("owner")
    c = login_conn(conn, owner)
    {:ok, view, _} = live(c, "/admin/roles/permissions")
    assert_rows(view, "#permissions-table tbody tr", 50)
    view |> element(".admin-pagination a", "Последняя") |> render_click()
    assert_patch(view, "/admin/roles/permissions?page=2")
    render_async(view, 2000)
    assert_rows(view, "#permissions-table tbody tr", 49)
    view |> form("#admin-filters", q: "roles", group: "roles") |> render_change()
    assert_patch(view, "/admin/roles/permissions?group=roles&q=roles")
    render_async(view, 2000)
    {:ok, fresh, _} = live(c, "/admin/roles/permissions?group=roles&q=roles")
    assert has_element?(fresh, "select[name=group] option[value=roles][selected]")
    assert has_element?(fresh, "#permissions-table", "roles.matrix.edit")
    refute has_element?(fresh, "#permissions-table", "video.watch.play")
  end

  test "removing an activity filter retains the fixed card target and tab", %{conn: conn} do
    owner = role_user("owner")
    target = user()

    {:ok, view, _} =
      live(
        login_conn(conn, owner),
        "/admin/users/#{target.id}?tab=activity&action[]=register&result[]=success"
      )

    view |> element(".filter-chips a[data-filter=action]") |> render_click()

    assert_patch(
      view,
      "/admin/users/#{target.id}?result[]=success&tab=activity&user_id=#{target.id}"
    )

    assert has_element?(view, "#activity-table", target.nick)
    refute has_element?(view, "#activity-table", owner.nick)
    refute has_element?(view, ".filter-chips a[data-filter=user_id]")
    view |> element(".reset-filters") |> render_click()
    assert_patch(view, "/admin/users/#{target.id}?tab=activity&user_id=#{target.id}")
    render_async(view, 2000)
    assert has_element?(view, "#activity-table", target.nick)
  end

  test "malformed query values are ignored and not carried by links", %{conn: conn} do
    owner = role_user("owner")

    {:ok, view, _} =
      live(
        login_conn(conn, owner),
        "/admin/users?q[x]=bad&role=no&status[]=active&status[]=active&status[]=wrong&from=wrong&unknown=bad&page=-1"
      )

    assert has_element?(view, ".filter-chips a[data-filter=status]")
    refute has_element?(view, ".filter-chips a[data-filter=status] ~ a[data-filter=status]")
    refute has_element?(view, ".filter-chips a[data-filter=q]")
    view |> element(".filter-chips a[data-filter=status]") |> render_click()
    assert_patch(view, "/admin/users")
    render_async(view, 2000)
    assert AdminQuery.url("/admin/users", %{"page" => "1", "q" => ""}) == "/admin/users"
  end

  test "new paginated contexts enforce access and bound invalid pages" do
    u = user()
    assert {:error, :forbidden} = Roles.list_page(u)
    assert {:error, :forbidden} = Roles.permissions_page(u)
    owner = role_user("owner")

    assert {:ok, %{page: 2, rows: rows, count: 99}} =
             Roles.permissions_page(owner, %{"page" => "99999"})

    assert length(rows) == 49

    assert {:ok, %{page: 1, count: 99}} =
             Roles.permissions_page(owner, %{"page" => %{}, "q" => %{}, "group" => "invalid"})

    assert {:ok, %{count: 0}} = Roles.list_page(owner, %{"q" => "%_"})
    refute Repo.exists?(from a in Anime.Audit, where: a.action == "roles.role.create")
  end
end
