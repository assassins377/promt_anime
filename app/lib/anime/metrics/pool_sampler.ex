defmodule Anime.Metrics.PoolSampler do
  @moduledoc """
  Reads DBConnection's public single-pool metrics, without SQL or busy estimates.
  Timing, worker lifecycle and freshness are shared with the VM sampler.
  """
  alias Anime.Metrics
  alias Anime.Metrics.Sampler

  def child_spec(options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}
  def start_link(options), do: Sampler.start_link(__MODULE__, options)
  def poll(server \\ __MODULE__), do: Sampler.poll(server)
  def snapshot(server \\ __MODULE__), do: Sampler.snapshot(server)

  def scrape(server, reporter),
    do: Sampler.render(server, fn -> TelemetryMetricsPrometheus.Core.scrape(reporter) end)

  @doc false
  def read, do: read_repo()
  @doc false
  def publish(snapshot), do: Metrics.publish_pool_snapshot(snapshot)
  @doc false
  def guard(body, snapshot), do: Anime.Metrics.Exporter.guard_pool_snapshot(body, snapshot)

  @doc false
  def read_repo(repo \\ Anime.Repo) do
    meta = Ecto.Adapter.lookup_meta(repo)

    # Ownership proxies and partitioned pools have different counting semantics.
    if Map.has_key?(meta, :partition_supervisor) or
         Keyword.get(meta.opts, :pool, DBConnection.ConnectionPool) != DBConnection.ConnectionPool do
      :unavailable
    else
      read_pool(meta.pid)
    end
  end

  @doc false
  def read_pool(pool) do
    case DBConnection.get_connection_metrics(pool) do
      [%{source: {:pool, ^pool}, ready_conn_count: ready, checkout_queue_length: waiting}] ->
        normalize({:ok, %{ready: ready, waiting: waiting}})

      _ ->
        :unavailable
    end
  end

  @doc false
  def normalize({:ok, %{ready: ready, waiting: waiting}}) do
    if Metrics.valid_pool_count?(ready) and Metrics.valid_pool_count?(waiting),
      do: {:ok, %{ready: ready, waiting: waiting}},
      else: :unavailable
  end

  def normalize(_), do: :unavailable
end
