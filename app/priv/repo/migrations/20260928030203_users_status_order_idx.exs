defmodule Anime.Repo.Migrations.UsersStatusOrder do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create index(:users, ["status", "id"], name: :users_status_order_idx, concurrently: true)
  end

  def down do
    drop_if_exists index(:users, [], name: :users_status_order_idx, concurrently: true)
  end
end
