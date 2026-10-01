defmodule Anime.Repo.Migrations.Index26 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create index(:audit_logs, [:object_type, :object_id], concurrently: true)
  end
end
