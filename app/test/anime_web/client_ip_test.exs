defmodule AnimeWeb.ClientIPTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  import ExUnit.CaptureLog
  alias Anime.{ClientIP, Audit}
  alias Anime.Accounts.UserToken

  @peer {10, 0, 0, 2}
  @client {203, 0, 113, 7}
  @request_id "test-trusted-request-id-123"

  setup do
    previous = Application.fetch_env!(:anime, :trusted_proxies)
    Application.put_env(:anime, :trusted_proxies, ClientIP.parse_trusted!("10.0.0.0/8"))
    on_exit(fn -> Application.put_env(:anime, :trusted_proxies, previous) end)
    :ok
  end

  defp proxy(conn, value \\ "203.0.113.7,10.0.0.1") do
    conn
    |> Plug.Test.put_peer_data(%{address: @peer, port: 1234, ssl_cert: nil})
    |> put_req_header("x-forwarded-for", value)
    |> put_req_header("x-geo-country", "RU")
    |> put_req_header("x-request-id", @request_id)
  end

  test "Endpoint uses transport peer, not an already overwritten remote_ip", %{conn: conn} do
    conn = %{conn | remote_ip: @peer}

    capture_log(fn ->
      c = conn |> put_req_header("x-forwarded-for", "203.0.113.7") |> get("/healthz")
      assert c.remote_ip == {127, 0, 0, 1}
      assert c.assigns.client_country == "unknown"
      assert c.private.client_ip.forwarded == :untrusted_peer
      assert response(c, 200)
    end)
  end

  test "trusted transport changes HTTP metadata before routing and preserves safe request ID", %{
    conn: conn
  } do
    c = conn |> proxy() |> get("/healthz")
    assert response(c, 200)
    assert c.remote_ip == @client
    assert AnimeWeb.Auth.meta(c).ip == "203.0.113.7"
    assert c.assigns.client_country == "RU"
    assert get_resp_header(c, "x-request-id") == [@request_id]
  end

  test "direct request ID is regenerated; duplicate and unsafe trusted IDs are discarded", %{
    conn: conn
  } do
    c = conn |> put_req_header("x-request-id", @request_id) |> get("/healthz")
    refute get_resp_header(c, "x-request-id") == [@request_id]

    for id <- [
          "short",
          String.duplicate("x", 201),
          "<script>alert('x')</script>",
          "unsafe request id with spaces"
        ] do
      c = conn |> proxy() |> put_req_header("x-request-id", id) |> get("/healthz")
      [generated] = get_resp_header(c, "x-request-id")
      refute generated == id
      assert byte_size(generated) in 20..200
    end

    for peer <- [@peer, {127, 0, 0, 1}] do
      c = proxy(conn) |> Plug.Test.put_peer_data(%{address: peer, port: 1234, ssl_cert: nil})
      c = %{c | req_headers: [{"x-request-id", "another-valid-request-id-123"} | c.req_headers]}
      # ConnTest dispatch merges duplicate request headers. Exercise the Plug with
      # the original header list so this assertion covers the ambiguous input.
      capture_log(fn ->
        c = AnimeWeb.ClientIP.call(c, [])
        refute get_resp_header(c, "x-request-id") == [@request_id]
        refute get_resp_header(c, "x-request-id") == ["another-valid-request-id-123"]
        assert get_req_header(c, "x-request-id") == []
      end)
    end
  end

  test "rejected chain emits only fixed reason/count, never the original header or IP", %{
    conn: conn
  } do
    handler = "client-ip-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:anime, :client_ip, :rejected],
        &__MODULE__.forward_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    log =
      capture_log(fn ->
        c = conn |> proxy("PRIVATE-SENTINEL,203.0.113.7") |> get("/healthz")
        assert c.remote_ip == @peer
        assert c.assigns.client_country == "unknown"
      end)

    assert log =~ "Discarded X-Forwarded-For (invalid)"
    refute log =~ "PRIVATE-SENTINEL"
    refute log =~ "203.0.113.7"
    assert_receive {:client_ip_event, %{count: 1}, %{reason: :invalid, transport: :http}}
  end

  def forward_event(_event, measurements, metadata, pid),
    do: send(pid, {:client_ip_event, measurements, metadata})

  test "HTTP login stores resolved IP in session and uses it in rate-limit subjects", %{
    conn: conn
  } do
    u = user()

    signed_in =
      conn |> proxy() |> post("/login", user: %{login: u.nick, password: "InitialExample123"})

    assert redirected_to(signed_in)
    token = Repo.one!(from t in UserToken, where: t.user_id == ^u.id and t.context == :session)
    assert token.ip == "203.0.113.7"

    conn
    |> proxy()
    |> post("/login", user: %{login: "missing_proxy_user", password: "Wrong123", ip: "spoofed"})

    %{rows: rows} =
      Repo.query!(
        "SELECT scope, subject FROM rate_limit_counters WHERE scope IN ('login','login_ip')"
      )

    assert ["login_ip", "ip:203.0.113.7"] in rows
    assert ["login", Jason.encode!(["missing_proxy_user", "203.0.113.7"])] in rows
    refute Enum.any?(rows, fn [_, subject] -> subject =~ "spoofed" end)
  end

  test "connected LiveView resolves handshake peer and headers, never connect/form params", %{
    conn: conn
  } do
    # Static HTTP and the connected socket have separate trust boundaries.
    c =
      conn
      |> put_private(:live_view_connect_info, %{
        peer_data: %{address: @peer, port: 1234, ssl_cert: nil},
        x_headers: [{"x-forwarded-for", "198.51.100.9,203.0.113.7,10.0.0.1"}],
        user_agent: "Proxy test"
      })
      |> put_connect_params(%{"ip" => "198.51.100.77", "x-forwarded-for" => "198.51.100.77"})

    {:ok, view, _} = live(c, "/password/reset")

    render_submit(view, "submit", %{
      "user" => %{"email" => "absent@example.com", "ip" => "198.51.100.77"}
    })

    a = Repo.one!(from a in Audit, where: a.action == "password_reset_request")
    assert a.ip == "203.0.113.7"
  end

  test "untrusted WebSocket peer cannot borrow HTTP trust or spoof reset audit IP", %{conn: conn} do
    c =
      conn
      |> proxy()
      |> put_private(:live_view_connect_info, %{
        peer_data: %{address: {198, 51, 100, 10}, port: 1234, ssl_cert: nil},
        x_headers: [{"x-forwarded-for", "203.0.113.7"}],
        user_agent: "Untrusted socket"
      })

    capture_log(fn ->
      {:ok, view, _} = live(c, "/password/reset")
      render_submit(view, "submit", %{"user" => %{"email" => "absent@example.com"}})
    end)

    assert Repo.one!(from a in Audit, where: a.action == "password_reset_request").ip ==
             "198.51.100.10"
  end

  test "invalid socket chain falls back to its own peer, not HTTP's resolved client", %{
    conn: conn
  } do
    c =
      conn
      |> proxy()
      |> put_private(:live_view_connect_info, %{
        peer_data: %{address: @peer, port: 1234, ssl_cert: nil},
        x_headers: [{"x-forwarded-for", "bad,203.0.113.7"}],
        user_agent: "Bad socket"
      })

    capture_log(fn ->
      {:ok, view, _} = live(c, "/password/reset")
      render_submit(view, "submit", %{"user" => %{"email" => "absent@example.com"}})
    end)

    assert Repo.one!(from a in Audit, where: a.action == "password_reset_request").ip ==
             "10.0.0.2"
  end

  defmodule Probe do
    use Plug.Builder
    plug AnimeWeb.ClientIP
    plug :reply

    defp reply(conn, _) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          ip: Anime.ClientIP.text(conn.remote_ip),
          country: conn.assigns.client_country
        })
      )
    end
  end

  test "real loopback HTTP listener enforces opt-in proxy trust and survives malformed chain" do
    pid =
      start_supervised!({Bandit, plug: Probe, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    url = "http://127.0.0.1:#{port}/"

    headers = [
      {"x-forwarded-for", "203.0.113.7"},
      {"x-geo-country", "RU"},
      {"x-request-id", @request_id}
    ]

    capture_log(fn ->
      r = Req.get!(url, headers: headers, retry: false)
      assert r.status == 200 and r.body == %{"ip" => "127.0.0.1", "country" => "unknown"}
      refute r.headers["x-request-id"] == [@request_id]
    end)

    Application.put_env(:anime, :trusted_proxies, ClientIP.parse_trusted!("127.0.0.1/32"))
    r = Req.get!(url, headers: headers, retry: false)
    assert r.body == %{"ip" => "203.0.113.7", "country" => "RU"}
    assert r.headers["x-request-id"] == [@request_id]

    # Send duplicate fields as bytes: HTTP test helpers may merge them before
    # dispatch. Neither value may survive the real server's header parsing.
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

    try do
      :ok =
        :gen_tcp.send(socket, [
          "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n",
          "X-Forwarded-For: 203.0.113.7\r\n",
          "X-Request-Id: ",
          @request_id,
          "\r\n",
          "X-Request-Id: duplicate-request-id-12345\r\n\r\n"
        ])

      raw = read_response(socket, "")
      assert raw =~ "HTTP/1.1 200"
      refute raw =~ @request_id
      refute raw =~ "duplicate-request-id-12345"
    after
      :gen_tcp.close(socket)
    end

    capture_log(fn ->
      r = Req.get!(url, headers: [{"x-forwarded-for", "bad,203.0.113.7"}], retry: false)
      assert r.status == 200 and r.body == %{"ip" => "127.0.0.1", "country" => "unknown"}
    end)
  end

  defp read_response(socket, data) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, chunk} -> read_response(socket, data <> chunk)
      {:error, :closed} -> data
      {:error, reason} -> flunk("Loopback HTTP response failed: #{reason}")
    end
  end
end
