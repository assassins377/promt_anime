defmodule AnimeWeb.AdminList do
  @moduledoc "Cancellable refreshes of already-mounted admin lists; never caches authorization."
  import Phoenix.Component
  import Phoenix.LiveView
  alias AnimeWeb.AdminPage

  def init(socket) do
    socket
    |> assign(list_loading: false, list_failed: false, list_generation: 0)
    |> attach_hook(:admin_list_async, :handle_async, &complete/3)
    |> attach_hook(:admin_list_timeout, :handle_info, &timeout/2)
    |> attach_hook(:admin_list_actions, :handle_event, &event/3)
  end

  def load(socket, query, fetch, apply_result) do
    socket =
      socket
      |> stop()
      |> assign(query: query, list_failed: false)
      |> put_private(:admin_list_fetch, fetch)
      |> put_private(:admin_list_apply, apply_result)

    # The initial HTTP/connected render retains a complete, accessible table.
    if connected?(socket) && socket.assigns.listing != nil do
      generation = socket.assigns.list_generation + 1
      token = socket.assigns.session_token
      permission = socket.view.__admin_permission__()
      timer = Process.send_after(self(), {:admin_list_timeout, generation}, 15_000)

      {:noreply,
       socket
       |> assign(list_loading: true, list_generation: generation)
       |> put_private(:admin_list_timer, timer)
       |> start_async(
         :admin_list,
         Anime.LogContext.wrap(fn ->
           actor = Anime.Accounts.Tokens.user(token)

           result =
             if Anime.Access.allowed?(actor, "admin.panel.access") &&
                  Anime.Access.allowed?(actor, permission),
                do: fetch.(actor),
                else: {:error, :forbidden}

           {generation, result}
         end)
       )}
    else
      AdminPage.with_access(socket, socket.view.__admin_permission__(), fn actor ->
        accept(socket, fetch.(actor), actor)
      end)
    end
  end

  defp stop(socket) do
    if timer = socket.private[:admin_list_timer], do: Process.cancel_timer(timer)
    cancel_async(socket, :admin_list)
  end

  defp complete(:admin_list, {:ok, {generation, result}}, socket) do
    if socket.assigns.list_loading && generation == socket.assigns.list_generation do
      socket = stop(socket) |> assign(list_loading: false, list_failed: true)

      {:noreply, socket} =
        AdminPage.with_access(socket, socket.view.__admin_permission__(), fn actor ->
          accept(socket, result, actor)
        end)

      {:halt, socket}
    else
      {:halt, socket}
    end
  end

  defp complete(:admin_list, {:exit, _}, socket) do
    if socket.assigns.list_loading do
      {:noreply, socket} = failed(stop(socket), :list_failed)
      {:halt, socket}
    else
      {:halt, socket}
    end
  end

  defp complete(_, _, socket), do: {:cont, socket}

  defp timeout({:admin_list_timeout, generation}, socket) do
    if socket.assigns.list_loading && generation == socket.assigns.list_generation do
      {:noreply, socket} = failed(stop(socket), :list_failed)
      {:halt, socket}
    else
      {:halt, socket}
    end
  end

  defp timeout(_, socket), do: {:cont, socket}

  defp accept(socket, {:ok, listing}, actor) do
    socket = assign(socket, list_loading: false, list_failed: false)

    socket =
      case socket.assigns[:admin_failure] do
        {reason, message} when reason in [:list_failed, :list_loading] ->
          if Phoenix.Flash.get(socket.assigns.flash, :error) == message,
            do: clear_flash(socket, :error),
            else: socket

        _ ->
          socket
      end

    socket.private.admin_list_apply.(socket, listing, actor)
  end

  defp accept(socket, {:error, reason}, _), do: failed(socket, reason)

  defp failed(socket, reason) do
    socket |> assign(list_loading: false, list_failed: true) |> AdminPage.failure(reason)
  end

  defp event("retry_list", _, socket) do
    {:noreply, socket} =
      AdminPage.with_access(socket, socket.view.__admin_permission__(), fn _ ->
        load(
          socket,
          socket.assigns.query,
          socket.private.admin_list_fetch,
          socket.private.admin_list_apply
        )
      end)

    {:halt, socket}
  end

  defp event(event, _, socket) do
    if (socket.assigns.list_loading || socket.assigns.list_failed) &&
         event not in ~w(filter page activity_filter admin_locale validate cancel cancel_edit cancel_bulk) do
      {:noreply, socket} =
        AdminPage.with_access(socket, socket.view.__admin_permission__(), fn _ ->
          AdminPage.failure(socket, :list_loading)
        end)

      {:halt, socket}
    else
      {:cont, socket}
    end
  end
end
