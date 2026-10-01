defmodule Anime.Storage.ReadinessTest do
  use ExUnit.Case, async: true
  alias Anime.Storage.Readiness

  test "positive and negative results expire at ten seconds" do
    for value <- [true, false] do
      table = :ets.new(:probe, [:set, :public])
      parent = self()

      opts = [
        table: table,
        clock: fn -> 0 end,
        probe: fn ->
          send(parent, :called)
          value
        end
      ]

      assert Readiness.ready?(opts) == value
      assert_receive :called
      assert Readiness.ready?(Keyword.put(opts, :clock, fn -> 9999 end)) == value
      refute_receive :called
      assert Readiness.ready?(Keyword.put(opts, :clock, fn -> 10_000 end)) == value
      assert_receive :called
    end
  end

  test "exception and task exit fail closed and are cached" do
    for probe <- [fn -> raise "private details" end, fn -> exit(:failed) end] do
      table = :ets.new(:probe, [:set, :public])
      refute Readiness.ready?(table: table, probe: probe)
      refute Readiness.ready?(table: table, probe: fn -> true end)
    end
  end

  test "timeout terminates the worker" do
    table = :ets.new(:probe, [:set, :public])
    parent = self()

    refute Readiness.ready?(
             table: table,
             timeout: 20,
             probe: fn ->
               send(parent, {:worker, self()})
               Process.sleep(:infinity)
             end
           )

    assert_receive {:worker, pid}
    refute Process.alive?(pid)
  end

  test "missing owner and removed table fail closed" do
    table = :ets.new(:probe, [:set, :public])
    :ets.delete(table)
    refute Readiness.ready?(table: table)
    refute Readiness.ready?(table: :absent_readiness_test_table)
  end

  test "in-flight result is not inserted into replacement table" do
    table = :ets.new(:probe, [:set, :public])
    parent = self()

    caller =
      Task.async(fn ->
        Readiness.ready?(
          table: table,
          probe: fn ->
            send(parent, {:loading, self()})

            receive do
              :finish -> true
            end
          end
        )
      end)

    assert_receive {:loading, pid}
    :ets.delete(table)
    replacement = :ets.new(:probe, [:set, :public])
    send(pid, :finish)
    refute Task.await(caller)
    assert :ets.tab2list(replacement) == []
  end
end
