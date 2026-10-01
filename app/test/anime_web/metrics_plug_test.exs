defmodule AnimeWeb.MetricsPlugTest do
  use AnimeWeb.ConnCase
  alias AnimeWeb.MetricsPlug

  test "a real page request reaches the HTTP exposition through the safe projection" do
    key = ~s(anime_router_total{method="GET",route="/login"} )
    before = sample(Anime.Metrics.Exporter.scrape(), key)
    page = get(build_conn(), "/login?email=PRIVATE-REQUEST-SENTINEL")
    assert page.status == 200
    scrape = Plug.Test.conn(:get, "/metrics") |> MetricsPlug.call([])
    assert sample(scrape.resp_body, key) == before + 1
    refute scrape.resp_body =~ "PRIVATE-REQUEST-SENTINEL"
  end

  test "test application never opens the default metrics port implicitly" do
    refute Enum.any?(Supervisor.which_children(Anime.Metrics.Exporter), fn {id, _, _, _} ->
             id == Anime.Metrics.Listener
           end)
  end

  test "dedicated listener binds loopback and serves real Prometheus over HTTP" do
    pid = start_supervised!(Anime.Metrics.Exporter.listener_spec(0))
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    url = "http://127.0.0.1:#{port}"
    :telemetry.execute([:anime, :metrics, :projection_error], %{count: 1}, %{})
    response = Req.get!(url <> "/metrics", retry: false)
    assert response.status == 200
    assert response.headers["content-type"] == ["text/plain; version=0.0.4; charset=utf-8"]
    assert response.headers["cache-control"] == ["no-store"]
    assert response.body =~ "# TYPE anime_projection_error_total counter"
    assert Req.head!(url <> "/metrics", retry: false).body == ""
    assert Req.get!(url <> "/", retry: false).status == 404
    assert Req.post!(url <> "/metrics", body: "PRIVATE-METRICS-BODY", retry: false).status == 405
  end

  test "main endpoint never publishes metrics" do
    for path <- ~w(/metrics /en/metrics) do
      conn = get(build_conn(), path)
      assert conn.status == 404
      refute conn.resp_body =~ "# TYPE anime_"
    end

    refute Enum.any?(AnimeWeb.Router.__routes__(), &(&1.path == "/metrics"))
  end

  test "scrape is read-only non-cacheable and has no CORS or session effects" do
    conn =
      Plug.Test.conn(:get, "/metrics?token=PRIVATE-METRICS-TOKEN")
      |> put_req_header("origin", "https://untrusted.invalid")
      |> MetricsPlug.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    assert get_resp_header(conn, "access-control-allow-origin") == []
    assert get_resp_header(conn, "set-cookie") == []
    refute conn.resp_body =~ "PRIVATE-METRICS"

    for method <- ~w(POST PUT PATCH DELETE OPTIONS) do
      result = Plug.Test.conn(method, "/metrics") |> MetricsPlug.call([])
      assert result.status == 405
      assert get_resp_header(result, "allow") == ["GET, HEAD"]
    end
  end

  test "non-loopback peers cannot bypass access with XFF or Host" do
    conn =
      %{Plug.Test.conn(:get, "/metrics") | remote_ip: {203, 0, 113, 12}, host: "localhost"}
      |> put_req_header("x-forwarded-for", "127.0.0.1")
      |> MetricsPlug.call([])

    assert conn.status == 404
    refute conn.resp_body =~ "# TYPE"
  end

  test "service failure returns generic 503 without credentials or exception" do
    Supervisor.terminate_child(Anime.Metrics.Exporter, Anime.Metrics.Reporter)

    try do
      conn = Plug.Test.conn(:get, "/metrics") |> MetricsPlug.call([])
      assert conn.status == 503
      assert conn.resp_body == "Metrics unavailable\n"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    after
      assert {:ok, _} = Supervisor.restart_child(Anime.Metrics.Exporter, Anime.Metrics.Reporter)
    end
  end

  test "scraping does not generate public endpoint measurements" do
    {conn, records} =
      Anime.MetricsProbe.capture(fn ->
        Plug.Test.conn(:get, "/metrics") |> MetricsPlug.call([])
      end)

    assert conn.status == 200
    assert records == []
  end

  test "reporter exception through a live sampler returns the same private 503" do
    start_supervised!(
      {Anime.Metrics.DatabaseActivitySampler,
       enabled: true, read: fn -> :unavailable end, interval: 60_000}
    )

    :ok = Supervisor.terminate_child(Anime.Metrics.Exporter, Anime.Metrics.Reporter)

    try do
      conn = Plug.Test.conn(:get, "/metrics") |> MetricsPlug.call([])
      assert conn.status == 503
      assert conn.resp_body == "Metrics unavailable\n"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "set-cookie") == []
    after
      assert {:ok, _} = Supervisor.restart_child(Anime.Metrics.Exporter, Anime.Metrics.Reporter)
    end
  end

  defp sample(body, key) do
    case Enum.find(String.split(body, "\n"), &String.starts_with?(&1, key)) do
      nil -> 0
      line -> line |> String.replace_prefix(key, "") |> String.to_integer()
    end
  end
end
