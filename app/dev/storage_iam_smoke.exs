defmodule StorageIAMSmoke do
  alias ExAws.S3
  @origin [{"origin", "https://anime.example"}]

  def run do
    "http://127.0.0.1:59438" = System.fetch_env!("MINIO_ENDPOINT")
    dir = System.fetch_env!("STORAGE_FIXTURE_DIR")
    true = Regex.match?(~r{\A/tmp/anime-storage-check\.[a-zA-Z0-9]+\z}, dir)
    credentials = File.read!(Path.join(dir, "credentials.json")) |> Jason.decode!()
    %{"key" => key, "secret" => secret} = credentials["provision"]
    # The release command itself runs under provision, not root.
    Application.load(:anime)
    Application.put_env(:ex_aws, :access_key_id, key)
    Application.put_env(:ex_aws, :secret_access_key, secret)
    %{access_key_id: ^key} = ExAws.Config.new(:s3)
    {:ok, names} = Anime.Release.storage_setup()
    {:ok, ^names} = Anime.Release.storage_setup()
    IO.puts("PASS 1: restricted provision creates five buckets and repeats setup")

    root = [
      access_key_id: System.fetch_env!("MINIO_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("MINIO_SECRET_ACCESS_KEY")
    ]

    for bucket <- names do
      {:ok, _} = ExAws.request(S3.put_object(bucket, "sentinel.txt", "synthetic"), root)
    end

    for bucket <- ["anime-video", "anime-previews"] do
      r = signed(credentials["reader"], :get, bucket, "sentinel.txt")
      200 = r.status_code
      "synthetic" = r.body
      true = {"access-control-allow-origin", "https://anime.example"} in r.headers
    end

    denied!(S3.put_object("anime-video", "forbidden", "no"), credentials["reader"])
    denied!(S3.delete_object("anime-video", "sentinel.txt"), credentials["reader"])
    denied!(S3.get_object("anime-originals", "sentinel.txt"), credentials["reader"])
    IO.puts("PASS 2: reader signed GET through nginx works; writes and deletes denied")

    uploader = credentials["uploader"]

    {:ok, %{body: %{upload_id: upload_id}}} =
      call(S3.initiate_multipart_upload("anime-originals", "upload.bin"), uploader)

    part =
      signed(uploader, :put, "anime-originals", "upload.bin", "restricted-upload",
        query_params: [{"partNumber", "1"}, {"uploadId", upload_id}]
      )

    200 = part.status_code
    {_, etag} = Enum.find(part.headers, fn {k, _} -> k == "etag" end)
    {:ok, _} = call(S3.list_parts("anime-originals", "upload.bin", upload_id), uploader)

    {:ok, _} =
      call(
        S3.complete_multipart_upload("anime-originals", "upload.bin", upload_id, [{1, etag}]),
        uploader
      )

    {:ok, %{body: "restricted-upload"}} =
      ExAws.request(S3.get_object("anime-originals", "upload.bin"), root)

    denied!(S3.get_object("anime-originals", "upload.bin"), uploader)
    denied!(S3.delete_object("anime-originals", "upload.bin"), uploader)
    denied!(S3.put_object("anime-video", "forbidden", "no"), uploader)

    {:ok, %{body: %{upload_id: abandoned_id}}} =
      call(S3.initiate_multipart_upload("anime-originals", "abandoned.bin"), uploader)

    {:ok, _} =
      call(S3.abort_multipart_upload("anime-originals", "abandoned.bin", abandoned_id), uploader)

    IO.puts("PASS 3: uploader multipart through nginx completes; read and delete denied")

    for {_role, identity} <- credentials do
      denied!(S3.get_object("foreign-fixture", "sentinel.txt"), identity)
      denied!(S3.put_object("foreign-fixture", "forbidden", "no"), identity)
      denied!(S3.delete_object("foreign-fixture", "sentinel.txt"), identity)
      denied!(S3.put_bucket("outside-fixture", "us-east-1"), identity)
    end

    {:ok, %{body: "foreign-sentinel"}} =
      ExAws.request(S3.get_object("foreign-fixture", "sentinel.txt"), root)

    IO.puts("PASS 4: all identities denied foreign bucket access; sentinel unchanged")

    for role <- ["reader", "uploader"] do
      identity = credentials[role]
      denied!(S3.delete_bucket_policy("anime-video"), identity)
      denied!(S3.delete_bucket_lifecycle("anime-video"), identity)
      denied!(S3.get_bucket_policy("anime-video"), identity)
    end

    denied!(S3.delete_bucket("anime-video"), credentials["provision"])
    denied!(S3.get_object("anime-video", "sentinel.txt"), credentials["provision"])
    nil = Process.whereis(Anime.Supervisor)
    nil = Process.whereis(Anime.Repo)

    IO.puts(
      "PASS 5: reader/uploader bucket administration denied; provision cannot read objects or delete buckets"
    )
  end

  defp options(identity),
    do: [
      access_key_id: identity["key"],
      secret_access_key: identity["secret"],
      retries: [max_attempts: 1]
    ]

  defp call(operation, identity), do: ExAws.request(operation, options(identity))

  defp denied!(operation, identity) do
    case call(operation, identity) do
      {:error, {:http_error, 403, _}} -> :ok
      _ -> raise "Expected restricted operation to return 403"
    end
  end

  defp signed(identity, method, bucket, key, body \\ "", opts \\ []) do
    config = ExAws.Config.new(:s3, options(identity)) |> Map.put(:port, 59440)
    {:ok, url} = S3.presigned_url(config, method, bucket, key, [expires_in: 60] ++ opts)
    {:ok, response} = Anime.Storage.HTTP.request(method, url, body, @origin, [])
    response
  end
end

StorageIAMSmoke.run()
