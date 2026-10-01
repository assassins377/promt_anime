defmodule AnimeWeb.ConnectionStatusTest do
  use AnimeWeb.ConnCase

  test "public layouts provide one localized, non-interactive connection status", %{conn: conn} do
    for {path, text} <- [
          {"/login", "Связь с сервером потеряна. Переподключаемся…"},
          {"/en/login", "Connection lost. Reconnecting…"}
        ] do
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "#connection-status[role=status][aria-live=polite]", text)
      refute has_element?(view, "#connection-status button")
      refute has_element?(view, "#connection-status ~ #connection-status")
    end
  end

  test "admin connection notice follows an in-place locale change", %{conn: conn} do
    {:ok, view, _} = live(login_conn(conn, role_user("owner")), "/admin/users")
    assert has_element?(view, "#admin-content #connection-status", "Связь с сервером потеряна")
    view |> form("#admin-locale", locale: "en") |> render_change()

    assert has_element?(
             view,
             "#admin-content #connection-status",
             "Connection lost. Reconnecting…"
           )

    refute render(view) =~ "Связь с сервером потеряна"
  end

  test "access revocation flash remains translated after catalog extraction", %{conn: conn} do
    owner = role_user("owner") |> Ecto.Changeset.change(locale: :en) |> Repo.update!()
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/dashboard")
    send(view.pid, :access_changed)
    assert %{"error" => "Permissions changed. Access closed."} = assert_redirect(view, "/")
  end
end
