defmodule Anime.Repo.Migrations.Index20 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create index(:users, [:status, :inserted_at], concurrently: true)
  end
end
