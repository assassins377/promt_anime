defmodule AnimeWeb.AccountActivityTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.{Accounts, Audit}
  alias Anime.Accounts.{Tokens, UserToken}

  defp event(action), do: Repo.one!(from a in Audit, where: a.action == ^action)

  defp with_ip(conn) do
    # ConnTest's transport peer remains loopback when only remote_ip is replaced.
    # Supply both the HTTP address and WebSocket handshake metadata, not form params.
    %{conn | remote_ip: {203, 0, 113, 26}}
    |> Plug.Test.put_peer_data(%{address: {203, 0, 113, 26}, port: 1234, ssl_cert: nil})
    |> put_private(:live_view_connect_info, %{
      peer_data: %{address: {203, 0, 113, 26}, port: 1234, ssl_cert: nil},
      user_agent: "ExUnit"
    })
  end

  test "HTTP logout audits the actual browser, clears remember-me and shows confirmation", %{
    conn: conn
  } do
    u = user()
    {:ok, {other, _}} = Accounts.create_session(u, false, meta())

    signed_in =
      post(conn, "/login",
        user: %{login: u.nick, password: "InitialExample123", remember: "true"}
      )

    current = get_session(signed_in, :user_token)
    {:ok, view, _} = live(recycle(signed_in), "/profile")
    signed_out = signed_in |> recycle() |> with_ip() |> post("/logout")
    assert redirected_to(signed_out) == "/"
    assert Phoenix.Flash.get(signed_out.assigns.flash, :info) == "Вы вышли из аккаунта"
    assert signed_out.resp_cookies["_anime_remember"].max_age == 0
    assert get_session(signed_out, :user_token) == nil
    assert_redirect(view, "/login")
    refute Tokens.user(current)
    assert Tokens.user(other)

    assert Repo.aggregate(
             from(t in UserToken, where: t.user_id == ^u.id and t.context == :remember_me),
             :count
           ) == 0

    assert event("logout").ip == "203.0.113.26"
    assert event("logout").user_id == u.id
    repeated = signed_out |> recycle() |> post("/logout")
    assert redirected_to(repeated) == "/"
    assert Repo.aggregate(from(a in Audit, where: a.action == "logout"), :count) == 1
  end

  test "password reset LiveViews carry connection metadata, never client-supplied IP", %{
    conn: conn
  } do
    u = user()
    c = with_ip(conn)
    {:ok, request, _} = live(c, "/password/reset")
    render_submit(request, "submit", %{"user" => %{"email" => u.email, "ip" => "fake"}})
    assert event("password_reset_request").ip == "203.0.113.26"
    assert event("password_reset_request").actor_label == "guest"
    assert render(request) =~ "Если такой email зарегистрирован"

    token =
      Repo.one!(from t in UserToken, where: t.user_id == ^u.id and t.context == :reset_password)

    raw = Base.url_encode64(Tokens.mail_bytes(token), padding: false)
    {:ok, reset, _} = live(c, "/password/reset/#{raw}")

    reset
    |> form("#auth-form",
      user: %{password: "ChangedExample456", password_confirmation: "ChangedExample456"}
    )
    |> render_submit()

    assert_redirect(reset, "/login")
    assert event("password_change").ip == "203.0.113.26"
    assert event("password_change").old_value == nil
    assert event("password_change").new_value == nil
  end

  test "password change controller forwards IP and does not log form secrets", %{conn: conn} do
    u = user()

    c =
      conn
      |> login_conn(u)
      |> with_ip()
      |> post("/password/change",
        user: %{
          current_password: "InitialExample123",
          password: "ChangedExample456",
          password_confirmation: "ChangedExample456"
        }
      )

    assert redirected_to(c) == "/profile"
    a = event("password_change")
    assert a.ip == "203.0.113.26"
    assert a.user_id == u.id
    assert a.old_value == nil
    assert a.new_value == nil
  end

  test "profile preferences and locale endpoint feed the activity report", %{conn: conn} do
    owner = role_user("owner")
    c = conn |> login_conn(owner) |> with_ip()
    {:ok, view, _} = live(c, "/profile/settings")

    view
    |> form("form[phx-submit=preferences]", preferences: %{show_bookmarks_public: "false"})
    |> render_submit()

    assert event("preferences_change").ip == "203.0.113.26"
    changed = post(c, "/locale", locale: "en", return_to: "/profile/settings")
    assert redirected_to(changed) == "/en/profile/settings"
    assert event("locale_change").ip == "203.0.113.26"
    assert event("locale_change").new_value == %{"locale" => "en"}

    for action <- ["preferences_change", "locale_change"] do
      {:ok, report, _} = live(c, "/admin/users/activity?action[]=#{action}")
      assert has_element?(report, "#activity-#{event(action).id}")
    end
  end

  test "anonymous locale choice has no account audit record", %{conn: conn} do
    c = post(conn, "/locale", locale: "en", return_to: "/login")
    assert redirected_to(c) == "/en/login"
    refute Repo.exists?(from a in Audit, where: a.action == "locale_change")
  end
end
