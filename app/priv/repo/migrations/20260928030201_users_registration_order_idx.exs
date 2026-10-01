defmodule Anime.Repo.Migrations.UsersRegistrationOrder do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create index(:users, ["inserted_at DESC", "id DESC"],
             name: :users_registration_order_idx,
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:users, [], name: :users_registration_order_idx, concurrently: true)
  end
end
