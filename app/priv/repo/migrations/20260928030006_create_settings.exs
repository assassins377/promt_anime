defmodule Anime.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :key, :text, null: false
      add :value, :text, null: false
      add :value_type, :text, null: false
      add :group, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
