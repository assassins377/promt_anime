defmodule AnimeWeb.AdminGuard do
  import Phoenix.Component
  use Gettext, backend: AnimeWeb.Gettext

  def on_mount(:admin, _, _, socket) do
    permission = socket.view.__admin_permission__()

    result =
      with {:ok, _} <-
             Anime.Access.protect(
               socket.assigns.current_user,
               "admin.panel.access",
               "Admin",
               nil,
               fn user -> user end
             ),
           do:
             Anime.Access.protect(
               socket.assigns.current_user,
               permission,
               "Admin",
               nil,
               fn user -> user end
             )

    case result do
      {:ok, user} ->
        locale = to_string(user.locale)
        Gettext.put_locale(AnimeWeb.Gettext, locale)

        {:cont,
         socket
         |> assign(:current_user, user)
         |> assign(:locale, locale)
         |> assign(:permissions, Anime.Access.permissions(user))
         |> assign(
           :client_meta,
           Map.put(socket.assigns.client_meta, :required_permissions, [
             "admin.panel.access",
             permission
           ])
         )
         |> Phoenix.LiveView.attach_hook(:admin_location, :handle_params, fn _, uri, socket ->
           {:cont, location(socket, URI.parse(uri).path)}
         end)
         |> Phoenix.LiveView.attach_hook(:admin_locale, :handle_event, fn
           "admin_locale", %{"locale" => locale}, socket when locale in ["ru", "en"] ->
             {:noreply, socket} =
               AnimeWeb.AdminPage.with_access(socket, permission, fn actor ->
                 case Anime.Accounts.update_preferences(
                        actor,
                        %{"locale" => locale},
                        socket.assigns.client_meta
                      ) do
                   {:ok, user} ->
                     Gettext.put_locale(AnimeWeb.Gettext, locale)

                     {:noreply,
                      socket
                      |> assign(:locale, locale)
                      |> assign(:current_user, %{user | role: actor.role})
                      |> AnimeWeb.AdminPage.refresh_error()
                      |> location(socket.assigns.admin_path)
                      |> Phoenix.LiveView.push_event("admin:locale", %{locale: locale})}

                   {:error, reason} ->
                     AnimeWeb.AdminPage.failure(socket, reason)
                 end
               end)

             {:halt, socket}

           "admin_locale", _, socket ->
             {:halt, socket}

           _, _, socket ->
             {:cont, socket}
         end)
         |> Phoenix.LiveView.attach_hook(:access_changed, :handle_info, fn
           :access_changed, socket ->
             {:halt,
              socket
              |> Phoenix.LiveView.put_flash(
                :error,
                gettext("Права изменены, доступ закрыт")
              )
              |> Phoenix.LiveView.redirect(to: "/")}

           _, socket ->
             {:cont, socket}
         end)}

      _ ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(
           :error,
           gettext("Недостаточно прав")
         )
         |> Phoenix.LiveView.redirect(to: AnimeWeb.Auth.localized(socket.assigns.locale, "/403"))}
    end
  end

  defp location(socket, path) do
    current = AnimeWeb.AdminNavigation.current(socket.assigns.permissions, path)

    title =
      Enum.join(
        [current.title, current.section_label, Anime.Settings.get("site_name", "Anime")],
        " — "
      )

    socket |> assign(:admin_path, path) |> assign(:page_title, title)
  end
end
