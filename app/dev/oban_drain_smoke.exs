# Offline release eval against the runner's newly created database only.
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:oban)
{:ok, repo} = Anime.Repo.start_link()
true = Process.register(self(), :oban_drain_fixture)

defmodule ObanDrainFixtureWorker do
  use Oban.Worker, queue: :mailers

  def perform(%Oban.Job{args: %{"marker" => marker}}) do
    send(:oban_drain_fixture, {:working, marker, self()})

    receive do
      :finish -> :ok
    after
      120_000 -> {:error, :fixture_timeout}
    end
  end
end

60_000 = Application.fetch_env!(:anime, Oban)[:shutdown_grace_period]

{:ok, oban} =
  Oban.start_link(
    name: ObanDrainFixture,
    repo: Anime.Repo,
    queues: [mailers: 1],
    testing: :disabled,
    peer: Oban.Peers.Isolated,
    notifier: Oban.Notifiers.Isolated,
    stager: false,
    lifeline: false,
    plugins: [],
    shutdown_grace_period: 60_000
  )

Process.unlink(oban)

try do
  {:ok, first} = Oban.insert(ObanDrainFixture, ObanDrainFixtureWorker.new(%{marker: "first"}))

  worker =
    receive do
      {:working, "first", pid} -> pid
    after
      5000 -> raise "Worker didn't start"
    end

  {:ok, second} = Oban.insert(ObanDrainFixture, ObanDrainFixtureWorker.new(%{marker: "second"}))
  stop = Task.async(fn -> Supervisor.stop(oban, :normal, 65_000) end)

  paused =
    Enum.reduce_while(1..100, false, fn _, _ ->
      case Oban.check_queue(ObanDrainFixture, queue: :mailers) do
        %{paused: true} ->
          {:halt, true}

        _ ->
          Process.sleep(10)
          {:cont, false}
      end
    end)

  true = paused
  true = Process.alive?(worker)
  send(worker, :finish)
  :ok = Task.await(stop, 5_000)
  "completed" = Anime.Repo.get!(Oban.Job, first.id).state
  %{state: "available", attempt: 0} = Anime.Repo.get!(Oban.Job, second.id)

  receive do
    {:working, "second", _} -> raise "Queue fetched work during shutdown"
  after
    100 -> :ok
  end

  nil = Process.whereis(Anime.Supervisor)
  # Remove only our two fixture jobs before the later release boot; the worker
  # module exists solely in this offline eval, not in the packaged application.
  Anime.Repo.delete!(first)
  Anime.Repo.delete!(second)

  IO.puts(
    "PASS: Oban configured for 60s; running job completes, queued job stays available with attempt=0"
  )

  {:ok, hanging_oban} =
    Oban.start_link(
      name: ObanHungFixture,
      repo: Anime.Repo,
      queues: [mailers: 1],
      testing: :disabled,
      peer: Oban.Peers.Isolated,
      notifier: Oban.Notifiers.Isolated,
      stager: false,
      lifeline: false,
      plugins: [],
      shutdown_grace_period: 60_000
    )

  Process.unlink(hanging_oban)

  try do
    {:ok, hung} = Oban.insert(ObanHungFixture, ObanDrainFixtureWorker.new(%{marker: "hung"}))

    hung_pid =
      receive do
        {:working, "hung", pid} -> pid
      after
        5000 -> raise "Hung fixture didn't start"
      end

    started = System.monotonic_time(:millisecond)
    :ok = Supervisor.stop(hanging_oban, :normal, 70_000)
    elapsed = System.monotonic_time(:millisecond) - started
    true = elapsed >= 59_000 and elapsed <= 65_000
    false = Process.alive?(hung_pid)
    %{state: "executing", attempt: 1} = Anime.Repo.get!(Oban.Job, hung.id)

    # Keep dispatch paused while exercising the real rescue timer. Only this
    # fixture's timestamp is aged; the production eight-hour threshold stays intact.
    lifeline = Application.fetch_env!(:anime, Oban)[:lifeline]
    28_800_000 = lifeline[:rescue_after]
    60_000 = lifeline[:interval]

    {:ok, recovery} =
      Oban.start_link(
        name: ObanRecoveryFixture,
        repo: Anime.Repo,
        queues: false,
        testing: :disabled,
        peer: Oban.Peers.Isolated,
        notifier: Oban.Notifiers.Isolated,
        stager: false,
        lifeline: Keyword.put(lifeline, :interval, 100),
        plugins: []
      )

    Process.unlink(recovery)

    try do
      Process.sleep(350)
      "executing" = Anime.Repo.get!(Oban.Job, hung.id).state

      hung
      |> Ecto.Changeset.change(attempted_at: DateTime.add(DateTime.utc_now(), -28_801, :second))
      |> Anime.Repo.update!()

      rescued =
        Enum.reduce_while(1..100, false, fn _, _ ->
          case Anime.Repo.get!(Oban.Job, hung.id) do
            %{state: "available", attempt: 1} ->
              {:halt, true}

            _ ->
              Process.sleep(50)
              {:cont, false}
          end
        end)

      true = rescued
      Anime.Repo.delete!(hung)

      IO.puts(
        "PASS: hung worker stopped after #{elapsed}ms; fresh job not rescued; eight-hour orphan becomes available without dispatch"
      )
    after
      Supervisor.stop(recovery)
    end
  after
    if Process.alive?(hanging_oban), do: Supervisor.stop(hanging_oban, :normal, 70_000)
  end
after
  if Process.alive?(oban), do: Supervisor.stop(oban, :normal, 65_000)
  Supervisor.stop(repo)
end
