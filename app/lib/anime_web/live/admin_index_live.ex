defmodule AnimeWeb.AdminIndexLive do
  use AnimeWeb.AdminPage, permission: "admin.panel.access"

  def mount(_, _, socket),
    do:
      {:ok, redirect(socket, to: AnimeWeb.AdminNavigation.first_path(socket.assigns.permissions))}

  def render(assigns),
    do: ~H"""
    <span></span>
    """
end
