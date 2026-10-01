defmodule Anime.DatabaseMetricsTest do
  use AnimeWeb.ConnCase
  import Anime.MetricsProbe
  alias Anime.Metrics.Context
  @secret "PRIVATE-DATABASE-METRIC-SENTINEL"
  @phases [:total_time, :query_time, :queue_time, :decode_time, :idle_time]

  defmodule QueryWorker do
    use Anime.Worker, queue: :maintenance, max_attempts: 1
    @impl Oban.Worker
    def perform(%Oban.Job{args: args}) do
      Repo.query!("SELECT $1::text", [args["secret"]])
      if args["raise"], do: raise("PRIVATE-DATABASE-METRIC-SENTINEL")
      :ok
    end
  end

  defp native(us), do: System.convert_time_unit(us, :microsecond, :native)

  defp emit(measurements, overrides \\ %{}) do
    metadata = %{
      repo: Anime.Repo,
      type: :ecto_sql_query,
      result: {:ok, %{rows: [[@secret]]}},
      source: @secret,
      query: @secret,
      params: [@secret],
      cast_params: [@secret],
      stacktrace: [@secret],
      options: [source: :oban, private: @secret]
    }

    :telemetry.execute([:anime, :repo, :query], measurements, Map.merge(metadata, overrides))
  end

  defp safe!(records) do
    refute inspect(records) =~ @secret

    for {event, measurements, tags} <- records do
      contract = Map.fetch!(Anime.Metrics.contracts(), event)
      assert Enum.sort(Map.keys(measurements)) == Enum.sort(contract.measurements)
      assert Enum.sort(Map.keys(tags)) == Enum.sort(contract.tags)
    end

    records
  end

  test "all five durations preserve units and use server origin, not table or telemetry options" do
    {_, records} =
      capture(fn ->
        Context.with_source(:web, fn ->
          emit(Map.new(@phases, &{&1, native(1234)}))
        end)
      end)

    safe!(records)
    assert rows(records, :db_query) == [{%{count: 1}, %{source: "web", outcome: "ok"}}]
    assert length(rows(records, :db_timing)) == 5

    for {measurement, tags} <- rows(records, :db_timing) do
      assert measurement == %{count: 1, duration_ms: 1.234}
      assert tags.source == "web"
      assert tags.phase in Enum.map(@phases, &to_string/1)
    end

    assert Context.current() == :other
  end

  test "missing timings are absent rather than invented zero and one bad phase does not hide others" do
    {_, records} =
      capture(fn ->
        emit(%{
          total_time: native(3),
          queue_time: 0,
          query_time: -1,
          decode_time: @secret,
          idle_time: nil
        })

        emit(%{private: @secret}, %{result: {:error, %Postgrex.Error{message: @secret}}})
      end)

    safe!(records)
    assert length(rows(records, :db_query)) == 2

    assert Enum.sort(Enum.map(rows(records, :db_timing), &elem(&1, 1).phase)) ==
             ["queue_time", "total_time"]

    assert {%{count: 1, duration_ms: 0.0}, %{source: "other", phase: "queue_time"}} in rows(
             records,
             :db_timing
           )

    assert rows(records, :db_checkout_timeout) == []
  end

  test "slow threshold is strictly above 500ms total, excluding idle time" do
    threshold = native(500_000)

    {_, records} =
      capture(fn ->
        for total <- [threshold - 1, threshold, threshold + 1],
            do: emit(%{total_time: total, idle_time: native(2_000_000)})

        emit(%{query_time: native(900_000)})
      end)

    assert rows(safe!(records), :db_slow) == [{%{count: 1}, %{source: "other"}}]
  end

  test "checkout timeouts use typed reason, never exception text or global pool events" do
    {_, records} =
      capture(fn ->
        emit(%{}, %{
          result:
            {:error, %DBConnection.ConnectionError{reason: :queue_timeout, message: @secret}}
        })

        emit(%{}, %{
          result:
            {:error, %DBConnection.ConnectionError{reason: :error, message: "queue_timeout"}}
        })

        emit(%{}, %{result: {:error, %Postgrex.Error{message: "queue_timeout"}}})

        :telemetry.execute([:db_connection, :connection_error], %{count: 1}, %{
          error: %DBConnection.ConnectionError{reason: :queue_timeout},
          opts: [secret: @secret]
        })
      end)

    assert rows(safe!(records), :db_checkout_timeout) == [{%{count: 1}, %{source: "other"}}]
  end

  test "other repositories and event types cannot pollute our database metrics" do
    {_, records} =
      capture(fn ->
        emit(%{total_time: native(2)}, %{repo: OtherRepo})
        emit(%{total_time: native(2)}, %{type: @secret})
        emit(%{}, %{result: :unexpected})
      end)

    assert rows(safe!(records), :db_query) == [
             {%{count: 1}, %{source: "other", outcome: "unknown"}}
           ]

    assert rows(records, :db_timing) == []
  end

  test "malformed and excessive timings never overflow the projector or invent slow queries" do
    {_, records} =
      capture(fn ->
        for value <- [nil, -1, 1.5, @secret, %{}, Integer.pow(10, 400)] do
          emit(Map.new(@phases, &{&1, value}))
        end

        emit(%{total_time: 0})
      end)

    safe!(records)
    assert length(rows(records, :db_query)) == 7

    assert rows(records, :db_timing) == [
             {%{count: 1, duration_ms: 0.0}, %{source: "other", phase: "total_time"}}
           ]

    assert rows(records, :db_slow) == []
    assert rows(records, :projection_error) == []
  end

  test "real queue overload is counted once on the repo query, not again on DBConnection event" do
    pool =
      start_supervised!(
        {Repo,
         name: nil,
         pool: DBConnection.ConnectionPool,
         pool_size: 1,
         queue_target: 1,
         queue_interval: 10,
         timeout: 5_000}
      )

    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(pool)
    Repo.query!("SELECT 1")
    owner = self()

    holder =
      Task.async(fn ->
        Repo.put_dynamic_repo(pool)

        Repo.checkout(fn ->
          send(owner, :held)

          receive do
            :release -> :ok
          after
            5_000 -> :ok
          end
        end)
      end)

    try do
      assert_receive :held, 2_000
      {result, records} = capture(fn -> Repo.query("SELECT 1", [], timeout: 2_000) end)
      assert {:error, %DBConnection.ConnectionError{reason: :queue_timeout}} = result
      assert rows(safe!(records), :db_checkout_timeout) == [{%{count: 1}, %{source: "other"}}]
      assert rows(records, :db_query) == [{%{count: 1}, %{source: "other", outcome: "error"}}]
    after
      send(holder.pid, :release)
      Task.shutdown(holder, 1_000)
      Repo.put_dynamic_repo(previous)
    end
  end

  test "actual bound parameter query and database error are projected without result or SQL" do
    {_, records} =
      capture(fn ->
        assert %{rows: [[@secret]]} = Repo.query!("SELECT $1::text", [@secret])
        # A SAVEPOINT keeps the sandbox usable after this deliberate database error.
        assert {:error, %Postgrex.Error{}} = Repo.query("SELECT 1 / 0", [], mode: :savepoint)
      end)

    safe!(records)
    outcomes = Enum.map(rows(records, :db_query), &elem(&1, 1).outcome)
    assert "ok" in outcomes
    assert "error" in outcomes
    assert Enum.any?(rows(records, :db_timing), &(elem(&1, 1).phase == "query_time"))
    assert rows(records, :db_checkout_timeout) == []
  end

  test "real database observations reach Prometheus without SQL, values, errors or identifiers" do
    reporter = Anime.Metrics.DatabaseTestReporter

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: reporter, metrics: Anime.Metrics.definitions(), start_async: false}
    )

    Context.with_source(:web, fn -> Repo.query!("SELECT $1::text", [@secret]) end)
    body = TelemetryMetricsPrometheus.Core.scrape(reporter)
    assert body =~ "anime_db_query_total{outcome=\"ok\",source=\"web\"} 1"

    assert body =~
             "anime_db_timing_duration_microseconds_total{phase=\"total_time\",source=\"web\"}"

    for forbidden <- [
          @secret,
          "SELECT",
          "params",
          "stacktrace",
          "request_id",
          "query=",
          "result="
        ] do
      refute body =~ forbidden
    end
  end

  test "real HTTP assigns web source and restores caller after response and parser error" do
    {_, records} =
      capture(fn ->
        get(build_conn(), "/u/" <> @secret)
        assert Context.current() == :other

        assert_error_sent 400, fn ->
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/login", "{")
        end

        assert Context.current() == :other
      end)

    assert Enum.any?(rows(safe!(records), :db_query), &(elem(&1, 1).source == "web"))
  end

  test "actual LiveView mount and event SQL are marked separately from surrounding HTTP" do
    conn = build_conn() |> login_conn(role_user("owner"))
    {{:ok, view, _}, mount_records} = capture(fn -> live(conn, "/admin/roles") end)
    assert Enum.any?(rows(safe!(mount_records), :db_query), &(elem(&1, 1).source == "live_view"))
    assert Context.current() == :other

    {_, records} =
      capture(fn ->
        render_patch(view, "/admin/roles?q=" <> @secret)
        # Await the task and handle_async SQL, not merely the initial patch.
        render_async(view)
      end)

    assert rows(records, :db_query) != []
    assert Enum.all?(rows(safe!(records), :db_query), &(elem(&1, 1).source == "live_view"))
  end

  test "real Oban SQL uses job source and restores source even after failed work" do
    for fail? <- [false, true] do
      QueryWorker.new(%{secret: @secret, raise: fail?}) |> Oban.insert!()

      {_, records} =
        capture(fn ->
          Context.with_source(:web, fn ->
            Oban.drain_queue(queue: :maintenance, with_safety: true)
            assert Context.current() == :web
          end)
        end)

      assert Enum.any?(rows(safe!(records), :db_query), &(elem(&1, 1).source == "oban"))
      assert Context.current() == :other
    end
  end

  test "async wrapper carries only trusted source and restores it after exceptions" do
    wrapped =
      Context.with_source(:live_view, fn ->
        Anime.LogContext.wrap(fn ->
          assert Context.current() == :live_view
          Repo.query!("SELECT $1::text", [@secret])
          raise @secret
        end)
      end)

    {_, records} =
      capture(fn ->
        Task.async(fn ->
          Context.with_source(:oban, fn ->
            assert_raise RuntimeError, @secret, wrapped
            assert Context.current() == :oban
          end)
        end)
        |> Task.await()
      end)

    assert Enum.any?(rows(safe!(records), :db_query), &(elem(&1, 1).source == "live_view"))
    assert Context.current() == :other
  end

  test "nested scopes restore on normal and exceptional stop, foreign origin is never retained" do
    Context.put(@secret)
    assert Context.current() == :other
    socket = %Phoenix.LiveView.Socket{view: AnimeWeb.AuthLive}
    job = %Oban.Job{id: 1, worker: "Anime.Workers.Mail"}

    Context.with_source(:web, fn ->
      :telemetry.execute([:phoenix, :live_view, :mount, :start], %{}, %{socket: socket})
      assert Context.current() == :live_view
      :telemetry.execute([:oban, :job, :start], %{}, %{job: job})
      assert Context.current() == :oban
      :telemetry.execute([:oban, :job, :exception], %{}, %{job: job, state: :failure})
      assert Context.current() == :live_view
      :telemetry.execute([:phoenix, :live_view, :mount, :exception], %{}, %{socket: socket})
      assert Context.current() == :web
    end)

    assert Context.current() == :other
  end
end
