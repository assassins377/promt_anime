defmodule Anime.CheckoutMetricsTest do
  use ExUnit.Case, async: false
  import Anime.MetricsProbe
  alias Anime.Repo
  alias Anime.Metrics.Context
  @secret "PRIVATE-CHECKOUT-SENTINEL"

  setup do
    pool = ordinary_repo(:primary)
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(pool)
    Repo.query!("SELECT 1")
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    %{pool: pool}
  end

  test "real checkout queue_timeout is counted once without any query event", %{pool: pool} do
    with_held(pool, fn ->
      {error, records} =
        capture(fn ->
          assert_raise DBConnection.ConnectionError, fn ->
            Repo.checkout(fn -> flunk("callback must not run") end, timeout: 2_000)
          end
        end)

      assert error.reason == :queue_timeout
      assert rows(records, :db_checkout_timeout) == [{%{count: 1}, %{source: "other"}}]
      assert rows(records, :db_query) == []
      assert rows(records, :db_timing) == []
      safe!(records)
      assert_no_markers()
    end)

    {result, records} = capture(fn -> Repo.checkout(fn -> :recovered end) end)
    assert result == :recovered
    assert rows(records, :db_checkout_timeout) == []
  end

  test "server origin wins over all caller options and no error details enter Prometheus", %{
    pool: pool
  } do
    reporter = Anime.Metrics.CheckoutTestReporter

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: reporter, metrics: Anime.Metrics.definitions(), start_async: false}
    )

    with_held(pool, fn ->
      for source <- [:web, :live_view, :oban, :other] do
        {_, records} =
          capture(fn ->
            Context.with_source(source, fn ->
              assert_raise DBConnection.ConnectionError, fn ->
                Repo.checkout(fn -> :not_called end,
                  timeout: 2_000,
                  log: false,
                  telemetry_event: false,
                  source: @secret,
                  telemetry_options: [source: @secret, password: @secret]
                )
              end
            end)
          end)

        assert rows(safe!(records), :db_checkout_timeout) ==
                 [{%{count: 1}, %{source: Atom.to_string(source)}}]
      end
    end)

    body = TelemetryMetricsPrometheus.Core.scrape(reporter)

    for source <- ~w(web live_view oban other) do
      assert body =~ ~s(anime_db_checkout_timeout_total{source="#{source}"} 1\n)
    end

    for forbidden <- [@secret, "password", "opts", "params", "SELECT", "queue_target", "#PID"],
        do: refute(body =~ forbidden)

    assert Context.current() == :other
    assert_no_markers()
  end

  test "callback exception with the same reason is not an acquisition timeout" do
    exception = %DBConnection.ConnectionError{reason: :queue_timeout, message: @secret}

    {error, records} =
      capture(fn ->
        assert_raise DBConnection.ConnectionError, @secret, fn ->
          Repo.checkout(fn -> raise exception end)
        end
      end)

    assert error == exception
    assert rows(records, :db_checkout_timeout) == []
    safe!(records)
    assert_no_markers()
  end

  test "successful and nested checkout preserve values, checked_out and leave no markers" do
    refute Repo.checked_out?()

    {result, records} =
      capture(fn ->
        Repo.checkout(fn ->
          assert Repo.checked_out?()

          Repo.checkout(fn ->
            assert Repo.checked_out?()
            {:unchanged, @secret}
          end)
        end)
      end)

    assert result == {:unchanged, @secret}
    assert rows(records, :db_checkout_timeout) == []
    assert rows(records, :db_query) == []
    refute Repo.checked_out?()
    assert_no_markers()
  end

  test "callback throws, exits and ordinary errors are preserved and cleanup always runs" do
    {_, records} =
      capture(fn ->
        assert catch_throw(Repo.checkout(fn -> throw({:reason, @secret}) end)) ==
                 {:reason, @secret}

        assert catch_exit(Repo.checkout(fn -> exit(@secret) end)) == @secret
        assert_raise RuntimeError, @secret, fn -> Repo.checkout(fn -> raise @secret end) end

        assert_raise DBConnection.ConnectionError, @secret, fn ->
          Repo.checkout(fn ->
            raise DBConnection.ConnectionError, reason: :error, message: @secret
          end)
        end
      end)

    assert rows(records, :db_checkout_timeout) == []
    assert_no_markers()
    assert Repo.checkout(fn -> :ok end) == :ok
  end

  test "callback exception keeps its original stack location" do
    try do
      Repo.checkout(fn -> callback_failure() end)
      flunk("expected exception")
    rescue
      error in RuntimeError ->
        assert error.message == @secret
        assert [{__MODULE__, :callback_failure, 0, _} | _] = __STACKTRACE__
    end

    assert_no_markers()
  end

  test "nested failure against another dynamic pool counts only the inner acquisition" do
    blocked = ordinary_repo(:secondary)

    with_held(blocked, fn ->
      {error, records} =
        capture(fn ->
          assert_raise DBConnection.ConnectionError, fn ->
            Repo.checkout(fn ->
              previous = Repo.put_dynamic_repo(blocked)

              try do
                Repo.checkout(fn -> :not_called end, timeout: 2_000)
              after
                Repo.put_dynamic_repo(previous)
              end
            end)
          end
        end)

      assert error.reason == :queue_timeout
      assert rows(records, :db_checkout_timeout) == [{%{count: 1}, %{source: "other"}}]
      assert rows(records, :db_query) == []
      assert_no_markers()
    end)
  end

  test "a query timeout inside checkout is still counted once by its query event" do
    blocked = ordinary_repo(:secondary)

    with_held(blocked, fn ->
      {error, records} =
        capture(fn ->
          assert_raise DBConnection.ConnectionError, fn ->
            Repo.checkout(fn ->
              previous = Repo.put_dynamic_repo(blocked)

              try do
                Repo.query!("SELECT $1::text", [@secret], timeout: 2_000)
              after
                Repo.put_dynamic_repo(previous)
              end
            end)
          end
        end)

      assert error.reason == :queue_timeout
      assert rows(safe!(records), :db_checkout_timeout) == [{%{count: 1}, %{source: "other"}}]
      assert rows(records, :db_query) == [{%{count: 1}, %{source: "other", outcome: "error"}}]
      assert_no_markers()
    end)
  end

  test "a callback can catch a nested timeout and continue on its own connection" do
    blocked = ordinary_repo(:secondary)

    with_held(blocked, fn ->
      {result, records} =
        capture(fn ->
          Repo.checkout(fn ->
            previous = Repo.put_dynamic_repo(blocked)

            try do
              assert_raise DBConnection.ConnectionError, fn ->
                Repo.checkout(fn -> :not_called end, timeout: 2_000)
              end
            after
              Repo.put_dynamic_repo(previous)
            end

            Repo.query!("SELECT 42").rows
          end)
        end)

      assert result == [[42]]
      assert length(rows(records, :db_checkout_timeout)) == 1
      assert rows(records, :db_query) == [{%{count: 1}, %{source: "other", outcome: "ok"}}]
      assert_no_markers()
    end)
  end

  test "global errors and another repo cannot impersonate the new projection" do
    {_, records} =
      capture(fn ->
        :telemetry.execute([:db_connection, :connection_error], %{count: 1}, %{
          error: %DBConnection.ConnectionError{reason: :queue_timeout, message: @secret},
          opts: [repo: Repo, source: :web, secret: @secret]
        })

        :telemetry.execute([:anime, :repo, :checkout_timeout], %{count: 1}, %{repo: OtherRepo})
        :telemetry.execute([:anime, :repo, :checkout_timeout], %{count: 2}, %{repo: Repo})
        :telemetry.execute([:anime, :repo, :checkout_timeout], %{}, %{repo: Repo})
      end)

    assert records == []
  end

  test "bare DBConnection calls remain outside our Repo measurement", %{pool: pool} do
    %{pid: connection_pool} = Ecto.Adapter.lookup_meta(pool)

    with_held(pool, fn ->
      {error, records} =
        capture(fn ->
          assert_raise DBConnection.ConnectionError, fn ->
            DBConnection.run(connection_pool, fn _ -> :not_called end, timeout: 2_000)
          end
        end)

      assert error.reason == :queue_timeout
      assert rows(records, :db_checkout_timeout) == []
      assert_no_markers()
    end)
  end

  test "generic acquisition failure without queueing is not a queue_timeout", %{pool: pool} do
    with_held(pool, fn ->
      {error, records} =
        capture(fn ->
          assert_raise DBConnection.ConnectionError, fn ->
            Repo.checkout(fn -> :not_called end, queue: false)
          end
        end)

      assert error.reason != :queue_timeout
      assert rows(records, :db_checkout_timeout) == []
      assert_no_markers()
    end)
  end

  test "checkout inside a transaction keeps transaction and after_commit semantics" do
    {result, records} =
      capture(fn ->
        Repo.transact(fn ->
          Repo.checkout(fn ->
            assert Repo.in_transaction?()
            Repo.after_commit(fn -> send(self(), :committed) end)
            {:ok, 42}
          end)
        end)
      end)

    assert result == {:ok, 42}
    assert_receive :committed
    assert rows(records, :db_checkout_timeout) == []
    refute Repo.checked_out?()
    assert_no_markers()
  end

  test "transaction acquisition timeout still comes from a query event only", %{pool: pool} do
    with_held(pool, fn ->
      {error, records} =
        capture(fn ->
          assert_raise DBConnection.ConnectionError, fn ->
            Repo.transact(fn -> flunk("transaction must not begin") end, timeout: 2_000)
          end
        end)

      assert error.reason == :queue_timeout
      assert rows(records, :db_checkout_timeout) == [{%{count: 1}, %{source: "other"}}]
      assert length(rows(records, :db_query)) == 1
      assert_no_markers()
    end)
  end

  test "a dead repo does not create a timeout or leak its invocation marker" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    previous = Repo.put_dynamic_repo(dead)

    try do
      {_, records} =
        capture(fn ->
          assert_raise ArgumentError, fn -> Repo.checkout(fn -> :not_called end) end
        end)

      assert rows(records, :db_checkout_timeout) == []
      assert_no_markers()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  test "parallel direct acquisition failures preserve each caller's origin exactly once", %{
    pool: pool
  } do
    with_held(pool, fn ->
      {_, records} =
        capture(fn ->
          for source <- [:web, :live_view, :oban, :other, :web, :live_view, :oban, :other] do
            Task.async(fn ->
              Repo.put_dynamic_repo(pool)

              Context.with_source(source, fn ->
                error =
                  assert_raise DBConnection.ConnectionError, fn ->
                    Repo.checkout(fn -> :not_called end, timeout: 2_000)
                  end

                assert error.reason == :queue_timeout
                assert_no_markers()
              end)
            end)
          end
          |> Task.await_many(5_000)
        end)

      counts =
        rows(safe!(records), :db_checkout_timeout)
        |> Enum.frequencies_by(fn {_, tags} -> tags.source end)

      assert counts == %{"web" => 2, "live_view" => 2, "oban" => 2, "other" => 2}
      assert rows(records, :db_query) == []
    end)
  end

  test "the new raw notification contains no original exception or caller options", %{pool: pool} do
    owner = self()
    ref = make_ref()
    event = [:anime, :repo, :checkout_timeout]
    :ok = :telemetry.attach(ref, event, &__MODULE__.raw_notification/4, {owner, ref})

    try do
      with_held(pool, fn ->
        assert_raise DBConnection.ConnectionError, fn ->
          Repo.checkout(fn -> :not_called end, timeout: 2_000, private: @secret)
        end

        assert_receive {^ref, ^event, %{count: 1} = measurements, %{repo: Repo} = metadata}
        assert measurements == %{count: 1}
        assert metadata == %{repo: Repo}
        refute_receive {^ref, _, _, _}, 10
      end)
    after
      :telemetry.detach(ref)
    end
  end

  def raw_notification(event, measurements, metadata, {owner, ref}),
    do: send(owner, {ref, event, measurements, metadata})

  defp callback_failure, do: raise(@secret)

  defp ordinary_repo(id) do
    start_supervised!(
      Supervisor.child_spec(
        {Repo,
         name: nil,
         pool: DBConnection.ConnectionPool,
         pool_size: 1,
         queue_target: 1,
         queue_interval: 10,
         timeout: 5_000},
        id: id
      )
    )
  end

  defp with_held(pool, fun) do
    owner = self()

    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(pool)

        Repo.checkout(fn ->
          send(owner, {:held, self()})

          receive do
            :release -> :ok
          after
            10_000 -> :ok
          end
        end)
      end)

    pid = task.pid

    try do
      assert_receive {:held, ^pid}, 2_000
      fun.()
    after
      send(pid, :release)
      Task.await(task, 2_000)
    end
  end

  defp assert_no_markers do
    refute Enum.any?(Process.get_keys(), fn
             {Repo, :checkout_acquired, _} -> true
             _ -> false
           end)
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
end
