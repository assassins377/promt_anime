defmodule Anime.Repo.Migrations.CreateRolePermissions do
  use Ecto.Migration

  def change do
    create table(:role_permissions) do
      add :role_id, references(:roles, type: :bigint, on_delete: :delete_all), null: false

      add :permission_id, references(:permissions, type: :bigint, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
