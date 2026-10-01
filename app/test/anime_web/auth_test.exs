defmodule AnimeWeb.AuthTest do
  use AnimeWeb.ConnCase
  alias Anime.Accounts

  test "GET pages render with CSP, no external script, and localized routes", %{conn: conn} do
    for path <- [
          "/",
          "/register",
          "/login",
          "/en/register",
          "/en/login",
          "/password/reset",
          "/catalog"
        ] do
      c = get(conn, path)
      assert html_response(c, 200) =~ "<!DOCTYPE html>" || c.resp_body =~ "<!doctype html>"
      assert [csp] = get_resp_header(c, "content-security-policy")
      assert csp =~ "object-src 'none'"
      assert csp =~ "frame-ancestors 'none'"
      assert get_resp_header(c, "x-frame-options") == ["DENY"]
      refute csp =~ "script-src 'self' 'unsafe-inline'"
      assert get_resp_header(c, "cache-control") == ["no-store"]
    end
  end

  test "profile and admin require HTTP authentication", %{conn: conn} do
    assert redirected_to(get(conn, "/profile")) == "/login"
    assert redirected_to(get(conn, "/admin")) == "/login"
  end

  test "LiveView register validates without writing user", %{conn: conn} do
    {:ok, view, _} = live(conn, "/register")

    html =
      view
      |> form("#auth-form",
        user: %{email: "bad", nick: "a", password: "x", password_confirmation: "y"}
      )
      |> render_change()

    assert html =~ "Неверный формат"
    assert Repo.aggregate(Accounts.User, :count) == 0
  end

  test "direct registration requires elapsed signed form timestamp", %{conn: conn} do
    fresh = Phoenix.Token.sign(@endpoint, "registration-form", System.system_time(:second))
    c = post(conn, "/register", user: attrs(), opened: fresh)
    assert redirected_to(c) == "/register"
    assert Repo.aggregate(Accounts.User, :count) == 0
    older = Phoenix.Token.sign(@endpoint, "registration-form", System.system_time(:second) - 4)
    c = post(conn, "/register", user: attrs(), opened: older)
    assert get_session(c, :user_token)
    assert redirected_to(c) == "/"
  end

  test "login sets secure encrypted session and logout revokes it", %{conn: conn} do
    u = user()

    c =
      post(conn, "/login",
        user: %{login: u.email, password: "InitialExample123", remember: "true"}
      )

    raw = get_session(c, :user_token)
    assert Accounts.Tokens.user(raw).id == u.id
    assert c.resp_cookies["_anime_session"].secure
    assert c.resp_cookies["_anime_remember"].http_only
    c = c |> recycle() |> post("/logout", %{})
    assert redirected_to(c) == "/"
    refute Accounts.Tokens.user(raw)
  end

  test "profile LiveView does not query future tables and ordinary admin mount denied", %{
    conn: conn
  } do
    c = login_conn(conn, user())
    {:ok, view, html} = live(c, "/profile")
    assert html =~ "Аккаунт готов"
    assert render(view) =~ "Каталог, избранное"
    assert {:error, {:redirect, %{to: "/403"}}} = live(c, "/admin")
  end

  test "revoked socket cannot change preferences", %{conn: conn} do
    u = user()
    c = login_conn(conn, u)
    {:ok, view, _} = live(c, "/profile/settings")
    raw = get_session(c, :user_token)
    Accounts.Tokens.revoke(raw)

    view
    |> form("form[phx-submit=preferences]", preferences: %{show_bookmarks_public: "false"})
    |> render_submit()

    assert_redirect(view, "/login")
    assert Repo.get!(Accounts.User, u.id).show_bookmarks_public
  end

  test "owner forced password gate precedes admin access", %{conn: conn} do
    u = role_user("owner") |> Ecto.Changeset.change(must_change_password: true) |> Repo.update!()
    c = login_conn(conn, u)
    assert redirected_to(get(c, "/admin")) == "/password/change"
  end

  test "healthz does not require session", %{conn: conn} do
    c = get(conn, "/healthz")
    assert response(c, 200) == "ok"
    assert get_resp_header(c, "cache-control") == ["no-store"]
  end

  test "CSRF is enforced on logout and login", %{conn: conn} do
    for route <- ["/logout", "/login"] do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn |> put_private(:plug_skip_csrf_protection, false) |> post(route, %{})
      end
    end
  end

  for path <- [
        "https://evil.example",
        "//evil.example",
        "/%2Fevil.example",
        "/%5cevil.example",
        "/admin/users",
        "javascript:alert(1)",
        "/ok%0d%0aX:1"
      ] do
    test "unsafe return #{path} is rejected" do
      assert AnimeWeb.Auth.safe_return(unquote(path)) == "/"
    end
  end

  test "relative return path preserved",
    do: assert(AnimeWeb.Auth.safe_return("/catalog?page=2") == "/catalog?page=2")
end
