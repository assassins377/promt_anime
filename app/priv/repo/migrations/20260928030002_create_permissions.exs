defmodule Anime.Repo.Migrations.CreatePermissions do
  use Ecto.Migration

  def change do
    create table(:permissions) do
      add :code, :text, null: false
      add :name, :text, null: false
      add :group, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
