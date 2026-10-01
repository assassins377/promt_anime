defmodule AnimeWeb.RequestLog do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _) do
    started = System.monotonic_time()
    method = conn.method

    register_before_send(conn, fn conn ->
      path = Anime.Log.safe_path(conn.request_path, method)

      unless conn.status == 404 and path in ["/assets/*path", "/images/*path", "/favicon.ico"] do
        fields = %{
          method: method,
          path: path,
          status: conn.status,
          duration_ms:
            System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) /
              1000,
          user_id: user_id(conn)
        }

        Anime.Log.emit(:http_response, fields)
      end

      conn
    end)
  end

  defp user_id(%{assigns: %{current_user: %{id: id}}}) when is_integer(id), do: id
  defp user_id(_), do: nil
end
