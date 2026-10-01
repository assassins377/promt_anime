defmodule Anime.Repo.Migrations.Index9 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create unique_index(:roles, [:code], concurrently: true)
  end
end
