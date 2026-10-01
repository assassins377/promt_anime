defmodule Anime.Repo.Migrations.ValidatePermissionsChecks do
  use Ecto.Migration

  @checks [
    {:permissions_group_allowed,
     "\"group\" IN ('admin', 'users', 'roles', 'moderation', 'content', 'video', 'blog', 'announcements', 'feedback', 'billing', 'audit', 'settings', 'system')"}
  ]

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, _expression} <- @checks do
      execute("ALTER TABLE permissions VALIDATE CONSTRAINT #{name}")
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    # Restore NOT VALID while still enforcing the check on new writes.
    # The transaction keeps drop/recreate invisible to other connections.
    for {name, expression} <- @checks do
      drop constraint(:permissions, name)
      create constraint(:permissions, name, check: expression, validate: false)
    end
  end
end
