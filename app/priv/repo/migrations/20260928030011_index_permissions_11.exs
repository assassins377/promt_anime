defmodule Anime.Repo.Migrations.Index11 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create unique_index(:permissions, [:code], concurrently: true)
  end
end
