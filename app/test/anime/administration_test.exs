defmodule Anime.AdministrationTest do
  use Anime.DataCase
  alias Anime.Accounts.{Administration, User, UserToken, Tokens}
  alias Anime.Access.{Role, Permission, RolePermission}
  alias Anime.{Accounts, Audit}

  test "every context entrypoint rejects ordinary users and stale actors" do
    u = user()
    target = user()
    assert {:error, :forbidden} = Administration.list(u)
    assert {:error, :forbidden} = Administration.get(u, target.id)
    assert {:error, :forbidden} = Administration.ban(u, target.id, ban_attrs())
    assert {:error, :forbidden} = Administration.unban(u, target.id)
    assert {:error, :forbidden} = Administration.change_role(u, target.id, u.role_id)
    assert {:error, :forbidden} = Administration.revoke_sessions(u, target.id)
    owner = role_user("owner")
    Repo.update!(Ecto.Changeset.change(owner, status: :blocked))
    assert {:error, :forbidden} = Administration.ban(owner, target.id, ban_attrs())
    assert Repo.get!(User, target.id).status == :active
  end

  test "ban is atomic with revocation, audit, optional mail and pubsub; unban retains reason" do
    owner = role_user("owner")
    target = user()
    {:ok, {raw, remember}} = Accounts.create_session(target, true, meta())
    Phoenix.PubSub.subscribe(Anime.PubSub, "user:#{target.id}:access")

    assert {:ok, _} =
             Administration.ban(owner, target.id, Map.put(ban_attrs(), "notify", "true"), meta())

    assert_receive :access_changed
    blocked = Repo.get!(User, target.id)
    assert blocked.status == :blocked
    assert blocked.blocked_by_id == owner.id
    assert DateTime.diff(blocked.blocked_until, blocked.blocked_at) == 86400
    refute Tokens.user(raw)
    refute Tokens.find(remember, [:remember_me])

    assert Repo.exists?(
             from t in UserToken, where: t.user_id == ^target.id and t.context == :confirm
           )

    assert {:error, :forbidden} = Accounts.create_session(target, false, meta())
    audit = Repo.get_by!(Audit, action: "users.user.ban", result: :success)
    assert audit.old_value["status"] == "active"
    assert audit.new_value["status"] == "blocked"

    assert Repo.exists?(
             from j in Oban.Job, where: fragment("?->>'kind'", j.args) == "account_blocked"
           )

    assert {:ok, _} = Administration.unban(owner, target.id)
    active = Repo.get!(User, target.id)
    assert active.status == :active
    assert active.block_reason == blocked.block_reason

    assert is_nil(active.blocked_at) && is_nil(active.blocked_until) &&
             is_nil(active.blocked_by_id)

    refute Tokens.user(raw)

    assert Repo.exists?(
             from j in Oban.Job, where: fragment("?->>'kind'", j.args) == "login_after_block"
           )
  end

  test "invalid ban form changes neither account nor tokens nor mail jobs" do
    owner = role_user("owner")
    target = user()
    {:ok, {raw, _}} = Accounts.create_session(target, false, meta())

    for attrs <- [
          %{"reason" => "injected", "days" => "1"},
          %{"reason" => "other", "comment" => "short", "days" => "1"},
          %{"reason" => "spam", "days" => "3651"},
          %{"reason" => "spam", "days" => "1.5"}
        ] do
      assert {:error, _} = Administration.ban(owner, target.id, attrs)
      assert Tokens.user(raw)
      assert Repo.get!(User, target.id).status == :active
    end

    assert {:ok, _} =
             Administration.ban(owner, target.id, %{
               "reason" => "other",
               "comment" => "Detailed operator reason",
               "permanent" => "true"
             })

    assert is_nil(Repo.get!(User, target.id).blocked_until)
  end

  test "self actions, owner and privilege escalation are guarded in the context" do
    owner = role_user("owner")
    admin = role_user("admin")
    target = user()

    for operation <- [
          fn -> Administration.ban(owner, owner.id, ban_attrs()) end,
          fn -> Administration.change_role(owner, owner.id, target.role_id) end,
          fn -> Administration.revoke_sessions(owner, owner.id) end
        ] do
      assert {:error, :self_action} = operation.()
    end

    assert {:error, :protected_owner} = Administration.ban(admin, owner.id, ban_attrs())

    assert {:error, :protected_owner} =
             Administration.change_role(admin, owner.id, target.role_id)

    assert {:error, :privilege_escalation} =
             Administration.change_role(admin, target.id, owner.role_id)

    moderator = Repo.get_by!(Role, code: "comment_moderator")
    admin = Repo.update!(Ecto.Changeset.change(admin, role_id: moderator.id))
    editor = Repo.get_by!(Role, code: "content_editor")
    Repo.update!(Ecto.Changeset.change(target, role_id: editor.id))
    assert {:error, :privilege_escalation} = Administration.ban(admin, target.id, ban_attrs())
  end

  test "role changes preserve tokens, audit old/new codes, deny revoked web permissions" do
    owner = role_user("owner")
    admin = role_user("admin")
    target = user()
    {:ok, {raw, _}} = Accounts.create_session(target, false, meta())
    editor = Repo.get_by!(Role, code: "content_editor")
    assert {:ok, _} = Administration.change_role(owner, target.id, editor.id)
    assert Tokens.user(raw).role.code == "content_editor"
    audit = Repo.get_by!(Audit, action: "users.role.assign", result: :success)
    assert audit.old_value == %{"role" => "user"}
    assert audit.new_value == %{"role" => "content_editor"}
    p = Repo.get_by!(Permission, code: "admin.panel.access")

    Repo.delete_all(
      from rp in RolePermission, where: rp.role_id == ^admin.role_id and rp.permission_id == ^p.id
    )

    assert {:error, :forbidden} =
             Administration.ban(admin, target.id, ban_attrs(), %{
               required_permissions: ["admin.panel.access", "users.user.view"]
             })

    assert Repo.get!(User, target.id).status == :active
  end

  test "single and bulk revoke are scoped by owner and context, no hashes in detail" do
    owner = role_user("owner")
    target = user()
    outsider = user()
    {:ok, {raw, remember}} = Accounts.create_session(target, true, meta())
    {:ok, {foreign, _}} = Accounts.create_session(outsider, false, meta())
    id = Tokens.find(raw, [:session]).id

    confirm =
      Repo.one!(from t in UserToken, where: t.user_id == ^target.id and t.context == :confirm)

    assert {:error, :not_found} = Administration.revoke_sessions(owner, target.id, confirm.id)

    assert {:error, :not_found} =
             Administration.revoke_sessions(owner, target.id, Tokens.find(foreign, [:session]).id)

    {:ok, detail} = Administration.get(owner, target.id)
    refute Map.has_key?(detail.user, :hashed_password)
    assert detail.session_count == 2
    refute Map.has_key?(detail, :sessions)
    {:ok, sessions} = Administration.sessions(owner, target.id)
    assert Enum.all?(sessions.rows, &(!Map.has_key?(&1, :token)))
    assert {:ok, _} = Administration.revoke_sessions(owner, target.id, id)
    refute Tokens.user(raw)
    assert Tokens.find(remember, [:remember_me])
    assert {:ok, _} = Administration.revoke_sessions(owner, target.id)
    refute Tokens.find(remember, [:remember_me])
    assert Tokens.user(foreign)
    assert Repo.get(UserToken, confirm.id)

    logs =
      Repo.all(
        from a in Audit,
          where: a.action == "users.session.revoke" and a.result == :success,
          order_by: a.id
      )

    assert Enum.map(logs, &{&1.old_value["sessions"], &1.new_value["sessions"]}) == [
             {2, 1},
             {1, 0}
           ]
  end

  test "expiry worker rechecks deadlines and never restores deletion-requested access" do
    owner = role_user("owner")
    target = user()
    assert {:ok, _} = Administration.ban(owner, target.id, ban_attrs())
    assert {:error, :not_due} = Administration.unblock_expired(target.id)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(User, target.id),
        blocked_until: DateTime.add(DateTime.utc_now(), -10),
        deletion_requested: true,
        deletion_requested_at: DateTime.utc_now()
      )
    )

    assert :ok = Anime.Workers.UnblockUsers.perform(%Oban.Job{})
    u = Repo.get!(User, target.id)
    assert u.status == :active && u.deletion_requested
    refute User.active?(u)
    assert {:error, :not_due} = Administration.unblock_expired(target.id)

    assert Repo.aggregate(
             from(a in Audit, where: a.action == "users.user.unban" and a.result == :success),
             :count
           ) == 1
  end

  test "SQL search filters old nick, role, status and literal wildcards without exposing hashes" do
    owner = role_user("owner")
    target = user(%{"nick" => "read_underscore"})

    Repo.update!(
      Ecto.Changeset.change(target,
        previous_nick: "OldReader",
        previous_nick_until: DateTime.add(DateTime.utc_now(), 86400)
      )
    )

    {:ok, found} = Administration.list(owner, %{"q" => "oldreader"})
    assert Enum.map(found.rows, & &1.id) == [target.id]
    {:ok, found} = Administration.list(owner, %{"q" => "read_"})
    assert Enum.map(found.rows, & &1.id) == [target.id]
    {:ok, found} = Administration.list(owner, %{"q" => "%_"})
    assert found.rows == []
    assert {:ok, _} = Administration.ban(owner, target.id, ban_attrs())

    {:ok, found} =
      Administration.list(owner, %{
        "status" => ["blocked"],
        "role" => to_string(target.role_id),
        "sort" => "role",
        "page" => "999",
        "from" => "invalid"
      })

    assert length(found.rows) == 1 && found.page == 1
    refute Map.has_key?(hd(found.rows), :hashed_password)
    assert {:error, :not_found} = Administration.get(owner, "not-an-id")
  end

  test "paged users order is stable and limited to fifty" do
    owner = role_user("owner")
    role = Repo.get_by!(Role, code: "user")
    now = DateTime.utc_now()

    rows =
      for i <- 1..55,
          do: %{
            nick: "page_user_#{i}",
            email: "page#{i}@example.test",
            hashed_password: "not-a-real-password",
            role_id: role.id,
            consent_accepted_at: now,
            consent_version: "test",
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all(User, rows)
    {:ok, first} = Administration.list(owner, %{"q" => "page_user_", "sort" => "inserted_at"})

    {:ok, second} =
      Administration.list(owner, %{"q" => "page_user_", "sort" => "inserted_at", "page" => "2"})

    assert length(first.rows) == 50 && length(second.rows) == 5
    assert first.count == 55 && first.pages == 2
    ids = Enum.map(first.rows ++ second.rows, & &1.id)
    assert ids == Enum.sort(ids, :desc)
    assert length(Enum.uniq(ids)) == 55
  end

  test "assignable choices omit owner and unavailable grants" do
    admin = role_user("admin")
    target = user()
    {:ok, detail} = Administration.get(admin, target.id)
    refute Enum.any?(detail.roles, &(&1.code == "owner"))
    assert Enum.any?(detail.roles, &(&1.code == "user"))
    assert {:error, :not_found} = Administration.change_role(admin, target.id, "bad")
  end

  test "mail worker sends recorded security notices even for blocked accounts" do
    import Swoosh.TestAssertions
    owner = role_user("owner")
    target = user()
    {:ok, _} = Administration.ban(owner, target.id, Map.put(ban_attrs(), "notify", "true"))

    job =
      Repo.one!(from j in Oban.Job, where: fragment("?->>'kind'", j.args) == "account_blocked")

    assert :ok = Anime.Workers.Mail.perform(job)
    assert_email_sent(subject: "Аккаунт заблокирован", to: [{"", target.email}])
    {:ok, _} = Administration.unban(owner, target.id)

    job =
      Repo.one!(from j in Oban.Job, where: fragment("?->>'kind'", j.args) == "login_after_block")

    assert :ok = Anime.Workers.Mail.perform(job)
    assert_email_sent(subject: "Доступ восстановлен", to: [{"", target.email}])
  end

  defp ban_attrs, do: %{"reason" => "spam", "days" => "1", "comment" => ""}

  test "expiry processes more than one batch, leaving permanent and extended blocks" do
    role = Repo.get_by!(Role, code: "user")
    now = DateTime.utc_now()
    due = DateTime.add(now, -100)

    for i <- 1..202 do
      %User{
        nick: "expiry_#{i}",
        email: "expiry#{i}@example.test",
        hashed_password: "not-a-real-password",
        role_id: role.id,
        status: :blocked,
        blocked_at: due,
        blocked_until: due,
        consent_accepted_at: now,
        consent_version: "test"
      }
      |> Repo.insert!()
    end

    target = user()
    target = Repo.update!(Ecto.Changeset.change(target, status: :blocked, blocked_until: nil))
    assert :ok = Anime.Workers.UnblockUsers.perform(%Oban.Job{})
    assert Repo.aggregate(from(u in User, where: u.status == :blocked), :count) == 1
    assert Repo.get!(User, target.id).status == :blocked

    assert Repo.aggregate(
             from(a in Audit, where: a.action == "users.user.unban" and a.result == :success),
             :count
           ) == 202
  end
end
