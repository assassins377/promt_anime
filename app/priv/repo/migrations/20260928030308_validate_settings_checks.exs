defmodule Anime.Repo.Migrations.ValidateSettingsChecks do
  use Ecto.Migration

  @checks [
    {:settings_value_type_allowed, "value_type IN ('string', 'integer', 'boolean', 'json')"},
    {:settings_group_allowed,
     "\"group\" IN ('main', 'seo', 'email', 'registration', 'notifications', 'security')"}
  ]

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, _expression} <- @checks do
      execute("ALTER TABLE settings VALIDATE CONSTRAINT #{name}")
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    # Restore NOT VALID while still enforcing the check on new writes.
    # The transaction keeps drop/recreate invisible to other connections.
    for {name, expression} <- @checks do
      drop constraint(:settings, name)
      create constraint(:settings, name, check: expression, validate: false)
    end
  end
end
