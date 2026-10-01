Code.eval_file(Path.join(__DIR__, "storage_smoke.exs"))

defmodule StorageTLSSmoke do
  alias ExAws.S3
  @base "https://localhost:59441"

  def run do
    dir = System.fetch_env!("STORAGE_FIXTURE_DIR")
    true = Regex.match?(~r{\A/tmp/anime-storage-check\.[a-zA-Z0-9]+\z}, dir)
    ca = Path.join(dir, "ca.crt")

    config =
      ExAws.Config.new(:s3) |> Map.merge(%{scheme: "https://", host: "localhost", port: 59441})

    {:ok, url} = S3.presigned_url(config, :get, "anime-video", "probe.txt", expires_in: 60)
    true = String.starts_with?(url, @base <> "/")
    {:ok, %{status: 200, body: "synthetic-content"}} = request(:get, url, ca)

    IO.puts(
      "PASS 1: trusted fixture CA and matching DNS name accepted through two nginx listeners"
    )

    {:error, error} = request(:get, url, nil)
    true = String.contains?(inspect(error.reason), "unknown_ca")
    {:error, _} = Anime.Storage.HTTP.request(:get, url, "", [], [])
    IO.puts("PASS 2: untrusted certificate rejected, including production HTTP adapter")

    {:error, error} = request(:get, String.replace(url, "localhost", "127.0.0.1"), ca)
    true = String.contains?(inspect(error.reason), "hostname_check_failed")
    IO.puts("PASS 3: wrong server identity rejected even with trusted CA")

    {:ok, range} = request(:get, url, ca, "", [{"range", "bytes=0-8"}])
    206 = range.status
    "synthetic" = range.body
    ["https://anime.example"] = range.headers["access-control-allow-origin"]
    {:ok, %{status: 403}} = request(:get, url <> "&changed=1", ca)
    IO.puts("PASS 4: signed HTTPS Range and CORS work; altered signature rejected")

    bucket = "anime-originals"
    key = "tls/часть +%.bin"

    {:ok, %{body: %{upload_id: id}}} =
      S3.initiate_multipart_upload(bucket, key) |> ExAws.request()

    try do
      {:ok, put} =
        S3.presigned_url(config, :put, bucket, key,
          expires_in: 60,
          query_params: [{"partNumber", "1"}, {"uploadId", id}]
        )

      {:ok, %{status: 204}} =
        request(:options, put, ca, "", [{"access-control-request-method", "PUT"}])

      {:ok, part} = request(:put, put, ca, "tls-upload")
      200 = part.status
      [etag] = part.headers["etag"]
      ["https://anime.example"] = part.headers["access-control-allow-origin"]
      {:ok, _} = S3.complete_multipart_upload(bucket, key, id, [{1, etag}]) |> ExAws.request()
      {:ok, %{body: "tls-upload"}} = S3.get_object(bucket, key) |> ExAws.request()
    after
      S3.abort_multipart_upload(bucket, key, id) |> ExAws.request()
    end

    IO.puts("PASS 5: HTTPS multipart preflight, signed PUT, ETag and completion work")
    nil = Process.whereis(Anime.Supervisor)
    nil = Process.whereis(Anime.Repo)
  end

  defp request(method, url, ca, body \\ "", headers \\ []) do
    tls = if ca, do: [cacertfile: ca], else: []

    Req.request(
      method: method,
      url: url,
      body: body,
      headers: [{"origin", "https://anime.example"} | headers],
      retry: false,
      redirect: false,
      decode_body: false,
      connect_options: [timeout: 2000, transport_opts: tls],
      receive_timeout: 2000
    )
  end
end

StorageTLSSmoke.run()
