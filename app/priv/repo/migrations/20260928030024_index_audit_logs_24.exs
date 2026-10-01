defmodule Anime.Repo.Migrations.Index24 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create index(:audit_logs, [:occurred_at], concurrently: true)
  end
end
