defmodule Anime.LiveTransports do
  @moduledoc "Node-local monitored LiveView transports, without retaining socket or user data."
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))

  def track(pid, server \\ __MODULE__) when is_pid(pid), do: GenServer.call(server, {:track, pid})
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:track, pid}, _, refs) do
    refs = if Map.has_key?(refs, pid), do: refs, else: Map.put(refs, pid, Process.monitor(pid))
    {:reply, :ok, refs}
  end

  def handle_call(:snapshot, _, refs), do: {:reply, Map.keys(refs), refs}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, refs) do
    refs = if Map.get(refs, pid) == ref, do: Map.delete(refs, pid), else: refs
    {:noreply, refs}
  end
end
