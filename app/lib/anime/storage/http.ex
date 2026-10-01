defmodule Anime.Storage.HTTP do
  @behaviour ExAws.Request.HttpClient
  def request(method, url, body, headers, _opts) do
    case Req.request(
           method: method,
           url: url,
           body: body,
           headers: headers,
           retry: false,
           redirect: false,
           receive_timeout: 2000,
           connect_options: [timeout: 2000],
           decode_body: false
         ) do
      {:ok, r} ->
        {:ok,
         %{
           status_code: r.status,
           body: r.body,
           headers: Enum.flat_map(r.headers, fn {k, vs} -> Enum.map(vs, &{k, &1}) end)
         }}

      {:error, e} ->
        {:error, %{reason: e}}
    end
  end
end
