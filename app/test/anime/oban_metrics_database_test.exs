defmodule Anime.ObanMetricsDatabaseTest do
  use ExUnit.Case, async: false
  alias Anime.Repo
  alias Anime.Metrics.ObanSampler

  setup do
    reader = ordinary_repo(:reader)
    previous = Repo.put_dynamic_repo(reader)
    Repo.query!("SELECT 1")
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    %{reader: reader}
  end

  test "busy ordinary pool is skipped without enqueueing monitoring behind application work", %{
    reader: reader
  } do
    with_held(reader, :checkout, fn ->
      started = System.monotonic_time(:millisecond)
      assert ObanSampler.read() == :unavailable
      assert System.monotonic_time(:millisecond) - started < 700
    end)

    assert {:ok, _} = ObanSampler.read()
  end

  test "real blocked aggregate SELECT times out, releases its connection and recovers" do
    locker = ordinary_repo(:locker)

    with_held(locker, :table_lock, fn ->
      started = System.monotonic_time(:millisecond)
      assert ObanSampler.read() == :unavailable
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 650
      assert elapsed < 3_000
    end)

    eventually(fn -> match?({:ok, _}, ObanSampler.read()) end)
    assert %{rows: [[1]]} = Repo.query!("SELECT 1")
  end

  test "stopped real repo returns only unavailability without a partial count", %{reader: reader} do
    stop_supervised!(:reader)
    refute Process.alive?(reader)
    assert ObanSampler.read() == :unavailable
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
         timeout: 5_000},
        id: id
      )
    )
  end

  defp with_held(pool, kind, fun) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(pool)

        wait = fn ->
          send(parent, :held)

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
              Repo.query!("LOCK TABLE public.oban_jobs IN ACCESS EXCLUSIVE MODE")
              wait.()
            end)
        end
      end)

    try do
      assert_receive :held, 2_000
      fun.()
    after
      send(task.pid, :release)
      Task.await(task, 2_000)
    end
  end

  defp eventually(fun, attempts \\ 100)
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
