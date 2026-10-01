defmodule Anime.DatabaseActivityMetricsTest do
  use ExUnit.Case, async: false
  import Anime.MetricsProbe
  alias Anime.Metrics
  alias Anime.Metrics.{DatabaseActivitySampler, Exporter, Sampler}
  alias TelemetryMetricsPrometheus.Core
  @reporter Anime.Metrics.ActivityTestReporter
  @secret "PRIVATE-ACTIVITY-SENTINEL"

  setup do
    reporter()
    :ok
  end

  defmodule InspectRepo do
    def in_transaction?, do: Process.get(:test_transaction, false)

    def query(sql, args, opts) do
      send(self(), {:query, sql, args, opts, Anime.Metrics.Context.current()})

      case Process.get(:test_reply, {:ok, %{rows: [[true, true, 2, 3, 40]]}}) do
        :raise -> raise "PRIVATE-ACTIVITY-SENTINEL"
        :exit -> exit("PRIVATE-ACTIVITY-SENTINEL")
        result -> result
      end
    end
  end

  test "one bounded read-only aggregate supplies only counts and age" do
    Metrics.Context.put(:web)
    assert DatabaseActivitySampler.read(InspectRepo) == {:ok, sample()}
    assert_receive {:query, sql, [], [timeout: 750, queue: false, log: false], :other}
    assert Metrics.Context.current() == :web
    assert sql =~ "SELECT backend_type, state, xact_start"
    assert sql =~ "pg_catalog.pg_stat_activity"
    assert sql =~ "pid <> pg_backend_pid()"
    assert sql =~ "datname = current_database()"
    assert sql =~ "statement_timestamp()"

    for private <- ~w(query_start query_id client_addr client_hostname usename application_name),
        do: refute(sql =~ private)

    refute sql =~ "SELECT *"
    refute_receive {:query, _, _, _, _}, 20
  end

  test "restricted visibility disabled tracking and malformed results cannot create plausible zeros" do
    for reply <- [
          {:ok, %{rows: [[false, true, 0, 0, 0]]}},
          {:ok, %{rows: [[true, false, 0, 0, 0]]}},
          {:ok, %{rows: [[nil, true, 0, 0, 0]]}},
          {:ok, %{rows: [[true, true, nil, 0, 0]]}},
          {:ok, %{rows: [[true, true, 0, 0, 0], [true, true, 1, 1, 1]]}},
          {:ok, %{rows: []}},
          {:error, @secret},
          :raise,
          :exit
        ] do
      Process.put(:test_reply, reply)
      assert DatabaseActivitySampler.read(InspectRepo) == :unavailable
    end
  end

  test "an existing transaction is skipped rather than reusing its cached pg_stat_activity" do
    Process.put(:test_transaction, true)
    assert DatabaseActivitySampler.read(InspectRepo) == :unavailable
    refute_receive {:query, _, _, _, _}, 20
  end

  test "normalization rejects incomplete counts and drops any private metadata" do
    assert DatabaseActivitySampler.normalize({:ok, Map.put(sample(), :query, @secret)}) ==
             {:ok, sample()}

    for key <- [:active, :idle, :oldest_seconds] do
      assert DatabaseActivitySampler.normalize({:ok, Map.delete(sample(), key)}) == :unavailable

      for bad <- [nil, -1, 1.5, @secret, Integer.pow(10, 100)] do
        assert DatabaseActivitySampler.normalize({:ok, Map.put(sample(), key, bad)}) ==
                 :unavailable
      end
    end

    assert DatabaseActivitySampler.normalize({:ok, sample(0)}) == {:ok, sample(0)}
  end

  test "four safe Telemetry measurements contain no labels or raw connection state" do
    {_, records} =
      capture(fn ->
        DatabaseActivitySampler.publish({:ok, Map.put(sample(), :client, @secret)})
      end)

    assert length(records) == 4

    for {event, measurements, tags} <- records do
      assert Map.keys(measurements) == [:value]
      assert is_integer(measurements.value)
      assert tags == %{}
      assert MapSet.member?(Metrics.allowed_tags()[event], tags)
    end

    refute inspect(records) =~ @secret
    {_, bad} = capture(fn -> DatabaseActivitySampler.publish(:unavailable) end)
    assert bad == [{[:anime, :metrics, :db_activity_available], %{value: 0}, %{}}]
  end

  test "invalid direct observations are ignored and repeated values replace rather than sum" do
    keys = [
      :db_active_connections,
      :db_idle_in_transaction_connections,
      :db_oldest_transaction_age_seconds,
      :db_activity_available
    ]

    for key <- keys,
        bad <- [nil, -1, 1.5, @secret, Integer.pow(10, 100)],
        do: :telemetry.execute([:anime, :metrics, key], %{value: bad}, %{user: @secret})

    :telemetry.execute([:anime, :metrics, :db_activity_available], %{value: 2}, %{})
    assert Core.scrape(@reporter) == ""
    for n <- [10, 2, 0], do: DatabaseActivitySampler.publish({:ok, sample(n)})
    body = Core.scrape(@reporter)
    assert body =~ "anime_db_active_connections 0\n"
    assert body =~ "anime_db_idle_in_transaction_connections 0\n"
    assert body =~ "anime_db_oldest_transaction_age_seconds 0\n"
    assert body =~ "anime_db_activity_available 1\n"
    assert length(Regex.scan(~r/^anime_db_/m, body)) == 4
    refute body =~ @secret
  end

  test "scrapes reuse the snapshot with no SQL and do not affect other database groups" do
    owner = self()

    pid =
      sampler(
        read: fn ->
          send(owner, :read)
          {:ok, sample()}
        end
      )

    eventually(fn -> Sampler.snapshot(pid) != :unavailable end)
    assert :sys.get_state(pid).interval == 15_000
    assert :sys.get_state(pid).timeout == 1000
    assert :sys.get_state(pid).max_age == 30_000
    assert_receive :read
    Metrics.publish_runtime_versions()

    for _ <- 1..3 do
      body = scrape(pid)
      assert body =~ "anime_db_active_connections 2\n"
      assert body =~ "anime_db_metadata_available 0\n"
      assert body =~ "anime_runtime_info"
    end

    refute_receive :read, 30
  end

  test "staleness and clock reversal suppress counts instead of exporting zero usage" do
    clock = start_supervised!({Agent, fn -> 0 end})
    pid = sampler(read: fn -> {:ok, sample()} end, clock: fn -> Agent.get(clock, & &1) end)
    eventually(fn -> Sampler.snapshot(pid) != :unavailable end)
    Agent.update(clock, fn _ -> 29_999 end)
    assert scrape(pid) =~ "anime_db_activity_available 1\n"

    for now <- [30_000, -1] do
      Agent.update(clock, fn _ -> now end)
      unavailable!(scrape(pid))
    end
  end

  test "failed sample hides old values and a later sample restores fresh observations" do
    data = start_supervised!({Agent, fn -> {:ok, sample()} end})
    pid = sampler(read: fn -> Agent.get(data, & &1) end)
    eventually(fn -> Sampler.snapshot(pid) != :unavailable end)
    Agent.update(data, fn _ -> {:error, @secret} end)
    Sampler.poll(pid)
    eventually(fn -> Sampler.snapshot(pid) == :unavailable end)
    unavailable!(scrape(pid))
    Agent.update(data, fn _ -> {:ok, sample(0)} end)
    Sampler.poll(pid)
    eventually(fn -> Sampler.snapshot(pid) == {:ok, sample(0)} end)
    assert scrape(pid) =~ "anime_db_active_connections 0\n"
  end

  test "readers cannot overlap and timed out work is killed before recovery" do
    owner = self()

    pid =
      sampler(
        timeout: 100,
        read: fn ->
          send(owner, {:reading, self()})

          receive do
            :finish -> {:ok, sample()}
          end
        end
      )

    assert_receive {:reading, worker}
    ref = Process.monitor(worker)
    Sampler.poll(pid)
    refute_receive {:reading, _}, 20
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 500
    unavailable!(scrape(pid))
    Sampler.poll(pid)
    assert_receive {:reading, next}
    send(next, :finish)
    eventually(fn -> Sampler.snapshot(pid) == {:ok, sample()} end)
  end

  test "killing the owner also kills its outstanding reader" do
    owner = self()

    pid =
      sampler(
        read: fn ->
          send(owner, {:reader, self()})

          receive do
            :never -> :unavailable
          end
        end
      )

    assert_receive {:reader, worker}
    ref = Process.monitor(worker)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 500
    unavailable!(scrape(pid))
  end

  test "reporter restart restores the current snapshot without rereading the database" do
    owner = self()

    pid =
      sampler(
        read: fn ->
          send(owner, :read)
          {:ok, sample()}
        end
      )

    assert_receive :read
    eventually(fn -> Sampler.snapshot(pid) != :unavailable end)
    stop_supervised!(@reporter)
    assert_raise RuntimeError, "Metrics unavailable", fn -> scrape(pid) end
    reporter()
    assert scrape(pid) =~ "anime_db_active_connections 2\n"
    refute_receive :read, 20
  end

  defp sample, do: %{active: 2, idle: 3, oldest_seconds: 40}
  defp sample(n), do: %{active: n, idle: n, oldest_seconds: n}

  defp reporter,
    do:
      start_supervised!(
        {Core, name: @reporter, metrics: Metrics.definitions(), start_async: false}
      )

  defp sampler(options),
    do:
      start_supervised!(
        Supervisor.child_spec(
          {DatabaseActivitySampler, Keyword.merge([name: nil, enabled: true], options)},
          restart: :temporary
        )
      )

  defp scrape(pid),
    do:
      Exporter.scrape(
        :no_pool,
        :no_vm,
        :no_sched,
        :no_cache,
        :no_oban,
        :no_pg,
        :no_size,
        pid,
        @reporter
      )

  defp unavailable!(body) do
    assert body =~ "anime_db_activity_available 0\n"

    for name <-
          ~w(anime_db_active_connections anime_db_idle_in_transaction_connections anime_db_oldest_transaction_age_seconds),
        do: refute(body =~ name)

    refute body =~ @secret
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(5)
            eventually(fun, attempts - 1)
          )
      )
end
