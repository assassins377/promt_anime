defmodule Anime.Repo.Migrations.UsersRoleOrder do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create index(:users, ["role_id", "id"], name: :users_role_order_idx, concurrently: true)
  end

  def down do
    drop_if_exists index(:users, [], name: :users_role_order_idx, concurrently: true)
  end
end
