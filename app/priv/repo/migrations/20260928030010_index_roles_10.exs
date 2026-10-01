defmodule Anime.Repo.Migrations.Index10 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create unique_index(:roles, [:is_default], concurrently: true, where: "is_default = true")
  end
end
