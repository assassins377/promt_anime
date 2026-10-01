defmodule Anime.Metrics.CacheSampler do
  @moduledoc "Bounded snapshots of the explicit application cache inventory, never table contents."
  alias Anime.Metrics
  alias Anime.Metrics.Sampler

  def child_spec(options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}
  def start_link(options), do: Sampler.start_link(__MODULE__, options)
  def poll(server \\ __MODULE__), do: Sampler.poll(server)
  def snapshot(server \\ __MODULE__), do: Sampler.snapshot(server)

  @doc false
  def read, do: {:ok, Anime.Cache.statistics()}
  @doc false
  def normalize(snapshot), do: Metrics.normalize_cache_snapshot(snapshot)
  @doc false
  def publish(snapshot), do: Metrics.publish_cache_snapshot(snapshot)
  @doc false
  def guard(body, snapshot), do: Anime.Metrics.Exporter.guard_cache_snapshot(body, snapshot)
end
