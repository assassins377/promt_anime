defmodule Anime.Shutdown do
  @moduledoc "Node-local shutdown intent, surviving individual supervisor child restarts."
  @key {__MODULE__, :draining}
  @reject_key {__MODULE__, :rejecting}

  def draining?, do: :persistent_term.get(@key, false)

  def reset do
    :persistent_term.put(@key, false)
    :persistent_term.put(@reject_key, false)
  end

  def rejecting?, do: :persistent_term.get(@reject_key, false)
  def begin_rejection, do: :persistent_term.put(@reject_key, true)
  def begin_drain, do: :persistent_term.put(@key, true)

  def prepare(wait \\ &Process.sleep/1) do
    begin_drain()
    wait.(10_000)
    begin_rejection()
    :ok
  end

  def stop_accepting(endpoint) do
    for scheme <- [:http, :https] do
      case server_pid(endpoint, scheme) do
        {:ok, pid} when is_pid(pid) -> :ok = ThousandIsland.suspend(pid)
        {:error, :no_server_found} -> :ok
        {:ok, state} when state in [:undefined, :restarting] -> :ok
      end
    end

    :ok
  end

  def quiesce_jobs(name \\ Oban) do
    # The pinned Basic engine pauses locally here, without a DB-backed notifier.
    # Normal Oban termination still owns waiting for and stopping running jobs.
    for queue <- ~w(mailers maintenance video_health) do
      case Oban.Registry.whereis(name, {:producer, queue}) do
        nil -> :ok
        pid -> :ok = Oban.Queues.Producer.shutdown(pid)
      end
    end

    :ok
  end

  def drain_web(endpoint) do
    servers =
      for scheme <- [:http, :https],
          {:ok, pid} <- [server_pid(endpoint, scheme)],
          is_pid(pid),
          do: pid

    drain_connections(servers)
  end

  defp server_pid(endpoint, scheme) do
    Bandit.PhoenixAdapter.bandit_pid(endpoint, scheme)
  catch
    :exit, {:noproc, _call} -> {:error, :no_server_found}
  end

  def drain_connections(servers, wait \\ &Process.sleep/1) do
    wait.(30_000)
    tracked = MapSet.new(Anime.LiveTransports.snapshot())

    connections = Enum.flat_map(servers, &connection_pids/1)

    sockets = Enum.filter(connections, &MapSet.member?(tracked, &1))
    monitors = Enum.map(sockets, &{&1, Process.monitor(&1)})
    Enum.each(sockets, &send(&1, :socket_drain))

    for pid <- connections, not MapSet.member?(tracked, pid), do: Process.exit(pid, :kill)

    # One shared close-handshake allowance, not one timeout per connection.
    deadline = System.monotonic_time(:millisecond) + 1_000

    for {pid, ref} <- monitors do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        remaining ->
          Process.exit(pid, :kill)
          Process.demonitor(ref, [:flush])
      end
    end

    :ok
  end

  defp connection_pids(server) do
    case ThousandIsland.connection_pids(server) do
      {:ok, pids} -> pids
      :error -> []
    end
  catch
    :exit, reason ->
      # A completed server shutdown has no remaining connections. Do not hide
      # failures of a still-running server (including a blocked supervisor).
      if Process.alive?(server), do: exit(reason), else: []
  end

  def failures(checks) do
    if draining?() do
      [:shutdown]
    else
      results = checks.()
      # A request that began before SIGTERM must not advertise readiness afterwards.
      if draining?(), do: [:shutdown], else: for({key, false} <- results, do: key)
    end
  end
end
