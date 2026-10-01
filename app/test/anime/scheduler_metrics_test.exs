defmodule Anime.SchedulerMetricsTest do
  use ExUnit.Case, async: false
  import Anime.MetricsProbe
  alias Anime.Metrics
  alias Anime.Metrics.{Exporter, SchedulerSampler, VMSampler}
  alias TelemetryMetricsPrometheus.Core
  @reporter Anime.Metrics.SchedulerTestReporter
  @tiny %{normal: 2, dirty_cpu: 1, dirty_io: 1}
  @secret "PRIVATE-SCHEDULER-SENTINEL"

  setup do
    reporter()
    :ok
  end

  test "actual OTP queue and wall-time sample matches the installed topology" do
    sampler = sampler(read: &SchedulerSampler.read/0)
    eventually(fn -> SchedulerSampler.snapshot(sampler) != :unavailable end)
    {:ok, values} = SchedulerSampler.snapshot(sampler)
    assert length(values.queues) == Metrics.scheduler_topology().normal + 2
    assert Enum.all?(values.queues, fn {_, v} -> is_integer(v) and v >= 0 end)
    assert values.utilization == nil
    Process.sleep(10)
    SchedulerSampler.poll(sampler)

    eventually(fn ->
      match?(
        {:ok, %{utilization: values}} when is_list(values),
        SchedulerSampler.snapshot(sampler)
      )
    end)

    {:ok, values} = SchedulerSampler.snapshot(sampler)
    assert Enum.all?(values.utilization, fn {_, v} -> v >= 0 and v <= 1 end)
  end

  test "unsorted rows are matched by ID and dirty queues are shared, not duplicated" do
    current = raw(0, @tiny)

    assert {:ok, clean} =
             SchedulerSampler.normalize(
               {:ok, %{current | wall: Enum.reverse(current.wall)}},
               @tiny
             )

    assert clean.queues == [
             {%{kind: "normal", id: "1"}, 0},
             {%{kind: "normal", id: "2"}, 0},
             {%{kind: "dirty_cpu", id: "shared"}, 0},
             {%{kind: "dirty_io", id: "shared"}, 0}
           ]

    assert map_size(clean.wall) == 4
  end

  test "interval ratios use deltas, not lifetime ratios or scheduler count averages" do
    first = normalize(raw(0, @tiny))
    second = normalize(raw(1, @tiny))

    assert {{:ok, %{utilization: nil}}, baseline} =
             SchedulerSampler.project(first, nil, 0, 30_000)

    assert {{:ok, %{utilization: rows}}, _} =
             SchedulerSampler.project(second, baseline, 15_000, 30_000)

    assert length(rows) == 4
    assert Enum.all?(rows, fn {_, v} -> v == 0.25 end)
  end

  test "missing, duplicate, negative, overfull and malformed wall rows discard only utilization" do
    sample = raw(0, @tiny)

    for wall <- [
          :undefined,
          nil,
          @secret,
          [],
          tl(sample.wall),
          [hd(sample.wall) | tl(tl(sample.wall))] ++ [hd(sample.wall)],
          [{1, -1, 1} | tl(sample.wall)],
          [{1, 2, 1} | tl(sample.wall)],
          [{5, 1, 2} | tl(sample.wall)],
          [{1, 1, Integer.pow(10, 100)} | tl(sample.wall)]
        ] do
      assert {:ok, clean} = SchedulerSampler.normalize({:ok, %{sample | wall: wall}}, @tiny)
      assert clean.wall == nil
      assert length(clean.queues) == 4
    end
  end

  test "malformed queues, topology and online counts reject the sample" do
    sample = raw(0, @tiny)

    for bad <- [
          %{sample | queues: []},
          %{sample | queues: [0, -1, 0, 0]},
          %{sample | queues: [0, @secret, 0, 0]},
          %{sample | online: %{normal: 3, dirty_cpu: 1}},
          %{sample | online: %{}},
          %{sample | topology: %{normal: 3, dirty_cpu: 1, dirty_io: 1}}
        ] do
      assert SchedulerSampler.normalize({:ok, bad}, @tiny) == :unavailable
    end

    assert SchedulerSampler.normalize({:error, @secret}, @tiny) == :unavailable
  end

  test "extra raw data is not retained in baseline or output" do
    sample = raw(0, @tiny) |> Map.put(:secret, @secret)
    {:ok, normalized} = SchedulerSampler.normalize({:ok, sample}, @tiny)
    assert Map.keys(normalized) |> Enum.sort() == [:online, :queues, :topology, :wall]
    refute inspect(normalized) =~ @secret
  end

  test "zero interval, stale interval, clock reversal and reset never fabricate a ratio" do
    first = normalize(raw(1, @tiny))
    {_, baseline} = SchedulerSampler.project(first, nil, 100, 30_000)

    for now <- [100, 99, 30_100] do
      assert {{:ok, %{utilization: nil}}, _} =
               SchedulerSampler.project(normalize(raw(2, @tiny)), baseline, now, 30_000)
    end

    assert {{:ok, %{utilization: nil}}, _} =
             SchedulerSampler.project(first, baseline, 200, 30_000)

    assert {{:ok, %{utilization: nil}}, _} =
             SchedulerSampler.project(normalize(raw(0, @tiny)), baseline, 200, 30_000)

    altered = raw(2, @tiny) |> Map.update!(:wall, fn [_ | tail] -> [{1, 500, 600} | tail] end)

    assert {{:ok, %{utilization: nil}}, _} =
             SchedulerSampler.project(normalize(altered), baseline, 200, 30_000)
  end

  test "offline schedulers are omitted and an online configuration change warms up again" do
    first = normalize(raw(0, @tiny))
    {_, baseline} = SchedulerSampler.project(first, nil, 0, 30_000)
    second = %{raw(1, @tiny) | online: %{normal: 1, dirty_cpu: 1}} |> normalize()

    assert {{:ok, %{utilization: nil}}, baseline} =
             SchedulerSampler.project(second, baseline, 15_000, 30_000)

    third = %{raw(2, @tiny) | online: %{normal: 1, dirty_cpu: 1}} |> normalize()

    assert {{:ok, %{utilization: rows}}, _} =
             SchedulerSampler.project(third, baseline, 30_000, 30_000)

    assert length(rows) == 3
    refute Enum.any?(rows, fn {tags, _} -> tags == %{kind: "normal", id: "2"} end)
  end

  test "a failed read clears baseline and needs two new successful samples" do
    {_, baseline} = SchedulerSampler.project(normalize(raw(0, @tiny)), nil, 0, 30_000)
    assert {:unavailable, nil} = SchedulerSampler.project(:unavailable, baseline, 10, 30_000)

    assert {{:ok, %{utilization: nil}}, baseline} =
             SchedulerSampler.project(normalize(raw(1, @tiny)), nil, 15, 30_000)

    assert {{:ok, %{utilization: rows}}, _} =
             SchedulerSampler.project(normalize(raw(2, @tiny)), baseline, 30, 30_000)

    assert is_list(rows)
  end

  test "raw safe events contain only values and closed hardware labels" do
    {_, baseline} = SchedulerSampler.project(normalize(raw(0, @tiny)), nil, 0, 30_000)
    {snapshot, _} = SchedulerSampler.project(normalize(raw(1, @tiny)), baseline, 10, 30_000)
    {_, records} = capture(fn -> Metrics.publish_scheduler_snapshot(snapshot) end)
    assert length(records) == 10

    for {event, values, tags} <- records do
      assert Map.keys(values) == [:value]
      assert MapSet.member?(Metrics.allowed_tags()[event], tags)
      refute inspect(tags) =~ @secret
    end
  end

  test "invalid values and unbounded IDs cannot grow exporter series" do
    for n <- 1..600 do
      :telemetry.execute([:anime, :metrics, :scheduler_run_queue_length], %{value: 1}, %{
        kind: @secret,
        id: to_string(n)
      })

      :telemetry.execute([:anime, :metrics, :scheduler_utilization_ratio], %{value: 0.5}, %{
        kind: "normal",
        id: @secret <> to_string(n)
      })
    end

    for value <- [-1, 1.1, nil, @secret] do
      :telemetry.execute([:anime, :metrics, :scheduler_utilization_ratio], %{value: value}, %{
        kind: "normal",
        id: "1"
      })
    end

    :telemetry.execute([:anime, :metrics, :scheduler_snapshot_available], %{value: 2}, %{
      measurement: "queues"
    })

    assert Core.scrape(@reporter) == ""
  end

  test "publication reconstructs safe tags before telemetry, not merely at export" do
    tags = %{kind: "normal", id: "1", secret: @secret, pid: self()}

    {_, records} =
      capture(fn ->
        Metrics.publish_scheduler_snapshot(
          {:ok, %{queues: [{tags, 1}], utilization: [{tags, 0.2}], secret: @secret}}
        )
      end)

    assert length(records) == 4
    refute inspect(records) =~ @secret
    for {_, _, tags} <- records, do: refute(Map.has_key?(tags, :pid))
  end

  test "malformed projections publish only unavailability and no private payload" do
    tags = %{kind: "normal", id: "1"}

    for bad <- [
          :bad,
          {:ok, %{}},
          {:ok, %{queues: [@secret], utilization: nil}},
          {:ok, %{queues: [{tags, @secret}], utilization: nil}},
          {:ok, %{queues: [{tags, 1}], utilization: [{tags, 3}]}},
          {:ok, %{queues: [{%{kind: @secret, id: "1"}, 1}], utilization: nil}}
        ] do
      {_, records} = capture(fn -> Metrics.publish_scheduler_snapshot(bad) end)
      assert length(records) == 2

      assert Enum.all?(records, fn {event, values, _} ->
               event == [:anime, :metrics, :scheduler_snapshot_available] and
                 values == %{value: 0}
             end)

      refute inspect(records) =~ @secret
    end
  end

  test "duplicate scheduler identities are rejected instead of arbitrary last wins" do
    row = {%{kind: "normal", id: "1"}, 1}

    {_, records} =
      capture(fn ->
        Metrics.publish_scheduler_snapshot({:ok, %{queues: [row, row], utilization: nil}})
      end)

    assert length(records) == 2
    refute Core.scrape(@reporter) =~ "anime_scheduler_run_queue_length"
  end

  test "full hardware label budget is checked, never silently truncated" do
    domains = Metrics.scheduler_domains(%{normal: 499, dirty_cpu: 1, dirty_io: 1})
    metric = Telemetry.Metrics.last_value("test.scheduler")

    assert_raise ArgumentError, ~r/exceeds 500/, fn ->
      Metrics.validate_budget!(metric, domains.scheduler_run_queue_length)
    end

    assert_raise ArgumentError, ~r/exceeds 500/, fn ->
      Metrics.validate_budget!(metric, domains.scheduler_utilization_ratio)
    end
  end

  test "fresh warmup hides earlier utilization but keeps new queue readings" do
    publish_ratio()
    vm = sampler(read: fn -> {:ok, raw(0)} end)
    eventually(fn -> SchedulerSampler.snapshot(vm) != :unavailable end)
    body = scrape(vm)
    refute body =~ "anime_scheduler_utilization_ratio"
    assert body =~ ~s(anime_scheduler_snapshot_available{measurement="queues"} 1)
    assert body =~ ~s(anime_scheduler_snapshot_available{measurement="utilization"} 0)
    assert body =~ "anime_scheduler_run_queue_length"
  end

  test "offline label sets left in Core are removed from a fresh exposition" do
    publish_ratio()
    values = [{%{kind: "normal", id: "1"}, 0.5}]

    body =
      Exporter.guard_scheduler_snapshot(Core.scrape(@reporter), {:ok, %{utilization: values}})

    assert body =~ ~s(anime_scheduler_utilization_ratio{id="1",kind="normal"})
    refute body =~ ~s(anime_scheduler_utilization_ratio{id="2",kind="normal"})
    refute body =~ ~s(anime_scheduler_utilization_ratio{id="1",kind="dirty_cpu"})
  end

  test "expiry removes both scheduler groups, not VM or pool values" do
    publish_ratio()
    :telemetry.execute([:anime, :metrics, :vm_process_count], %{value: 123}, %{})
    Metrics.publish_pool_snapshot({:ok, %{ready: 4, waiting: 1}})
    body = Exporter.guard_scheduler_snapshot(Core.scrape(@reporter), :unavailable)
    unavailable!(body)
    assert body =~ "anime_vm_process_count 123"
    assert body =~ "anime_db_pool_ready 4"
  end

  test "scrape does not read statistics; reporter restart restores the last interval" do
    source = start_supervised!({Agent, fn -> 0 end})
    owner = self()

    sampler =
      sampler(
        read: fn ->
          n = Agent.get(source, & &1)
          send(owner, :read)
          {:ok, raw(n)}
        end,
        clock: fn -> Agent.get(source, &(&1 * 15_000)) end
      )

    assert_receive :read
    eventually(fn -> SchedulerSampler.snapshot(sampler) != :unavailable end)
    Agent.update(source, fn _ -> 1 end)
    SchedulerSampler.poll(sampler)
    assert_receive :read

    eventually(fn ->
      match?({:ok, %{utilization: v}} when is_list(v), SchedulerSampler.snapshot(sampler))
    end)

    for _ <- 1..5, do: assert(scrape(sampler) =~ "anime_scheduler_utilization_ratio")
    refute_receive :read, 20
    stop_supervised!(@reporter)
    assert_raise RuntimeError, "Metrics unavailable", fn -> scrape(sampler) end
    assert Process.alive?(sampler)
    reporter()
    assert scrape(sampler) =~ "anime_scheduler_utilization_ratio"
    Agent.update(source, fn _ -> 3 end)
    unavailable!(scrape(sampler))
  end

  test "timeout clears source baseline and late responses cannot restore it" do
    sampler = sampler(read: blocking_read(self()), timeout: 100)
    assert_receive {:reading, worker}
    token = :sys.get_state(sampler).worker.token
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
    eventually(fn -> :sys.get_state(sampler).worker == nil end)
    send(sampler, {:sample, token, {:ok, raw(0)}, 0})
    unavailable!(scrape(sampler))
    assert :sys.get_state(sampler).source_state == nil
  end

  test "periodic polling does not overlap a blocked statistics read" do
    sampler = sampler(read: blocking_read(self()), interval: 20)
    assert_receive {:reading, worker}
    for _ <- 1..10, do: SchedulerSampler.poll(sampler)
    refute_receive {:reading, _}, 60
    send(worker, {:result, {:ok, raw(0)}})
    assert_receive {:reading, next}, 200
    assert worker != next
  end

  test "statistics exceptions remove old data without leaking details" do
    publish_ratio()
    sampler = sampler(read: fn -> raise @secret end)
    eventually(fn -> :sys.get_state(sampler).worker == nil end)
    unavailable!(scrape(sampler))
    assert Process.alive?(sampler)
  end

  test "killing sampler releases its measurement reference and kills its worker" do
    before = :erlang.statistics(:scheduler_wall_time_all)
    sampler = sampler(read: blocking_read(self()), restart: :temporary)
    assert_receive {:reading, worker}
    assert is_list(:erlang.statistics(:scheduler_wall_time_all))
    ref = Process.monitor(worker)
    Process.exit(sampler, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}

    if before == :undefined,
      do: eventually(fn -> :erlang.statistics(:scheduler_wall_time_all) == :undefined end)

    unavailable!(scrape(sampler))
  end

  test "normal stop does not disable measurements owned by another process" do
    :erlang.system_flag(:scheduler_wall_time, true)

    try do
      sampler(read: fn -> {:ok, raw(0)} end)
      stop_supervised!(SchedulerSampler)
      assert is_list(:erlang.statistics(:scheduler_wall_time_all))
    after
      :erlang.system_flag(:scheduler_wall_time, false)
    end
  end

  test "supervision restarts with warmup instead of an old interval" do
    name = Anime.Metrics.RestartSchedulerSampler
    sampler = sampler(name: name, read: blocking_read(self()))
    assert_receive {:reading, worker}
    send(worker, {:result, {:ok, raw(0)}})
    eventually(fn -> SchedulerSampler.snapshot(name) != :unavailable end)
    Process.exit(sampler, :kill)
    assert_receive {:reading, next}, 1_000
    unavailable!(scrape(name))
    send(next, {:result, {:ok, raw(1)}})
    eventually(fn -> SchedulerSampler.snapshot(name) != :unavailable end)
    assert {:ok, %{utilization: nil}} = SchedulerSampler.snapshot(name)
  end

  test "real HTTP serves scheduler queues, warmup and degradation without a public site" do
    sampler = sampler(name: SchedulerSampler, read: fn -> {:ok, raw(0)} end)
    eventually(fn -> SchedulerSampler.snapshot(sampler) != :unavailable end)
    pid = start_supervised!(Exporter.listener_spec(0))
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    url = "http://127.0.0.1:#{port}/metrics"
    response = Req.get!(url, retry: false)
    assert response.status == 200
    assert response.body =~ "anime_scheduler_run_queue_length"
    refute response.body =~ "anime_scheduler_utilization_ratio"
    stop_supervised!(SchedulerSampler)
    response = Req.get!(url, retry: false)
    assert response.status == 200
    unavailable!(response.body)
  end

  test "suspended scheduler cannot hide the fresh VM group indefinitely" do
    assert {:ok, sample} = VMSampler.read()

    vm =
      start_supervised!(
        {VMSampler, enabled: true, name: nil, interval: 60_000, read: fn -> {:ok, sample} end}
      )

    sampler = sampler(read: fn -> {:ok, raw(0)} end)
    eventually(fn -> VMSampler.snapshot(vm) != :unavailable end)
    eventually(fn -> SchedulerSampler.snapshot(sampler) != :unavailable end)
    :sys.suspend(sampler)

    try do
      body = Exporter.scrape(:missing_pool, vm, sampler, @reporter)
      unavailable!(body)
      assert body =~ "anime_vm_process_count"
    after
      :sys.resume(sampler)
    end
  end

  defp raw(n, topology \\ Metrics.scheduler_topology()) do
    count = topology.normal + topology.dirty_cpu + topology.dirty_io

    %{
      topology: topology,
      online: %{normal: topology.normal, dirty_cpu: topology.dirty_cpu},
      queues: List.duplicate(n, topology.normal + 2),
      wall: for(id <- 1..count, do: {id, 50 + 25 * n, 200 + 100 * n})
    }
  end

  defp normalize(raw), do: SchedulerSampler.normalize({:ok, raw}, @tiny)

  defp publish_ratio do
    {_, baseline} = SchedulerSampler.project(normalize(raw(0, @tiny)), nil, 0, 30_000)
    {snapshot, _} = SchedulerSampler.project(normalize(raw(1, @tiny)), baseline, 10, 30_000)
    Metrics.publish_scheduler_snapshot(snapshot)
  end

  defp sampler(options) do
    {restart, options} = Keyword.pop(options, :restart, :permanent)
    options = Keyword.merge([enabled: true, name: nil, interval: 60_000], options)
    start_supervised!(Supervisor.child_spec({SchedulerSampler, options}, restart: restart))
  end

  defp reporter do
    start_supervised!(
      Supervisor.child_spec(
        {Core, name: @reporter, metrics: Metrics.definitions(), start_async: false},
        id: @reporter
      )
    )
  end

  defp scrape(sampler), do: Exporter.scrape(:missing_pool, :missing_vm, sampler, @reporter)

  defp blocking_read(owner),
    do: fn ->
      send(owner, {:reading, self()})
      receive do: ({:result, result} -> result)
    end

  defp unavailable!(body) do
    for measurement <- ["queues", "utilization"] do
      assert body =~ ~s(anime_scheduler_snapshot_available{measurement="#{measurement}"} 0)
    end

    refute body =~ "anime_scheduler_run_queue_length"
    refute body =~ "anime_scheduler_utilization_ratio"
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
