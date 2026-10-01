defmodule Anime.Repo.Migrations.Index25 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create index(:audit_logs, [:user_id, :occurred_at], concurrently: true)
  end
end
