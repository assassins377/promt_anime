defmodule Anime.Metrics.VMSampler do
  @moduledoc """
  Public OTP counters only: no process/port enumeration, atom names or contents.
  BEAM memory categories overlap and are not OS RSS or an atomic VM snapshot.
  """
  alias Anime.Metrics
  alias Anime.Metrics.Sampler

  def child_spec(options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}
  def start_link(options), do: Sampler.start_link(__MODULE__, options)
  def poll(server \\ __MODULE__), do: Sampler.poll(server)
  def snapshot(server \\ __MODULE__), do: Sampler.snapshot(server)

  @doc false
  def read(clock \\ Anime.RuntimeClock) do
    with {:ok, %{started_at: started_at, uptime_ms: uptime_ms}} <-
           Anime.RuntimeClock.measure(clock) do
      {collections, _words_reclaimed, _reserved} = :erlang.statistics(:garbage_collection)

      normalize(
        {:ok,
         %{
           memory: Map.new(:erlang.memory()),
           vm_process_count: :erlang.system_info(:process_count),
           vm_port_count: :erlang.system_info(:port_count),
           vm_atom_count: :erlang.system_info(:atom_count),
           vm_gc_collections: collections,
           application_start_time_seconds: started_at,
           application_uptime_seconds: div(uptime_ms, 1_000)
         }}
      )
    end
  end

  @doc false
  def normalize(snapshot), do: Metrics.normalize_vm_snapshot(snapshot)
  @doc false
  def publish(snapshot), do: Metrics.publish_vm_snapshot(snapshot)
  @doc false
  def guard(body, snapshot), do: Anime.Metrics.Exporter.guard_vm_snapshot(body, snapshot)
end
