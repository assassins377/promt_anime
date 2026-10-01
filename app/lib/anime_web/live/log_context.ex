defmodule AnimeWeb.LogContext do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]
  alias Anime.LogContext

  # This map goes into Phoenix's signed per-page LiveView session, not the
  # browser cookie. Two tabs cannot overwrite each other's correlation.
  def session(conn, extra \\ %{}) do
    id =
      conn |> Plug.Conn.get_resp_header("x-request-id") |> List.first() |> LogContext.valid_id()

    extra
    |> Map.put("request_id", id || LogContext.generate("live"))
    |> Map.put("shutdown_return_to", AnimeWeb.Locale.current_path(conn))
  end

  def on_mount(:default, _params, session, socket) do
    id = LogContext.valid_id(session["request_id"]) || LogContext.generate("live")
    LogContext.put(id)

    socket =
      socket
      |> assign(:request_id, id)
      |> Phoenix.LiveView.attach_hook(:log_event_context, :handle_event, fn _, _, socket ->
        LogContext.put(socket.assigns.request_id)
        {:cont, socket}
      end)
      |> Phoenix.LiveView.attach_hook(:log_params_context, :handle_params, fn _, _, socket ->
        LogContext.put(socket.assigns.request_id)
        {:cont, socket}
      end)
      |> Phoenix.LiveView.attach_hook(:log_info_context, :handle_info, fn _, socket ->
        LogContext.put(socket.assigns.request_id)
        Anime.Metrics.Context.put(:live_view)
        {:cont, socket}
      end)
      |> Phoenix.LiveView.attach_hook(:log_async_context, :handle_async, fn _, _, socket ->
        LogContext.put(socket.assigns.request_id)
        Anime.Metrics.Context.put(:live_view)
        {:cont, socket}
      end)

    {:cont, socket}
  end
end
