defmodule AnimeWeb.AdminLive do
  use AnimeWeb.AdminPage, permission: "admin.dashboard.view"
  @required_permission "admin.dashboard.view"
  def mount(_, _, socket) do
    case Anime.Access.protect(
           socket.assigns.current_user,
           @required_permission,
           "Dashboard",
           nil,
           fn u -> u end
         ) do
      {:ok, _} ->
        {:ok, assign(socket, :codes, Anime.Access.permissions(socket.assigns.current_user)),
         layout: {AnimeWeb.Layouts, :admin}}

      _ ->
        {:ok, redirect(socket, to: AnimeWeb.Auth.localized(socket.assigns.locale, "/403"))}
    end
  end

  def render(assigns) do
    ~H"""
    <section :for={locale <- [@locale]} :key={locale} class="admin">
      <h1>{gettext("Дашборд")}</h1><p>
        {gettext("Каркас доступа готов. Разделы управления появятся по порядку реализации.")}
      </p><section class="panel">
        <h2>{@current_user.role.name}</h2><p>{length(@codes)} / 99</p><details>
          <summary>{gettext("Разрешения")}</summary><ul class="permission-list">
            <li :for={code <- @codes}>{code}</li>
          </ul>
        </details>
      </section>
    </section>
    """
  end
end
