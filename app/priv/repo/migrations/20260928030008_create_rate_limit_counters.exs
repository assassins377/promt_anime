defmodule Anime.Repo.Migrations.CreateRateLimitCounters do
  use Ecto.Migration

  def change do
    create table(:rate_limit_counters) do
      add :scope, :text, null: false
      add :subject, :text, null: false
      add :window_started_at, :utc_datetime_usec, null: false
      add :window_seconds, :integer, null: false
      add :count, :integer, null: false, default: 0
      add :blocked_until, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
  end
end
