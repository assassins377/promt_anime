# Invoked only by check_storage_local.sh with a new MinIO and synthetic credentials.
defmodule StorageSmoke do
  alias ExAws.S3

  def run do
    "http://127.0.0.1:59438" = System.fetch_env!("MINIO_ENDPOINT")
    {:ok, names} = Anime.Release.storage_setup()
    5 = length(names)
    config = ExAws.Config.new(:s3)

    for bucket <- names do
      {:ok, _} = S3.put_object(bucket, "probe.txt", "synthetic-content") |> ExAws.request()
      {:ok, %{body: "synthetic-content"}} = S3.get_object(bucket, "probe.txt") |> ExAws.request()

      {:ok, %{status_code: 403}} =
        Anime.Storage.HTTP.request(:get, "http://127.0.0.1:59438/#{bucket}/probe.txt", "", [], [])

      {:ok, signed} = S3.presigned_url(config, :get, bucket, "probe.txt", expires_in: 60)

      {:ok, %{status_code: 200, body: "synthetic-content"}} =
        Anime.Storage.HTTP.request(:get, signed, "", [], [])

      tampered = String.replace(signed, "probe.txt", "other.txt")
      {:ok, %{status_code: 403}} = Anime.Storage.HTTP.request(:get, tampered, "", [], [])
    end

    # Deliberate policy drift on this freshly created fixture only.
    bucket = hd(names)

    policy =
      Jason.encode!(%{
        Version: "2012-10-17",
        Statement: [
          %{
            Effect: "Allow",
            Principal: "*",
            Action: ["s3:GetObject"],
            Resource: ["arn:aws:s3:::#{bucket}/*"]
          }
        ]
      })

    {:ok, _} = S3.put_bucket_policy(bucket, policy) |> ExAws.request()

    {:ok, %{status_code: 200}} =
      Anime.Storage.HTTP.request(:get, "http://127.0.0.1:59438/#{bucket}/probe.txt", "", [], [])

    {:ok, ^names} = Anime.Release.storage_setup()

    for bucket <- names do
      {:ok, %{body: "synthetic-content"}} = S3.get_object(bucket, "probe.txt") |> ExAws.request()

      {:ok, %{status_code: 403}} =
        Anime.Storage.HTTP.request(:get, "http://127.0.0.1:59438/#{bucket}/probe.txt", "", [], [])
    end

    nil = Process.whereis(Anime.Supervisor)
    nil = Process.whereis(Anime.Repo)

    IO.puts(
      "PASS: five buckets, lifecycle readback, private access, signed GET, tamper rejection, policy drift repaired, objects preserved"
    )
  end
end

StorageSmoke.run()
