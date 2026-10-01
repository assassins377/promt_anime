defmodule AnimeWeb.ClientIP do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn
  alias Anime.ClientIP
  @request_id_options Plug.RequestId.init([])

  def init(opts), do: opts

  def call(conn, _opts) do
    result = ClientIP.resolve(get_peer_data(conn).address, conn.req_headers)

    conn =
      %{conn | remote_ip: result.ip}
      |> assign(:client_country, result.country)
      |> put_private(:client_ip, result)
      |> filter_request_id(result.trusted_peer)
      |> Plug.RequestId.call(@request_id_options)

    ClientIP.observe(result, :http)
    conn
  end

  defp filter_request_id(conn, trusted) do
    case get_req_header(conn, "x-request-id") do
      [value] when trusted and byte_size(value) in 20..200 ->
        if Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, value),
          do: conn,
          else: drop_request_ids(conn)

      _ ->
        drop_request_ids(conn)
    end
  end

  # Plug.Conn.delete_req_header/2 removes only the first occurrence. A remaining
  # duplicate must not be accepted by Plug.RequestId as the next valid value.
  defp drop_request_ids(conn),
    do: %{
      conn
      | req_headers: Enum.reject(conn.req_headers, fn {key, _} -> key == "x-request-id" end)
    }
end
