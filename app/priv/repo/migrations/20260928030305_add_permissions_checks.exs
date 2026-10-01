defmodule Anime.Repo.Migrations.AddPermissionsChecks do
  use Ecto.Migration

  @checks [
    {:permissions_group_allowed,
     "\"group\" IN ('admin', 'users', 'roles', 'moderation', 'content', 'video', 'blog', 'announcements', 'feedback', 'billing', 'audit', 'settings', 'system')"}
  ]

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, expression} <- @checks do
      create constraint(:permissions, name, check: expression, validate: false)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, _expression} <- @checks do
      drop constraint(:permissions, name)
    end
  end
end
