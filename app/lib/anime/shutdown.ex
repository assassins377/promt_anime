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
      case Bandit.PhoenixAdapter.bandit_pid(endpoint, scheme) do
        {:ok, pid} when is_pid(pid) -> :ok = ThousandIsland.suspend(pid)
        {:error, :no_server_found} -> :ok
      end
    end

    :ok
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
