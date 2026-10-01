# Run after test compilation: MIX_ENV=test mix run --no-start dev/logging_smoke.exs
# Uses the real OTP stdout handler in a child VM, not ExUnit.CaptureLog.
# Does not read .env, start Anime/Repo, access services or create accounts.
defmodule LoggingSmoke do
  def run do
    code = ~S"""
    require Logger
    nil = Process.whereis(Anime.Supervisor)
    nil = Process.whereis(Anime.Repo)
    # Mix --no-start only loads config; mirror Mix app.start's Logger restart
    # without starting Anime or its external-service dependencies.
    Logger.App.stop()
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, %{formatter: {Anime.LogFormatter, %{}}}} = :logger.get_handler_config(:default)
    :debug = Logger.level()
    Logger.metadata(request_id: "safe-smoke-request-12345")
    Anime.Log.emit(:application_started)
    Anime.Log.emit(:http_response, %{
      method: "GET", path: "/confirm/PRIVATE-SENTINEL?token=PRIVATE-SENTINEL",
      status: 400, duration_ms: 1.25, user_id: 42, email: "PRIVATE-SENTINEL"
    })
    Anime.Log.proxy_rejected(:invalid)
    task = Task.async(Anime.LogContext.wrap(fn ->
      Anime.Log.emit(:access_denied, %{user_id: 42, email: "PRIVATE-SENTINEL"})
    end))
    Task.await(task)
    Anime.Log.emit(:rate_limited, %{subject: "PRIVATE-SENTINEL"})
    Anime.Log.emit(:permissions_cache_reset, %{values: "PRIVATE-SENTINEL"})
    Anime.Log.emit(:mail_accepted, %{email: "PRIVATE-SENTINEL", receipt: "PRIVATE-SENTINEL"})
    Anime.Log.emit(:mail_failed, %{reason: "PRIVATE-SENTINEL"})
    Anime.LogContext.with_id(nil, fn ->
      for event <- [:queue_started, :queue_stopped, :queue_failed] do
        Anime.Log.emit(event, %{oban_queue: "mailers", reason: "PRIVATE-SENTINEL"})
      end
    end)
    failing = Anime.LogContext.wrap(fn -> raise "PRIVATE-SENTINEL" end)
    try do
      failing.()
    rescue
      RuntimeError -> :ok
    end
    Logger.warning("PRIVATE-SENTINEL\nforged second record", email: "PRIVATE-SENTINEL")
    :logger.error(%{password: "PRIVATE-SENTINEL", body: "PRIVATE-SENTINEL"},
      %{crash_reason: {"PRIVATE-SENTINEL", ["PRIVATE-SENTINEL"]}})
    defmodule CrashAck do
      def log(%{level: :error}, %{config: %{observer: observer}}),
        do: send(observer, :crash_report_delivered)
      def log(_, _), do: :ok
    end
    :ok = :logger.add_handler(:smoke_crash_ack, CrashAck, %{config: %{observer: self()}})
    {pid, ref} = spawn_monitor(fn -> raise "PRIVATE-SENTINEL" end)
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5000 -> raise "Synthetic child did not exit"
    end
    # DOWN can precede the asynchronous VM crash report; wait for the handler,
    # not a sleep, before flushing stdout and terminating this VM.
    receive do
      :crash_report_delivered -> :ok
    after
      5000 -> raise "Synthetic crash report was not delivered"
    end
    :ok = :logger.remove_handler(:smoke_crash_ack)
    Anime.Log.emit(:application_stopped)
    Logger.flush()
    """

    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "--no-compile", "--no-start", "-e", code],
        env: [{"MIX_ENV", "test"}, {"ELIXIR_ERL_OPTIONS", "+S 2:2"}],
        stderr_to_stdout: true
      )

    check!(status == 0, "child exit status")

    for hidden <- ["PRIVATE-SENTINEL", "forged second record", "\e["],
        do: check!(not String.contains?(output, hidden), "private output")

    rows =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case Jason.decode(line) do
          {:ok, row} when is_map(row) -> row
          _ -> raise "Logging smoke failed: non-JSON line; output withheld"
        end
      end)

    check!(length(rows) == 16, "event count including process crash (received #{length(rows)})")

    for row <- rows do
      check!(
        Enum.all?(~w(ts level message node app_version request_id), &Map.has_key?(row, &1)),
        "required keys"
      )

      check!(
        Enum.all?(Map.values(row), &(is_nil(&1) or is_binary(&1) or is_number(&1))),
        "flat fields"
      )

      check!(row["ts"] =~ ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/, "timestamp")
    end

    [http] = Enum.filter(rows, &(&1["message"] == "HTTP request completed"))
    check!(http["path"] == "/confirm/:token" and http["status"] == 400, "safe HTTP fields")
    check!(http["request_id"] == "safe-smoke-request-12345", "request correlation")

    check!(
      Enum.count(rows, &(&1["level"] == "error")) == 5,
      "async/mail/queue failure, OTP report and crash"
    )

    for {message, level} <- [
          {"Mail transport accepted message", "debug"},
          {"Mail transport failed", "error"}
        ] do
      [record] = Enum.filter(rows, &(&1["message"] == message))

      check!(
        record["level"] == level and record["request_id"] == "safe-smoke-request-12345",
        "mail level and correlation"
      )
    end

    for {message, level} <- [
          {"Oban queue started", "info"},
          {"Oban queue stopped", "info"},
          {"Oban queue process failed", "error"}
        ] do
      [record] = Enum.filter(rows, &(&1["message"] == message))

      check!(
        record["level"] == level and record["request_id"] == nil and
          record["oban_queue"] == "mailers",
        "queue fields and level"
      )
    end

    for message <- [
          "Access denied",
          "Rate limit reached",
          "Role permissions ETS cache reset",
          "Asynchronous callback failed"
        ] do
      [record] = Enum.filter(rows, &(&1["message"] == message))
      check!(record["request_id"] == "safe-smoke-request-12345", "async/operation correlation")
    end

    check!(Enum.any?(rows, &(&1["message"] == "Application started")), "startup")
    check!(Enum.any?(rows, &(&1["message"] == "Application stopped")), "shutdown")

    IO.puts(
      "16 stdout JSON records verified at configured test debug level, including mail/queue/async events and a crashed process; no application/services started"
    )
  end

  defp check!(true, _), do: :ok
  defp check!(false, label), do: raise("Logging smoke failed: #{label}; output withheld")
end

LoggingSmoke.run()
