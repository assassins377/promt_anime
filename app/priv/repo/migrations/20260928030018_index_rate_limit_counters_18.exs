defmodule Anime.Repo.Migrations.Index18 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create unique_index(
             :rate_limit_counters,
             [:scope, :subject, :window_seconds, :window_started_at],
             concurrently: true
           )
  end
end
