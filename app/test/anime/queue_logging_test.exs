defmodule Anime.QueueLoggingTest do
  use Anime.DataCase
  import ExUnit.CaptureLog
  @name __MODULE__.Instance

  setup do
    start_supervised!(
      {Oban,
       name: @name,
       repo: Repo,
       queues: [],
       testing: :disabled,
       peer: Oban.Peers.Isolated,
       notifier: Oban.Notifiers.Isolated,
       stager: false,
       lifeline: false,
       plugins: []}
    )

    :ok
  end

  defp start_queue(queue) do
    {:ok, _} = Oban.Queues.start_queue(Oban.config(@name), queue: queue, limit: 1, paused: true)
    pid = Oban.Registry.whereis(@name, {:producer, queue})
    assert is_pid(pid)
    await(fn -> Map.has_key?(:sys.get_state(Anime.LogTelemetry), pid) end)
    pid
  end

  defp stop_queue(queue, pid) do
    :ok = Oban.Queues.stop_queue(Oban.config(@name), queue)
    await(fn -> not Map.has_key?(:sys.get_state(Anime.LogTelemetry), pid) end)
  end

  defp await(fun, remaining \\ 250)
  defp await(fun, 0), do: assert(fun.(), "queue observer did not reach expected state")

  defp await(fun, remaining) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      await(fun, remaining - 1)
    end
  end

  defp records(output) do
    refute output =~ "PRIVATE-QUEUE-SENTINEL"

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&String.starts_with?(&1["message"], "Oban queue"))
  end

  test "real paused producers log one start and graceful stop, not task events" do
    Anime.LogContext.put("caller-not-a-queue-id-12345")

    output =
      capture_log(fn ->
        for queue <- ["mailers", "maintenance"] do
          pid = start_queue(queue)
          send(Anime.LogTelemetry, {:observe_queue, pid, queue})
          :sys.get_state(Anime.LogTelemetry)
          stop_queue(queue, pid)
        end
      end)

    rows = records(output)

    assert Enum.map(rows, &{&1["message"], &1["oban_queue"]}) == [
             {"Oban queue started", "mailers"},
             {"Oban queue stopped", "mailers"},
             {"Oban queue started", "maintenance"},
             {"Oban queue stopped", "maintenance"}
           ]

    for row <- rows do
      assert row["level"] == "info"
      assert row["request_id"] == nil

      assert Enum.sort(Map.keys(row)) ==
               ~w(app_version level message node oban_queue request_id ts)
    end

    assert Anime.LogContext.current() == "caller-not-a-queue-id-12345"
  end

  test "actual killed producer reports error and supervised restart, without a fake clean stop" do
    output =
      capture_log(fn ->
        old = start_queue("mailers")
        Process.exit(old, :kill)

        await(fn ->
          pid = Oban.Registry.whereis(@name, {:producer, "mailers"})
          is_pid(pid) and pid != old and Map.has_key?(:sys.get_state(Anime.LogTelemetry), pid)
        end)

        pid = Oban.Registry.whereis(@name, {:producer, "mailers"})
        stop_queue("mailers", pid)
      end)

    rows = records(output)
    assert Enum.count(rows, &(&1["message"] == "Oban queue started")) == 2
    assert Enum.count(rows, &(&1["message"] == "Oban queue stopped")) == 1
    [failure] = Enum.filter(rows, &(&1["message"] == "Oban queue process failed"))
    assert failure["level"] == "error"
    assert failure["request_id"] == nil
    assert failure["oban_queue"] == "mailers"
  end

  test "engine init from ordinary process and manual draining are not queue startup" do
    %{token_id: 0} |> Anime.Workers.Mail.new() |> Oban.insert!()

    output =
      capture_log(fn ->
        assert {:ok, _} = Oban.Engine.init(Oban.config(@name), queue: "mailers", limit: 1)
        assert %{success: 1} = Oban.drain_queue(queue: :mailers)
        :sys.get_state(Anime.LogTelemetry)
      end)

    assert records(output) == []
  end

  test "restarting log observer restores existing monitors without duplicate startup" do
    pid = start_queue("maintenance")

    on_exit(fn ->
      unless Process.whereis(Anime.LogTelemetry),
        do: Supervisor.restart_child(Anime.Supervisor, Anime.LogTelemetry)
    end)

    output =
      capture_log(fn ->
        :ok = Supervisor.terminate_child(Anime.Supervisor, Anime.LogTelemetry)
        assert {:ok, _} = Supervisor.restart_child(Anime.Supervisor, Anime.LogTelemetry)
        assert Map.has_key?(:sys.get_state(Anime.LogTelemetry), pid)
        stop_queue("maintenance", pid)
      end)

    [row] = records(output)
    assert row["message"] == "Oban queue stopped"
  end

  test "unrecognized queue label is redacted at both lifecycle boundaries" do
    output =
      capture_log(fn ->
        pid = start_queue("PRIVATE-QUEUE-SENTINEL")
        stop_queue("PRIVATE-QUEUE-SENTINEL", pid)
      end)

    assert length(records(output)) == 2
    assert Enum.all?(records(output), &(&1["oban_queue"] == "[unknown]"))
  end

  test "stopping the entire Oban supervisor reports both producer shutdowns" do
    mailers = start_queue("mailers")
    maintenance = start_queue("maintenance")

    output =
      capture_log(fn ->
        stop_supervised!(@name)

        await(fn ->
          monitored = :sys.get_state(Anime.LogTelemetry)
          not Map.has_key?(monitored, mailers) and not Map.has_key?(monitored, maintenance)
        end)
      end)

    rows = records(output)
    assert Enum.sort(Enum.map(rows, & &1["oban_queue"])) == ["mailers", "maintenance"]
    assert Enum.all?(rows, &(&1["message"] == "Oban queue stopped" and &1["level"] == "info"))
  end
end
