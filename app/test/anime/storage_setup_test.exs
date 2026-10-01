defmodule Anime.StorageSetupTest do
  use ExUnit.Case, async: true
  alias Anime.Storage.Setup

  defmodule WireStub do
    import Plug.Conn
    def init(request), do: request

    def call(conn, request) do
      conn = fetch_query_params(conn)
      {:ok, body, conn} = read_body(conn)

      op = %ExAws.Operation.S3{
        http_method:
          %{"HEAD" => :head, "GET" => :get, "PUT" => :put, "DELETE" => :delete}[conn.method],
        bucket: String.trim(conn.request_path, "/"),
        resource: conn.query_params |> Map.keys() |> List.first() || "",
        body: body
      }

      case get_req_header(conn, "authorization") do
        ["AWS4-HMAC-SHA256 " <> _] ->
          case request.(op) do
            {:ok, result} ->
              send_resp(conn, 200, Map.get(result, :body, ""))

            {:error, {:http_error, status, result}} ->
              send_resp(conn, status, Map.get(result, :body, ""))
          end

        _ ->
          send_resp(conn, 403, "unsigned")
      end
    end
  end

  test "real signed HTTP adapter completes provisioning twice against isolated stub" do
    {_, fake} = stub()

    server =
      start_supervised!(
        {Bandit, plug: {WireStub, fake}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    request = fn operation ->
      ExAws.request(operation,
        scheme: "http://",
        host: "127.0.0.1",
        port: port,
        access_key_id: "SYNTHETIC",
        secret_access_key: "SYNTHETIC",
        region: "us-east-1",
        http_client: Anime.Storage.HTTP,
        retries: [max_attempts: 1]
      )
    end

    assert {:ok, names} = Setup.run(env: %{}, request: request)
    assert {:ok, ^names} = Setup.run(env: %{}, request: request)
  end

  defp policy_missing do
    {:error, {:http_error, 404, %{body: "<Error><Code>NoSuchBucketPolicy</Code></Error>"}}}
  end

  defp stub(opts \\ []) do
    {:ok, agent} =
      start_supervised({Agent, fn -> %{calls: [], lifecycle: %{}, buckets: MapSet.new()} end})

    request = fn op ->
      Agent.get_and_update(agent, fn state ->
        state = update_in(state.calls, &[op | &1])
        override = Keyword.get(opts, :override, fn _ -> nil end).(op)

        {result, state} =
          if override do
            {override, state}
          else
            case {op.http_method, op.resource} do
              {:head, ""} ->
                if Keyword.get(opts, :existing, false) or MapSet.member?(state.buckets, op.bucket),
                  do: {{:ok, %{}}, state},
                  else: {{:error, {:http_error, 404, %{}}}, state}

              {:put, ""} ->
                {{:ok, %{}}, update_in(state.buckets, &MapSet.put(&1, op.bucket))}

              {:get, "versioning"} ->
                {{:ok,
                  %{
                    body:
                      "<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"/>"
                  }}, state}

              {:delete, "policy"} ->
                {{:ok, %{}}, state}

              {:get, "policy"} ->
                {policy_missing(), state}

              {:put, "lifecycle"} ->
                {{:ok, %{}}, put_in(state, [:lifecycle, op.bucket], op.body)}

              {:get, "lifecycle"} ->
                {{:ok, %{body: state.lifecycle[op.bucket]}}, state}
            end
          end

        {result, state}
      end)
    end

    {agent, request}
  end

  test "all five names validated before network, including collisions" do
    assert length(Setup.plan(%{})) == 5
    assert "my-originals" in Setup.plan(%{"MINIO_BUCKET_ORIGINALS" => "my-originals"})

    for name <- ["", "ab", "Upper", "a/b", "a.b", String.duplicate("a", 64)] do
      assert_raise ArgumentError, fn ->
        Setup.run(env: %{"MINIO_BUCKET_VIDEO" => name}, request: fn _ -> flunk("network") end)
      end
    end

    assert_raise ArgumentError, fn -> Setup.plan(%{"MINIO_BUCKET_VIDEO" => "anime-originals"}) end
  end

  test "creates only missing buckets; repeat preserves configuration and never calls CORS/object APIs" do
    {agent, request} = stub()
    assert {:ok, names} = Setup.run(env: %{}, request: request)
    first = Agent.get(agent, & &1.lifecycle)
    assert {:ok, ^names} = Setup.run(env: %{}, request: request)
    assert Agent.get(agent, & &1.lifecycle) == first
    calls = Agent.get(agent, & &1.calls)
    assert Enum.count(calls, &(&1.http_method == :put and &1.resource == "")) == 5

    assert Enum.all?(
             calls,
             &(&1.path == "/" and &1.resource in ["", "policy", "versioning", "lifecycle"])
           )

    assert Enum.all?(first, fn {_, xml} ->
             not (xml =~ "AbortIncompleteMultipartUpload") and xml =~ "<Days>7" and
               xml =~ "exports/"
           end)
  end

  for status <- ["Enabled", "Suspended"] do
    test "rejects #{status} before any write" do
      status = unquote(status)

      {agent, request} =
        stub(
          existing: true,
          override: fn
            %{resource: "versioning"} ->
              {:ok,
               %{
                 body:
                   "<VersioningConfiguration><Status>#{status}</Status></VersioningConfiguration>"
               }}

            _ ->
              nil
          end
        )

      assert_raise RuntimeError, ~r/require_unversioned_bucket/, fn ->
        Setup.run(env: %{}, request: request)
      end

      assert Enum.all?(Agent.get(agent, & &1.calls), &(&1.http_method in [:get, :head]))
    end
  end

  test "403 is never mistaken for missing and response secrets do not escape" do
    {agent, request} =
      stub(override: fn _ -> {:error, {:http_error, 403, %{body: "PRIVATE-TOKEN"}}} end)

    error = assert_raise RuntimeError, fn -> Setup.run(env: %{}, request: request) end
    assert error.message == "Storage setup failed: anime-originals: head_bucket"
    assert length(Agent.get(agent, & &1.calls)) == 1
  end

  for {method, resource, label} <- [
        {:put, "", "create_bucket"},
        {:delete, "policy", "delete_policy"},
        {:put, "lifecycle", "put_lifecycle"},
        {:get, "lifecycle", "get_lifecycle"}
      ] do
    test "stops at #{label}, without continuing subsequent buckets" do
      {agent, request} =
        stub(
          override: fn op ->
            if op.http_method == unquote(method) and op.resource == unquote(resource),
              do: {:error, :denied}
          end
        )

      assert_raise RuntimeError, ~r/#{unquote(label)}/, fn ->
        Setup.run(env: %{}, request: request)
      end

      writes = Agent.get(agent, & &1.calls) |> Enum.reject(&(&1.http_method == :head))
      assert Enum.all?(writes, &(&1.bucket == "anime-originals"))
    end
  end

  test "refuses remaining policy and incorrect lifecycle readback" do
    for resource <- ["policy", "lifecycle"] do
      request = fn op ->
        case {op.http_method, op.resource} do
          {:head, _} -> {:ok, %{}}
          {:get, "versioning"} -> {:ok, %{body: "<VersioningConfiguration/>"}}
          {:get, "policy"} when resource != "policy" -> policy_missing()
          {:get, ^resource} -> {:ok, %{body: "<Wrong/>"}}
          _ -> {:ok, %{}}
        end
      end

      assert_raise RuntimeError, fn -> Setup.run(env: %{}, request: request) end
    end
  end

  test "rejects malformed XML, DTD and oversize response" do
    for body <- [
          "not xml",
          "<!DOCTYPE x SYSTEM 'file:///etc/passwd'><VersioningConfiguration/>",
          String.duplicate("x", 65_537)
        ] do
      request = fn
        %{http_method: :head} -> {:ok, %{}}
        _ -> {:ok, %{body: body}}
      end

      assert_raise RuntimeError, ~r/require_unversioned/, fn ->
        Setup.run(env: %{}, request: request)
      end
    end
  end

  test "adapter exceptions are sanitized" do
    assert_raise RuntimeError, "Storage setup failed: anime-originals: head_bucket", fn ->
      Setup.run(env: %{}, request: fn _ -> raise "SECRET" end)
    end
  end
end
