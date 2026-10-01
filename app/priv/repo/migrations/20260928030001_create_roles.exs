defmodule Anime.Repo.Migrations.CreateRoles do
  use Ecto.Migration

  def change do
    create table(:roles) do
      add :code, :text, null: false
      add :name, :text, null: false
      add :system, :boolean, null: false, default: false
      add :is_default, :boolean, null: false, default: false
      add :show_badge, :boolean, null: false, default: false
      add :position, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
