defmodule Anime.InventoryMetricsTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  import Anime.MetricsProbe
  alias Anime.{Cache, Metrics}
  alias Anime.Metrics.{CacheSampler, Exporter, PoolSampler}
  alias TelemetryMetricsPrometheus.Core
  @reporter Anime.Metrics.InventoryTestReporter
  @table :anime_role_permissions
  @secret "PRIVATE-INVENTORY-SENTINEL"

  setup do
    reporter()
    Cache.invalidate_permissions()
    on_exit(fn -> Cache.invalidate_permissions() end)
    :ok
  end

  test "runtime labels use the loaded application and actual runtime, not a tool version file" do
    assert Metrics.runtime_version_tags() == [
             %{component: "application", version: Application.spec(:anime, :vsn) |> to_string()},
             %{component: "elixir", version: System.version()},
             %{component: "erlang_otp", version: :erlang.system_info(:otp_release) |> to_string()}
           ]

    refute Enum.any?(Metrics.runtime_version_tags(), &(&1.component in ~w(postgresql ffmpeg)))
  end

  test "runtime constant publication contains only the closed version pairs and ones" do
    {_, records} = capture(fn -> Metrics.publish_runtime_versions() end)
    assert length(records) == 3

    for {event, measurements, tags} <- records do
      assert event == [:anime, :metrics, :runtime_info]
      assert measurements == %{value: 1}
      assert MapSet.member?(Metrics.allowed_tags()[event], tags)
    end

    for _ <- 1..3, do: Metrics.publish_runtime_versions()
    body = Core.scrape(@reporter)
    assert length(Regex.scan(~r/^anime_runtime_info\{/m, body)) == 3
    assert Enum.all?(sample_rows(body), &String.ends_with?(&1, " 1"))
  end

  test "reporter restart republishes constants without waiting for a new request" do
    Supervisor.terminate_child(Exporter, Anime.Metrics.Reporter)
    assert {:ok, _} = Supervisor.restart_child(Exporter, Anime.Metrics.Reporter)
    body = Core.scrape(Anime.Metrics.Reporter)
    assert length(Regex.scan(~r/^anime_runtime_info\{/m, body)) == 3
    assert body =~ ~s(component="elixir",version="#{System.version()}")
  end

  test "arbitrary version strings, mismatched component pairs and counts cannot create rows" do
    for n <- 1..600 do
      emit(:runtime_info, 1, %{component: "application", version: @secret <> to_string(n)})
      emit(:cache_entries, 1, %{table: @secret <> to_string(n)})
    end

    emit(:runtime_info, 1, %{component: "ffmpeg", version: System.version()})

    for tag <- Metrics.runtime_version_tags(),
        value <- [0, 1.0, 2, -1, @secret, nil],
        do: emit(:runtime_info, value, tag)

    assert Core.scrape(@reporter) == ""
    emit(:runtime_info, 1, Map.put(hd(Metrics.runtime_version_tags()), :private, @secret))
    refute Core.scrape(@reporter) =~ @secret
    assert length(sample_rows(Core.scrape(@reporter))) == 1
  end

  test "cache inventory contains implemented application tables, not all ETS" do
    foreign = :ets.new(:inventory_private_test, [:set, :private])
    :ets.insert(foreign, {@secret, @secret})
    assert Cache.inventory() == [@table, Anime.Storage.Readiness.table()]
    assert Enum.sort(Map.keys(Cache.statistics())) == Enum.sort(Cache.inventory())
    refute inspect(Cache.statistics()) =~ @secret
  end

  test "real table statistics expose object count and allocated words converted to bytes" do
    :ets.insert(@table, [{101, MapSet.new([@secret])}, {102, %{secret: @secret}}])
    stats = Cache.statistics()[@table]
    assert stats.entries == 2
    assert stats.memory_bytes == :ets.info(@table, :memory) * :erlang.system_info(:wordsize)
    assert stats.memory_bytes > 0
    assert Map.keys(stats) |> Enum.sort() == [:entries, :memory_bytes]
    assert :ets.lookup(@table, 102) == [{102, %{secret: @secret}}]
    refute inspect(CacheSampler.read()) =~ @secret
  end

  test "empty is a real zero count with allocated memory, not unavailability" do
    {:ok, snapshot} = CacheSampler.read()
    assert snapshot[@table].entries == 0
    assert snapshot[@table].memory_bytes > 0
    Metrics.publish_cache_snapshot({:ok, snapshot})
    body = Core.scrape(@reporter)
    assert body =~ ~s(anime_cache_entries{table="#{@table}"} 0\n)
    assert body =~ ~s(anime_cache_snapshot_available{table="#{@table}"} 1\n)
  end

  test "missing owner or a same-name impostor table is unavailable rather than zero" do
    Supervisor.terminate_child(Anime.Supervisor, Cache)

    try do
      assert Cache.statistics() == Map.new(Cache.inventory(), &{&1, :unavailable})
      table = :ets.new(@table, [:named_table, :public])

      try do
        :ets.insert(table, {1, @secret})
        assert Cache.statistics() == Map.new(Cache.inventory(), &{&1, :unavailable})
      after
        :ets.delete(table)
      end
    after
      assert {:ok, _} = Supervisor.restart_child(Anime.Supervisor, Cache)
    end

    assert Cache.statistics()[@table].entries == 0
  end

  test "statistics do not call the owner or block cache operations behind sampling" do
    owner = Process.whereis(Cache)
    :sys.suspend(owner)

    try do
      assert Cache.statistics()[@table].entries == 0
    after
      :sys.resume(owner)
    end
  end

  test "normalization drops unknown tables and extra fields before safe events" do
    snapshot = Map.put(sample(), :unknown, @secret)
    snapshot = put_in(snapshot, [@table, :private], @secret)
    assert CacheSampler.normalize({:ok, snapshot}) == {:ok, sample()}
    {_, records} = capture(fn -> Metrics.publish_cache_snapshot({:ok, snapshot}) end)
    assert length(records) == 4
    refute inspect(records) =~ @secret

    for {event, %{value: value}, tags} <- records do
      assert Metrics.valid_pool_count?(value)
      assert MapSet.member?(Metrics.allowed_tags()[event], tags)
      assert Map.keys(tags) == [:table]
    end
  end

  test "bad or missing table numbers invalidate the pair without publishing partial fields" do
    for field <- [:entries, :memory_bytes],
        value <- [-1, 1.5, nil, @secret, Integer.pow(10, 100)] do
      snapshot = put_in(sample(), [@table, field], value)
      assert CacheSampler.normalize({:ok, snapshot}) == {:ok, unavailable_tables()}
      {_, records} = capture(fn -> Metrics.publish_cache_snapshot({:ok, snapshot}) end)

      assert records ==
               Enum.map(Cache.inventory(), fn table ->
                 {[:anime, :metrics, :cache_snapshot_available], %{value: 0},
                  %{table: to_string(table)}}
               end)
    end

    assert CacheSampler.normalize({:ok, %{}}) == {:ok, unavailable_tables()}
    assert CacheSampler.normalize({:error, @secret}) == :unavailable
  end

  test "invalid direct cache measurements cannot create values or unbounded labels" do
    for key <- [:cache_entries, :cache_memory_bytes, :cache_snapshot_available],
        value <- [-1, 0.5, @secret, nil, Integer.pow(10, 100)],
        do: emit(key, value, %{table: to_string(@table)})

    emit(:cache_snapshot_available, 2, %{table: to_string(@table)})
    assert Core.scrape(@reporter) == ""
  end

  test "cache gauges replace snapshots including a reset to an empty table" do
    for n <- [4, 7, 0], do: Metrics.publish_cache_snapshot({:ok, sample(n)})
    body = Core.scrape(@reporter)
    assert body =~ ~s(anime_cache_entries{table="#{@table}"} 0\n)
    assert body =~ ~s(anime_cache_memory_bytes{table="#{@table}"} 256\n)
    assert length(sample_rows(body)) == 4
  end

  test "cold sampler omits resource zeros while preserving version constants" do
    Metrics.publish_runtime_versions()
    cache = sampler(read: blocking_read(self()))
    assert_receive {:reading, worker}
    unavailable!(scrape(cache))
    assert scrape(cache) =~ "anime_runtime_info"
    send(worker, {:result, {:ok, sample()}})
    eventually(fn -> CacheSampler.snapshot(cache) == {:ok, sample()} end)
    assert scrape(cache) =~ ~s(anime_cache_entries{table="#{@table}"} 4\n)
  end

  test "freshness boundary and backwards clock remove old gauges then recover" do
    clock = start_supervised!({Agent, fn -> 0 end})
    cache = sampler(read: fn -> {:ok, sample()} end, clock: fn -> Agent.get(clock, & &1) end)
    eventually(fn -> CacheSampler.snapshot(cache) != :unavailable end)
    Agent.update(clock, fn _ -> 29_999 end)
    assert scrape(cache) =~ ~s(anime_cache_entries{table="#{@table}"} 4\n)

    for time <- [30_000, -1] do
      Agent.update(clock, fn _ -> time end)
      unavailable!(scrape(cache))
    end

    CacheSampler.poll(cache)
    eventually(fn -> CacheSampler.snapshot(cache) != :unavailable end)
    assert scrape(cache) =~ ~s(anime_cache_snapshot_available{table="#{@table}"} 1\n)
  end

  test "sampling failure removes cached rows but keeps other families and constants" do
    Metrics.publish_cache_snapshot({:ok, sample()})
    Metrics.publish_runtime_versions()
    :telemetry.execute([:anime, :metrics, :projection_error], %{count: 1}, %{})

    pool =
      start_supervised!(
        {PoolSampler,
         name: nil,
         enabled: true,
         interval: 60_000,
         read: fn -> {:ok, %{ready: 3, waiting: 2}} end}
      )

    eventually(fn -> PoolSampler.snapshot(pool) != :unavailable end)
    body = Exporter.scrape(pool, :missing_vm, :missing_scheduler, :missing_cache, @reporter)
    unavailable!(body)
    assert body =~ "anime_db_pool_ready 3\n"
    assert body =~ "anime_projection_error_total 1\n"
    assert body =~ "anime_runtime_info"
  end

  test "scrapes neither read tables again nor issue SQL and do not leak table contents" do
    owner = self()

    cache =
      sampler(
        read: fn ->
          send(owner, :read)
          {:ok, sample()}
        end
      )

    assert_receive :read
    eventually(fn -> CacheSampler.snapshot(cache) != :unavailable end)
    ref = make_ref()
    :telemetry.attach(ref, [:anime, :repo, :query], &__MODULE__.notice/4, self())

    try do
      for _ <- 1..10, do: assert(scrape(cache) =~ "anime_cache_entries")
      refute_receive :read, 20
      refute_receive :query, 20
    after
      :telemetry.detach(ref)
    end
  end

  test "bounded worker rejects timeouts and late replies without overlapping reads" do
    cache = sampler(read: blocking_read(self()), timeout: 120)
    assert_receive {:reading, worker}
    for _ <- 1..10, do: CacheSampler.poll(cache)
    refute_receive {:reading, _}, 20
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
    unavailable!(scrape(cache))
    CacheSampler.poll(cache)
    assert_receive {:reading, next}
    send(cache, {:sample, make_ref(), {:ok, sample(999)}, 0})
    send(next, {:result, {:ok, sample()}})
    eventually(fn -> CacheSampler.snapshot(cache) == {:ok, sample()} end)
    refute scrape(cache) =~ "999"
  end

  test "supervised sampler restart resets its old snapshot and kills the old worker" do
    name = Anime.Metrics.InventoryRestartSampler
    cache = sampler(name: name, read: blocking_read(self()))
    assert_receive {:reading, worker}
    ref = Process.monitor(worker)
    Process.exit(cache, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    assert_receive {:reading, next}, 1_000
    assert next != worker
    unavailable!(scrape(name))
    send(next, {:result, {:ok, sample()}})
    eventually(fn -> CacheSampler.snapshot(name) == {:ok, sample()} end)
  end

  test "reporter restart restores cache values from a fresh sample without re-reading" do
    owner = self()

    cache =
      sampler(
        read: fn ->
          send(owner, :read)
          {:ok, sample()}
        end
      )

    assert_receive :read
    eventually(fn -> CacheSampler.snapshot(cache) != :unavailable end)
    stop_supervised!(@reporter)
    assert_raise RuntimeError, "Metrics unavailable", fn -> scrape(cache) end
    reporter()
    assert scrape(cache) =~ ~s(anime_cache_entries{table="#{@table}"} 4\n)
    refute_receive :read, 20
  end

  test "suspended cache sampler degrades independently and leaves version constants available" do
    Metrics.publish_runtime_versions()
    cache = sampler(read: fn -> {:ok, sample()} end)
    eventually(fn -> CacheSampler.snapshot(cache) != :unavailable end)
    :sys.suspend(cache)

    try do
      body = scrape(cache)
      unavailable!(body)
      assert body =~ "anime_runtime_info"
    after
      :sys.resume(cache)
    end
  end

  test "normal stop also terminates its unfinished cache reader" do
    cache = sampler(read: blocking_read(self()))
    assert_receive {:reading, worker}
    ref = Process.monitor(worker)
    stop_supervised!(CacheSampler)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    unavailable!(scrape(cache))
  end

  test "UI cache invalidation is reflected on the next sample without changing the stats API" do
    :ets.insert(@table, {1, MapSet.new([@secret])})
    cache = sampler(read: &CacheSampler.read/0)
    eventually(fn -> match?({:ok, %{@table => %{entries: 1}}}, CacheSampler.snapshot(cache)) end)
    Cache.invalidate_permissions()
    CacheSampler.poll(cache)
    eventually(fn -> match?({:ok, %{@table => %{entries: 0}}}, CacheSampler.snapshot(cache)) end)
    assert scrape(cache) =~ ~s(anime_cache_entries{table="#{@table}"} 0\n)
    assert Cache.statistics()[@table].entries == 0
  end

  test "owner restart is sampled as a new empty table without carrying permissions or memory" do
    :ets.insert(@table, {1, @secret})
    cache = sampler(read: &CacheSampler.read/0)
    eventually(fn -> match?({:ok, %{@table => %{entries: 1}}}, CacheSampler.snapshot(cache)) end)
    Supervisor.terminate_child(Anime.Supervisor, Cache)

    try do
      CacheSampler.poll(cache)
      eventually(fn -> CacheSampler.snapshot(cache) == {:ok, unavailable_tables()} end)
      unavailable!(scrape(cache))
    after
      assert {:ok, _} = Supervisor.restart_child(Anime.Supervisor, Cache)
    end

    CacheSampler.poll(cache)
    eventually(fn -> match?({:ok, %{@table => %{entries: 0}}}, CacheSampler.snapshot(cache)) end)
    assert scrape(cache) =~ ~s(anime_cache_entries{table="#{@table}"} 0\n)
  end

  test "real loopback HTTP emits cache gauges and versions without exposing contents" do
    :ets.insert(@table, {1, @secret})
    cache = sampler(name: CacheSampler, read: &CacheSampler.read/0)
    eventually(fn -> CacheSampler.snapshot(cache) != :unavailable end)
    pid = start_supervised!(Exporter.listener_spec(0))
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    response = Req.get!("http://127.0.0.1:#{port}/metrics", retry: false)
    assert response.status == 200
    assert response.body =~ ~s(anime_cache_entries{table="#{@table}"} 1\n)
    assert response.body =~ "anime_runtime_info"
    refute response.body =~ @secret
  end

  def notice(_, _, _, owner), do: send(owner, :query)

  defp reporter,
    do:
      start_supervised!(
        {Core, name: @reporter, metrics: Metrics.definitions(), start_async: false}
      )

  defp sample(n \\ 4),
    do: Map.put(unavailable_tables(), @table, %{entries: n, memory_bytes: 256 + n * 8})

  defp unavailable_tables, do: Map.new(Cache.inventory(), &{&1, :unavailable})

  defp emit(key, value, tags),
    do: :telemetry.execute([:anime, :metrics, key], %{value: value}, tags)

  defp sampler(opts) do
    start_supervised!(
      {CacheSampler,
       Keyword.merge([name: nil, enabled: true, interval: 60_000, timeout: 1_000], opts)}
    )
  end

  defp scrape(cache),
    do: Exporter.scrape(:missing_pool, :missing_vm, :missing_scheduler, cache, @reporter)

  defp sample_rows(body),
    do: body |> String.split("\n", trim: true) |> Enum.reject(&String.starts_with?(&1, "#"))

  defp blocking_read(owner),
    do: fn ->
      send(owner, {:reading, self()})
      receive do: ({:result, result} -> result)
    end

  defp unavailable!(body) do
    assert body =~ ~s(anime_cache_snapshot_available{table="#{@table}"} 0\n)
    refute body =~ "anime_cache_entries"
    refute body =~ "anime_cache_memory_bytes"
    refute body =~ @secret

    assert length(Regex.scan(~r/^anime_cache_snapshot_available\{/m, body)) ==
             length(Cache.inventory())
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
