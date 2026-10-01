defmodule AnimeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :anime

  @session_options AnimeWeb.RequestPipeline.session_options()
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [:peer_data, :x_headers, :user_agent, session: @session_options],
      max_frame_size: 65_536,
      log: false
    ],
    longpoll: false

  plug AnimeWeb.Metrics
  plug AnimeWeb.SecurityHeaders
  plug AnimeWeb.ClientIP
  plug AnimeWeb.RequestLog
  plug AnimeWeb.ShutdownGate
  plug :dispatch_request

  # Even errors before Router wraps the connection (e.g. malformed JSON) must
  # retain the nonce, security headers and request id in Phoenix's error response.
  defp dispatch_request(conn, _) do
    try do
      Anime.Metrics.Context.with_source(:web, fn ->
        AnimeWeb.RequestPipeline.call(conn, [])
      end)
    rescue
      error in Plug.Conn.WrapperError -> reraise error, __STACKTRACE__
    catch
      kind, reason -> Plug.Conn.WrapperError.reraise(conn, kind, reason, __STACKTRACE__)
    end
  end
end
