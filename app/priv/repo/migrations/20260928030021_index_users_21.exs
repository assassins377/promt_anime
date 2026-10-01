defmodule Anime.Repo.Migrations.Index21 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create index(:users, [:blocked_until], concurrently: true, where: "status = 'blocked'")
  end
end
