defmodule Anime.Repo.Migrations.UsersBlockOrder do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create index(:users, ["blocked_at DESC NULLS LAST", "id DESC"],
             name: :users_block_order_idx,
             concurrently: true,
             where: "status = 'blocked'"
           )
  end

  def down do
    drop_if_exists index(:users, [], name: :users_block_order_idx, concurrently: true)
  end
end
