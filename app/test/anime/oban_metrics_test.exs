defmodule Anime.ObanMetricsTest do
  use Anime.DataCase
  import Anime.MetricsProbe
  alias Anime.Metrics
  alias Anime.Metrics.{CacheSampler, Exporter, ObanSampler}
  alias TelemetryMetricsPrometheus.Core
  @reporter Anime.Metrics.ObanTestReporter
  @secret "PRIVATE-OBAN-SENTINEL"

  setup do
    # Rolled back with the sandbox; no tasks are performed by these tests.
    Repo.delete_all(Oban.Job)
    reporter()
    :ok
  end

  test "closed queues match the existing workers and states deliberately follow the seven-state spec" do
    queues =
      for worker <- [
            Anime.Workers.Mail,
            Anime.Workers.ExpireAccounts,
            Anime.Workers.UnblockUsers,
            Anime.Workers.DeleteAccounts
          ],
          do: worker.new(%{}).changes.queue

    assert queues |> Enum.uniq() |> Enum.sort() == Enum.sort(Metrics.oban_queues())

    assert Metrics.oban_states() ==
             ~w(available scheduled executing retryable completed cancelled discarded)

    refute "suspended" in Metrics.oban_states()
    assert MapSet.size(Metrics.allowed_tags()[[:anime, :metrics, :oban_jobs]]) == 14
  end

  test "an empty successful SELECT publishes actual zeros for all queues and states" do
    assert {:ok, values} = ObanSampler.read()
    assert values == sample(0)
    Metrics.publish_oban_snapshot({:ok, values})
    body = Core.scrape(@reporter)
    assert length(Regex.scan(~r/^anime_oban_jobs\{/m, body)) == 14
    assert length(Regex.scan(~r/^anime_oban_oldest_available_age_seconds\{/m, body)) == 2
    assert body =~ "anime_oban_snapshot_available 1\n"
  end

  test "one real aggregate SELECT counts both queues and all seven states without reading payloads" do
    for queue <- Metrics.oban_queues(), state <- Metrics.oban_states() do
      job(queue, state, -120)
    end

    job("mailers", "completed", -60)
    ref = observe_sql()
    {result, records} = capture(fn -> ObanSampler.read() end)
    :telemetry.detach(ref)
    assert {:ok, values} = result
    assert values.counts[{"mailers", "completed"}] == 2
    assert Enum.sum(Map.values(values.counts)) == 15
    for queue <- Metrics.oban_queues(), do: assert(values.ages[queue] in 119..125)
    assert_receive {:query, query}
    assert query =~ "count("
    assert query =~ "MIN("
    assert query =~ "GROUP BY"
    refute query =~ "args"
    refute query =~ "meta"
    refute query =~ "errors"
    refute_receive {:query, _}, 20
    assert rows(records, :db_query) == [{%{count: 1}, %{source: "other", outcome: "ok"}}]
    refute inspect(result) =~ @secret
    refute inspect(records) =~ @secret
  end

  test "available age is eligibility age not insertion age or time until future scheduled jobs" do
    j = job("mailers", "available", -30)
    Repo.update_all(from(j in Oban.Job, where: j.id == ^j.id), set: [inserted_at: ago(86_400)])
    job("mailers", "available", -90)
    job("mailers", "scheduled", -10_000)
    job("mailers", "retryable", -20_000)
    job("maintenance", "scheduled", 3600)
    {:ok, values} = ObanSampler.read()
    assert values.ages["mailers"] in 89..95
    assert values.ages["maintenance"] == 0
    assert values.counts[{"mailers", "available"}] == 2
    assert values.counts[{"maintenance", "scheduled"}] == 1
  end

  test "future available timestamp is clamped to zero, with a positive count" do
    job("mailers", "available", 3600)
    assert {:ok, values} = ObanSampler.read()
    assert values.ages["mailers"] == 0
    assert values.counts[{"mailers", "available"}] == 1
  end

  test "database clock is timezone independent and unrelated queues/states never create labels" do
    Repo.query!("SET LOCAL TIME ZONE 'Asia/Yakutsk'")
    job("mailers", "available", -180)
    job(@secret, "available", -10000)
    job("video_transcode", "available", -10000)
    job("mailers", "suspended", -10000)
    {:ok, values} = ObanSampler.read()
    assert values.ages["mailers"] in 179..185
    assert Enum.sum(Map.values(values.counts)) == 1
    Metrics.publish_oban_snapshot({:ok, values})
    body = Core.scrape(@reporter)
    refute body =~ @secret
    refute body =~ "video_transcode"
    refute body =~ "suspended"
  end

  test "reading does not change jobs or execute workers; state changes and deletion replace gauges" do
    j = job("mailers", "available", -60)
    before = Repo.get!(Oban.Job, j.id)
    assert {:ok, values} = ObanSampler.read()
    Metrics.publish_oban_snapshot({:ok, values})
    assert Repo.get!(Oban.Job, j.id) == before
    Repo.update_all(from(j in Oban.Job, where: j.id == ^j.id), set: [state: "completed"])
    Metrics.publish_oban_snapshot(ObanSampler.read())
    assert Core.scrape(@reporter) =~ ~s(anime_oban_jobs{queue="mailers",state="available"} 0\n)
    assert Core.scrape(@reporter) =~ ~s(anime_oban_jobs{queue="mailers",state="completed"} 1\n)
    Repo.delete!(j)
    Metrics.publish_oban_snapshot(ObanSampler.read())
    assert Core.scrape(@reporter) =~ ~s(anime_oban_jobs{queue="mailers",state="completed"} 0\n)
  end

  defmodule InspectRepo do
    def all(query, options) do
      send(self(), {:read_options, query, options})
      []
    end
  end

  defmodule ErrorRepo do
    def all(_, _), do: raise("PRIVATE-OBAN-SENTINEL")
  end

  defmodule ExitRepo do
    def all(_, _), do: exit("PRIVATE-OBAN-SENTINEL")
  end

  test "query uses a 750ms operation limit without checkout queueing and restores caller context" do
    assert {:ok, _} =
             Metrics.Context.with_source(:web, fn ->
               result = ObanSampler.read(InspectRepo)
               assert Metrics.Context.current() == :web
               result
             end)

    assert_receive {:read_options, %Ecto.Query{}, options}
    assert options == [timeout: 750, queue: false, log: false]
    assert Metrics.Context.current() == :other
  end

  test "query exceptions and exits return no raw errors or false zeros" do
    for repo <- [ErrorRepo, ExitRepo] do
      {result, records} =
        capture(fn ->
          value = ObanSampler.read(repo)
          Metrics.publish_oban_snapshot(value)
          value
        end)

      assert result == :unavailable
      assert records == [{[:anime, :metrics, :oban_snapshot_available], %{value: 0}, %{}}]
    end
  end

  test "malformed, duplicate, unknown and impossible aggregate rows are rejected" do
    row = {"mailers", "available", 1, 50}
    assert {:ok, values} = ObanSampler.from_rows([row])
    assert values.counts[{"mailers", "available"}] == 1
    assert values.ages["mailers"] == 50

    for rows <- [
          [row, row],
          [{@secret, "available", 1, 50}],
          [{"mailers", "private", 1, 0}],
          [{"mailers", "completed", 1, 50}],
          [{"mailers", "available", 0, 0}],
          [{"mailers", "available", 1, nil}],
          [{"mailers", "available", 1, -1}],
          [{"mailers", "available", 1.5, 0}],
          [{"mailers", "available", Integer.pow(10, 100), 0}],
          [%{secret: @secret}],
          nil
        ],
        do: assert(ObanSampler.from_rows(rows) == :unavailable)
  end

  test "safe snapshot normalization requires complete numeric fields and strips unknown data" do
    values = sample()

    extra =
      values
      |> Map.put(:private, @secret)
      |> put_in([:counts, {@secret, @secret}], 100)

    extra = put_in(extra, [:ages, @secret], 1)
    assert ObanSampler.normalize({:ok, extra}) == {:ok, values}

    for key <- Map.keys(values.counts),
        do:
          assert(
            ObanSampler.normalize({:ok, %{values | counts: Map.delete(values.counts, key)}}) ==
              :unavailable
          )

    for queue <- Metrics.oban_queues(),
        do:
          assert(
            ObanSampler.normalize({:ok, %{values | ages: Map.delete(values.ages, queue)}}) ==
              :unavailable
          )

    assert ObanSampler.normalize({:ok, put_in(sample(0), [:ages, "mailers"], 1)}) == :unavailable

    for value <- [-1, 1.2, nil, @secret, Integer.pow(10, 100)],
        do:
          assert(
            ObanSampler.normalize(
              {:ok, put_in(values, [:counts, {"mailers", "available"}], value)}
            ) == :unavailable
          )
  end

  test "safe events contain only 14 counts, 2 ages and availability, never raw job fields" do
    {_, records} =
      capture(fn ->
        Metrics.publish_oban_snapshot({:ok, Map.put(sample(), :private, @secret)})
      end)

    assert length(records) == 17

    for {event, measurements, tags} <- records do
      assert Map.keys(measurements) == [:value]
      assert Metrics.valid_pool_count?(measurements.value)
      assert MapSet.member?(Metrics.allowed_tags()[event], tags)
    end

    refute inspect(records) =~ @secret
    {_, invalid} = capture(fn -> Metrics.publish_oban_snapshot({:ok, %{}}) end)
    assert invalid == [{[:anime, :metrics, :oban_snapshot_available], %{value: 0}, %{}}]
  end

  test "invalid direct events and hundreds of arbitrary queues cannot increase cardinality" do
    for n <- 1..600,
        do: emit(:oban_jobs, 1, %{queue: @secret <> to_string(n), state: "available"})

    emit(:oban_jobs, 1, %{queue: "mailers", state: @secret})

    for key <- [:oban_jobs, :oban_oldest_available_age_seconds, :oban_snapshot_available],
        value <- [-1, 1.2, @secret, nil, Integer.pow(10, 100)],
        do: emit(key, value, %{queue: "mailers", state: "available"})

    emit(:oban_snapshot_available, 2, %{})
    assert Core.scrape(@reporter) == ""
    emit(:oban_jobs, 2, %{queue: "mailers", state: "available", args: @secret})
    assert Core.scrape(@reporter) =~ ~s(anime_oban_jobs{queue="mailers",state="available"} 2\n)
    refute Core.scrape(@reporter) =~ @secret
  end

  test "repeated snapshots replace counts and sampled age rather than accumulating" do
    for n <- [9, 2], do: Metrics.publish_oban_snapshot({:ok, sample(n)})
    body = Core.scrape(@reporter)
    assert body =~ ~s(anime_oban_jobs{queue="mailers",state="available"} 2\n)
    assert body =~ ~s(anime_oban_oldest_available_age_seconds{queue="mailers"} 20\n)
    assert length(Regex.scan(~r/^anime_oban_jobs\{/m, body)) == 14
  end

  test "no false empty queues are exposed before the first successful sample" do
    oban = sampler(read: blocking_read(self()))
    assert_receive {:reading, reader}
    unavailable!(scrape(oban))
    send(reader, {:result, {:ok, sample(0)}})
    eventually(fn -> ObanSampler.snapshot(oban) == {:ok, sample(0)} end)
    assert scrape(oban) =~ "anime_oban_snapshot_available 1\n"
  end

  test "thirty second boundary and backwards clock hide stale rows, then recover" do
    clock = start_supervised!({Agent, fn -> 0 end})
    oban = sampler(read: fn -> {:ok, sample()} end, clock: fn -> Agent.get(clock, & &1) end)
    eventually(fn -> ObanSampler.snapshot(oban) != :unavailable end)
    Agent.update(clock, fn _ -> 29_999 end)
    assert scrape(oban) =~ "anime_oban_snapshot_available 1\n"

    for time <- [30_000, -1] do
      Agent.update(clock, fn _ -> time end)
      unavailable!(scrape(oban))
    end

    ObanSampler.poll(oban)
    eventually(fn -> ObanSampler.snapshot(oban) != :unavailable end)
    assert scrape(oban) =~ "anime_oban_snapshot_available 1\n"
  end

  test "SQL runs only during sampling, never on a scrape; no overlap or late reply is accepted" do
    owner = self()

    oban =
      sampler(
        read: fn ->
          send(owner, :read)
          ObanSampler.read()
        end
      )

    assert_receive :read
    eventually(fn -> ObanSampler.snapshot(oban) != :unavailable end)
    ref = observe_sql()

    try do
      for _ <- 1..10, do: assert(scrape(oban) =~ "anime_oban_snapshot_available 1\n")
      refute_receive {:query, _}, 20
      refute_receive :read, 20
    after
      :telemetry.detach(ref)
    end
  end

  test "timed out reader is killed, polls do not overlap and late messages cannot overwrite recovery" do
    oban = sampler(read: blocking_read(self()), timeout: 120)
    assert_receive {:reading, reader}
    ref = Process.monitor(reader)
    for _ <- 1..10, do: ObanSampler.poll(oban)
    refute_receive {:reading, _}, 20
    assert_receive {:DOWN, ^ref, :process, ^reader, :killed}, 1_000
    unavailable!(scrape(oban))
    ObanSampler.poll(oban)
    assert_receive {:reading, next}
    send(oban, {:sample, make_ref(), {:ok, sample(999)}, 0})
    send(next, {:result, {:ok, sample()}})
    eventually(fn -> ObanSampler.snapshot(oban) == {:ok, sample()} end)
  end

  test "normal stop kills unfinished SQL reader without leaking its result" do
    oban = sampler(read: blocking_read(self()))
    assert_receive {:reading, reader}
    ref = Process.monitor(reader)
    stop_supervised!(ObanSampler)
    assert_receive {:DOWN, ^ref, :process, ^reader, :killed}
    unavailable!(scrape(oban))
  end

  test "hard-killed sampler restarts cold and terminates its unfinished reader" do
    name = Anime.Metrics.RestartObanSampler
    oban = sampler(name: name, read: blocking_read(self()))
    assert_receive {:reading, reader}
    ref = Process.monitor(reader)
    Process.exit(oban, :kill)
    assert_receive {:DOWN, ^ref, :process, ^reader, :killed}
    assert_receive {:reading, next}, 1_000
    unavailable!(scrape(name))
    send(next, {:result, {:ok, sample()}})
    eventually(fn -> ObanSampler.snapshot(name) == {:ok, sample()} end)
  end

  test "failed aggregate read clears old jobs but preserves a healthy cache and versions" do
    Metrics.publish_oban_snapshot({:ok, sample()})
    Metrics.publish_runtime_versions()

    cache =
      start_supervised!(
        {CacheSampler,
         name: nil,
         enabled: true,
         interval: 60_000,
         read: fn -> {:ok, %{anime_role_permissions: %{entries: 3, memory_bytes: 256}}} end}
      )

    eventually(fn -> CacheSampler.snapshot(cache) != :unavailable end)

    body =
      Exporter.scrape(
        :missing_pool,
        :missing_vm,
        :missing_scheduler,
        cache,
        :missing_oban,
        @reporter
      )

    unavailable!(body)
    assert body =~ "anime_cache_entries"
    assert body =~ "anime_runtime_info"
  end

  test "suspended sampler eventually degrades independently without hiding the other families" do
    Metrics.publish_runtime_versions()
    oban = sampler(read: fn -> {:ok, sample()} end)
    eventually(fn -> ObanSampler.snapshot(oban) != :unavailable end)
    :sys.suspend(oban)

    try do
      body = scrape(oban)
      unavailable!(body)
      assert body =~ "anime_runtime_info"
    after
      :sys.resume(oban)
    end
  end

  test "reporter restart restores fresh values without another query" do
    owner = self()

    oban =
      sampler(
        read: fn ->
          send(owner, :read)
          {:ok, sample()}
        end
      )

    assert_receive :read
    eventually(fn -> ObanSampler.snapshot(oban) != :unavailable end)
    stop_supervised!(@reporter)
    assert_raise RuntimeError, "Metrics unavailable", fn -> scrape(oban) end
    reporter()
    assert scrape(oban) =~ "anime_oban_snapshot_available 1\n"
    refute_receive :read, 20
  end

  test "real HTTP emits a real database sample without workers, IDs or payloads" do
    job("mailers", "available", -60)
    oban = sampler(name: ObanSampler, read: &ObanSampler.read/0)
    eventually(fn -> ObanSampler.snapshot(oban) != :unavailable end)
    pid = start_supervised!(Exporter.listener_spec(0))
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    result = Req.get!("http://127.0.0.1:#{port}/metrics", retry: false)
    assert result.status == 200
    assert result.body =~ ~s(anime_oban_jobs{queue="mailers",state="available"} 1\n)
    refute result.body =~ @secret
    refute result.body =~ "job_id"
  end

  defp job(queue, state, offset) do
    Repo.insert!(%Oban.Job{
      queue: queue,
      state: state,
      worker: "Anime.Workers.Mail",
      args: %{"secret" => @secret},
      meta: %{"request_id" => @secret},
      errors: [%{"error" => @secret}],
      tags: [@secret],
      priority: 0,
      scheduled_at: DateTime.add(DateTime.utc_now(), offset),
      inserted_at: DateTime.utc_now()
    })
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds)
  def notice(_, _, meta, owner), do: send(owner, {:query, meta.query})

  defp observe_sql do
    ref = make_ref()
    :telemetry.attach(ref, [:anime, :repo, :query], &__MODULE__.notice/4, self())
    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  defp sample(n \\ 4) do
    %{
      counts:
        Map.new(for(q <- Metrics.oban_queues(), s <- Metrics.oban_states(), do: {{q, s}, n})),
      ages: Map.new(Metrics.oban_queues(), &{&1, n * 10})
    }
  end

  defp reporter,
    do:
      start_supervised!(
        {Core, name: @reporter, metrics: Metrics.definitions(), start_async: false}
      )

  defp emit(key, value, tags),
    do: :telemetry.execute([:anime, :metrics, key], %{value: value}, tags)

  defp sampler(opts),
    do:
      start_supervised!(
        {ObanSampler, Keyword.merge([name: nil, enabled: true, interval: 60_000], opts)}
      )

  defp scrape(oban),
    do:
      Exporter.scrape(
        :missing_pool,
        :missing_vm,
        :missing_scheduler,
        :missing_cache,
        oban,
        @reporter
      )

  defp blocking_read(owner),
    do: fn ->
      send(owner, {:reading, self()})
      receive do: ({:result, result} -> result)
    end

  defp unavailable!(body) do
    assert body =~ "anime_oban_snapshot_available 0\n"
    refute body =~ "anime_oban_jobs"
    refute body =~ "anime_oban_oldest_available_age_seconds"
    refute body =~ @secret
    assert length(Regex.scan(~r/^anime_oban_snapshot_available /m, body)) == 1
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
