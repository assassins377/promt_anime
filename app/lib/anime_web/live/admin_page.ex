defmodule AnimeWeb.AdminPage do
  defmacro __using__(opts) do
    permission = Keyword.fetch!(opts, :permission)

    unless permission in Anime.Access.Catalog.codes(),
      do: raise(ArgumentError, "Unknown admin permission")

    quote do
      use AnimeWeb, :live_view
      import AnimeWeb.AdminPage, only: [with_access: 3, failure: 2]
      import AnimeWeb.AdminComponents
      import AnimeWeb.AdminFormat, only: [number: 2]
      import Anime.Access.Labels, only: [role_name: 1, permission_name: 1, group_name: 1]
      def __admin_permission__, do: unquote(permission)
    end
  end

  def with_access(socket, permission, fun) do
    actor = Anime.Accounts.Tokens.user(socket.assigns.session_token)

    if Anime.Access.allowed?(actor, "admin.panel.access") &&
         Anime.Access.allowed?(actor, permission) do
      fun.(actor)
    else
      Anime.Audit.record(actor, permission, "Admin", nil, :denied)
      failure(socket, :forbidden)
    end
  end

  def failure(socket, reason) do
    # Only retain a safe discriminator, never changesets or arbitrary error payloads.
    reason =
      case reason do
        %Ecto.Changeset{} -> :invalid_fields
        atom when is_atom(atom) -> atom
        _ -> :unknown_error
      end

    message = AnimeWeb.AdminErrors.message(reason)

    {:noreply,
     socket
     |> Phoenix.Component.assign(:admin_failure, {reason, message})
     |> Phoenix.LiveView.put_flash(:error, message)}
  end

  def refresh_error(socket) do
    case socket.assigns[:admin_failure] do
      {reason, previous} ->
        if Phoenix.Flash.get(socket.assigns.flash, :error) == previous do
          {:noreply, socket} = failure(socket, reason)
          socket
        else
          socket
        end

      _ ->
        socket
    end
  end
end

defmodule AnimeWeb.AdminRouteCheck do
  def __after_compile__(env, _) do
    for route <- env.module.__routes__(),
        String.starts_with?(route.path, "/admin"),
        {view, _, _, _} <- [route.metadata[:phoenix_live_view]] do
      Code.ensure_compiled!(view)

      unless function_exported?(view, :__admin_permission__, 0),
        do:
          raise(CompileError,
            file: env.file,
            description: "Admin LiveView #{inspect(view)} has no required permission"
          )
    end
  end
end
