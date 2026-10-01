defmodule Anime.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs) do
      add :occurred_at, :utc_datetime_usec, null: false
      add :user_id, references(:users, type: :bigint, on_delete: :nilify_all)
      add :actor_label, :text, null: false
      add :role_code, :text
      add :ip, :text
      add :action, :text, null: false
      add :object_type, :text, null: false
      add :object_id, :text
      add :old_value, :map
      add :new_value, :map
      add :result, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
