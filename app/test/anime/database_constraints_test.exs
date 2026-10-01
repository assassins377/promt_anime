defmodule Anime.DatabaseConstraintsTest do
  use Anime.DataCase

  alias Anime.Accounts.{User, UserToken}
  alias Anime.Access.{Permission, Role, RolePermission}
  alias Anime.Settings.Setting
  alias Ecto.Adapters.SQL

  @checks ~w(
    users_locale_allowed users_status_allowed users_player_quality_allowed
    users_subtitle_size_allowed users_player_volume_range users_nick_length
    users_tokens_context_allowed users_tokens_hash_length users_tokens_nonce_length
    users_tokens_mail_nonce_required permissions_group_allowed
    settings_value_type_allowed settings_group_allowed audit_logs_result_allowed
    rate_limit_counters_scope_allowed rate_limit_counters_window_positive
    rate_limit_counters_count_nonnegative
  )

  # Direct SQL deliberately bypasses all changesets. Savepoints keep each expected
  # PostgreSQL error from aborting the surrounding Sandbox transaction.
  defp sql(statement, params \\ []) do
    SQL.query(Repo, statement, params, mode: :savepoint)
  end

  defp rejects(statement, params, code, constraint \\ nil) do
    assert {:error, %Postgrex.Error{postgres: error}} = sql(statement, params)
    assert error.code == code
    if constraint, do: assert(error.constraint == constraint)
  end

  defp enum_row(Anime.Audit) do
    Anime.Audit.record(nil, "database_check", "User", nil, :success)
  end

  defp enum_row(schema), do: Repo.one!(from row in schema, limit: 1)

  test "all seventeen domain checks are validated on the database, not just Ecto" do
    assert {:ok, %{rows: rows}} =
             sql("""
             SELECT conname, convalidated FROM pg_constraint
             WHERE connamespace = 'public'::regnamespace AND contype = 'c'
               AND conrelid::regclass::text IN
                 ('users', 'users_tokens', 'permissions', 'settings', 'audit_logs', 'rate_limit_counters')
             ORDER BY conname
             """)

    assert rows == Enum.map(Enum.sort(@checks), &[&1, true])
  end

  for {field, invalid, constraint} <- [
        {:locale, "de", "users_locale_allowed"},
        {:status, "deleted", "users_status_allowed"},
        {:player_quality, "4k", "users_player_quality_allowed"},
        {:subtitle_size, "huge", "users_subtitle_size_allowed"}
      ] do
    test "users.#{field} rejects unknown values and accepts every Ecto enum value" do
      u = user()
      statement = "UPDATE users SET #{unquote(field)} = $1 WHERE id = $2"

      rejects(statement, [unquote(invalid), u.id], :check_violation, unquote(constraint))
      rejects(statement, [nil, u.id], :not_null_violation)

      for value <- Ecto.Enum.dump_values(User, unquote(field)) do
        assert {:ok, %{num_rows: 1}} = sql(statement, [value, u.id])
      end
    end
  end

  test "volume and nickname enforce both boundaries, without inventing lifecycle rules" do
    u = user()

    for volume <- [-1, 101] do
      rejects(
        "UPDATE users SET player_volume = $1 WHERE id = $2",
        [volume, u.id],
        :check_violation,
        "users_player_volume_range"
      )
    end

    for volume <- [0, 100] do
      assert {:ok, %{num_rows: 1}} =
               sql("UPDATE users SET player_volume = $1 WHERE id = $2", [volume, u.id])
    end

    for nick <- ["", "ab", String.duplicate("x", 33)] do
      rejects(
        "UPDATE users SET nick = $1 WHERE id = $2",
        [nick, u.id],
        :check_violation,
        "users_nick_length"
      )
    end

    for nick <- ["abc", String.duplicate("x", 32)] do
      assert {:ok, %{num_rows: 1}} = sql("UPDATE users SET nick = $1 WHERE id = $2", [nick, u.id])
    end

    # Optional dates remain optional, as specified by the domain.
    assert {:ok, %{num_rows: 1}} =
             sql(
               "UPDATE users SET status = 'blocked', blocked_at = NULL, blocked_until = NULL WHERE id = $1",
               [u.id]
             )
  end

  test "token contexts match Ecto and mail contexts require their nonce" do
    u = user()
    t = Repo.get_by!(UserToken, user_id: u.id, context: :confirm)

    rejects(
      "UPDATE users_tokens SET context = $1 WHERE id = $2",
      ["admin", t.id],
      :check_violation,
      "users_tokens_context_allowed"
    )

    for context <- Ecto.Enum.dump_values(UserToken, :context) do
      assert {:ok, %{num_rows: 1}} =
               sql("UPDATE users_tokens SET context = $1 WHERE id = $2", [context, t.id])

      if context in ~w(confirm reset_password change_email delete_cancel) do
        rejects(
          "UPDATE users_tokens SET issue_nonce = NULL WHERE id = $1",
          [t.id],
          :check_violation,
          "users_tokens_mail_nonce_required"
        )
      end
    end

    for context <- ~w(session remember_me) do
      assert {:ok, %{num_rows: 1}} =
               sql("UPDATE users_tokens SET context = $1, issue_nonce = NULL WHERE id = $2", [
                 context,
                 t.id
               ])
    end
  end

  test "hash and optional nonce have exactly thirty-two bytes" do
    u = user()
    t = Repo.get_by!(UserToken, user_id: u.id, context: :confirm)

    for {field, name} <- [
          {"token", "users_tokens_hash_length"},
          {"issue_nonce", "users_tokens_nonce_length"}
        ],
        size <- [0, 31, 33] do
      rejects(
        "UPDATE users_tokens SET #{field} = $1 WHERE id = $2",
        [:binary.copy(<<0>>, size), t.id],
        :check_violation,
        name
      )
    end

    assert {:ok, %{num_rows: 1}} =
             sql(
               "UPDATE users_tokens SET token = $1, issue_nonce = $2 WHERE id = $3",
               [:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(32), t.id]
             )
  end

  for {schema, field, constraint} <- [
        {Permission, :group, "permissions_group_allowed"},
        {Setting, :group, "settings_group_allowed"},
        {Setting, :value_type, "settings_value_type_allowed"},
        {Anime.Audit, :result, "audit_logs_result_allowed"}
      ] do
    test "#{inspect(schema)}.#{field} matches the closed enum including NOT NULL" do
      schema = unquote(schema)

      row = enum_row(schema)

      statement =
        "UPDATE #{schema.__schema__(:source)} SET \"#{unquote(field)}\" = $1 WHERE id = $2"

      rejects(statement, ["unknown", row.id], :check_violation, unquote(constraint))
      rejects(statement, [nil, row.id], :not_null_violation)

      for value <- Ecto.Enum.dump_values(schema, unquote(field)) do
        assert {:ok, %{num_rows: 1}} = sql(statement, [value, row.id])
      end
    end
  end

  test "rate windows must be positive, counters nonnegative and scopes known" do
    {:ok, %{rows: [[id]]}} =
      sql("""
      INSERT INTO rate_limit_counters
        (scope, subject, window_seconds, window_started_at, count, inserted_at, updated_at)
      VALUES ('register', 'constraint-probe', 3600, '2026-09-28', 0, now(), now()) RETURNING id
      """)

    for scope <-
          ~w(login login_ip register confirm_resend password_reset comment_post rating_change
                    video_report donation_create feedback_create feedback_reply data_export admin_test_email admin_cron_run) do
      assert {:ok, %{num_rows: 1}} =
               sql("UPDATE rate_limit_counters SET scope = $1 WHERE id = $2", [scope, id])
    end

    rejects(
      "UPDATE rate_limit_counters SET scope = 'search' WHERE id = $1",
      [id],
      :check_violation,
      "rate_limit_counters_scope_allowed"
    )

    for seconds <- [0, -1] do
      rejects(
        "UPDATE rate_limit_counters SET window_seconds = $1 WHERE id = $2",
        [seconds, id],
        :check_violation,
        "rate_limit_counters_window_positive"
      )
    end

    rejects(
      "UPDATE rate_limit_counters SET count = -1 WHERE id = $1",
      [id],
      :check_violation,
      "rate_limit_counters_count_nonnegative"
    )

    assert {:ok, %{num_rows: 1}} =
             sql("UPDATE rate_limit_counters SET count = 0, window_seconds = 1 WHERE id = $1", [
               id
             ])

    for column <- ~w(scope subject window_seconds window_started_at count) do
      rejects(
        "UPDATE rate_limit_counters SET #{column} = NULL WHERE id = $1",
        [id],
        :not_null_violation
      )
    end
  end

  test "different rate windows coexist at the same boundary; an exact duplicate cannot" do
    insert = """
    INSERT INTO rate_limit_counters
      (scope, subject, window_seconds, window_started_at, count, inserted_at, updated_at)
    VALUES ('comment_post', 'same-user', $1, '2026-09-28', 0, now(), now())
    """

    for seconds <- [30, 3600, 86400], do: assert({:ok, %{num_rows: 1}} = sql(insert, [seconds]))
    rejects(insert, [3600], :unique_violation)
  end

  test "foreign keys reject orphan rows and keep the intentional future voice-over exception" do
    u = user()
    t = Repo.get_by!(UserToken, user_id: u.id, context: :confirm)
    audit = Anime.Audit.record(u, "database_check", "User", u.id, :success)
    grant = Repo.one!(from rp in RolePermission, limit: 1)

    for {table, column, id, constraint} <- [
          {"users", "role_id", u.id, "users_role_id_fkey"},
          {"users", "blocked_by_id", u.id, "users_blocked_by_id_fkey"},
          {"users_tokens", "user_id", t.id, "users_tokens_user_id_fkey"},
          {"audit_logs", "user_id", audit.id, "audit_logs_user_id_fkey"},
          {"role_permissions", "role_id", grant.id, "role_permissions_role_id_fkey"},
          {"role_permissions", "permission_id", grant.id, "role_permissions_permission_id_fkey"}
        ] do
      rejects(
        "UPDATE #{table} SET #{column} = -1 WHERE id = $1",
        [id],
        :foreign_key_violation,
        constraint
      )
    end

    assert {:ok, %{rows: [[0]]}} =
             sql("""
             SELECT count(*) FROM pg_constraint c
             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
             WHERE c.conrelid = 'users'::regclass AND c.contype = 'f' AND a.attname = 'last_voice_over_id'
             """)
  end

  test "deleting a user cascades tokens but preserves audit and blocked-user records" do
    actor = user()
    target = user()
    audit = Anime.Audit.record(actor, "database_check", "User", target.id, :success)
    target |> Ecto.Changeset.change(blocked_by_id: actor.id) |> Repo.update!()
    assert Repo.exists?(from t in UserToken, where: t.user_id == ^actor.id)

    assert {:ok, %{num_rows: 1}} = sql("DELETE FROM users WHERE id = $1", [actor.id])
    refute Repo.exists?(from t in UserToken, where: t.user_id == ^actor.id)
    assert Repo.get!(Anime.Audit, audit.id).user_id == nil
    assert Repo.get!(User, target.id).blocked_by_id == nil
    # Privacy anonymization belongs to Accounts deletion, not a FK side effect.
    assert Repo.get!(Anime.Audit, audit.id).actor_label == actor.nick
  end

  test "assigned roles restrict deletion, join-table links cascade from either parent" do
    u = user()

    rejects(
      "DELETE FROM roles WHERE id = $1",
      [u.role_id],
      :restrict_violation,
      "users_role_id_fkey"
    )

    role = Repo.insert!(%Role{code: "constraint_test", name: "Custom", position: 99})
    permission = Repo.one!(from p in Permission, limit: 1)
    link = Repo.insert!(%RolePermission{role_id: role.id, permission_id: permission.id})
    assert {:ok, %{num_rows: 1}} = sql("DELETE FROM roles WHERE id = $1", [role.id])
    assert Repo.get(RolePermission, link.id) == nil
    assert Repo.get!(Permission, permission.id)

    role = Repo.get_by!(Role, code: "owner")
    link = Repo.get_by!(RolePermission, role_id: role.id, permission_id: permission.id)
    assert {:ok, %{num_rows: 1}} = sql("DELETE FROM permissions WHERE id = $1", [permission.id])
    assert Repo.get(RolePermission, link.id) == nil
    assert Repo.get!(Role, role.id)
  end

  test "case-insensitive user uniqueness and reserved old nick index survive changes" do
    a = user()
    b = user()

    for column <- ~w(email nick) do
      rejects(
        "UPDATE users SET #{column} = $1 WHERE id = $2",
        [a |> Map.fetch!(String.to_existing_atom(column)) |> String.upcase(), b.id],
        :unique_violation
      )
    end

    assert {:ok, _} =
             sql("UPDATE users SET previous_nick = 'ReservedOldNick' WHERE id = $1", [a.id])

    rejects(
      "UPDATE users SET previous_nick = 'reservedoldnick' WHERE id = $1",
      [b.id],
      :unique_violation
    )

    # Cross-column reservations are checked under locks by Accounts, not this index.
  end

  test "at most one default role and unique role, permission, setting and grant keys" do
    owner = Repo.get_by!(Role, code: "owner")
    default = Repo.get_by!(Role, is_default: true)
    rejects("UPDATE roles SET is_default = true WHERE id = $1", [owner.id], :unique_violation)

    rejects(
      "UPDATE roles SET code = $1 WHERE id = $2",
      [default.code, owner.id],
      :unique_violation
    )

    [p1, p2] = Repo.all(from p in Permission, order_by: p.id, limit: 2)
    rejects("UPDATE permissions SET code = $1 WHERE id = $2", [p1.code, p2.id], :unique_violation)
    [s1, s2] = Repo.all(from s in Setting, order_by: s.id, limit: 2)
    rejects("UPDATE settings SET key = $1 WHERE id = $2", [s1.key, s2.id], :unique_violation)

    rejects(
      """
      INSERT INTO role_permissions (role_id, permission_id, inserted_at, updated_at)
      SELECT role_id, permission_id, inserted_at, updated_at FROM role_permissions LIMIT 1
      """,
      [],
      :unique_violation
    )
  end

  test "token hashes are unique per context, not globally" do
    u = user()
    t = Repo.get_by!(UserToken, user_id: u.id, context: :confirm)

    insert = """
    INSERT INTO users_tokens
      (user_id, token, issue_nonce, context, expires_at, inserted_at, updated_at)
    SELECT user_id, token, issue_nonce, $1, expires_at, inserted_at, updated_at
    FROM users_tokens WHERE id = $2
    """

    rejects(insert, ["confirm", t.id], :unique_violation)
    assert {:ok, %{num_rows: 1}} = sql(insert, ["reset_password", t.id])
  end
end
