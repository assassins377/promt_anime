defmodule Anime.Repo.Migrations.Index12 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create unique_index(:role_permissions, [:role_id, :permission_id], concurrently: true)
  end
end
