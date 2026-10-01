defmodule Anime.StorageHTTPTest do
  use ExUnit.Case, async: true
  alias Anime.Storage.HTTP

  defmodule StorageStub do
    @behaviour Plug
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, body, conn} = read_body(conn)
      send(owner, {:storage_request, conn.method, conn.request_path, conn.req_headers, body})

      case conn.request_path do
        "/" ->
          conn
          |> put_resp_content_type("application/xml")
          |> send_resp(200, """
          <ListAllMyBucketsResult>
            <Owner><ID>synthetic-owner</ID></Owner>
            <Buckets><Bucket>
              <Name>synthetic-bucket</Name>
              <CreationDate>2026-09-30T00:00:00Z</CreationDate>
            </Bucket></Buckets>
          </ListAllMyBucketsResult>
          """)

        "/xml" ->
          conn |> put_resp_content_type("application/xml") |> send_resp(200, "<Buckets/>")

        "/binary" ->
          conn
          |> put_resp_content_type("application/octet-stream")
          |> send_resp(200, <<0, 255, 1>>)

        "/upload" ->
          send_resp(conn, 201, "stored")

        "/head" ->
          conn |> put_resp_header("etag", ~s("synthetic-etag")) |> send_resp(200, "")

        "/redirect" ->
          conn |> put_resp_header("location", "/xml") |> send_resp(307, "redirect")

        "/retry" ->
          send_resp(conn, 503, "<Error>busy</Error>")

        "/timeout" ->
          Process.sleep(2_500)
          send_resp(conn, 200, "late")

        "/duplicate" ->
          conn = %{
            conn
            | resp_headers: [
                {"x-storage-tag", "first"},
                {"x-storage-tag", "second"} | conn.resp_headers
              ]
          }

          send_resp(conn, 200, "ok")
      end
    end
  end

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: {StorageStub, self()},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         http_options: [log_exceptions_with_status_codes: [], log_protocol_errors: false]}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}"}
  end

  test "XML and binary bodies stay raw for ExAws", %{url: url} do
    assert {:ok, %{status_code: 200, body: "<Buckets/>"}} =
             HTTP.request(:get, url <> "/xml", "", [], [])

    assert {:ok, %{status_code: 200, body: <<0, 255, 1>>}} =
             HTTP.request(:get, url <> "/binary", "", [], [])
  end

  test "ExAws signs and parses a bucket request through the configured HTTP adapter", %{url: url} do
    assert {:ok,
            %{
              status_code: 200,
              body: %{
                owner: %{id: "synthetic-owner"},
                buckets: [%{name: "synthetic-bucket", creation_date: "2026-09-30T00:00:00Z"}]
              }
            }} =
             ExAws.request(ExAws.S3.list_buckets(),
               scheme: "http://",
               host: "127.0.0.1",
               port: URI.parse(url).port,
               access_key_id: "SYNTHETIC-ACCESS",
               secret_access_key: "SYNTHETIC-SECRET",
               region: "us-east-1",
               http_client: HTTP,
               retries: [max_attempts: 1]
             )

    assert_receive {:storage_request, "GET", "/", headers, ""}
    assert {"authorization", "AWS4-HMAC-SHA256 " <> _} = List.keyfind(headers, "authorization", 0)
  end

  test "method upload bytes and signing headers survive Req/Finch/Mint", %{url: url} do
    bytes = <<0, 255, 10, 42>>

    headers = [
      {"authorization", "Synthetic-Signature"},
      {"x-amz-content-sha256", "synthetic-hash"}
    ]

    assert {:ok, %{status_code: 201, body: "stored"}} =
             HTTP.request(:put, url <> "/upload", bytes, headers, [])

    assert_receive {:storage_request, "PUT", "/upload", received, ^bytes}
    assert {"authorization", "Synthetic-Signature"} in received
    assert {"x-amz-content-sha256", "synthetic-hash"} in received
  end

  test "HEAD preserves etag and returns an empty body", %{url: url} do
    assert {:ok, %{status_code: 200, body: "", headers: headers}} =
             HTTP.request(:head, url <> "/head", "", [], [])

    assert {"etag", ~s("synthetic-etag")} in headers
  end

  test "duplicate response headers remain separate values", %{url: url} do
    assert {:ok, %{headers: headers}} = HTTP.request(:get, url <> "/duplicate", "", [], [])
    assert Enum.sort(for {"x-storage-tag", value} <- headers, do: value) == ["first", "second"]
  end

  test "signed requests are never automatically redirected", %{url: url} do
    assert {:ok, %{status_code: 307, body: "redirect"}} =
             HTTP.request(:get, url <> "/redirect", "", [], [])

    assert_receive {:storage_request, "GET", "/redirect", _, _}
    refute_receive {:storage_request, _, _, _, _}, 100
  end

  test "service errors are returned once without hidden retry", %{url: url} do
    assert {:ok, %{status_code: 503, body: "<Error>busy</Error>"}} =
             HTTP.request(:get, url <> "/retry", "", [], [])

    assert_receive {:storage_request, "GET", "/retry", _, _}
    refute_receive {:storage_request, _, _, _, _}, 100
  end

  test "receive timeout remains a transport error rather than a successful response", %{url: url} do
    assert {:error, %{reason: %Req.TransportError{reason: :timeout}}} =
             HTTP.request(:get, url <> "/timeout", "", [], [])
  end
end
