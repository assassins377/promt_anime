defmodule Anime.Repo.Migrations.Index27 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create index(:audit_logs, [:result, :occurred_at], concurrently: true)
  end
end
