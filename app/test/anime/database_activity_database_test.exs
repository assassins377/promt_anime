defmodule Anime.DatabaseActivityDatabaseTest do
  use ExUnit.Case, async: false
  alias Anime.Repo
  alias Anime.Metrics.{DatabaseActivitySampler, Exporter, Sampler}
  @secret "PRIVATE-ACTIVITY-QUERY"

  setup do
    reader = ordinary_repo(:reader)
    previous = Repo.put_dynamic_repo(reader)
    assert [["anime_test"]] == Repo.query!("SELECT current_database()").rows
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    %{reader: reader}
  end

  test "sampling connection and ordinary idle clients are excluded; empty is a real zero" do
    pool = ordinary_repo(:idle)

    with_session(pool, fn session ->
      assert {:ok, _} = sql(session, "SELECT 1")
      eventually(fn -> DatabaseActivitySampler.read() == empty() end)
    end)
  end

  test "real normal and aborted idle transactions are both counted without exporting query text" do
    pool = ordinary_repo(:transaction)

    with_session(pool, fn session ->
      assert {:ok, _} = sql(session, "BEGIN")
      assert {:ok, _} = sql(session, "SELECT '#{@secret}'")
      eventually(fn -> match?({:ok, %{active: 0, idle: 1}}, DatabaseActivitySampler.read()) end)
      assert {:error, %Postgrex.Error{}} = sql(session, "SELECT 1/0")
      eventually(fn -> match?({:ok, %{active: 0, idle: 1}}, DatabaseActivitySampler.read()) end)
      result = DatabaseActivitySampler.read()
      refute inspect(result) =~ @secret
      # PostgreSQL clears xact_start after abort: count the aborted session,
      # but never substitute last-query time as the transaction's start.
      [[nil]] =
        Repo.query!("SELECT xact_start FROM pg_stat_activity WHERE pid = $1", [session.pid]).rows

      assert {:ok, %{oldest_seconds: 0}} = result
      assert {:ok, _} = sql(session, "ROLLBACK")
      eventually(fn -> DatabaseActivitySampler.read() == empty() end)
    end)
  end

  test "active includes a real query waiting on a lock, not just CPU-running work" do
    locker = ordinary_repo(:locker)
    waiter = ordinary_repo(:waiter)

    with_session(locker, fn lock ->
      assert {:ok, _} = sql(lock, "SELECT pg_advisory_lock(9010042)")

      with_session(waiter, fn wait ->
        ref = request(wait, "SELECT pg_advisory_lock(9010042)")

        try do
          eventually(fn ->
            match?({:ok, %{active: 1, idle: 0}}, DatabaseActivitySampler.read())
          end)

          assert [["active", "Lock"]] ==
                   Repo.query!(
                     "SELECT state, wait_event_type FROM pg_stat_activity WHERE pid=$1",
                     [wait.pid]
                   ).rows
        after
          sql(lock, "SELECT pg_advisory_unlock(9010042)")
        end

        assert_receive {^ref, {:ok, _}}, 3000
        assert {:ok, _} = sql(wait, "SELECT pg_advisory_unlock(9010042)")
      end)
    end)
  end

  test "oldest age follows transaction start, can grow while idle, and drops after commit" do
    older = ordinary_repo(:older)
    newer = ordinary_repo(:newer)

    with_session(older, fn first ->
      assert {:ok, _} = sql(first, "BEGIN")
      assert {:ok, _} = sql(first, "SELECT 1")

      eventually(
        fn ->
          case DatabaseActivitySampler.read() do
            {:ok, %{oldest_seconds: age}} -> age >= 2
            _ -> false
          end
        end,
        400
      )

      with_session(newer, fn second ->
        assert {:ok, _} = sql(second, "BEGIN")
        assert {:ok, _} = sql(second, "SELECT 1")
        eventually(fn -> match?({:ok, %{idle: 2}}, DatabaseActivitySampler.read()) end)
        assert {:ok, %{oldest_seconds: age}} = DatabaseActivitySampler.read()
        assert age >= 2
        assert {:ok, _} = sql(first, "COMMIT")
        eventually(fn -> match?({:ok, %{idle: 1}}, DatabaseActivitySampler.read()) end)
        assert {:ok, %{oldest_seconds: youngest}} = DatabaseActivitySampler.read()

        [[expected]] =
          Repo.query!(
            "SELECT floor(extract(epoch FROM (statement_timestamp()-xact_start)))::bigint FROM pg_stat_activity WHERE pid=$1",
            [second.pid]
          ).rows

        assert abs(youngest - expected) <= 1
      end)
    end)

    eventually(fn -> DatabaseActivitySampler.read() == empty() end)
  end

  test "sessions in another database of this isolated cluster do not contribute" do
    pool = ordinary_repo(:other_db, database: "postgres")

    with_session(pool, fn session ->
      assert {:ok, %{rows: [["postgres"]]}} = sql(session, "SELECT current_database()")
      assert {:ok, _} = sql(session, "BEGIN")
      assert {:ok, _} = sql(session, "SELECT 1")
      assert DatabaseActivitySampler.read() == empty()
    end)
  end

  test "restricted role is unavailable, pg_read_all_stats role works, no grants are performed" do
    Repo.checkout(fn ->
      try do
        Repo.query!("SET ROLE pg_database_owner")
        assert DatabaseActivitySampler.read() == :unavailable
        Repo.query!("RESET ROLE")
        Repo.query!("SET ROLE pg_read_all_stats")
        assert {:ok, _} = DatabaseActivitySampler.read()
      after
        Repo.query!("RESET ROLE")
      end
    end)

    assert {:ok, _} = DatabaseActivitySampler.read()
  end

  test "disabled activity tracking in another client invalidates the whole snapshot" do
    pool = ordinary_repo(:hidden)

    with_session(pool, fn session ->
      assert {:ok, _} = sql(session, "SET track_activities = off")

      try do
        eventually(fn -> DatabaseActivitySampler.read() == :unavailable end)
      after
        sql(session, "SET track_activities = on")
      end

      eventually(fn -> match?({:ok, _}, DatabaseActivitySampler.read()) end)
    end)
  end

  test "reader with tracking off is unavailable and normal service resumes after reset" do
    Repo.checkout(fn ->
      Repo.query!("SET track_activities = off")

      try do
        assert DatabaseActivitySampler.read() == :unavailable
      after
        Repo.query!("RESET track_activities")
      end
    end)

    assert {:ok, _} = DatabaseActivitySampler.read()
  end

  test "read-only connection works and timezone cannot change elapsed age" do
    Repo.checkout(fn ->
      Repo.query!("SET default_transaction_read_only = on")
      Repo.query!("SET TimeZone = 'Asia/Yakutsk'")

      try do
        assert DatabaseActivitySampler.read() == empty()
      after
        Repo.query!("RESET default_transaction_read_only")
        Repo.query!("RESET TimeZone")
      end
    end)
  end

  test "explicit transactions are skipped instead of repeatedly reporting a cached snapshot" do
    assert {:ok, :unavailable} = Repo.transact(fn -> {:ok, DatabaseActivitySampler.read()} end)
    assert {:ok, _} = DatabaseActivitySampler.read()
  end

  test "occupied ordinary pool is skipped promptly without queuing a monitoring query", %{
    reader: reader
  } do
    with_session(reader, fn _ ->
      started = System.monotonic_time(:millisecond)
      assert DatabaseActivitySampler.read() == :unavailable
      assert System.monotonic_time(:millisecond) - started < 700
    end)

    assert {:ok, _} = DatabaseActivitySampler.read()
  end

  defmodule SlowRepo do
    def in_transaction?, do: Anime.Repo.in_transaction?()

    def query(sql, params, opts),
      do:
        Anime.Repo.query(
          "SELECT metrics.* FROM (#{sql}) AS metrics CROSS JOIN pg_sleep(2)",
          params,
          opts
        )
  end

  test "real delayed SELECT hits timeout and the reader connection recovers" do
    started = System.monotonic_time(:millisecond)
    assert DatabaseActivitySampler.read(SlowRepo) == :unavailable
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 650 and elapsed < 3000
    eventually(fn -> match?({:ok, _}, DatabaseActivitySampler.read()) end)
  end

  test "stopped repo returns unavailability instead of three fake zero readings" do
    stop_supervised!(:reader)
    assert DatabaseActivitySampler.read() == :unavailable
  end

  test "separate HTTP listener returns a real idle transaction without IDs or private SQL", %{
    reader: reader
  } do
    pool = ordinary_repo(:transaction)

    with_session(pool, fn session ->
      assert {:ok, _} = sql(session, "BEGIN")
      assert {:ok, _} = sql(session, "SELECT '#{@secret}'")

      sampler =
        start_supervised!(
          {DatabaseActivitySampler,
           enabled: true,
           name: DatabaseActivitySampler,
           read: fn ->
             Repo.put_dynamic_repo(reader)
             DatabaseActivitySampler.read()
           end}
        )

      eventually(fn -> match?({:ok, %{idle: 1}}, Sampler.snapshot(sampler)) end)
      listener = start_supervised!(Exporter.listener_spec(0))
      {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
      response = Req.get!("http://127.0.0.1:#{port}/metrics", retry: false)
      assert response.status == 200
      assert response.body =~ "anime_db_idle_in_transaction_connections 1\n"
      assert response.body =~ "anime_db_activity_available 1\n"
      refute response.body =~ @secret
      refute response.body =~ "anime_test"
      refute response.body =~ "backend_pid"
    end)
  end

  defp ordinary_repo(id, overrides \\ []) do
    options =
      Repo.config()
      |> Keyword.merge(
        url: nil,
        name: nil,
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        queue_target: 1,
        queue_interval: 10,
        timeout: 5000
      )
      |> Keyword.merge(overrides)

    start_supervised!(Supervisor.child_spec({Repo, options}, id: id))
  end

  defp with_session(pool, fun) do
    owner = self()

    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(pool)

        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(owner, {:session_ready, self(), pid})

          try do
            serve()
          after
            Repo.query("ROLLBACK", [], log: false)
          end
        end)
      end)

    try do
      assert_receive {:session_ready, worker, pid}, 2000
      fun.(%{worker: worker, pid: pid})
    after
      send(task.pid, :release)
      Task.await(task, 5000)
    end
  end

  defp serve do
    receive do
      {:sql, owner, ref, query} ->
        result = Repo.query(query, [], timeout: 5000, log: false)
        send(owner, {ref, result})
        serve()

      :release ->
        :ok
    after
      15_000 -> :expired
    end
  end

  defp request(session, query) do
    ref = make_ref()
    send(session.worker, {:sql, self(), ref, query})
    ref
  end

  defp sql(session, query) do
    ref = request(session, query)

    receive do
      {^ref, result} -> result
    after
      6000 -> flunk("test session did not respond")
    end
  end

  defp empty, do: {:ok, %{active: 0, idle: 0, oldest_seconds: 0}}
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
