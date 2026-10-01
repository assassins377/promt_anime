defmodule AnimeWeb.HealthController do
  use AnimeWeb, :controller
  def live(conn, _), do: text(conn, "ok")

  def ready(conn, _) do
    failed =
      Anime.Shutdown.failures(fn ->
        [database: database(), migrations: migrations(), storage: storage()]
      end)

    conn
    |> put_status(if(failed == [], do: 200, else: 503))
    |> json(%{ready: failed == [], failed: failed})
  end

  def robots(conn, _), do: text(conn, "User-agent: *\nDisallow: /\n")

  defp database do
    match?({:ok, _}, Ecto.Adapters.SQL.query(Anime.Repo, "SELECT 1", [], timeout: 2000))
  rescue
    _ -> false
  end

  defp migrations do
    Ecto.Migrator.migrations(Anime.Repo, Ecto.Migrator.migrations_path(Anime.Repo),
      skip_table_creation: true
    )
    |> Enum.all?(fn {status, _, _} -> status == :up end)
  rescue
    _ -> false
  end

  defp storage do
    Anime.Storage.Readiness.ready?()
  rescue
    _ -> false
  end
end
