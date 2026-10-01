defmodule Anime.VMMetricsTest do
  use ExUnit.Case, async: false
  import Anime.MetricsProbe
  alias Anime.Metrics
  alias Anime.Metrics.{Exporter, PoolSampler, Sampler, VMSampler}
  alias TelemetryMetricsPrometheus.Core
  @reporter Anime.Metrics.VMTestReporter
  @secret "PRIVATE-VM-SENTINEL"

  setup do
    reporter()
    :ok
  end

  test "real OTP reads only numeric counters and the fixed nine memory categories" do
    assert {:ok, values} = VMSampler.read()
    assert Map.keys(values.memory) |> Enum.sort() == Enum.sort(Metrics.memory_types())
    assert map_size(values) == 7
    assert values.vm_process_count > 0
    assert values.vm_port_count > 0
    assert values.vm_atom_count > 0
    assert values.vm_gc_collections >= 0
    assert values.application_start_time_seconds <= System.system_time(:second)
    assert values.application_uptime_seconds >= 0
    assert values.memory.total > 0
    assert Enum.all?(values.memory, fn {_, v} -> is_integer(v) and v >= 0 end)
  end

  test "uptime uses completed seconds from the shared application clock" do
    clock =
      start_supervised!(
        {Anime.RuntimeClock,
         name: nil, anchor: %{started_at: 100, monotonic_ms: -5_000}, clock: fn -> -3_765 end}
      )

    assert {:ok, values} = VMSampler.read(clock)
    assert values.application_start_time_seconds == 100
    assert values.application_uptime_seconds == 1
  end

  test "native GC count is cumulative and the reserved zero is not exposed as time" do
    assert {:ok, before} = VMSampler.read()
    :erlang.garbage_collect(self())
    assert {:ok, after_gc} = VMSampler.read()
    assert after_gc.vm_gc_collections >= before.vm_gc_collections
    refute Map.has_key?(after_gc, :vm_gc_duration)
    Metrics.publish_vm_snapshot({:ok, after_gc})
    body = Core.scrape(@reporter)
    assert body =~ "anime_vm_gc_collections #{after_gc.vm_gc_collections}\n"
    refute body =~ "gc_duration"
    refute body =~ "gc_time"
  end

  test "GC snapshot replaces rather than summing lifetime totals" do
    for n <- [10, 12, 2], do: Metrics.publish_vm_snapshot({:ok, sample(n)})
    assert Core.scrape(@reporter) =~ "anime_vm_gc_collections 2\n"
    assert Core.scrape(@reporter) =~ "# TYPE anime_vm_gc_collections gauge"
  end

  test "normalization strips unknown keys and requires every numeric field" do
    values = sample()

    extra =
      %{values | memory: Map.put(values.memory, :private, @secret)} |> Map.put(:private, self())

    assert VMSampler.normalize({:ok, extra}) == {:ok, values}

    for key <- Map.keys(values),
        do: assert(VMSampler.normalize({:ok, Map.delete(values, key)}) == :unavailable)

    for key <- Metrics.memory_types() do
      assert VMSampler.normalize({:ok, %{values | memory: Map.delete(values.memory, key)}}) ==
               :unavailable
    end
  end

  test "invalid values reject the whole snapshot without partial publication" do
    for value <- [-1, 1.5, nil, @secret, self(), Integer.pow(10, 100)] do
      assert VMSampler.normalize({:ok, %{sample() | vm_atom_count: value}}) == :unavailable

      assert VMSampler.normalize({:ok, put_in(sample(), [:memory, :total], value)}) ==
               :unavailable
    end

    for value <- [nil, %{}, {:error, @secret}, {:ok, %{memory: []}}] do
      assert VMSampler.normalize(value) == :unavailable
    end

    {_, records} =
      capture(fn -> Metrics.publish_vm_snapshot({:ok, %{sample() | vm_port_count: -1}}) end)

    assert records == [{[:anime, :metrics, :vm_snapshot_available], %{value: 0}, %{}}]
  end

  test "raw safe events have only bounded values and fixed memory kind labels" do
    {_, records} =
      capture(fn -> Metrics.publish_vm_snapshot({:ok, Map.put(sample(), :secret, @secret)}) end)

    assert length(records) == 16

    for {event, measurements, tags} <- records do
      assert Map.keys(measurements) == [:value]
      assert Metrics.valid_pool_count?(measurements.value)
      assert MapSet.member?(Metrics.allowed_tags()[event], tags)
    end

    refute inspect(records) =~ @secret
  end

  test "all gauges overwrite, preserve units and never accumulate across samples" do
    for n <- [9, 2], do: Metrics.publish_vm_snapshot({:ok, sample(n)})
    body = Core.scrape(@reporter)
    assert body =~ ~s(anime_vm_memory_bytes{kind="total"} 2\n)
    assert body =~ "anime_vm_process_count 2\n"
    assert body =~ "anime_application_start_time_seconds 100\n"
    assert body =~ "anime_application_uptime_seconds 2\n"
    assert body =~ "anime_vm_snapshot_available 1\n"
    assert length(Regex.scan(~r/^anime_vm_memory_bytes\{/m, body)) == 9
  end

  test "direct invalid events and arbitrary labels cannot create series" do
    for key <- [
          :vm_memory_bytes,
          :vm_process_count,
          :vm_port_count,
          :vm_atom_count,
          :vm_gc_collections,
          :application_start_time_seconds,
          :application_uptime_seconds,
          :vm_snapshot_available
        ],
        value <- [-1, nil, 1.2, @secret, Integer.pow(10, 100)] do
      :telemetry.execute([:anime, :metrics, key], %{value: value}, %{
        kind: "total",
        secret: @secret
      })
    end

    for n <- 1..600,
        do:
          :telemetry.execute([:anime, :metrics, :vm_memory_bytes], %{value: 1}, %{
            kind: @secret <> to_string(n)
          })

    :telemetry.execute([:anime, :metrics, :vm_snapshot_available], %{value: 2}, %{})
    assert Core.scrape(@reporter) == ""

    :telemetry.execute([:anime, :metrics, :vm_memory_bytes], %{value: 5}, %{
      kind: "ets",
      secret: @secret
    })

    refute Core.scrape(@reporter) =~ @secret
    assert Core.scrape(@reporter) =~ ~s(anime_vm_memory_bytes{kind="ets"} 5\n)
  end

  test "before first result no fictitious zero resource usage is exposed" do
    vm = sampler(read: blocking_read(self()))
    assert_receive {:reading, worker}
    unavailable!(scrape(vm))
    send(worker, {:result, {:ok, sample()}})
    eventually(fn -> VMSampler.snapshot(vm) == {:ok, sample()} end)
    assert scrape(vm) =~ "anime_vm_process_count 4\n"
  end

  test "scrapes neither resample resources nor perform SQL" do
    owner = self()

    vm =
      sampler(
        read: fn ->
          send(owner, :read)
          {:ok, sample()}
        end
      )

    assert_receive :read
    eventually(fn -> VMSampler.snapshot(vm) != :unavailable end)
    ref = make_ref()
    :telemetry.attach(ref, [:anime, :repo, :query], &__MODULE__.query_notice/4, owner)

    try do
      for _ <- 1..10, do: assert(scrape(vm) =~ "anime_vm_snapshot_available 1\n")
      refute_receive :read, 20
      refute_receive :query, 20
    after
      :telemetry.detach(ref)
    end
  end

  test "30 second boundary, backwards clock and recovery guard all labelled rows" do
    clock = start_supervised!({Agent, fn -> 0 end})
    vm = sampler(read: fn -> {:ok, sample()} end, clock: fn -> Agent.get(clock, & &1) end)
    eventually(fn -> VMSampler.snapshot(vm) != :unavailable end)
    Agent.update(clock, fn _ -> 29_999 end)
    assert scrape(vm) =~ "anime_vm_snapshot_available 1\n"
    Agent.update(clock, fn _ -> 30_000 end)
    unavailable!(scrape(vm))
    Agent.update(clock, fn _ -> -1 end)
    unavailable!(scrape(vm))
    VMSampler.poll(vm)
    eventually(fn -> VMSampler.snapshot(vm) != :unavailable end)
    assert scrape(vm) =~ "anime_vm_snapshot_available 1\n"
  end

  test "freshness is rechecked after rendering, not just before it" do
    clock = start_supervised!({Agent, fn -> 0 end})
    vm = sampler(read: fn -> {:ok, sample()} end, clock: fn -> Agent.get(clock, & &1) end)
    eventually(fn -> VMSampler.snapshot(vm) != :unavailable end)

    assert {:ok, body} =
             Sampler.render(vm, fn ->
               Agent.update(clock, fn _ -> 30_000 end)
               Core.scrape(@reporter)
             end)

    unavailable!(body)
  end

  test "source failures clear old values and never leak error details" do
    source = start_supervised!({Agent, fn -> :ok end})

    vm =
      sampler(
        read: fn ->
          case Agent.get(source, & &1) do
            :ok -> {:ok, sample()}
            :raise -> raise @secret
            :throw -> throw(@secret)
            :exit -> exit(@secret)
            :invalid -> {:ok, %{sample() | vm_process_count: @secret}}
          end
        end
      )

    eventually(fn -> VMSampler.snapshot(vm) != :unavailable end)

    for failure <- [:raise, :throw, :exit, :invalid] do
      Agent.update(source, fn _ -> failure end)
      VMSampler.poll(vm)
      eventually(fn -> VMSampler.snapshot(vm) == :unavailable end)
      unavailable!(scrape(vm))
      Agent.update(source, fn _ -> :ok end)
      VMSampler.poll(vm)
      eventually(fn -> VMSampler.snapshot(vm) != :unavailable end)
    end
  end

  test "periodic and manual polls never overlap a slow resource read" do
    vm = sampler(read: blocking_read(self()), interval: 20)
    assert_receive {:reading, worker}
    for _ <- 1..20, do: VMSampler.poll(vm)
    refute_receive {:reading, _}, 60
    send(worker, {:result, {:ok, sample()}})
    assert_receive {:reading, next}, 200
    assert next != worker
  end

  test "timed out worker is killed; late results ignored; next read recovers" do
    vm = sampler(read: blocking_read(self()), timeout: 100)
    assert_receive {:reading, worker}
    token = :sys.get_state(vm).worker.token
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
    eventually(fn -> :sys.get_state(vm).worker == nil end)
    unavailable!(scrape(vm))
    VMSampler.poll(vm)
    assert_receive {:reading, next}
    send(vm, {:sample, token, {:ok, sample(999)}, 0})
    send(vm, {:timeout, token})
    assert VMSampler.snapshot(vm) == :unavailable
    send(next, {:result, {:ok, sample(2)}})
    eventually(fn -> VMSampler.snapshot(vm) == {:ok, sample(2)} end)
  end

  test "supervised sampler restart drops its snapshot but does not reset application lifetime" do
    {:ok, before} = Anime.RuntimeClock.measure()
    name = Anime.Metrics.RestartVMSampler
    vm = sampler(name: name, read: blocking_read(self()))
    assert_receive {:reading, worker}
    send(worker, {:result, {:ok, sample()}})
    eventually(fn -> VMSampler.snapshot(name) != :unavailable end)
    Process.exit(vm, :kill)
    assert_receive {:reading, next}, 1_000
    assert next != worker
    unavailable!(scrape(name))
    {:ok, after_restart} = Anime.RuntimeClock.measure()
    assert after_restart.started_at == before.started_at
    assert after_restart.uptime_ms >= before.uptime_ms
  end

  test "normal stop and hard kill both stop an unfinished worker" do
    for mode <- [:normal, :kill] do
      vm = sampler(read: blocking_read(self()), restart: :temporary)
      assert_receive {:reading, worker}
      ref = Process.monitor(worker)
      if mode == :normal, do: stop_supervised!(VMSampler), else: Process.exit(vm, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
      unavailable!(scrape(vm))
    end
  end

  test "failed VM group does not suppress a fresh pool or accumulated counters" do
    Metrics.publish_vm_snapshot({:ok, sample()})
    pool = pool()
    :telemetry.execute([:anime, :metrics, :projection_error], %{count: 1}, %{})
    body = Exporter.scrape(pool, :missing_vm_sampler, @reporter)
    unavailable!(body)
    assert body =~ "anime_db_pool_ready 3\n"
    assert body =~ "anime_projection_error_total 1\n"
  end

  test "failed and suspended pool do not suppress fresh VM metrics" do
    vm = sampler(read: fn -> {:ok, sample()} end)
    eventually(fn -> VMSampler.snapshot(vm) != :unavailable end)
    assert scrape(vm) =~ "anime_vm_process_count 4\n"
    pool = pool()
    :sys.suspend(pool)

    try do
      body = Exporter.scrape(pool, vm, @reporter)
      assert body =~ "anime_db_pool_snapshot_available 0\n"
      assert body =~ "anime_vm_process_count 4\n"
    after
      :sys.resume(pool)
    end
  end

  test "suspended VM eventually degrades without preventing pool exposition" do
    vm = sampler(read: fn -> {:ok, sample()} end)
    eventually(fn -> VMSampler.snapshot(vm) != :unavailable end)
    pool = pool()
    :sys.suspend(vm)

    try do
      body = Exporter.scrape(pool, vm, @reporter)
      unavailable!(body)
      assert body =~ "anime_db_pool_ready 3\n"
    after
      :sys.resume(vm)
    end
  end

  test "reporter restart restores a fresh snapshot without restarting samplers or uptime" do
    vm = sampler(read: fn -> {:ok, sample()} end)
    eventually(fn -> VMSampler.snapshot(vm) != :unavailable end)
    stop_supervised!(@reporter)
    assert_raise RuntimeError, "Metrics unavailable", fn -> scrape(vm) end
    assert Process.alive?(vm)
    reporter()
    assert scrape(vm) =~ "anime_application_start_time_seconds 100\n"
  end

  test "concurrent reads cannot mix resource fields from different samples" do
    source = start_supervised!({Agent, fn -> 1 end})

    vm =
      sampler(
        read: fn ->
          n = Agent.get_and_update(source, fn n -> {n, n + 1} end)
          {:ok, sample(n)}
        end
      )

    eventually(fn -> VMSampler.snapshot(vm) != :unavailable end)

    1..30
    |> Task.async_stream(
      fn _ ->
        VMSampler.poll(vm)
        body = scrape(vm)
        [_, n] = Regex.run(~r/^anime_vm_process_count (\d+)$/m, body)
        assert body =~ ~s(anime_vm_memory_bytes{kind="total"} #{n}\n)
        assert body =~ "anime_vm_port_count #{n}\n"
      end,
      max_concurrency: 8
    )
    |> Enum.each(fn result -> assert result == {:ok, true} end)
  end

  test "HTTP exposes fresh resources and omits them after sampler loss" do
    vm = sampler(name: VMSampler, read: fn -> {:ok, sample()} end)
    eventually(fn -> VMSampler.snapshot(vm) != :unavailable end)
    listener = start_supervised!(Exporter.listener_spec(0))
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
    url = "http://127.0.0.1:#{port}/metrics"
    response = Req.get!(url, retry: false)
    assert response.status == 200
    assert response.body =~ ~s(anime_vm_memory_bytes{kind="total"} 4\n)
    assert response.headers["cache-control"] == ["no-store"]
    stop_supervised!(VMSampler)
    response = Req.get!(url, retry: false)
    assert response.status == 200
    unavailable!(response.body)
  end

  test "family expiry preserves names that merely share a prefix" do
    Metrics.publish_vm_snapshot({:ok, sample()})
    body = Core.scrape(@reporter) <> "anime_vm_memory_bytes_extra 7\n"
    expired = Exporter.guard_vm_snapshot(body, :unavailable)
    assert expired =~ "anime_vm_memory_bytes_extra 7\n"
    refute expired =~ ~s(anime_vm_memory_bytes{)
    assert length(Regex.scan(~r/^anime_vm_snapshot_available /m, expired)) == 1
  end

  def query_notice(_, _, _, owner), do: send(owner, :query)

  defp sample(n \\ 4),
    do: %{
      memory: Map.new(Metrics.memory_types(), &{&1, n}),
      vm_process_count: n,
      vm_port_count: n,
      vm_atom_count: n,
      vm_gc_collections: n,
      application_start_time_seconds: 100,
      application_uptime_seconds: n
    }

  defp sampler(options) do
    {restart, options} = Keyword.pop(options, :restart, :permanent)
    options = Keyword.merge([enabled: true, name: nil, interval: 60_000], options)
    start_supervised!(Supervisor.child_spec({VMSampler, options}, restart: restart))
  end

  defp pool do
    pool =
      start_supervised!(
        {PoolSampler,
         enabled: true,
         name: nil,
         interval: 60_000,
         read: fn -> {:ok, %{ready: 3, waiting: 1}} end}
      )

    eventually(fn -> PoolSampler.snapshot(pool) != :unavailable end)
    pool
  end

  defp reporter do
    start_supervised!(
      Supervisor.child_spec(
        {Core, name: @reporter, metrics: Metrics.definitions(), start_async: false},
        id: @reporter
      )
    )
  end

  defp scrape(vm), do: Exporter.scrape(:missing_pool_sampler, vm, @reporter)

  defp blocking_read(owner),
    do: fn ->
      send(owner, {:reading, self()})
      receive do: ({:result, result} -> result)
    end

  defp unavailable!(body) do
    assert body =~ "anime_vm_snapshot_available 0\n"
    assert length(Regex.scan(~r/^anime_vm_snapshot_available /m, body)) == 1

    for name <- Metrics.vm_metric_names() -- ["anime_vm_snapshot_available"],
        do: refute(body =~ name)

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
