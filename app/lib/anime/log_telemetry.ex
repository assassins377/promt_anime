defmodule Anime.LogTelemetry do
  @moduledoc "Projects framework telemetry to fixed events and scalar allowlisted fields."
  use GenServer
  alias Anime.{Log, LogContext}
  @handler __MODULE__
  @events for(
            stage <- [:mount, :handle_params, :handle_event],
            phase <- [:start, :stop, :exception],
            do: [:phoenix, :live_view, stage, phase]
          ) ++
            for(phase <- [:start, :stop, :exception], do: [:oban, :job, phase]) ++
            for(
              operation <- [:deliver, :deliver_many],
              phase <- [:stop, :exception],
              do: [:swoosh, operation, phase]
            ) ++ [[:oban, :engine, :init, :stop]]

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :telemetry.detach(@handler)
    # Recover monitors after this observer restarts; already running queues have
    # not just started, so don't invent new start records for them.
    monitored = existing_queues()
    :ok = :telemetry.attach_many(@handler, @events, &__MODULE__.handle/4, nil)
    {:ok, monitored}
  end

  @impl true
  def terminate(_, _), do: :telemetry.detach(@handler)

  @impl true
  def handle_info({:observe_queue, pid, queue}, monitored) when is_pid(pid) do
    if Map.has_key?(monitored, pid) do
      {:noreply, monitored}
    else
      ref = Process.monitor(pid)

      # Executed outside the Telemetry callback, after producer's handle_continue.
      # A span stop alone doesn't prove Engine.init returned {:ok, meta}.
      if queue_ready?(pid, queue), do: queue_log(:queue_started, queue)
      {:noreply, Map.put(monitored, pid, {ref, queue})}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, monitored) do
    case Map.get(monitored, pid) do
      {^ref, queue} ->
        event =
          if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
            do: :queue_stopped,
            else: :queue_failed

        queue_log(event, queue)
        {:noreply, Map.delete(monitored, pid)}

      _ ->
        {:noreply, monitored}
    end
  end

  def handle_info(_, monitored), do: {:noreply, monitored}

  defp existing_queues do
    if Process.whereis(Oban.Registry) do
      Oban.Registry.select([
        {{{:_, {:producer, :"$1"}}, :"$2", :_}, [], [{{:"$2", :"$1"}}]}
      ])
      |> Map.new(fn {pid, queue} -> {pid, {Process.monitor(pid), queue}} end)
    else
      %{}
    end
  end

  defp queue_ready?(pid, queue) do
    case GenServer.call(pid, :check, 1000) do
      %{queue: ^queue, started_at: started_at} when not is_nil(started_at) -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  defp queue_log(event, queue),
    do: LogContext.with_id(nil, fn -> Log.emit(event, %{oban_queue: queue}) end)

  def handle(event, measurements, meta, config) do
    dispatch(event, measurements, meta, config)
  rescue
    _ -> Log.emit(:telemetry_failed)
  catch
    _, _ -> Log.emit(:telemetry_failed)
  end

  defp dispatch([:phoenix, :live_view, _stage, :start], _, %{socket: socket} = meta, _) do
    # Mount's start precedes on_mount, so only the verified session is available.
    id = socket.assigns[:request_id] || (meta[:session] || %{})["request_id"]
    LogContext.put(id)
  end

  defp dispatch([:phoenix, :live_view, stage, phase], _, %{socket: socket} = meta, _)
       when phase in [:stop, :exception] do
    id = socket.assigns[:request_id] || (meta[:session] || %{})["request_id"]

    LogContext.with_id(id, fn ->
      fields = %{
        live_view: socket.view,
        live_action: socket.assigns[:live_action],
        live_event: if(stage == :handle_event, do: meta[:event]),
        socket_id: socket.id,
        user_id: user_id(socket)
      }

      event =
        case {stage, phase} do
          {_, :exception} -> :live_failed
          {:mount, _} -> :live_mounted
          {:handle_params, _} -> :live_params
          {:handle_event, _} -> :live_event
        end

      Log.emit(event, fields)
    end)
  end

  defp dispatch([:oban, :job, :start], _, %{job: %Oban.Job{} = job}, _) do
    LogContext.begin_job(job)
    Log.emit(:job_started, job_fields(job, %{}))
  end

  defp dispatch([:oban, :job, phase], measurements, %{job: %Oban.Job{} = job} = meta, _)
       when phase in [:stop, :exception] do
    try do
      LogContext.with_id(LogContext.job_id(job), fn ->
        Log.emit(job_event(meta[:state], job), job_fields(job, measurements))
      end)
    after
      LogContext.end_job(job)
    end
  end

  defp dispatch([:swoosh, operation, phase], _, %{mailer: Anime.Mailer} = meta, _)
       when operation in [:deliver, :deliver_many] and phase in [:stop, :exception] do
    cond do
      phase == :exception or Map.has_key?(meta, :error) -> Log.emit(:mail_failed)
      Map.has_key?(meta, :result) -> Log.emit(:mail_accepted)
      true -> :ok
    end
  end

  defp dispatch([:oban, :engine, :init, :stop], _, %{conf: conf, opts: opts}, _)
       when is_list(opts) do
    queue = Keyword.get(opts, :queue)

    # Only a real registered producer, never drain_queue or an arbitrary Engine.init.
    if is_binary(queue) and Oban.Registry.whereis(conf.name, {:producer, queue}) == self() do
      send(__MODULE__, {:observe_queue, self(), queue})
    end
  end

  defp dispatch(_, _, _, _), do: :ok

  defp job_event(:success, _), do: :job_completed
  defp job_event(:cancelled, _), do: :job_cancelled
  defp job_event(:snoozed, _), do: :job_snoozed

  defp job_event(state, job) do
    if state in [:discard, :exhausted] || job.attempt >= job.max_attempts,
      do: :job_failed,
      else: :job_retry
  end

  defp job_fields(job, measurements) do
    fields = %{
      oban_worker: job.worker,
      oban_job_id: job.id,
      oban_queue: job.queue,
      oban_attempt: job.attempt
    }

    case measurements[:duration] do
      n when is_integer(n) and n >= 0 ->
        Map.put(
          fields,
          :oban_duration_ms,
          System.convert_time_unit(n, :native, :microsecond) / 1000
        )

      _ ->
        fields
    end
  end

  defp user_id(%{assigns: %{current_user: %{id: id}}}), do: id
  defp user_id(_), do: nil
end
