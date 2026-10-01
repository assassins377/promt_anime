defmodule AnimeWeb.PublicHeaderTest do
  use AnimeWeb.ConnCase

  test "guest menu contains only theme choices and login exposes mobile language", %{conn: conn} do
    {:ok, view, _} = live(conn, "/login?return_to=%2Fcatalog%3Fpage%3D2")
    assert has_element?(view, "#profile-menu-toggle[aria-controls=profile-menu-panel]")
    assert has_element?(view, "#profile-menu-panel .theme-choices button", "Как в системе")
    refute has_element?(view, "#profile-menu-panel a")
    refute has_element?(view, "#menu-logout")
    refute has_element?(view, "#header-add-anime")
    assert has_element?(view, ".login-mobile-options a[href='/register']")

    for id <- ["locale-form", "login-locale-form"] do
      assert has_element?(view, "##{id}[method=post][action='/locale']")
      assert has_element?(view, "##{id} input[name=_csrf_token]")

      assert has_element?(
               view,
               "##{id} input[name=return_to][value='/login?return_to=%2Fcatalog%3Fpage%3D2']"
             )

      assert has_element?(view, "##{id} button[value=ru][aria-pressed=true]")
    end
  end

  test "profile menu has authorized links and POST logout but no unimplemented history", %{
    conn: conn
  } do
    {:ok, view, html} = conn |> login_conn(user()) |> live("/en/catalog?page=3")
    assert has_element?(view, "#profile-menu-panel a[href='/en/profile']", "My profile")
    assert has_element?(view, "#profile-menu-panel a[href='/en/profile/bookmarks']")
    assert has_element?(view, "#profile-menu-panel a[href='/en/profile/settings']")

    assert has_element?(
             view,
             "#profile-locale-form input[name=return_to][value='/en/catalog?page=3']"
           )

    assert has_element?(view, "#profile-locale-form button[value=en][aria-pressed=true]")

    assert has_element?(
             view,
             "#menu-logout[method=post][action='/logout'] input[name=_csrf_token]"
           )

    refute has_element?(view, "#profile-menu-panel a[href='/admin']")
    refute has_element?(view, "#header-add-anime")
    refute html =~ "/profile/history"
    refute html =~ "notifications"

    ids = html |> LazyHTML.from_document() |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")
    assert ids == Enum.uniq(ids)
  end

  test "owner sees mobile and desktop add links and actual placeholder is guarded", %{conn: conn} do
    c = login_conn(conn, role_user("owner"))
    {:ok, view, _} = live(c, "/catalog")
    assert has_element?(view, "#header-add-anime[href='/admin/content/anime/new']")
    assert has_element?(view, "#profile-menu-panel .mobile-add[href='/admin/content/anime/new']")
    assert has_element?(view, "#profile-menu-panel a[href='/admin']")
    {:ok, placeholder, _} = live(c, "/admin/content/anime/new")
    assert has_element?(placeholder, "h1", "Добавить аниме")
    assert render(placeholder) =~ "Раздел появится позже"

    assert {:error, {:redirect, %{to: "/403"}}} =
             conn |> login_conn(user()) |> live("/admin/content/anime/new")

    assert redirected_to(get(conn, "/admin/content/anime/new")) == "/login"
  end

  test "favorites is an honest authenticated placeholder in both locales", %{conn: conn} do
    c = login_conn(conn, user())

    for path <- ["/profile/bookmarks", "/en/profile/bookmarks"] do
      response = get(c, path)
      assert html_response(response, 200) =~ ~s(content="noindex,nofollow")
      {:ok, _, _} = live(c, path)
    end

    assert redirected_to(get(conn, "/profile/bookmarks")) =~ "/login"
  end

  test "active type is route-based, ordered, and survives locale and query", %{conn: conn} do
    for prefix <- ["", "/en"] do
      {:ok, view, _} = live(conn, prefix <> "/catalog/special?page=2")
      assert has_element?(view, ".types a[href='#{prefix}/catalog/special'][aria-current=page]")
      links = render(view) |> LazyHTML.from_document() |> LazyHTML.query(".types a")

      assert LazyHTML.attribute(links, "href") ==
               Enum.map(~w(tv movie ova ona special), &(prefix <> "/catalog/" <> &1))

      assert links |> LazyHTML.attribute("aria-current") == ["page"]
    end

    {:ok, view, _} = live(conn, "/catalog?return_to=/catalog/tv")
    refute has_element?(view, ".types a[aria-current]")
  end

  test "header language form follows LiveView query patches", %{conn: conn} do
    {:ok, view, _} = conn |> login_conn(user()) |> live("/catalog/tv")
    render_patch(view, "/catalog/tv?page=4")

    for id <- ["locale-form", "profile-locale-form"] do
      assert has_element?(view, "##{id} input[name=return_to][value='/catalog/tv?page=4']")
    end
  end
end
