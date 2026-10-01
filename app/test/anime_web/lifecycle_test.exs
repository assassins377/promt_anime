defmodule AnimeWeb.LifecycleTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.Accounts.{User, UserToken, Tokens}

  test "settings render nickname, email, deletion forms and do not reflect passwords", %{
    conn: conn
  } do
    u = user()
    {:ok, view, _} = live(login_conn(conn, u), "/profile/settings")
    assert has_element?(view, "#nickname-form")
    assert has_element?(view, "#email-change-form")
    assert has_element?(view, "#deletion-form")

    html =
      view
      |> form("#email-change-form", email_change: %{email: "bad", current_password: "TOPSECRET"})
      |> render_change()

    assert html =~ "Неверный формат"
    refute html =~ "TOPSECRET"

    view
    |> form("#email-change-form",
      email_change: %{email: "new@example.com", current_password: "InitialExample123"}
    )
    |> render_submit()

    assert has_element?(view, "#pending-email", "new@example.com")
    assert Repo.get!(User, u.id).email == u.email
    view |> element("button[phx-click=cancel_email]") |> render_click()
    refute has_element?(view, "#pending-email")
  end

  test "recovery of empty identity forms keeps the socket alive and the account unchanged", %{
    conn: conn
  } do
    u = user()
    {:ok, view, _} = live(login_conn(conn, u), "/en/profile/settings")

    for empty <- ["", "   "] do
      view |> form("#nickname-form", nickname: %{nick: empty}) |> render_change()
      assert has_element?(view, "#nickname-form .field-error", "can't be blank")

      html =
        view
        |> form("#email-change-form", email_change: %{email: empty, current_password: ""})
        |> render_change()

      assert has_element?(view, "#email-change-form .field-error", "can't be blank")
      refute html =~ "Internal Server Error"
      assert Process.alive?(view.pid)
    end

    assert %{nick: u.nick, email: u.email} == Map.take(Repo.get!(User, u.id), [:nick, :email])
    view |> form("#nickname-form", nickname: %{nick: "recovered_draft"}) |> render_change()
    assert has_element?(view, "#nickname-form input[value=recovered_draft]")
  end

  test "nickname updates on open socket, preserves current session", %{conn: conn} do
    u = user()
    c = login_conn(conn, u)
    {:ok, view, _} = live(c, "/profile/settings")
    view |> form("#nickname-form", nickname: %{nick: "reader_changed"}) |> render_submit()
    assert render(view) =~ "reader_changed"
    assert Tokens.user(get_session(c, :user_token)).nick == "reader_changed"
  end

  test "deletion logs out live profile, restoration controller is anonymous and one-use", %{
    conn: conn
  } do
    u = user()
    c = login_conn(conn, u)
    {:ok, view, _} = live(c, "/profile/settings")

    view
    |> form("#deletion-form", deletion: %{nick: u.nick, current_password: "InitialExample123"})
    |> render_submit()

    assert_redirect(view, "/login")
    refute Tokens.user(get_session(c, :user_token))
    t = Repo.one!(from t in UserToken, where: t.user_id == ^u.id and t.context == :delete_cancel)
    path = "/en/account/restore/" <> Base.url_encode64(Tokens.mail_bytes(t), padding: false)
    restored = get(conn, path)
    assert redirected_to(restored) == "/en/login"
    assert get_resp_header(restored, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(restored, "cache-control") == ["no-store"]
    assert html_response(get(conn, path), 404)
  end

  test "revoked session cannot submit identity changes", %{conn: conn} do
    u = user()
    c = login_conn(conn, u)
    {:ok, view, _} = live(c, "/profile/settings")
    Tokens.revoke(get_session(c, :user_token))
    view |> form("#nickname-form", nickname: %{nick: "not_allowed"}) |> render_submit()
    assert_redirect(view, "/login")
    assert Repo.get!(User, u.id).nick == u.nick
  end
end
