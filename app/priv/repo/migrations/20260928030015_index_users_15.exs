defmodule Anime.Repo.Migrations.Index15 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create unique_index(:users, [:previous_nick], concurrently: true)
  end
end
