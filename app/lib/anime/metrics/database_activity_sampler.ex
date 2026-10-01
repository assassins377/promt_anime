defmodule Anime.Metrics.DatabaseActivitySampler do
  @moduledoc "One read-only aggregate of visible client activity in the connected database."
  alias Anime.Metrics
  alias Anime.Metrics.Sampler

  @sql """
  WITH activity AS MATERIALIZED (
    SELECT backend_type, state, xact_start
    FROM pg_catalog.pg_stat_activity
    WHERE datid = (SELECT oid FROM pg_catalog.pg_database WHERE datname = current_database())
      AND pid <> pg_backend_pid()
  )
  SELECT pg_has_role(current_user, 'pg_read_all_stats', 'USAGE')
           AND current_setting('track_activities')::boolean,
         COALESCE(bool_and(backend_type IS NOT NULL AND
           (backend_type <> 'client backend' OR
            (state IN ('starting', 'active', 'idle', 'idle in transaction',
                       'idle in transaction (aborted)', 'fastpath function call')) IS TRUE)), true),
         count(*) FILTER (WHERE backend_type = 'client backend' AND state = 'active'),
         count(*) FILTER (WHERE backend_type = 'client backend'
           AND state IN ('idle in transaction', 'idle in transaction (aborted)')),
         GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (statement_timestamp() -
           min(xact_start) FILTER (WHERE backend_type = 'client backend')))))::bigint
  FROM activity
  """

  def child_spec(options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}
  def start_link(options), do: Sampler.start_link(__MODULE__, options)
  def poll(server \\ __MODULE__), do: Sampler.poll(server)
  def snapshot(server \\ __MODULE__), do: Sampler.snapshot(server)

  @doc false
  def read(repo \\ Anime.Repo) do
    # pg_stat_activity is cached inside a transaction. The background reader
    # uses autocommit; never present a caller's old transaction snapshot as fresh.
    if repo.in_transaction?() do
      :unavailable
    else
      Metrics.Context.with_source(:other, fn ->
        case repo.query(@sql, [], timeout: 750, queue: false, log: false) do
          {:ok, %{rows: [[true, true, active, idle, age]]}} ->
            normalize({:ok, %{active: active, idle: idle, oldest_seconds: age}})

          _ ->
            :unavailable
        end
      end)
    end
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  @doc false
  def normalize(snapshot), do: Metrics.normalize_postgres_snapshot(:activity, snapshot)
  @doc false
  def publish(snapshot), do: Metrics.publish_postgres_snapshot(:activity, snapshot)
  @doc false
  def guard(body, snapshot),
    do: Anime.Metrics.Exporter.guard_postgres_snapshot(body, :activity, snapshot)
end
