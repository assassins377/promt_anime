defmodule AnimeWeb.LocaleFlowTest do
  use AnimeWeb.ConnCase
  alias Anime.Accounts.User

  defp return_path(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#locale-form input[name=return_to]")
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  test "entry point negotiates from browser or cookie and preserves the query", %{conn: conn} do
    c = conn |> put_req_header("accept-language", "de, en-US;q=0.9, ru;q=0.8") |> get("/?page=2")
    assert redirected_to(c) == "/en?page=2"
    assert get_resp_header(c, "cache-control") == ["no-store"]
    assert html_response(c |> recycle() |> get("/en?page=2"), 200) =~ ~s(<html lang="en">)

    c =
      conn
      |> put_req_cookie("locale", "ru")
      |> put_req_header("accept-language", "en")
      |> get("/")

    assert html_response(c, 200) =~ ~s(<html lang="ru">)

    c =
      conn
      |> put_req_cookie("locale", "en")
      |> put_req_header("accept-language", "ru")
      |> get("/")

    assert redirected_to(c) == "/en"
  end

  test "stored user locale takes precedence at entry without rewriting the preference", %{
    conn: conn
  } do
    u = user(%{"locale" => "en"})

    c =
      conn
      |> login_conn(u)
      |> put_req_cookie("locale", "ru")
      |> put_req_header("accept-language", "ru")

    assert redirected_to(get(c, "/")) == "/en"
    assert Repo.get!(User, u.id).locale == :en
    u = u |> Ecto.Changeset.change(locale: :ru) |> Repo.update!()

    c =
      conn
      |> login_conn(u)
      |> put_req_cookie("locale", "en")
      |> put_req_header("accept-language", "en")

    assert html_response(get(c, "/"), 200) =~ ~s(<html lang="ru">)
    assert html_response(get(c, "/en"), 200) =~ ~s(<html lang="en">)
  end

  test "invalid preferences and unsupported browser languages fall back to Russian", %{conn: conn} do
    c =
      conn
      |> put_req_cookie("locale", "<script>")
      |> put_req_header("accept-language", "fr;q=1,de;q=0.9")
      |> get("/")

    assert html_response(c, 200) =~ ~s(<html lang="ru">)
    assert html_response(get(conn, "/"), 200) =~ ~s(<html lang="ru">)
  end

  test "HTTP and connected LiveView keep the current path and query in the switch form", %{
    conn: conn
  } do
    path = "/en/catalog/tv?genre[]=1&genre[]=2&page=3&q=a%26b"
    assert return_path(get(conn, path).resp_body) == path
    {:ok, view, html} = live(conn, path)
    assert return_path(html) == path

    assert return_path(render_patch(view, "/en/catalog/movie?page=2")) ==
             "/en/catalog/movie?page=2"
  end

  test "controller pages also return to the same public profile", %{conn: conn} do
    u = user()
    path = "/en/u/#{u.nick}?tab=ratings"
    assert return_path(html_response(get(conn, path), 200)) == path
  end

  test "guest switch uses a secure year-long cookie and preserves filter bytes", %{conn: conn} do
    path = "/catalog?genre[]=1&genre[]=2&q=a%26b"
    result = post(conn, "/locale", locale: "en", return_to: path)
    assert redirected_to(result) == "/en" <> path
    cookie = result.resp_cookies["locale"]
    assert cookie.value == "en"
    assert cookie.max_age == 365 * 86400
    assert cookie.http_only && cookie.secure && cookie.same_site == "Lax"
    assert get_session(result, :locale) == "en"

    result = result |> recycle() |> post("/locale", locale: "ru", return_to: "/en?page=2")
    assert redirected_to(result) == "/?page=2"
    assert result.resp_cookies["locale"].value == "ru"
  end

  test "signed-in choice updates the user, not the guest cookie", %{conn: conn} do
    u = user()

    result =
      conn
      |> login_conn(u)
      |> put_req_cookie("locale", "ru")
      |> post("/locale", locale: "en", return_to: "/profile/settings?tab=sessions")

    assert redirected_to(result) == "/en/profile/settings?tab=sessions"
    assert Repo.get!(User, u.id).locale == :en
    refute Map.has_key?(result.resp_cookies, "locale")
  end

  test "invalid or absent locale does not silently reset the preference", %{conn: conn} do
    u = user(%{"locale" => "en"})

    for params <- [%{}, %{locale: "de"}, %{locale: ["en"]}, %{locale: ""}] do
      result = conn |> login_conn(u) |> post("/locale", params)
      assert response(result, 400) == "Bad request"
      refute Map.has_key?(result.resp_cookies, "locale")
      assert Repo.get!(User, u.id).locale == :en
    end
  end

  test "locale selection requires CSRF protection", %{conn: conn} do
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/locale", locale: "en", return_to: "/login")
    end
  end

  test "a preference write refused after fetching the account does not report success", %{
    conn: conn
  } do
    u = user()
    Repo.update!(Ecto.Changeset.change(u, status: :blocked))

    result =
      conn
      |> init_test_session(%{})
      |> Phoenix.Controller.fetch_flash([])
      |> assign(:current_user, u)
      |> AnimeWeb.SessionController.locale(%{
        "locale" => "en",
        "return_to" => "/profile/settings"
      })

    assert redirected_to(result) == "/profile/settings"
    assert Phoenix.Flash.get(result.assigns.flash, :error)
    assert Repo.get!(User, u.id).locale == :ru
    refute Map.has_key?(result.resp_cookies, "locale")
    refute get_session(result, :locale)
  end

  test "unsafe returns after removing the prefix remain local", %{conn: conn} do
    for back <- [
          "/en//evil.example",
          "/en/%2Fevil.example",
          "/en/%5cevil.example",
          "/en/admin/users"
        ] do
      assert redirected_to(post(conn, "/locale", locale: "ru", return_to: back)) == "/"
    end
  end

  test "public page locale is bound to its route, not another tab's session or preference", %{
    conn: conn
  } do
    u = user(%{"locale" => "en"})

    c =
      conn
      |> login_conn(u)
      |> put_req_cookie("locale", "en")
      |> put_req_header("accept-language", "en")

    assert html_response(get(c, "/catalog"), 200) =~ ~s(<html lang="ru">)
    {:ok, ru, html} = c |> put_session(:locale, "en") |> live("/catalog")
    assert html =~ "Раздел появится позже"
    assert render(ru) =~ "Раздел появится позже"
    {:ok, en, html} = c |> put_session(:locale, "ru") |> live("/en/catalog")
    refute html =~ "Раздел появится позже"
    assert has_element?(en, "#locale-form button[value=en][aria-pressed=true]")
    assert Repo.get!(User, u.id).locale == :en
  end

  test "admin uses the stored user language before the cookie or browser header", %{conn: conn} do
    u = role_user("owner") |> Ecto.Changeset.change(locale: :en) |> Repo.update!()

    c =
      conn
      |> login_conn(u)
      |> put_req_cookie("locale", "ru")
      |> put_req_header("accept-language", "ru")

    assert html_response(get(c, "/admin/users"), 200) =~ ~s(<html lang="en">)
  end

  test "admin denial preserves the user's English locale in the destination and flash", %{
    conn: conn
  } do
    reader = user() |> Ecto.Changeset.change(locale: :en) |> Repo.update!()

    for path <- ["/admin", "/admin/dashboard", "/admin/users", "/admin/roles/matrix"] do
      c = conn |> login_conn(reader) |> put_req_cookie("locale", "ru")
      assert {:error, {:redirect, %{to: "/en/403", flash: flash}}} = live(c, path)
      assert flash["error"] == "Insufficient permissions"
      result = get(c, "/en/403")
      assert html_response(result, 403) =~ ~s(<html lang="en">)
      refute result.resp_body =~ "Недостаточно прав"
    end
  end

  test "anonymous admin redirect uses the valid guest preference without an admin prefix", %{
    conn: conn
  } do
    assert redirected_to(conn |> put_req_cookie("locale", "en") |> get("/admin")) == "/en/login"

    assert redirected_to(
             conn
             |> put_req_cookie("locale", "ru")
             |> put_req_header("accept-language", "en")
             |> get("/admin")
           ) == "/login"

    assert redirected_to(
             conn
             |> put_req_cookie("locale", "invalid")
             |> put_req_header("accept-language", "en-US")
             |> get("/admin")
           ) == "/en/login"
  end

  test "login return retains locale and query parameters", %{conn: conn} do
    u = user()
    c = get(conn, "/en/profile/settings?tab=sessions")
    assert redirected_to(c) == "/en/login"

    result =
      c |> recycle() |> post("/en/login", user: %{login: u.email, password: "InitialExample123"})

    assert redirected_to(result) == "/en/profile/settings?tab=sessions"
  end

  test "registration saves the language of the actual form, including for mail jobs", %{
    conn: conn
  } do
    opened = Phoenix.Token.sign(@endpoint, "registration-form", System.system_time(:second) - 4)
    result = post(conn, "/en/register", user: attrs(%{"locale" => "ru"}), opened: opened)
    u = Anime.Accounts.Tokens.user(get_session(result, :user_token))
    assert u.locale == :en

    assert [%{args: %{"locale" => "en"}}] =
             Oban.Testing.all_enqueued(repo: Repo, worker: Anime.Workers.Mail)
  end

  test "403 is translated and uses the normal layout on both locale routes", %{conn: conn} do
    result = get(conn, "/en/403")
    html = html_response(result, 403)
    assert html =~ ~s(<html lang="en">)
    assert html =~ "Insufficient permissions"
    assert html =~ ~s(href="/en/feedback")
    assert return_path(html) == "/en/403"
    assert html_response(get(conn, "/403"), 403) =~ "Недостаточно прав"
  end

  test "forced password change permits language selection without bypassing the gate", %{
    conn: conn
  } do
    u = role_user("owner") |> Ecto.Changeset.change(must_change_password: true) |> Repo.update!()
    c = conn |> login_conn(u) |> post("/locale", locale: "en", return_to: "/password/change")
    assert redirected_to(c) == "/en/password/change"
    assert Repo.get!(User, u.id).must_change_password
    assert Repo.get!(User, u.id).locale == :en

    assert html_response(c |> recycle() |> get("/en/password/change"), 200) =~
             ~s(<html lang="en">)

    assert redirected_to(c |> recycle() |> get("/admin/users")) == "/en/password/change"
    assert redirected_to(c |> recycle() |> get("/en/profile/settings")) == "/en/password/change"
  end
end
