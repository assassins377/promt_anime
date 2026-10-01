defmodule AnimeWeb.MetricsPlug do
  @moduledoc "Read-only scrape endpoint. Never install in the public router."
  @behaviour Plug
  import Plug.Conn

  def init(options), do: options

  def call(conn, _options) do
    conn =
      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("x-robots-tag", "noindex, nofollow")

    cond do
      conn.remote_ip != {127, 0, 0, 1} ->
        send_resp(conn, 404, "Not found\n")

      conn.request_path != "/metrics" ->
        send_resp(conn, 404, "Not found\n")

      conn.method not in ["GET", "HEAD"] ->
        conn |> put_resp_header("allow", "GET, HEAD") |> send_resp(405, "Method not allowed\n")

      true ->
        serve(conn)
    end
  end

  defp serve(conn) do
    # No body parsing, cookies, sessions, XFF trust, CORS or request logging.
    case scrape() do
      {:ok, body} ->
        conn
        |> put_resp_content_type("text/plain; version=0.0.4")
        |> send_resp(200, if(conn.method == "HEAD", do: "", else: body))

      :unavailable ->
        send_resp(conn, 503, "Metrics unavailable\n")
    end
  end

  defp scrape do
    {:ok, Anime.Metrics.Exporter.scrape()}
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end
end
