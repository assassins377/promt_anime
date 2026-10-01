defmodule Anime.Repo.Migrations.AddSettingsChecks do
  use Ecto.Migration

  @checks [
    {:settings_value_type_allowed, "value_type IN ('string', 'integer', 'boolean', 'json')"},
    {:settings_group_allowed,
     "\"group\" IN ('main', 'seo', 'email', 'registration', 'notifications', 'security')"}
  ]

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, expression} <- @checks do
      create constraint(:settings, name, check: expression, validate: false)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, _expression} <- @checks do
      drop constraint(:settings, name)
    end
  end
end
