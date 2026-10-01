defmodule Anime.Repo.Migrations.Index14 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create unique_index(:users, [:nick], concurrently: true)
  end
end
