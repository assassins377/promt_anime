defmodule Anime.Repo.Migrations.Index16 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create unique_index(:users_tokens, [:context, :token], concurrently: true)
  end
end
