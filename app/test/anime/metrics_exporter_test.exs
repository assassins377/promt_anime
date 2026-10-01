defmodule Anime.MetricsExporterTest do
  use ExUnit.Case, async: false
  alias TelemetryMetricsPrometheus.Core
  alias Anime.Metrics
  @reporter Anime.Metrics.TestReporter
  @secret "PRIVATE-EXPORT-SENTINEL"

  setup do
    start_supervised!({Core, name: @reporter, metrics: Metrics.definitions(), start_async: false})
    :ok
  end

  test "contracts have counters, integer duration sums and thirty bounded resource gauges" do
    metrics = Metrics.definitions()
    assert length(metrics) == 56
    assert length(Enum.uniq_by(metrics, & &1.name)) == 56
    assert MapSet.new(Enum.map(metrics, & &1.event_name)) == MapSet.new(Metrics.events())
    assert Enum.count(metrics, &match?(%Telemetry.Metrics.Sum{}, &1)) == 26
    assert Enum.count(metrics, &match?(%Telemetry.Metrics.LastValue{}, &1)) == 30
    assert Enum.all?(Metrics.allowed_tags(), fn {_, tags} -> MapSet.size(tags) <= 500 end)

    assert Enum.all?(:telemetry.list_handlers([:anime, :metrics, :http]), fn handler ->
             is_pid(elem(handler.id, 1))
           end)
  end

  test "real Core accumulates sub-millisecond durations without detaching handlers" do
    emit(:http, %{count: 1, duration_ms: 1.234}, %{status: 201})
    emit(:http, %{count: 1, duration_ms: 2.001}, %{status: 201})
    body = scrape()
    assert body =~ "# TYPE anime_http_total counter"
    assert value(body, "anime_http_total", ~s(status="201")) == 2
    assert value(body, "anime_http_duration_microseconds_total", ~s(status="201")) == 3235
    assert scrape() == body
    emit(:http, %{count: 1, duration_ms: 0.001}, %{status: 201})
    assert value(scrape(), "anime_http_duration_microseconds_total", ~s(status="201")) == 3236
  end

  test "every possible tag set is accepted and exposition stays within 500 rows per metric" do
    for {event, tags} <- Metrics.allowed_tags(), tag <- tags do
      value = if List.last(event) == :postgres_version_number, do: 180_006, else: 1
      :telemetry.execute(event, %{count: 1, duration_ms: 1.234, value: value}, tag)
    end

    body = scrape()
    rows = sample_rows(body)

    counts =
      Enum.frequencies_by(rows, fn line -> line |> String.split(~r/[{ ]/, parts: 2) |> hd() end)

    assert map_size(counts) == 56
    assert Enum.all?(counts, fn {_, count} -> count <= 500 end)

    for metric <- Metrics.definitions() do
      assert counts[Enum.join(metric.name, "_")] ==
               MapSet.size(Metrics.allowed_tags()[metric.event_name])
    end
  end

  test "500 budget counts histogram infinity sum count and rejects unprovable summaries" do
    histogram =
      Telemetry.Metrics.distribution("test.duration", reporter_options: [buckets: [1, 2]])

    assert Metrics.validate_budget!(histogram, Enum.to_list(1..100)) == histogram

    assert_raise ArgumentError, ~r/exceeds 500/, fn ->
      Metrics.validate_budget!(histogram, Enum.to_list(1..101))
    end

    assert_raise ArgumentError, ~r/cannot be proven/, fn ->
      Metrics.validate_budget!(Telemetry.Metrics.summary("test.duration"), [%{}])
    end

    assert_raise ArgumentError, ~r/exceeds 500/, fn ->
      Metrics.validate_budget!(Telemetry.Metrics.sum("test.total"), Enum.to_list(1..501))
    end
  end

  test "database timing samples have separate denominators and bounded label domains" do
    emit(:db_query, %{count: 1}, %{source: "web", outcome: "ok"})
    emit(:db_query, %{count: 1}, %{source: "web", outcome: "error"})
    emit(:db_timing, %{count: 1, duration_ms: 0}, %{source: "web", phase: "queue_time"})
    emit(:db_timing, %{count: 1, duration_ms: 1.234}, %{source: "web", phase: "total_time"})
    emit(:db_slow, %{count: 1}, %{source: "oban"})
    emit(:db_checkout_timeout, %{count: 1}, %{source: "live_view"})

    for n <- 1..600 do
      emit(:db_query, %{count: 1}, %{source: @secret <> to_string(n), outcome: "ok"})
      emit(:db_timing, %{count: 1, duration_ms: 1}, %{source: "web", phase: @secret})
    end

    body = scrape()
    refute body =~ @secret
    assert value(body, "anime_db_query_total", ~s(outcome="ok",source="web")) == 1
    assert value(body, "anime_db_query_total", ~s(outcome="error",source="web")) == 1
    assert value(body, "anime_db_timing_total", ~s(phase="queue_time",source="web")) == 1

    assert value(
             body,
             "anime_db_timing_duration_microseconds_total",
             ~s(phase="total_time",source="web")
           ) == 1234

    assert value(
             body,
             "anime_db_timing_duration_microseconds_total",
             ~s(phase="queue_time",source="web")
           ) == 0

    assert value(body, "anime_db_slow_total", ~s(source="oban")) == 1
    assert value(body, "anime_db_checkout_timeout_total", ~s(source="live_view")) == 1
    assert length(sample_rows(body)) == 8
  end

  test "unknown strings, impossible pairs and extra fields never become labels" do
    for n <- 1..600 do
      emit(:router, %{count: 1, duration_ms: 1}, %{route: "/#{@secret}/#{n}", method: "GET"})
      emit(:http, %{count: 1, duration_ms: 1}, %{status: 599 + n})

      emit(:live_event_exception, %{count: 1}, %{
        view: "AnimeWeb.AuthLive",
        event: @secret <> to_string(n)
      })

      emit(:access_denied, %{count: 1}, %{permission: @secret <> to_string(n)})
    end

    # Both values exist separately, but never in this combination.
    emit(:router, %{count: 1, duration_ms: 1}, %{route: "/healthz", method: "POST"})
    assert scrape() == ""

    emit(:router, %{count: 1, duration_ms: 1}, %{
      route: "/healthz",
      method: "HEAD",
      request_id: @secret
    })

    emit(:http, %{count: 1, duration_ms: 1, password: @secret}, %{
      status: 200,
      conn: %{secret: @secret}
    })

    body = scrape()
    refute body =~ @secret
    refute body =~ "request_id"
    assert value(body, "anime_router_total", ~s(method="HEAD",route="/healthz")) == 1
    assert length(sample_rows(body)) == 4
  end

  test "missing negative huge and secret-valued measurements do not detach or count" do
    for measurements <- [
          %{},
          %{count: 9},
          %{count: 1, duration_ms: -1},
          %{count: 1, duration_ms: @secret},
          %{count: 1, duration_ms: 1.0e300}
        ] do
      emit(:http, measurements, %{status: 200})
    end

    emit(:rate_limited, %{count: @secret}, %{scope: "login"})
    assert scrape() == ""
    emit(:http, %{count: 1, duration_ms: 0}, %{status: 200})
    emit(:rate_limited, %{count: 1}, %{scope: "login"})
    assert value(scrape(), "anime_http_total", ~s(status="200")) == 1
    assert value(scrape(), "anime_rate_limited_total", ~s(scope="login")) == 1
  end

  test "concurrent observations are not lost or duplicated and do not retain samples" do
    1..32
    |> Task.async_stream(
      fn _ ->
        for _ <- 1..100,
            do: emit(:job, %{count: 1, duration_ms: 0.007}, %{worker: "Anime.Workers.Mail"})
      end,
      max_concurrency: 16
    )
    |> Stream.run()

    body = scrape()
    assert value(body, "anime_job_total", ~s(worker="Anime.Workers.Mail")) == 3200

    assert value(body, "anime_job_duration_microseconds_total", ~s(worker="Anime.Workers.Mail")) ==
             22400

    assert :ets.info(@reporter, :size) == 2
    assert :ets.info(Anime.Metrics.TestReporter_dist, :size) == 0
  end

  test "raw framework metadata is projected before reaching the reporter" do
    conn =
      Plug.Test.conn(:get, "/u/" <> @secret)
      |> Plug.Conn.put_private(:phoenix_router, AnimeWeb.Router)

    :telemetry.execute([:phoenix, :router_dispatch, :stop], %{duration: 1_000_000}, %{
      conn: conn,
      route: "/u/:nick",
      secret: @secret
    })

    body = scrape()
    refute body =~ @secret
    assert value(body, "anime_router_total", ~s(method="GET",route="/u/:nick")) == 1
  end

  test "killed reporter restarts with fresh counters and no stale handlers" do
    old = Process.whereis(Anime.Metrics.Reporter)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}

    eventually(fn ->
      pid = Process.whereis(Anime.Metrics.Reporter)
      pid != nil and pid != old and length(Core.Registry.metrics(Anime.Metrics.Reporter)) == 56
    end)

    emit(:projection_error, %{count: 1}, %{})
    assert value(Anime.Metrics.Exporter.scrape(), "anime_projection_error_total", "") == 1
    handlers = :telemetry.list_handlers([:anime, :metrics, :projection_error])
    refute Enum.any?(handlers, fn h -> match?({_, ^old, _}, h.id) end)
    assert Enum.count(handlers, fn h -> h.config.table == Anime.Metrics.Reporter end) == 1
  end

  defp emit(key, m, tags), do: :telemetry.execute([:anime, :metrics, key], m, tags)
  defp scrape, do: Core.scrape(@reporter)

  defp sample_rows(body),
    do: body |> String.split("\n", trim: true) |> Enum.reject(&String.starts_with?(&1, "#"))

  defp value(body, metric, tags) do
    prefix = metric <> if(tags == "", do: " ", else: "{" <> tags <> "} ")
    row = Enum.find(sample_rows(body), &String.starts_with?(&1, prefix))
    assert row, "Missing sample #{prefix}"
    row |> String.replace_prefix(prefix, "") |> String.to_integer()
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
