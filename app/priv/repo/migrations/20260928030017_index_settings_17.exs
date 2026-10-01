defmodule Anime.Repo.Migrations.Index17 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create unique_index(:settings, [:key], concurrently: true)
  end
end
