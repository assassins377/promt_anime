defmodule Anime.Repo.Migrations.ValidateAuditLogsChecks do
  use Ecto.Migration

  @checks [
    {:audit_logs_result_allowed, "result IN ('success', 'denied', 'error')"}
  ]

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, _expression} <- @checks do
      execute("ALTER TABLE audit_logs VALIDATE CONSTRAINT #{name}")
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    # Restore NOT VALID while still enforcing the check on new writes.
    # The transaction keeps drop/recreate invisible to other connections.
    for {name, expression} <- @checks do
      drop constraint(:audit_logs, name)
      create constraint(:audit_logs, name, check: expression, validate: false)
    end
  end
end
