defmodule Anime.PostgresMetricsDatabaseTest do
  use ExUnit.Case, async: false
  alias Anime.Repo
  alias Anime.Metrics.{PostgresSampler, DatabaseSizeSampler}

  setup do
    reader = ordinary_repo(:reader)
    previous = Repo.put_dynamic_repo(reader)
    Repo.query!("SELECT 1")
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    %{reader: reader}
  end

  test "busy ordinary pool skips both measurements and recovers", %{reader: reader} do
    with_held(reader, :checkout, fn ->
      started = System.monotonic_time(:millisecond)
      assert PostgresSampler.read() == :unavailable
      assert DatabaseSizeSampler.read() == :unavailable
      assert System.monotonic_time(:millisecond) - started < 700
    end)

    assert {:ok, _} = PostgresSampler.read()
    assert {:ok, _} = DatabaseSizeSampler.read()
  end

  test "locked real migration ledger hits its deadline without blocking size or changing schema" do
    locker = ordinary_repo(:locker)

    with_held(locker, :table_lock, fn ->
      started = System.monotonic_time(:millisecond)
      assert PostgresSampler.read() == :unavailable
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 650
      assert elapsed < 3000
      eventually(fn -> match?({:ok, _}, DatabaseSizeSampler.read()) end)
    end)

    eventually(fn -> match?({:ok, %{pending: 0}}, PostgresSampler.read()) end)
  end

  test "missing ledger is unavailable and monitoring never creates it" do
    # An ordinary connection has no sandbox savepoints around each query.
    # Only the connection-local search path changes; no tables are removed.
    Repo.checkout(fn ->
      Repo.query!("SET search_path = pg_catalog")

      try do
        assert PostgresSampler.read() == :unavailable
        assert [[nil]] == Repo.query!("SELECT to_regclass('pg_catalog.schema_migrations')").rows
        assert {:ok, _} = DatabaseSizeSampler.read()
      after
        Repo.query!("RESET search_path")
      end
    end)

    assert {:ok, %{pending: 0}} = PostgresSampler.read()
  end

  test "stopped ordinary repo returns unavailability without fake version size or migration zero",
       %{reader: reader} do
    stop_supervised!(:reader)
    refute Process.alive?(reader)
    assert PostgresSampler.read() == :unavailable
    assert DatabaseSizeSampler.read() == :unavailable
  end

  defp ordinary_repo(id) do
    start_supervised!(
      Supervisor.child_spec(
        {Repo,
         name: nil,
         pool: DBConnection.ConnectionPool,
         pool_size: 1,
         queue_target: 1,
         queue_interval: 10,
         timeout: 5000},
        id: id
      )
    )
  end

  defp with_held(pool, kind, fun) do
    owner = self()

    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(pool)

        wait = fn ->
          send(owner, :held)

          receive do
            :release -> {:ok, :released}
          after
            10_000 -> {:error, :test_timeout}
          end
        end

        case kind do
          :checkout ->
            Repo.checkout(wait)

          :table_lock ->
            Repo.transact(fn ->
              Repo.query!("LOCK TABLE schema_migrations IN ACCESS EXCLUSIVE MODE")
              wait.()
            end)
        end
      end)

    try do
      assert_receive :held, 2000
      fun.()
    after
      send(task.pid, :release)
      Task.await(task, 2000)
    end
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(10)
            eventually(fun, attempts - 1)
          )
      )
end
