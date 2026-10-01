defmodule Anime.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :citext, null: false
      add :nick, :citext, null: false
      add :hashed_password, :text, null: false
      add :email_confirmed_at, :utc_datetime_usec
      add :previous_nick, :citext
      add :previous_nick_until, :utc_datetime_usec
      add :nick_changed_at, :utc_datetime_usec
      add :avatar_key_320, :text
      add :avatar_key_80, :text
      add :locale, :text, null: false, default: "ru"
      add :role_id, references(:roles, type: :bigint, on_delete: :restrict), null: false
      add :status, :text, null: false, default: "active"
      add :block_reason, :text
      add :blocked_at, :utc_datetime_usec
      add :blocked_until, :utc_datetime_usec
      add :blocked_by_id, references(:users, type: :bigint, on_delete: :nilify_all)
      add :deletion_requested, :boolean, null: false, default: false
      add :deletion_requested_at, :utc_datetime_usec
      add :must_change_password, :boolean, null: false, default: false
      add :show_bookmarks_public, :boolean, null: false, default: true
      add :keep_watch_history, :boolean, null: false, default: true
      add :age_confirmed_at, :utc_datetime_usec
      add :consent_accepted_at, :utc_datetime_usec, null: false
      add :consent_version, :text, null: false
      add :show_continue_watching, :boolean, null: false, default: true
      add :supporter_until, :utc_datetime_usec
      add :last_voice_over_id, :bigint
      add :player_volume, :integer, null: false, default: 100
      add :player_quality, :text, null: false, default: "auto"
      add :subtitles_enabled, :boolean, null: false, default: false
      add :subtitle_language, :text
      add :subtitle_size, :text, null: false, default: "medium"
      add :autoplay_next, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end
  end
end
