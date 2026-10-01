defmodule Anime.PostgresMetricsTest do
  use Anime.DataCase
  import Anime.MetricsProbe
  alias Anime.Metrics
  alias Anime.Metrics.{PostgresSampler, DatabaseSizeSampler, Sampler, Exporter}
  alias TelemetryMetricsPrometheus.Core
  @reporter Anime.Metrics.PostgresTestReporter
  @secret "PRIVATE-POSTGRES-SENTINEL"
  @moduletag :tmp_dir

  setup do
    reporter()
    :ok
  end

  test "real server version and release ledger are read without mutation" do
    before = Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows
    assert {:ok, value} = PostgresSampler.read()
    assert value.pending == 0

    assert value.version_number ==
             hd(hd(Repo.query!("SELECT current_setting('server_version_num')::integer").rows))

    assert Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows == before

    assert length(before) ==
             length(
               elem(PostgresSampler.migration_versions(Ecto.Migrator.migrations_path(Repo)), 1)
             )
  end

  test "both readers succeed inside a real read-only transaction" do
    # SET TRANSACTION must precede the first query; the DataCase has already
    # seeded, so mark subsequent commands read-only with SET LOCAL.
    Repo.query!("SET LOCAL transaction_read_only = on")
    assert {:ok, %{pending: 0}} = PostgresSampler.read()
    assert {:ok, %{bytes: bytes}} = DatabaseSizeSampler.read()
    assert bytes > 0
  end

  test "pending is the set difference for THIS release, not file count minus ledger count", %{
    tmp_dir: dir
  } do
    [[applied] | _] = Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows

    manifest(dir, [
      {applied, "applied"},
      {9_000_000_000_000_001, "new_one"},
      {9_000_000_000_000_002, "new_two"}
    ])

    assert {:ok, %{pending: 2}} = PostgresSampler.read(Repo, dir)
    # Contents raise if evaluated: monitoring must read names, not execute them.
    assert {:ok, [^applied, 9_000_000_000_000_001, 9_000_000_000_000_002]} =
             PostgresSampler.migration_versions(dir)
  end

  test "database size measures the connected database in bytes without reading names" do
    assert {:ok, %{bytes: bytes}} = DatabaseSizeSampler.read()
    [[expected]] = Repo.query!("SELECT pg_database_size(current_database())").rows
    assert bytes == expected
  end

  test "recursive release files and duplicate names or versions are checked", %{tmp_dir: dir} do
    nested = Path.join(dir, "nested")
    File.mkdir_p!(nested)
    manifest(dir, [{1, "one"}])
    manifest(nested, [{2, "two"}])
    assert PostgresSampler.migration_versions(dir) == {:ok, [1, 2]}
    manifest(nested, [{1, "different"}])
    assert PostgresSampler.migration_versions(dir) == :unavailable
    assert PostgresSampler.migration_versions(nested) == {:ok, [1, 2]}
    manifest(nested, [{3, "two"}])
    assert PostgresSampler.migration_versions(nested) == :unavailable
  end

  test "missing, empty, malformed and oversized migration inventories fail closed", %{
    tmp_dir: dir
  } do
    assert PostgresSampler.migration_versions(dir <> "/absent") == :unavailable
    assert PostgresSampler.migration_versions(dir) == :unavailable
    File.write!(Path.join(dir, "not_a_migration.exs"), "raise \"do not run\"")
    assert PostgresSampler.migration_versions(dir) == :unavailable
    assert PostgresSampler.read(Repo, dir) == :unavailable
    for n <- 1..4097, do: manifest(dir <> "/large", [{n, "m#{n}"}])
    assert PostgresSampler.migration_versions(dir <> "/large") == :unavailable
  end

  defmodule InspectRepo do
    def config, do: []

    def query(sql, params, opts) do
      send(self(), {:query, sql, params, opts})
      if params == [], do: {:ok, %{rows: [[1024]]}}, else: {:ok, %{rows: [[180_006, 1]]}}
    end
  end

  defmodule ErrorRepo do
    def config, do: []
    def query(_, _, _), do: raise("PRIVATE-POSTGRES-SENTINEL")
  end

  defmodule ExitRepo do
    def config, do: []
    def query(_, _, _), do: exit("PRIVATE-POSTGRES-SENTINEL")
  end

  defmodule OtherRepo do
    def config, do: [migration_source: "other"]
    def query(_, _, _), do: raise("must not query the wrong ledger")
  end

  test "read-only queries have a deadline, skip a busy pool and do not log", %{tmp_dir: dir} do
    manifest(dir, [{1, "one"}])
    assert {:ok, %{pending: 1}} = PostgresSampler.read(InspectRepo, dir)
    assert_receive {:query, sql, [[1]], opts}
    assert sql =~ "SELECT"
    refute sql =~ "CREATE"
    assert opts == [timeout: 750, queue: false, log: false]
    assert {:ok, %{bytes: 1024}} = DatabaseSizeSampler.read(InspectRepo)
    assert_receive {:query, "SELECT pg_database_size(current_database())", [], ^opts}
    assert PostgresSampler.read(OtherRepo, dir) == :unavailable
  end

  test "errors and exits discard raw terms, SQL, names and credentials", %{tmp_dir: dir} do
    manifest(dir, [{1, "one"}])

    for repo <- [ErrorRepo, ExitRepo] do
      assert PostgresSampler.read(repo, dir) == :unavailable
      assert DatabaseSizeSampler.read(repo) == :unavailable
    end
  end

  test "normalizers strip extras and reject incomplete or unsafe numeric values" do
    assert PostgresSampler.normalize({:ok, Map.put(metadata(), :secret, @secret)}) ==
             {:ok, metadata()}

    assert DatabaseSizeSampler.normalize({:ok, %{bytes: 0, name: @secret}}) == {:ok, %{bytes: 0}}

    for value <- [-1, 1.5, nil, @secret, Integer.pow(10, 100)] do
      assert PostgresSampler.normalize({:ok, %{metadata() | pending: value}}) == :unavailable

      assert PostgresSampler.normalize({:ok, %{metadata() | version_number: value}}) ==
               :unavailable

      assert DatabaseSizeSampler.normalize({:ok, %{bytes: value}}) == :unavailable
    end

    assert PostgresSampler.normalize({:ok, %{metadata() | pending: 4097}}) == :unavailable

    assert PostgresSampler.normalize({:ok, %{metadata() | version_number: 99_999}}) ==
             :unavailable

    assert PostgresSampler.normalize({:ok, %{}}) == :unavailable
  end

  test "safe Telemetry carries only numeric observations without labels" do
    {_, records} =
      capture(fn ->
        PostgresSampler.publish({:ok, metadata()})
        DatabaseSizeSampler.publish({:ok, %{bytes: 1024, database: @secret}})
      end)

    assert length(records) == 5

    assert Enum.all?(records, fn {event, %{value: value}, tags} ->
             is_integer(value) and tags == %{} and
               MapSet.member?(Metrics.allowed_tags()[event], tags)
           end)

    refute inspect(records) =~ @secret

    {_, bad} =
      capture(fn ->
        PostgresSampler.publish(:unavailable)
        DatabaseSizeSampler.publish(:unavailable)
      end)

    assert length(bad) == 2
    assert Enum.all?(bad, fn {_, m, t} -> m == %{value: 0} and t == %{} end)
  end

  test "new numeric definitions reject invalid direct observations and drop extra metadata" do
    for key <- [
          :postgres_version_number,
          :db_pending_migrations,
          :db_metadata_available,
          :db_size_bytes,
          :db_size_available
        ],
        value <- [-1, nil, @secret, 1.5, Integer.pow(10, 100)],
        do: :telemetry.execute([:anime, :metrics, key], %{value: value}, %{secret: @secret})

    assert Core.scrape(@reporter) == ""
    PostgresSampler.publish({:ok, metadata()})
    DatabaseSizeSampler.publish({:ok, %{bytes: 0}})
    assert Core.scrape(@reporter) =~ "anime_db_size_bytes 0\n"
    refute Core.scrape(@reporter) =~ @secret
  end

  test "hundreds of version changes replace one info row instead of accumulating label history" do
    assert Metrics.postgres_info_definition().max_series == 1

    body =
      Enum.reduce(180_000..180_600, "", fn version, body ->
        sample = {:ok, %{version_number: version, pending: 0}}
        PostgresSampler.publish(sample)
        result = Exporter.guard_postgres_snapshot(body, :metadata, sample)
        assert length(Regex.scan(~r/^anime_postgres_info\{/m, result)) == 1
        result
      end)

    assert body =~ ~s(anime_postgres_info{version="18.600"} 1\n)
    refute body =~ ~s(version="18.0")
    assert length(Regex.scan(~r/^anime_postgres_version_number /m, Core.scrape(@reporter))) == 1
    refute Core.scrape(@reporter) =~ "version="
  end

  test "metadata refreshes every 15s and size every 5min; scrape triggers no reads" do
    parent = self()

    pg =
      sampler(PostgresSampler,
        read: fn ->
          send(parent, :metadata_read)
          {:ok, metadata()}
        end
      )

    size =
      sampler(DatabaseSizeSampler,
        read: fn ->
          send(parent, :size_read)
          {:ok, %{bytes: 2048}}
        end
      )

    eventually(fn ->
      Sampler.snapshot(pg) != :unavailable and Sampler.snapshot(size) != :unavailable
    end)

    assert :sys.get_state(pg).interval == 15_000
    assert :sys.get_state(size).interval == 300_000
    assert :sys.get_state(size).max_age == 315_000
    assert_receive :metadata_read
    assert_receive :size_read

    for _ <- 1..3 do
      body = scrape(pg, size)
      assert body =~ ~s(anime_postgres_info{version="18.6"} 1\n)
      assert body =~ "anime_db_pending_migrations 0\n"
      assert body =~ "anime_db_size_bytes 2048\n"
    end

    refute_receive :metadata_read, 20
    refute_receive :size_read, 20
  end

  test "independent freshness hides old data exactly at the deadline without inventing zeros" do
    clock = start_supervised!({Agent, fn -> 0 end})
    options = [clock: fn -> Agent.get(clock, & &1) end]
    pg = sampler(PostgresSampler, [read: fn -> {:ok, metadata()} end] ++ options)
    size = sampler(DatabaseSizeSampler, [read: fn -> {:ok, %{bytes: 2048}} end] ++ options)

    eventually(fn ->
      Sampler.snapshot(pg) != :unavailable and Sampler.snapshot(size) != :unavailable
    end)

    Agent.update(clock, fn _ -> 30_000 end)
    body = scrape(pg, size)
    assert body =~ "anime_db_metadata_available 0\n"
    refute body =~ "anime_db_pending_migrations"
    refute body =~ "anime_postgres_info"
    assert body =~ "anime_db_size_bytes 2048\n"
    Agent.update(clock, fn _ -> 315_000 end)
    body = scrape(pg, size)
    assert body =~ "anime_db_size_available 0\n"
    refute body =~ "anime_db_size_bytes"
  end

  for source <- [PostgresSampler, DatabaseSizeSampler] do
    test "#{source} stops overlapping/late readers and recovers after timeout" do
      source = unquote(source)
      owner = self()
      sample = sample_for(source)

      pid =
        sampler(source,
          timeout: 80,
          read: fn ->
            send(owner, {:reading, self()})

            receive do
              :finish -> {:ok, sample}
            end
          end
        )

      assert_receive {:reading, worker}
      ref = Process.monitor(worker)
      Sampler.poll(pid)
      refute_receive {:reading, _}, 20
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 500
      assert Sampler.snapshot(pid) == :unavailable
      Sampler.poll(pid)
      assert_receive {:reading, next}
      send(next, :finish)
      eventually(fn -> Sampler.snapshot(pid) == {:ok, sample} end)
      Sampler.poll(pid)
      assert_receive {:reading, last}
      last_ref = Process.monitor(last)
      GenServer.stop(pid)
      assert_receive {:DOWN, ^last_ref, :process, ^last, :killed}, 500
    end
  end

  test "missing samplers mask only their own groups" do
    PostgresSampler.publish({:ok, metadata()})
    size = sampler(DatabaseSizeSampler, read: fn -> {:ok, %{bytes: 10}} end)
    eventually(fn -> Sampler.snapshot(size) != :unavailable end)
    Metrics.publish_runtime_versions()
    body = scrape(:missing_pg, size)
    assert body =~ "anime_runtime_info"
    assert body =~ "anime_db_size_bytes 10\n"
    assert body =~ "anime_db_metadata_available 0\n"
    refute body =~ "anime_db_pending_migrations"
    body = scrape(:missing_pg, :missing_size)
    assert body =~ "anime_db_size_available 0\n"
    refute body =~ "anime_db_size_bytes"
  end

  test "reporter restart restores current gauges and version without another read" do
    owner = self()

    pg =
      sampler(PostgresSampler,
        read: fn ->
          send(owner, :read)
          {:ok, metadata()}
        end
      )

    size =
      sampler(DatabaseSizeSampler,
        read: fn ->
          send(owner, :read)
          {:ok, %{bytes: 10}}
        end
      )

    eventually(fn ->
      Sampler.snapshot(pg) != :unavailable and Sampler.snapshot(size) != :unavailable
    end)

    assert_receive :read
    assert_receive :read
    stop_supervised!(@reporter)
    assert_raise RuntimeError, "Metrics unavailable", fn -> scrape(pg, size) end
    reporter()
    body = scrape(pg, size)
    assert body =~ "anime_db_size_bytes 10\n"
    assert body =~ ~s(anime_postgres_info{version="18.6"} 1\n)
    refute_receive :read, 20
  end

  test "dedicated HTTP listener exports real PostgreSQL values without database names" do
    pg = sampler(PostgresSampler, name: PostgresSampler, read: &PostgresSampler.read/0)
    eventually(fn -> Sampler.snapshot(pg) != :unavailable end)

    size =
      sampler(DatabaseSizeSampler, name: DatabaseSizeSampler, read: &DatabaseSizeSampler.read/0)

    eventually(fn ->
      Sampler.snapshot(pg) != :unavailable and Sampler.snapshot(size) != :unavailable
    end)

    pid = start_supervised!(Exporter.listener_spec(0))
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    result = Req.get!("http://127.0.0.1:#{port}/metrics", retry: false)
    assert result.status == 200
    assert result.body =~ "anime_postgres_info{version=\"18."
    assert result.body =~ "anime_db_pending_migrations 0\n"
    assert result.body =~ "anime_db_size_available 1\n"
    refute result.body =~ "anime_test"
    refute result.body =~ "schema_migrations"
    refute result.body =~ @secret
  end

  defp manifest(dir, entries) do
    File.mkdir_p!(dir)

    for {version, name} <- entries,
        do: File.write!(Path.join(dir, "#{version}_#{name}.exs"), "raise \"MUST NOT RUN\"")
  end

  defp metadata, do: %{version_number: 180_006, pending: 0}
  defp sample_for(PostgresSampler), do: metadata()
  defp sample_for(DatabaseSizeSampler), do: %{bytes: 1234}

  defp sampler(source, options),
    do: start_supervised!({source, Keyword.merge([name: nil, enabled: true], options)})

  defp reporter,
    do:
      start_supervised!(
        {Core, name: @reporter, metrics: Metrics.definitions(), start_async: false}
      )

  defp scrape(pg, size),
    do:
      Exporter.scrape(
        :missing_pool,
        :missing_vm,
        :missing_scheduler,
        :missing_cache,
        :missing_oban,
        pg,
        size,
        @reporter
      )

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
