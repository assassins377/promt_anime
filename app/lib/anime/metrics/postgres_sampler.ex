defmodule Anime.Metrics.PostgresSampler do
  @moduledoc "Read-only release metadata; never runs the Ecto migration machinery."
  alias Anime.Metrics
  alias Anime.Metrics.Sampler

  @metadata_sql """
  SELECT current_setting('server_version_num')::integer,
         (SELECT count(*) FROM unnest($1::bigint[]) AS pending(version)
          WHERE NOT EXISTS
            (SELECT 1 FROM schema_migrations AS applied
             WHERE applied.version = pending.version))
  """

  def child_spec(options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}
  def start_link(options), do: Sampler.start_link(__MODULE__, options)
  def poll(server \\ __MODULE__), do: Sampler.poll(server)
  def snapshot(server \\ __MODULE__), do: Sampler.snapshot(server)

  @doc false
  def read(repo \\ Anime.Repo, directory \\ nil) do
    config = repo.config()

    # This application has one default migration ledger. Do not silently read
    # the wrong ledger if a future release introduces another migration repo.
    with true <- Keyword.get(config, :migration_repo, repo) == repo,
         "schema_migrations" <- Keyword.get(config, :migration_source, "schema_migrations"),
         {:ok, versions} <- migration_versions(directory || Ecto.Migrator.migrations_path(repo)) do
      Metrics.Context.with_source(:other, fn ->
        case repo.query(@metadata_sql, [versions], timeout: 750, queue: false, log: false) do
          {:ok, %{rows: [[version, pending]]}} ->
            normalize({:ok, %{version_number: version, pending: pending}})

          _ ->
            :unavailable
        end
      end)
    else
      _ -> :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  @doc false
  def migration_versions(directory) do
    # Match Ecto's recursive .exs inventory, without evaluating any file or
    # calling migrated_versions/migrations (those may create the ledger).
    files = Path.wildcard(Path.join(directory, "**/*.exs"))

    if File.dir?(directory) and length(files) in 1..4096 do
      entries =
        Enum.map(files, fn file ->
          case Integer.parse(Path.rootname(Path.basename(file))) do
            {version, "_" <> name}
            when version > 0 and version <= 9_223_372_036_854_775_807 and name != "" ->
              {version, name}

            _ ->
              :invalid
          end
        end)

      if :invalid not in entries and
           length(Enum.uniq_by(entries, &elem(&1, 0))) == length(entries) and
           length(Enum.uniq_by(entries, &elem(&1, 1))) == length(entries),
         do: {:ok, entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()},
         else: :unavailable
    else
      :unavailable
    end
  end

  @doc false
  def normalize(snapshot), do: Metrics.normalize_postgres_snapshot(:metadata, snapshot)
  @doc false
  def publish(snapshot), do: Metrics.publish_postgres_snapshot(:metadata, snapshot)
  @doc false
  def guard(body, snapshot),
    do: Anime.Metrics.Exporter.guard_postgres_snapshot(body, :metadata, snapshot)
end
