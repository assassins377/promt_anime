defmodule AnimeWeb.ProfilesSessionsTest do
  use AnimeWeb.ConnCase
  alias Anime.Accounts
  alias Anime.Accounts.{Tokens, UserToken}
  import Ecto.Query

  test "public profile works in both locales and contains no private data", %{conn: conn} do
    u = user(%{"email" => "private-address@example.com"})

    {:ok, {raw, _}} =
      Accounts.create_session(u, false, %{ip: "203.0.113.123", user_agent: "PRIVATE-UA"})

    for prefix <- ["", "/en"] do
      response = get(conn, "#{prefix}/u/#{u.nick}")
      html = html_response(response, 200)
      assert html =~ "id=\"public-profile\""
      assert html =~ u.nick
      assert html =~ "noindex,follow"
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert get_resp_header(response, "content-security-policy") != []

      for secret <- [u.email, "203.0.113.123", "PRIVATE-UA", raw, u.hashed_password] do
        refute html =~ secret
      end

      refute html =~ "id=\"role-badge\""
      assert html =~ if(prefix == "", do: "Публичный профиль", else: "Public profile")
    end
  end

  test "missing, blocked and deletion-requested profiles return a real 404", %{conn: conn} do
    u = user()
    staff = role_user("comment_moderator")
    assert html_response(get(conn, "/u/not_present"), 404) =~ "Страница не найдена"
    assert html_response(get(conn, "/en/u/not_present"), 404) =~ "Page not found"

    for changes <- [[status: :blocked], [status: :active, deletion_requested: true]] do
      Repo.update!(Ecto.Changeset.change(u, changes))
      assert html_response(get(conn, "/u/#{u.nick}"), 404)
      html = conn |> login_conn(staff) |> get("/u/#{u.nick}") |> html_response(200)
      assert html =~ "id=\"restricted-profile\""
      refute html =~ u.email
    end
  end

  test "staff role badge follows the show_badge setting", %{conn: conn} do
    u = role_user("comment_moderator")
    assert html_response(get(conn, "/u/#{u.nick}"), 200) =~ "id=\"role-badge\""
    Repo.update!(Ecto.Changeset.change(u.role, show_badge: false))
    refute html_response(get(conn, "/u/#{u.nick}"), 200) =~ "id=\"role-badge\""
  end

  test "privacy setting immediately changes the public page", %{conn: conn} do
    u = user()
    {:ok, view, _} = live(login_conn(conn, u), "/profile/settings")

    view
    |> form("form[phx-submit=preferences]", preferences: %{show_bookmarks_public: "false"})
    |> render_submit()

    html = html_response(get(conn, "/u/#{u.nick}"), 200)
    assert html =~ "Избранное скрыто"
    refute html =~ "Избранное будет доступно"
    assert has_element?(view, "#public-profile-link[href='/u/#{u.nick}']")
  end

  test "settings mark current session and revoke other sockets without logging this one out", %{
    conn: conn
  } do
    u = user()
    current_conn = login_conn(conn, u)
    remote_conn = login_conn(conn, u)
    {:ok, remote_view, _} = live(remote_conn, "/profile/settings")
    {:ok, view, html} = live(current_conn, "/profile/settings")
    current = Tokens.find(get_session(current_conn, :user_token), [:session])
    assert has_element?(view, "#session-#{current.id} .current-session", "Текущая")
    assert html =~ "Последнее использование:"
    assert html =~ "UTC"
    view |> element("#revoke-other-sessions") |> render_click()
    assert_redirect(remote_view, "/login")
    assert render(view) =~ "Остальные сессии завершены"
    assert length(Accounts.sessions(u)) == 1
    assert Tokens.user(get_session(current_conn, :user_token))
  end

  test "revoking current session redirects in the current locale", %{conn: conn} do
    u = user()
    c = login_conn(conn, u)
    {:ok, view, _} = live(c, "/en/profile/settings")
    t = Tokens.find(get_session(c, :user_token), [:session])
    assert has_element?(view, "#session-#{t.id} .current-session", "Current")
    view |> element("#session-#{t.id} button") |> render_click()
    assert_redirect(view, "/en/login")
  end

  test "stale socket cannot choose a different keep token or revoke sessions", %{conn: conn} do
    u = user()
    c = login_conn(conn, u)
    {:ok, {other, _}} = Accounts.create_session(u, false, meta())
    {:ok, view, _} = live(c, "/profile/settings")
    Tokens.revoke(get_session(c, :user_token))
    render_click(view, "revoke_others", %{"current_token" => other})
    assert_redirect(view, "/login")
    assert Tokens.user(other)
  end

  test "forged single-session event cannot delete someone else's token", %{conn: conn} do
    u = user()
    other = user()
    {:ok, {foreign, _}} = Accounts.create_session(other, false, meta())
    {:ok, view, _} = live(login_conn(conn, u), "/profile/settings")
    render_click(view, "revoke", %{"id" => to_string(Tokens.find(foreign, [:session]).id)})
    assert Tokens.user(foreign)
    assert Repo.exists?(from t in UserToken, where: t.user_id == ^other.id)
  end

  test "remember-me cookie restores a missing session but cannot revive access after bulk revoke",
       %{conn: conn} do
    u = user()

    signed_in =
      post(conn, "/login",
        user: %{login: u.email, password: "InitialExample123", remember: "true"}
      )

    current = get_session(signed_in, :user_token)
    cookie = signed_in.resp_cookies["_anime_remember"].value
    fresh = build_conn() |> put_req_cookie("_anime_remember", cookie) |> get("/profile/settings")
    assert html_response(fresh, 200)
    assert Tokens.user(get_session(fresh, :user_token)).id == u.id
    assert get_session(fresh, :user_token) != current

    assert {:ok, _} = Accounts.revoke_other_sessions(u, current)
    denied = build_conn() |> put_req_cookie("_anime_remember", cookie) |> get("/profile/settings")
    assert redirected_to(denied) == "/login"
    assert denied.resp_cookies["_anime_remember"].max_age == 0
  end
end
