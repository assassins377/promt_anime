defmodule Anime.Repo.Migrations.ValidateUsersChecks do
  use Ecto.Migration

  @checks [
    {:users_locale_allowed, "locale IN ('ru', 'en')"},
    {:users_status_allowed, "status IN ('active', 'blocked')"},
    {:users_player_quality_allowed,
     "player_quality IN ('auto', '360p', '480p', '720p', '1080p')"},
    {:users_subtitle_size_allowed, "subtitle_size IN ('small', 'medium', 'large')"},
    {:users_player_volume_range, "player_volume BETWEEN 0 AND 100"},
    {:users_nick_length, "char_length(nick) BETWEEN 3 AND 32"}
  ]

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, _expression} <- @checks do
      execute("ALTER TABLE users VALIDATE CONSTRAINT #{name}")
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    # Restore NOT VALID while still enforcing the check on new writes.
    # The transaction keeps drop/recreate invisible to other connections.
    for {name, expression} <- @checks do
      drop constraint(:users, name)
      create constraint(:users, name, check: expression, validate: false)
    end
  end
end
