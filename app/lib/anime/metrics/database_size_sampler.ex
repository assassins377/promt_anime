defmodule Anime.Metrics.DatabaseSizeSampler do
  @moduledoc "Database disk usage every five minutes, independent of metadata availability."
  alias Anime.Metrics
  alias Anime.Metrics.Sampler

  def child_spec(options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}

  def start_link(options) do
    defaults = [interval: 300_000, max_age: 315_000]
    config = Application.get_env(:anime, __MODULE__, [])
    Sampler.start_link(__MODULE__, defaults |> Keyword.merge(config) |> Keyword.merge(options))
  end

  def poll(server \\ __MODULE__), do: Sampler.poll(server)
  def snapshot(server \\ __MODULE__), do: Sampler.snapshot(server)

  @doc false
  def read(repo \\ Anime.Repo) do
    Metrics.Context.with_source(:other, fn ->
      case repo.query("SELECT pg_database_size(current_database())", [],
             timeout: 750,
             queue: false,
             log: false
           ) do
        {:ok, %{rows: [[bytes]]}} -> normalize({:ok, %{bytes: bytes}})
        _ -> :unavailable
      end
    end)
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  @doc false
  def normalize(snapshot), do: Metrics.normalize_postgres_snapshot(:size, snapshot)
  @doc false
  def publish(snapshot), do: Metrics.publish_postgres_snapshot(:size, snapshot)
  @doc false
  def guard(body, snapshot),
    do: Anime.Metrics.Exporter.guard_postgres_snapshot(body, :size, snapshot)
end
