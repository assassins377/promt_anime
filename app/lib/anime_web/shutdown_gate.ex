defmodule AnimeWeb.ShutdownGate do
  @moduledoc "Reject new application work after the load-balancer withdrawal period."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _) do
    if Anime.Shutdown.rejecting?() and conn.request_path not in ["/healthz", "/readyz"] do
      conn
      |> put_resp_header("retry-after", "1")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(503, "Service restarting")
      |> halt()
    else
      conn
    end
  end

  # Only new mounts traverse this callback. Existing LiveViews continue handling
  # events during their grace period. The return path is in the signed LV session.
  def on_mount(:default, _params, session, socket) do
    if Anime.Shutdown.rejecting?() do
      path = session["shutdown_return_to"] || "/"
      {:halt, Phoenix.LiveView.redirect(socket, to: path)}
    else
      if is_pid(socket.transport_pid), do: Anime.LiveTransports.track(socket.transport_pid)
      {:cont, socket}
    end
  end
end
