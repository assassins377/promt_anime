defmodule Anime.PoolMetricsTest do
  use ExUnit.Case, async: false
  import Anime.MetricsProbe
  alias Anime.Metrics
  alias Anime.Metrics.{Exporter, PoolSampler}
  alias TelemetryMetricsPrometheus.Core
  @reporter Anime.Metrics.PoolTestReporter
  @secret "PRIVATE-POOL-SENTINEL"

  setup do
    reporter()
    :ok
  end

  test "gauges accept only bounded integers, ignore metadata and replace instead of accumulate" do
    for value <- [-1, nil, 1.5, @secret, Integer.pow(10, 100)] do
      for key <- [:db_pool_ready, :db_pool_waiting, :db_pool_snapshot_available],
          do: :telemetry.execute([:anime, :metrics, key], %{value: value}, %{private: @secret})
    end

    :telemetry.execute([:anime, :metrics, :db_pool_snapshot_available], %{value: 2}, %{})
    assert Core.scrape(@reporter) == ""

    for ready <- [5, 2], do: Metrics.publish_pool_snapshot({:ok, %{ready: ready, waiting: 0}})
    body = Core.scrape(@reporter)
    assert body =~ "# TYPE anime_db_pool_ready gauge"
    assert body =~ "anime_db_pool_ready 2\n"
    assert body =~ "anime_db_pool_waiting 0\n"
    assert body =~ "anime_db_pool_snapshot_available 1\n"
    refute body =~ @secret
    refute body =~ "{"
    refute body =~ "busy"
  end

  test "first unfinished read has availability zero, not fictitious zero connections" do
    owner = self()
    sampler = sampler(read: blocking_read(owner))
    assert_receive {:reading, worker}
    :telemetry.execute([:anime, :metrics, :projection_error], %{count: 1}, %{})
    body = Exporter.scrape(sampler, @reporter)
    unavailable!(body)
    assert body =~ "anime_projection_error_total 1\n"
    send(worker, {:result, {:ok, %{ready: 0, waiting: 0}}})
    eventually(fn -> PoolSampler.snapshot(sampler) == {:ok, %{ready: 0, waiting: 0}} end)
    assert Exporter.scrape(sampler, @reporter) =~ "anime_db_pool_ready 0\n"
  end

  test "fresh scrape reuses the snapshot and never calls the pool or SQL" do
    owner = self()

    sampler =
      sampler(
        read: fn ->
          send(owner, :read)
          {:ok, %{ready: 3, waiting: 2}}
        end
      )

    assert_receive :read
    eventually(fn -> PoolSampler.snapshot(sampler) == {:ok, %{ready: 3, waiting: 2}} end)

    {_, records} = capture(fn -> for _ <- 1..10, do: Exporter.scrape(sampler, @reporter) end)
    assert length(records) == 30

    assert Enum.all?(records, fn {event, measurements, tags} ->
             assert Map.keys(measurements) == [:value]
             assert tags == %{}

             event in Enum.map(
               [:db_pool_ready, :db_pool_waiting, :db_pool_snapshot_available],
               &[:anime, :metrics, &1]
             )
           end)

    refute_receive :read, 20
  end

  test "exceptions throws exits and malformed samples clear prior values without leaking reasons" do
    {:ok, source} = Agent.start_link(fn -> {:ok, %{ready: 2, waiting: 1, secret: @secret}} end)
    on_exit(fn -> if Process.alive?(source), do: Agent.stop(source) end)

    read = fn ->
      case Agent.get(source, & &1) do
        :raise -> raise @secret
        :throw -> throw(@secret)
        :exit -> exit(@secret)
        value -> value
      end
    end

    sampler = sampler(read: read)
    eventually(fn -> PoolSampler.snapshot(sampler) == {:ok, %{ready: 2, waiting: 1}} end)

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        for result <- [:raise, :throw, :exit, @secret, {:ok, %{ready: -1, waiting: 0}}] do
          Agent.update(source, fn _ -> result end)
          PoolSampler.poll(sampler)
          eventually(fn -> PoolSampler.snapshot(sampler) == :unavailable end)
          unavailable!(Exporter.scrape(sampler, @reporter))
          eventually(fn -> :sys.get_state(sampler).worker == nil end)
        end
      end)

    refute logs =~ @secret
    refute inspect(:sys.get_state(sampler).sample) =~ @secret
    assert Process.alive?(sampler)
  end

  test "freshness expires at 30 seconds, rejects backward clock, and recovers on next sample" do
    clock = start_supervised!({Agent, fn -> 0 end})

    sampler =
      sampler(
        read: fn -> {:ok, %{ready: 7, waiting: 1}} end,
        clock: fn -> Agent.get(clock, & &1) end
      )

    eventually(fn -> PoolSampler.snapshot(sampler) != :unavailable end)
    Agent.update(clock, fn _ -> 29_999 end)
    assert Exporter.scrape(sampler, @reporter) =~ "anime_db_pool_ready 7\n"
    Agent.update(clock, fn _ -> 30_000 end)
    unavailable!(Exporter.scrape(sampler, @reporter))
    Agent.update(clock, fn _ -> -1 end)
    unavailable!(Exporter.scrape(sampler, @reporter))
    Agent.update(clock, fn _ -> 31_000 end)
    PoolSampler.poll(sampler)
    eventually(fn -> PoolSampler.snapshot(sampler) != :unavailable end)
    assert Exporter.scrape(sampler, @reporter) =~ "anime_db_pool_ready 7\n"
  end

  test "only one read runs while periodic and manual polls arrive" do
    sampler = sampler(read: blocking_read(self()), interval: 20)
    assert_receive {:reading, worker}
    for _ <- 1..20, do: PoolSampler.poll(sampler)
    assert PoolSampler.snapshot(sampler) == :unavailable
    refute_receive {:reading, _}, 60
    send(worker, {:result, {:ok, %{ready: 2, waiting: 0}}})
    assert_receive {:reading, next}, 200
    assert next != worker
  end

  test "hung read is killed, late messages are ignored and the next read recovers" do
    sampler = sampler(read: blocking_read(self()), timeout: 100)
    assert_receive {:reading, worker}
    token = :sys.get_state(sampler).worker.token
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
    eventually(fn -> :sys.get_state(sampler).worker == nil end)
    unavailable!(Exporter.scrape(sampler, @reporter))
    PoolSampler.poll(sampler)
    assert_receive {:reading, next}
    send(sampler, {:sample, token, {:ok, %{ready: 999, waiting: 999}}, 0})
    send(sampler, {:timeout, token})
    assert PoolSampler.snapshot(sampler) == :unavailable
    send(next, {:result, {:ok, %{ready: 1, waiting: 0}}})
    eventually(fn -> PoolSampler.snapshot(sampler) == {:ok, %{ready: 1, waiting: 0}} end)
  end

  test "worker killed externally does not kill sampler or leave a read in flight" do
    sampler = sampler(read: blocking_read(self()))
    assert_receive {:reading, worker}
    Process.exit(worker, :kill)
    eventually(fn -> :sys.get_state(sampler).worker == nil end)
    assert Process.alive?(sampler)
    unavailable!(Exporter.scrape(sampler, @reporter))
    PoolSampler.poll(sampler)
    assert_receive {:reading, _}
  end

  test "killing the sampler kills its linked worker and never exposes old Core gauges" do
    sampler = sampler(read: blocking_read(self()), restart: :temporary)
    assert_receive {:reading, worker}
    worker_ref = Process.monitor(worker)
    sampler_ref = Process.monitor(sampler)
    Metrics.publish_pool_snapshot({:ok, %{ready: 10, waiting: 3}})
    Process.exit(sampler, :kill)
    assert_receive {:DOWN, ^sampler_ref, :process, ^sampler, :killed}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    unavailable!(Exporter.scrape(sampler, @reporter))
  end

  test "supervision restarts sampler without inheriting stale state" do
    name = Anime.Metrics.RestartTestSampler
    sampler = sampler(name: name, read: blocking_read(self()))
    assert_receive {:reading, worker}
    send(worker, {:result, {:ok, %{ready: 4, waiting: 0}}})
    eventually(fn -> PoolSampler.snapshot(name) != :unavailable end)
    Process.exit(sampler, :kill)
    assert_receive {:reading, next}, 1_000
    assert next != worker
    assert Process.whereis(name) != sampler
    unavailable!(Exporter.scrape(name, @reporter))
  end

  test "suspended sampler cannot indefinitely stall HTTP exposition or leak last gauges" do
    sampler = sampler(read: fn -> {:ok, %{ready: 4, waiting: 0}} end)
    eventually(fn -> PoolSampler.snapshot(sampler) != :unavailable end)
    :sys.suspend(sampler)

    try do
      unavailable!(Exporter.scrape(sampler, @reporter))
    after
      :sys.resume(sampler)
    end

    assert Exporter.scrape(sampler, @reporter) =~ "anime_db_pool_ready 4\n"
  end

  test "reporter failure is isolated; a new reporter receives the current snapshot on scrape" do
    sampler = sampler(read: fn -> {:ok, %{ready: 3, waiting: 1}} end)
    eventually(fn -> PoolSampler.snapshot(sampler) != :unavailable end)
    stop_supervised!(@reporter)

    assert_raise RuntimeError, "Metrics unavailable", fn ->
      Exporter.scrape(sampler, @reporter)
    end

    assert Process.alive?(sampler)
    reporter()
    body = Exporter.scrape(sampler, @reporter)
    assert body =~ "anime_db_pool_ready 3\n"
    assert body =~ "anime_db_pool_waiting 1\n"
  end

  test "normal shutdown also stops an unfinished worker" do
    sampler(read: blocking_read(self()))
    assert_receive {:reading, worker}
    ref = Process.monitor(worker)
    stop_supervised!(PoolSampler)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
  end

  test "a result processed past the deadline cannot become a fresh snapshot" do
    sampler = sampler(read: blocking_read(self()), timeout: 60)
    assert_receive {:reading, worker}
    :sys.suspend(sampler)

    try do
      send(worker, {:result, {:ok, %{ready: 8, waiting: 0}}})
      Process.sleep(80)
    after
      :sys.resume(sampler)
    end

    unavailable!(Exporter.scrape(sampler, @reporter))
    assert PoolSampler.snapshot(sampler) == :unavailable
  end

  test "concurrent scrapes cannot mix values from different pool snapshots" do
    source = start_supervised!({Agent, fn -> 0 end})

    sampler =
      sampler(
        read: fn ->
          ready = Agent.get_and_update(source, fn n -> {n, n + 1} end)
          {:ok, %{ready: ready, waiting: ready + 10}}
        end
      )

    eventually(fn -> PoolSampler.snapshot(sampler) != :unavailable end)

    1..50
    |> Task.async_stream(
      fn _ ->
        PoolSampler.poll(sampler)
        body = Exporter.scrape(sampler, @reporter)
        [_, ready] = Regex.run(~r/^anime_db_pool_ready (\d+)$/m, body)
        [_, waiting] = Regex.run(~r/^anime_db_pool_waiting (\d+)$/m, body)
        assert String.to_integer(waiting) == String.to_integer(ready) + 10
      end,
      max_concurrency: 10
    )
    |> Enum.each(fn result -> assert result == {:ok, true} end)
  end

  test "ownership sandbox is not mistaken for the physical connection pool" do
    assert PoolSampler.read_repo(Anime.Repo) == :unavailable
  end

  test "actual ordinary pool counts idle, held and waiting checkouts, then recovers" do
    repo = ordinary_repo()
    read = fn -> PoolSampler.read_repo(repo) end
    eventually(fn -> read.() == {:ok, %{ready: 1, waiting: 0}} end)
    sampler = sampler(read: read)
    eventually(fn -> PoolSampler.snapshot(sampler) == {:ok, %{ready: 1, waiting: 0}} end)
    owner = self()

    holder =
      Task.async(fn ->
        Anime.Repo.put_dynamic_repo(repo)

        Anime.Repo.checkout(fn ->
          send(owner, :held)

          receive do
            :release -> :ok
          after
            5_000 -> :ok
          end
        end)
      end)

    assert_receive :held, 2_000

    waiter =
      Task.async(fn ->
        Anime.Repo.put_dynamic_repo(repo)
        Anime.Repo.checkout(fn -> :acquired end)
      end)

    try do
      eventually(fn -> read.() == {:ok, %{ready: 0, waiting: 1}} end)
      PoolSampler.poll(sampler)
      eventually(fn -> PoolSampler.snapshot(sampler) == {:ok, %{ready: 0, waiting: 1}} end)
      {body, records} = capture(fn -> Exporter.scrape(sampler, @reporter) end)
      assert body =~ "anime_db_pool_ready 0\n"
      assert body =~ "anime_db_pool_waiting 1\n"
      assert rows(records, :db_query) == []
    after
      send(holder.pid, :release)
      Task.await(holder)
      assert Task.await(waiter) == :acquired
    end

    eventually(fn -> read.() == {:ok, %{ready: 1, waiting: 0}} end)
    PoolSampler.poll(sampler)
    eventually(fn -> PoolSampler.snapshot(sampler) == {:ok, %{ready: 1, waiting: 0}} end)
  end

  test "a real pool API that stops replying is bounded without executing SQL" do
    repo = ordinary_repo()
    %{pid: pool} = Ecto.Adapter.lookup_meta(repo)
    eventually(fn -> PoolSampler.read_repo(repo) == {:ok, %{ready: 1, waiting: 0}} end)
    :sys.suspend(pool)

    try do
      sampler = sampler(read: fn -> PoolSampler.read_repo(repo) end, timeout: 60)
      eventually(fn -> :sys.get_state(sampler).worker != nil end)
      %{worker: %{pid: worker}} = :sys.get_state(sampler)
      ref = Process.monitor(worker)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
      unavailable!(Exporter.scrape(sampler, @reporter))
    after
      :sys.resume(pool)
    end
  end

  test "sample availability does not claim PostgreSQL is connected or estimate busy slots" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    try do
      pool =
        start_supervised!(
          Supervisor.child_spec(
            {Postgrex,
             hostname: "127.0.0.1",
             port: port,
             username: "pool_test",
             database: "pool_test",
             pool_size: 2,
             connect_timeout: 5_000},
            id: :disconnected_pool
          )
        )

      sampler = sampler(read: fn -> PoolSampler.read_pool(pool) end)
      eventually(fn -> PoolSampler.snapshot(sampler) == {:ok, %{ready: 0, waiting: 0}} end)
      body = Exporter.scrape(sampler, @reporter)
      assert body =~ "anime_db_pool_snapshot_available 1\n"
      assert body =~ "anime_db_pool_ready 0\n"
      refute body =~ "busy"
      refute body =~ "pool_test"
      stop_supervised!(:disconnected_pool)
    after
      :gen_tcp.close(listener)
    end
  end

  test "metrics HTTP response omits stale pool values when sampler is not running" do
    Metrics.publish_pool_snapshot({:ok, %{ready: 9, waiting: 2}})
    pid = start_supervised!(Exporter.listener_spec(0))
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    response = Req.get!("http://127.0.0.1:#{port}/metrics", retry: false)
    assert response.status == 200
    unavailable!(response.body)
  end

  defp reporter do
    start_supervised!(
      Supervisor.child_spec(
        {Core, name: @reporter, metrics: Metrics.definitions(), start_async: false},
        id: @reporter
      )
    )
  end

  defp sampler(options) do
    {restart, options} = Keyword.pop(options, :restart, :permanent)
    options = Keyword.merge([enabled: true, name: nil, interval: 60_000], options)
    start_supervised!(Supervisor.child_spec({PoolSampler, options}, restart: restart))
  end

  defp ordinary_repo do
    start_supervised!(
      {Anime.Repo,
       name: nil,
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       queue_target: 5_000,
       timeout: 5_000}
    )
  end

  defp blocking_read(owner) do
    fn ->
      send(owner, {:reading, self()})

      receive do
        {:result, result} -> result
      end
    end
  end

  defp unavailable!(body) do
    assert body =~ "# TYPE anime_db_pool_snapshot_available gauge"
    assert body =~ "anime_db_pool_snapshot_available 0\n"
    assert length(Regex.scan(~r/^anime_db_pool_snapshot_available /m, body)) == 1
    refute body =~ "anime_db_pool_ready"
    refute body =~ "anime_db_pool_waiting"
    refute body =~ @secret
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end
end
