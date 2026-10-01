defmodule Anime.Repo.Migrations.Index19 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create index(:users, [:role_id], concurrently: true)
  end
end
