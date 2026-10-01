defmodule Anime.Repo.Migrations.AddAuditLogsChecks do
  use Ecto.Migration

  @checks [
    {:audit_logs_result_allowed, "result IN ('success', 'denied', 'error')"}
  ]

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, expression} <- @checks do
      create constraint(:audit_logs, name, check: expression, validate: false)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, _expression} <- @checks do
      drop constraint(:audit_logs, name)
    end
  end
end
