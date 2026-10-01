-- Read-only preflight for queue 1 CHECK constraints; returns counts, never row data.
-- Run before migration against the target database. Every invalid_rows must be zero.
-- Do not repair/delete records automatically if a count is nonzero.
BEGIN READ ONLY;
SET LOCAL statement_timeout = '60s';
SELECT 'users' AS table_name, 'users_locale_allowed' AS constraint_name,
       count(*) AS invalid_rows FROM users WHERE (locale IN ('ru', 'en')) IS FALSE
UNION ALL
SELECT 'users' AS table_name, 'users_status_allowed' AS constraint_name,
       count(*) AS invalid_rows FROM users WHERE (status IN ('active', 'blocked')) IS FALSE
UNION ALL
SELECT 'users' AS table_name, 'users_player_quality_allowed' AS constraint_name,
       count(*) AS invalid_rows FROM users WHERE (player_quality IN ('auto', '360p', '480p', '720p', '1080p')) IS FALSE
UNION ALL
SELECT 'users' AS table_name, 'users_subtitle_size_allowed' AS constraint_name,
       count(*) AS invalid_rows FROM users WHERE (subtitle_size IN ('small', 'medium', 'large')) IS FALSE
UNION ALL
SELECT 'users' AS table_name, 'users_player_volume_range' AS constraint_name,
       count(*) AS invalid_rows FROM users WHERE (player_volume BETWEEN 0 AND 100) IS FALSE
UNION ALL
SELECT 'users' AS table_name, 'users_nick_length' AS constraint_name,
       count(*) AS invalid_rows FROM users WHERE (char_length(nick) BETWEEN 3 AND 32) IS FALSE
UNION ALL
SELECT 'users_tokens' AS table_name, 'users_tokens_context_allowed' AS constraint_name,
       count(*) AS invalid_rows FROM users_tokens WHERE (context IN ('session', 'remember_me', 'confirm', 'reset_password', 'change_email', 'delete_cancel')) IS FALSE
UNION ALL
SELECT 'users_tokens' AS table_name, 'users_tokens_hash_length' AS constraint_name,
       count(*) AS invalid_rows FROM users_tokens WHERE (octet_length(token) = 32) IS FALSE
UNION ALL
SELECT 'users_tokens' AS table_name, 'users_tokens_nonce_length' AS constraint_name,
       count(*) AS invalid_rows FROM users_tokens WHERE (issue_nonce IS NULL OR octet_length(issue_nonce) = 32) IS FALSE
UNION ALL
SELECT 'users_tokens' AS table_name, 'users_tokens_mail_nonce_required' AS constraint_name,
       count(*) AS invalid_rows FROM users_tokens WHERE (context NOT IN ('confirm', 'reset_password', 'change_email', 'delete_cancel') OR issue_nonce IS NOT NULL) IS FALSE
UNION ALL
SELECT 'permissions' AS table_name, 'permissions_group_allowed' AS constraint_name,
       count(*) AS invalid_rows FROM permissions WHERE ("group" IN ('admin', 'users', 'roles', 'moderation', 'content', 'video', 'blog', 'announcements', 'feedback', 'billing', 'audit', 'settings', 'system')) IS FALSE
UNION ALL
SELECT 'settings' AS table_name, 'settings_value_type_allowed' AS constraint_name,
       count(*) AS invalid_rows FROM settings WHERE (value_type IN ('string', 'integer', 'boolean', 'json')) IS FALSE
UNION ALL
SELECT 'settings' AS table_name, 'settings_group_allowed' AS constraint_name,
       count(*) AS invalid_rows FROM settings WHERE ("group" IN ('main', 'seo', 'email', 'registration', 'notifications', 'security')) IS FALSE
UNION ALL
SELECT 'audit_logs' AS table_name, 'audit_logs_result_allowed' AS constraint_name,
       count(*) AS invalid_rows FROM audit_logs WHERE (result IN ('success', 'denied', 'error')) IS FALSE
UNION ALL
SELECT 'rate_limit_counters' AS table_name, 'rate_limit_counters_scope_allowed' AS constraint_name,
       count(*) AS invalid_rows FROM rate_limit_counters WHERE (scope IN ('login', 'login_ip', 'register', 'confirm_resend', 'password_reset', 'comment_post', 'rating_change', 'video_report', 'donation_create', 'feedback_create', 'feedback_reply', 'data_export', 'admin_test_email', 'admin_cron_run')) IS FALSE
UNION ALL
SELECT 'rate_limit_counters' AS table_name, 'rate_limit_counters_window_positive' AS constraint_name,
       count(*) AS invalid_rows FROM rate_limit_counters WHERE (window_seconds > 0) IS FALSE
UNION ALL
SELECT 'rate_limit_counters' AS table_name, 'rate_limit_counters_count_nonnegative' AS constraint_name,
       count(*) AS invalid_rows FROM rate_limit_counters WHERE (count >= 0) IS FALSE
ORDER BY 1, 2;
COMMIT;

