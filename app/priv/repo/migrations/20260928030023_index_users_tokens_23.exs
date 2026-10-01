defmodule Anime.Repo.Migrations.Index23 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create index(:users_tokens, [:user_id, :context], concurrently: true)
  end
end
