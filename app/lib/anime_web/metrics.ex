defmodule AnimeWeb.Metrics do
  @moduledoc false
  @behaviour Plug
  def init(opts), do: Plug.Telemetry.init(Keyword.put(opts, :event_prefix, [:phoenix, :endpoint]))

  def call(conn, opts) do
    conn
    |> Plug.Conn.put_private(:anime_metrics_method, conn.method)
    |> Plug.Telemetry.call(opts)
  end
end
