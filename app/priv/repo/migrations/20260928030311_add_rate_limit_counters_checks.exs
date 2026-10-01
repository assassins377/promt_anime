defmodule Anime.Repo.Migrations.AddRateLimitCountersChecks do
  use Ecto.Migration

  @checks [
    {:rate_limit_counters_scope_allowed,
     "scope IN ('login', 'login_ip', 'register', 'confirm_resend', 'password_reset', 'comment_post', 'rating_change', 'video_report', 'donation_create', 'feedback_create', 'feedback_reply', 'data_export', 'admin_test_email', 'admin_cron_run')"},
    {:rate_limit_counters_window_positive, "window_seconds > 0"},
    {:rate_limit_counters_count_nonnegative, "count >= 0"}
  ]

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, expression} <- @checks do
      create constraint(:rate_limit_counters, name, check: expression, validate: false)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '0'")

    for {name, _expression} <- @checks do
      drop constraint(:rate_limit_counters, name)
    end
  end
end
