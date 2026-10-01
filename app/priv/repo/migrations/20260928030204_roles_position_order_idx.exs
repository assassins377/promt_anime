defmodule Anime.Repo.Migrations.RolesPositionOrder do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create index(:roles, ["position", "id"], name: :roles_position_order_idx, concurrently: true)
  end

  def down do
    drop_if_exists index(:roles, [], name: :roles_position_order_idx, concurrently: true)
  end
end
