defmodule Anime.ShutdownJobsTest do
  use Anime.DataCase
  @name __MODULE__.Instance
  @owner {__MODULE__, :owner}
  @moduletag :capture_log

  defmodule HeldJob do
    use Oban.Worker, queue: :maintenance

    def perform(job) do
      send(:persistent_term.get({Anime.ShutdownJobsTest, :owner}), {:started, job.id, self()})

      receive do
        :finish -> :ok
      after
        5000 -> {:error, :fixture_timeout}
      end
    end
  end

  test "start of drain stops fetches without DB calls and lets the active job finish" do
    :persistent_term.put(@owner, self())
    on_exit(fn -> :persistent_term.erase(@owner) end)
    first = HeldJob.new(%{}) |> Oban.insert!()
    second = HeldJob.new(%{}) |> Oban.insert!()

    start_supervised!(
      {Oban,
       name: @name,
       repo: Repo,
       queues: [maintenance: 1],
       testing: :disabled,
       peer: Oban.Peers.Isolated,
       notifier: Oban.Notifiers.Isolated,
       stager: false,
       lifeline: false,
       plugins: []}
    )

    producer = Oban.Registry.whereis(@name, {:producer, "maintenance"})
    _ = Oban.Queues.Producer.check(producer)
    :ok = Oban.Notifier.notify(@name, :insert, %{queue: "maintenance"})
    first_id = first.id
    assert_receive {:started, ^first_id, worker}, 2000
    observer = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(observer, [:anime, :repo, :query], &__MODULE__.query/4, self())

    try do
      assert :ok = Anime.Shutdown.quiesce_jobs(@name)
      refute_received :database_query
    after
      :telemetry.detach(observer)
    end

    assert Process.alive?(worker)
    send(worker, :finish)
    await_completed(first.id, 200)
    :ok = Oban.Notifier.notify(@name, :insert, %{queue: "maintenance"})
    refute_receive {:started, _, _}, 100
    assert Repo.get!(Oban.Job, second.id).state == "available"
    assert :ok = Anime.Shutdown.quiesce_jobs(@name)
    :ok = Oban.Queues.stop_queue(Oban.config(@name), "maintenance")
  end

  def query(_, _, _, owner), do: send(owner, :database_query)

  defp await_completed(id, remaining) do
    if Repo.get!(Oban.Job, id).state != "completed" do
      assert remaining > 0, "running job did not finish"
      Process.sleep(10)
      await_completed(id, remaining - 1)
    end
  end
end
