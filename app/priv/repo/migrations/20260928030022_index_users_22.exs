defmodule Anime.Repo.Migrations.Index22 do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create index(:users, [:deletion_requested_at],
             concurrently: true,
             where: "deletion_requested = true"
           )
  end
end
