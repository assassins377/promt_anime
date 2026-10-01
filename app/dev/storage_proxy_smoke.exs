# Only invoked with a new MinIO and loopback nginx by check_storage_local.sh.
Code.eval_file(Path.join(__DIR__, "storage_smoke.exs"))

defmodule StorageProxySmoke do
  alias ExAws.S3
  @origin "https://anime.example"
  @base "http://127.0.0.1:59440"

  def run do
    config = ExAws.Config.new(:s3) |> Map.put(:port, 59440)
    # Reserved characters exercise percent encoding through nginx and the signer.
    key = "folder/тест + percent% file.txt"

    for bucket <- ["anime-video", "anime-previews"] do
      {:ok, _} = S3.put_object(bucket, key, "0123456789") |> ExAws.request()
      {:ok, url} = S3.presigned_url(config, :get, bucket, key, expires_in: 60)
      true = String.starts_with?(url, @base <> "/")
      r = request(:get, url, "", [{"origin", @origin}, {"range", "bytes=2-5"}])
      206 = r.status_code
      "2345" = r.body
      "bytes 2-5/10" = header(r, "content-range")
      cors!(r)
      true = String.contains?(header(r, "access-control-expose-headers"), "Content-Range")
      denied = request(:get, url, "", [{"origin", "https://evil.example"}])
      403 = denied.status_code
      nil = header(denied, "access-control-allow-origin")
      tampered = request(:get, url <> "&unexpected=1", "", [{"origin", @origin}])
      403 = tampered.status_code
      cors!(tampered)
      anonymous = request(:get, @base <> "/#{bucket}/probe.txt", "", [{"origin", @origin}])
      403 = anonymous.status_code
      cors!(anonymous)
    end

    bucket = "anime-originals"
    key = "multipart/probe +%.bin"

    {:ok, %{body: %{upload_id: upload_id}}} =
      S3.initiate_multipart_upload(bucket, key) |> ExAws.request()

    try do
      {:ok, url} =
        S3.presigned_url(config, :put, bucket, key,
          expires_in: 60,
          query_params: [{"partNumber", "1"}, {"uploadId", upload_id}]
        )

      preflight =
        request(:options, url, "", [
          {"origin", @origin},
          {"access-control-request-method", "PUT"},
          {"access-control-request-headers", "content-type"}
        ])

      204 = preflight.status_code
      cors!(preflight)

      part =
        request(:put, url, "multipart-through-nginx", [
          {"origin", @origin},
          {"content-type", "application/octet-stream"}
        ])

      200 = part.status_code
      cors!(part)
      etag = header(part, "etag")
      true = is_binary(etag) and byte_size(etag) > 0
      true = String.contains?(header(part, "access-control-expose-headers"), "ETag")

      {:ok, _} =
        S3.complete_multipart_upload(bucket, key, upload_id, [{1, etag}]) |> ExAws.request()

      {:ok, %{body: "multipart-through-nginx"}} = S3.get_object(bucket, key) |> ExAws.request()
    after
      # Aborting an already completed fixture is harmless; clean up failed parts too.
      S3.abort_multipart_upload(bucket, key, upload_id) |> ExAws.request()
    end

    nil = Process.whereis(Anime.Supervisor)
    nil = Process.whereis(Anime.Repo)

    IO.puts(
      "PASS: real MinIO through nginx: encoded keys, signed range GET, CORS, signature tampering, anonymous denial, signed multipart PUT with ETag and completion"
    )
  end

  defp request(method, url, body, headers) do
    {:ok, response} = Anime.Storage.HTTP.request(method, url, body, headers, [])
    response
  end

  defp header(response, key) do
    Enum.find_value(response.headers, fn {name, value} ->
      if String.downcase(name) == key, do: value
    end)
  end

  defp cors!(response) do
    @origin = header(response, "access-control-allow-origin")
    nil = header(response, "access-control-allow-credentials")
  end
end

StorageProxySmoke.run()
