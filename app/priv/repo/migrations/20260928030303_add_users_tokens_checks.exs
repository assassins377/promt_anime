defmodule Anime.Repo.Migrations.AddUsersTokensChecks do
  use Ecto.Migration

  @checks [
    {:users_tokens_context_allowed,
     "context IN ('session', 'remember_me', 'confirm', 'reset_password', 'change_email', 'delete_cancel')"},
    {:users_tokens_hash_length, "octet_length(token) = 32"},
    {:users_tokens_nonce_length, "issue_nonce IS NULL OR octet_length(issue_nonce) = 32"},
    {:users_tokens_mail_nonce_required,
     "context NOT IN ('confirm', 'reset_password', 'change_email', 'delete_cancel') OR issue_nonce IS NOT NULL"}
  ]

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, expression} <- @checks do
      create constraint(:users_tokens, name, check: expression, validate: false)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, _expression} <- @checks do
      drop constraint(:users_tokens, name)
    end
  end
end
