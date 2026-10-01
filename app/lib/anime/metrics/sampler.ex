defmodule Anime.Metrics.Sampler do
  @moduledoc """
  Bounded, non-overlapping numeric sampling. Each source owns one snapshot,
  never history. Freshness checks and exposition are serialized with publication.
  """
  use GenServer

  def start_link(source, options) do
    options = Keyword.merge(Application.get_env(:anime, source, []), options)

    if Keyword.get(options, :enabled, true),
      do:
        GenServer.start_link(__MODULE__, Keyword.put(options, :source, source),
          name: Keyword.get(options, :name, source)
        ),
      else: :ignore
  end

  def poll(server), do: GenServer.cast(server, :poll)
  def snapshot(server), do: GenServer.call(server, :snapshot)

  def render(server, render, timeout \\ 1_000),
    do: GenServer.call(server, {:render, render}, timeout)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    source = Keyword.fetch!(options, :source)

    state = %{
      source: source,
      source_state: if(function_exported?(source, :init_sampling, 0), do: source.init_sampling()),
      read: Keyword.get(options, :read, &source.read/0),
      clock: Keyword.get(options, :clock, fn -> System.monotonic_time(:millisecond) end),
      interval: Keyword.get(options, :interval, 15_000),
      timeout: Keyword.get(options, :timeout, 1_000),
      max_age: Keyword.get(options, :max_age, 30_000),
      worker: nil,
      sample: nil,
      timer: nil
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_cast(:poll, state), do: {:noreply, start_read(state)}

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, fresh(state), state}

  def handle_call({:render, render}, _, state) do
    # Serialize the snapshot and Core scrape with result publication. Re-publish
    # gauges after a reporter restart, without querying the pool on scrape.
    snapshot = fresh(state)
    state.source.publish(snapshot)

    result =
      try do
        body = render.()
        {:ok, state.source.guard(body, fresh(state))}
      rescue
        _ -> :reporter_unavailable
      catch
        :exit, _ -> :reporter_unavailable
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:tick, state) do
    timer = Process.send_after(self(), :tick, state.interval)
    {:noreply, start_read(%{state | timer: timer})}
  end

  def handle_info(
        {:sample, token, result, measured_at},
        %{worker: %{token: token} = worker} = state
      ) do
    late? = System.monotonic_time(:millisecond) - worker.started >= state.timeout
    result = if late?, do: :unavailable, else: result
    state = release_worker(state)
    {:noreply, accept(state, result, measured_at)}
  end

  def handle_info({:timeout, token}, %{worker: %{token: token}} = state),
    do: {:noreply, failed_read(state)}

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: %{ref: ref}} = state),
    do: {:noreply, failed_read(state)}

  # Late results, monitors, cancelled timers and linked worker exits are inert.
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    release_worker(state)
    :ok
  end

  defp start_read(%{worker: worker} = state) when not is_nil(worker), do: state

  defp start_read(state) do
    owner = self()
    token = make_ref()
    started = System.monotonic_time(:millisecond)
    read = state.read
    source = state.source
    clock = state.clock

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          # Never send exception terms, credentials, pool PIDs or config to state,
          # logs or telemetry. Linking also kills the worker if its owner is killed.
          result =
            try do
              source.normalize(read.())
            rescue
              _ -> :unavailable
            catch
              _, _ -> :unavailable
            end

          send(owner, {:sample, token, result, clock.()})
        end,
        [:link, :monitor]
      )

    timer = Process.send_after(owner, {:timeout, token}, state.timeout)
    %{state | worker: %{pid: pid, ref: ref, token: token, timer: timer, started: started}}
  end

  defp failed_read(state) do
    accept(release_worker(state), :unavailable, state.clock.())
  end

  defp accept(state, result, measured_at) do
    {result, source_state} =
      if function_exported?(state.source, :project, 4),
        do: state.source.project(result, state.source_state, measured_at, state.max_age),
        else: {result, state.source_state}

    state.source.publish(result)
    sample = if match?({:ok, _}, result), do: {result, measured_at}
    %{state | sample: sample, source_state: source_state}
  end

  defp release_worker(%{worker: nil} = state), do: state

  defp release_worker(%{worker: worker} = state) do
    Process.cancel_timer(worker.timer)
    Process.demonitor(worker.ref, [:flush])
    Process.exit(worker.pid, :kill)
    %{state | worker: nil}
  end

  defp fresh(%{sample: {sample, measured_at}} = state) do
    age = state.clock.() - measured_at
    if age >= 0 and age < state.max_age, do: sample, else: :unavailable
  end

  defp fresh(_), do: :unavailable
end
