defmodule Anime.Repo.Migrations.CreateUsersTokens do
  use Ecto.Migration

  def change do
    create table(:users_tokens) do
      add :user_id, references(:users, type: :bigint, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :issue_nonce, :binary
      add :context, :text, null: false
      add :sent_to, :text
      add :ip, :text
      add :user_agent, :text
      add :last_used_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
