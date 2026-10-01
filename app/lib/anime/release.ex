defmodule Anime.Release.MigrationRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :anime, adapter: Ecto.Adapters.Postgres
end

defmodule Anime.Release do
  @moduledoc "Offline release commands. Migrations use their own URL; seed uses the application role."
  alias Anime.Release.MigrationRepo

  def migrate, do: run(:up, all: true)

  @doc "Explicit storage provisioning, independent of the database and CORS."
  def storage_setup do
    Application.load(:anime)
    offline!()
    {:ok, _} = Application.ensure_all_started(:ex_aws)
    {:ok, _} = Application.ensure_all_started(:req)
    Anime.Storage.Setup.run()
  end

  @doc "Seed through DATABASE_URL without starting Endpoint, Oban or Anime."
  def seed do
    Application.load(:anime)
    offline!()

    for key <- ~w(ADMIN_EMAIL ADMIN_NICK ADMIN_PASSWORD) do
      unless is_binary(System.get_env(key)) and String.trim(System.get_env(key)) != "",
        do: raise(ArgumentError, "#{key}: required")
    end

    {:ok, _} = Application.ensure_all_started(:bcrypt_elixir)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    previous = Application.fetch_env!(:anime, Anime.Repo)
    Application.put_env(:anime, Anime.Repo, Keyword.put(previous, :log, false))

    try do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(Anime.Repo, fn _ ->
          {:ok, supervisor} =
            Supervisor.start_link(
              [
                {Phoenix.PubSub, name: Anime.PubSub},
                Anime.Cache,
                Anime.Passwords
              ],
              strategy: :one_for_one
            )

          try do
            Anime.Seeds.owner!()
          after
            Supervisor.stop(supervisor)
          end
        end)

      result
    after
      Application.put_env(:anime, Anime.Repo, previous)
    end
  end

  def rollback(Anime.Repo, version) when is_integer(version) and version >= 0,
    do: run(:down, to_exclusive: version)

  def rollback(_, _), do: raise(ArgumentError, "Expected Anime.Repo and a nonnegative version")

  defp run(direction, options) do
    Application.load(:anime)

    offline!()

    url = System.get_env("MIGRATION_DATABASE_URL")
    ssl = Anime.RuntimeConfig.migration_database!(url) || false
    previous = Application.get_env(:anime, MigrationRepo)

    Application.put_env(:anime, MigrationRepo,
      url: url,
      ssl: ssl,
      pool_size: 2,
      priv: "priv/repo",
      log: false,
      show_sensitive_data_on_connection_error: false,
      parameters: [lock_timeout: "5000", statement_timeout: "0"],
      migration_lock: :pg_advisory_lock
    )

    try do
      {:ok, versions, _} =
        Ecto.Migrator.with_repo(MigrationRepo, fn repo ->
          Ecto.Migrator.run(repo, direction, options)
        end)

      versions
    after
      if previous,
        do: Application.put_env(:anime, MigrationRepo, previous),
        else: Application.delete_env(:anime, MigrationRepo)
    end
  end

  defp offline! do
    if Enum.any?(
         [
           Anime.Supervisor,
           Anime.Repo,
           MigrationRepo,
           Anime.PubSub,
           Anime.Cache,
           Anime.Passwords
         ],
         &Process.whereis/1
       ),
       do: raise(ArgumentError, "Run commands in a separate release eval process")
  end
end
