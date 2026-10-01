defmodule Anime.JobLoggingTest do
  use Anime.DataCase
  import ExUnit.CaptureLog
  alias Anime.LogContext
  @moduletag :capture_log
  @id "original-http-request-123456"
  @secret "PRIVATE-JOB-SENTINEL"

  defmodule ProbeWorker do
    use Anime.Worker, queue: :maintenance, max_attempts: 2
    @impl Oban.Worker
    def perform(%Oban.Job{args: args}) do
      case args["outcome"] do
        "retry" ->
          {:error, "PRIVATE-JOB-SENTINEL"}

        "raise" ->
          raise "PRIVATE-JOB-SENTINEL"

        "cancel" ->
          {:cancel, "PRIVATE-JOB-SENTINEL"}

        "discard" ->
          {:discard, "PRIVATE-JOB-SENTINEL"}

        "snooze" ->
          {:snooze, 60}

        "child" ->
          %{token_id: 0} |> Anime.Workers.Mail.new() |> Oban.insert!()
          :ok

        _ ->
          :ok
      end
    end
  end

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    LogContext.put(@id)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  defp records(output) do
    refute output =~ @secret
    output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "real mail execution has persisted correlation, safe fields and no arguments in logs" do
    u = user()
    job = Repo.one!(from j in Oban.Job, order_by: [desc: j.id], limit: 1)
    assert job.meta["request_id"] == @id
    LogContext.put("another-enqueuer-12345678")
    output = capture_log(fn -> assert %{success: 1} = Oban.drain_queue(queue: :mailers) end)
    [row] = records(output) |> Enum.filter(&(&1["message"] == "Oban job completed"))
    assert row["request_id"] == @id
    assert row["oban_worker"] == "Anime.Workers.Mail"
    assert row["oban_job_id"] == job.id
    assert row["oban_queue"] == "mailers"
    assert row["oban_attempt"] == 1
    assert row["oban_duration_ms"] >= 0
    assert LogContext.current() == "another-enqueuer-12345678"
    refute output =~ u.email
    refute output =~ "token_id"
    assert Repo.get!(Oban.Job, job.id).state == "completed"
  end

  test "failure retries with the same ID then logs exhaustion without raw error" do
    job = ProbeWorker.new(%{outcome: "retry", secret: @secret}) |> Oban.insert!()

    for {attempt, message, level} <- [
          {1, "Oban job will retry", "warning"},
          {2, "Oban job exhausted or discarded", "error"}
        ] do
      output =
        capture_log(fn ->
          Oban.drain_queue(queue: :maintenance, with_scheduled: true, with_safety: true)
        end)

      [row] = Enum.filter(records(output), &(&1["message"] == message))
      assert row["request_id"] == @id
      assert row["oban_attempt"] == attempt
      assert row["level"] == level
      assert LogContext.current() == @id
      assert Repo.get!(Oban.Job, job.id).meta["request_id"] == @id
    end

    assert Repo.get!(Oban.Job, job.id).state == "discarded"
  end

  test "raised exception is logged safely and does not leak context to subsequent work" do
    ProbeWorker.new(%{outcome: "raise"}, max_attempts: 1) |> Oban.insert!()
    LogContext.put("caller-after-enqueue-12345")
    output = capture_log(fn -> Oban.drain_queue(queue: :maintenance, with_safety: true) end)
    [row] = Enum.filter(records(output), &(&1["message"] == "Oban job exhausted or discarded"))
    assert row["request_id"] == @id
    assert row["level"] == "error"
    assert LogContext.current() == "caller-after-enqueue-12345"

    assert Ecto.Changeset.get_field(Anime.Workers.Mail.new(%{}), :meta)["request_id"] ==
             LogContext.current()
  end

  test "child job inherits the executing parent's ID instead of the caller's context" do
    ProbeWorker.new(%{outcome: "child"}) |> Oban.insert!()
    LogContext.put("unrelated-caller-12345678")
    capture_log(fn -> Oban.drain_queue(queue: :maintenance) end)
    child = Repo.one!(from j in Oban.Job, where: j.worker == "Anime.Workers.Mail")
    assert child.meta["request_id"] == @id
    assert LogContext.current() == "unrelated-caller-12345678"
    output = capture_log(fn -> Oban.drain_queue(queue: :mailers) end)

    assert Enum.any?(
             records(output),
             &(&1["message"] == "Oban job completed" && &1["request_id"] == @id)
           )
  end

  test "cancel, snooze and explicit discard are distinct safe outcomes" do
    for {outcome, message} <- [
          {"cancel", "Oban job cancelled"},
          {"snooze", "Oban job snoozed"},
          {"discard", "Oban job exhausted or discarded"}
        ] do
      job = ProbeWorker.new(%{outcome: outcome}) |> Oban.insert!()
      output = capture_log(fn -> Oban.drain_queue(queue: :maintenance) end)

      assert Enum.any?(
               records(output),
               &(&1["message"] == message && &1["oban_job_id"] == job.id)
             )

      assert LogContext.current() == @id
    end
  end

  test "real Cron plugin inserts request ID before the job reaches PostgreSQL" do
    name = __MODULE__.CronInstance
    handler = {__MODULE__, :cron_ready}
    :ok = :telemetry.attach(handler, [:oban, :plugin, :init], &__MODULE__.cron_ready/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    start_supervised!(
      {Oban,
       name: name,
       repo: Repo,
       queues: [],
       testing: :disabled,
       peer: Oban.Peers.Isolated,
       notifier: Oban.Notifiers.Isolated,
       stager: false,
       lifeline: false,
       plugins: [{Oban.Plugins.Cron, crontab: [{"@reboot", Anime.Workers.ExpireAccounts}]}]}
    )

    assert_receive {:cron_ready, cron}, 5000
    assert Oban.Registry.whereis(name, {:plugin, Oban.Cron}) == cron
    send(cron, :evaluate)
    :sys.get_state(cron)
    job = Repo.one!(from j in Oban.Job, where: j.worker == "Anime.Workers.ExpireAccounts")
    assert job.meta["cron"] == true
    assert job.meta["cron_expr"] == "@reboot"
    assert String.starts_with?(job.meta["request_id"], "cron-Anime.Workers.ExpireAccounts-")
    assert LogContext.valid_id(job.meta["request_id"])
    output = capture_log(fn -> Oban.drain_queue(name, queue: :maintenance) end)

    assert Enum.any?(
             records(output),
             &(&1["request_id"] == job.meta["request_id"] && &1["message"] == "Oban job completed")
           )
  end

  test "late exception emitted by another process does not overwrite its logger context" do
    job = %Oban.Job{
      id: 19,
      worker: "Anime.Workers.Mail",
      queue: "mailers",
      attempt: 5,
      max_attempts: 5,
      meta: %{"request_id" => "job-original-request-12345"}
    }

    output =
      capture_log(fn ->
        :telemetry.execute([:oban, :job, :exception], %{duration: 1000}, %{
          job: job,
          state: :discard,
          reason: @secret,
          args: %{"secret" => @secret}
        })
      end)

    [row] = records(output)
    assert row["request_id"] == job.meta["request_id"]
    assert LogContext.current() == @id
  end

  test "malformed telemetry stays attached and never inspects rejected data" do
    output =
      capture_log(fn ->
        Anime.LogTelemetry.handle(
          [:phoenix, :live_view, :mount, :stop],
          %{},
          %{socket: @secret},
          nil
        )
      end)

    assert [%{"message" => "Log telemetry projection failed safely"}] = records(output)

    assert Enum.any?(
             :telemetry.list_handlers([:phoenix, :live_view, :mount, :stop]),
             &(&1.id == Anime.LogTelemetry)
           )
  end

  def cron_ready(_, _, %{plugin: Oban.Cron, conf: %{name: __MODULE__.CronInstance}}, observer),
    do: send(observer, {:cron_ready, self()})

  def cron_ready(_, _, _, _), do: :ok
end
