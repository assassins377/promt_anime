defmodule Anime.AdminLifecycleTest do
  use Anime.DataCase
  alias Anime.{Accounts, Audit}
  alias Anime.Accounts.{Administration, Activity, User, UserToken, Tokens, Lifecycle}
  alias Anime.Access.{Permission, RolePermission}

  test "operator deletion requires exact nick, revokes every token and sends no restoration link" do
    owner = role_user("owner")
    target = user()
    {:ok, {session, remember}} = Accounts.create_session(target, true, meta())
    Accounts.request_reset(target.email)
    jobs = Repo.aggregate(Oban.Job, :count)

    assert {:error, :nickname_mismatch} =
             Administration.request_deletion(owner, target.id, "other")

    assert Tokens.user(session)
    Phoenix.PubSub.subscribe(Anime.PubSub, "user:#{target.id}:access")
    assert {:ok, _} = Administration.request_deletion(owner, target.id, target.nick)
    assert_receive :access_changed
    u = Repo.get!(User, target.id)
    assert u.deletion_requested && u.deletion_requested_at
    refute Tokens.user(session)
    refute Tokens.find(remember, [:remember_me])
    refute Repo.exists?(from t in UserToken, where: t.user_id == ^target.id)
    assert Repo.aggregate(Oban.Job, :count) == jobs

    assert {:error, :already_requested} =
             Administration.request_deletion(owner, target.id, target.nick)

    assert Repo.get!(User, target.id).deletion_requested_at == u.deletion_requested_at

    assert {:error, :invalid_credentials} =
             Accounts.authenticate(target.nick, "InitialExample123", meta())

    assert {:ok, :not_due} = Lifecycle.delete_due_account(target.id)
    assert {:ok, _} = Administration.cancel_deletion(owner, target.id)
    refute Repo.get!(User, target.id).deletion_requested
    refute Tokens.user(session)
    assert {:error, :not_requested} = Administration.cancel_deletion(owner, target.id)

    logs =
      Repo.all(
        from a in Audit, where: a.action in ["account_delete_request", "account_delete_cancel"]
      )

    assert length(logs) == 2
    assert Enum.all?(logs, &(&1.user_id == owner.id && &1.object_id == to_string(target.id)))
  end

  test "cancellation invalidates a former self-service restore link and preserves blocking" do
    owner = role_user("owner")
    target = user()
    {:ok, _} = Accounts.request_deletion(target, "InitialExample123", target.nick)

    token =
      Repo.one!(
        from t in UserToken, where: t.user_id == ^target.id and t.context == :delete_cancel
      )

    raw = Tokens.mail_bytes(token) |> Base.url_encode64(padding: false)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(User, target.id), status: :blocked, block_reason: "spam")
    )

    assert {:ok, _} = Administration.cancel_deletion(owner, target.id)
    u = Repo.get!(User, target.id)
    refute u.deletion_requested
    assert u.status == :blocked && u.block_reason == "spam"
    assert {:error, :invalid_token} = Accounts.restore_account(raw)
    assert {:ok, _} = Administration.request_deletion(owner, target.id, target.nick)
    assert {:error, :invalid_token} = Accounts.restore_account(raw)
  end

  test "operator-requested deletion uses the existing 30-day cleanup and keeps the operator audit" do
    owner = role_user("owner")
    target = user()
    assert {:ok, _} = Administration.request_deletion(owner, target.id, target.nick)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(User, target.id),
        deletion_requested_at: DateTime.add(DateTime.utc_now(), -31 * 86400)
      )
    )

    assert {:ok, :deleted} = Lifecycle.delete_due_account(target.id)
    refute Repo.get(User, target.id)
    assert Repo.get!(User, owner.id)

    assert Repo.get_by!(Audit, action: "account_delete_request", user_id: owner.id).object_id ==
             to_string(target.id)

    final = Repo.get_by!(Audit, action: "account_delete_final")
    assert final.user_id == nil && String.starts_with?(final.actor_label, "deleted-")
  end

  test "operator edits three allowlisted fields atomically and does not touch password or consent" do
    owner = role_user("owner")
    target = user()

    target =
      Repo.update!(
        Ecto.Changeset.change(target,
          nick_changed_at: DateTime.utc_now(),
          email_confirmed_at: DateTime.utc_now()
        )
      )

    {:ok, {session, _}} = Accounts.create_session(target, true, meta())

    {:ok, _} =
      Accounts.request_email_change(target, "InitialExample123", %{email: "pending@example.com"})

    pending =
      Repo.one!(
        from t in UserToken, where: t.user_id == ^target.id and t.context == :change_email
      )

    raw = Tokens.mail_bytes(pending) |> Base.url_encode64(padding: false)
    jobs = Repo.aggregate(Oban.Job, :count)

    attrs = %{
      "nick" => "edited_reader",
      "email" => "EDITED@example.com",
      "locale" => "en",
      "role_id" => owner.role_id,
      "status" => "blocked",
      "hashed_password" => "forged",
      "password" => "ForgedPassword123",
      "consent_version" => "forged",
      "must_change_password" => true
    }

    assert {:ok, _} = Administration.edit(owner, target.id, attrs)
    u = Repo.get!(User, target.id)
    assert {u.nick, u.email, u.locale} == {"edited_reader", "edited@example.com", :en}
    assert u.role_id == target.role_id && u.status == :active

    assert u.hashed_password == target.hashed_password &&
             u.consent_version == target.consent_version

    refute u.must_change_password
    assert u.previous_nick == target.nick
    assert DateTime.diff(u.previous_nick_until, u.nick_changed_at) == 30 * 86400
    assert u.email_confirmed_at == nil
    refute Tokens.user(session)
    refute Repo.exists?(from t in UserToken, where: t.user_id == ^target.id)
    assert {:error, :invalid_token} = Accounts.confirm(raw)
    assert Repo.aggregate(Oban.Job, :count) == jobs

    logs =
      Repo.all(from a in Audit, where: a.action == "users.user.edit" and a.result == :success)

    assert length(logs) == 3

    assert Enum.map(logs, &Map.keys(&1.new_value)) |> List.flatten() |> Enum.sort() ==
             ~w(email locale nick)

    assert {:error, %Ecto.Changeset{}} = Accounts.change_nick(owner, %{nick: target.nick})
  end

  test "validation, duplicate email and reserved nick roll back every field and token change" do
    owner = role_user("owner")
    target = user()
    {:ok, {session, _}} = Accounts.create_session(target, false, meta())

    for attrs <- [
          %{"nick" => "admin"},
          %{"nick" => "valid_new_nick", "email" => owner.email, "locale" => "en"},
          %{"email" => "invalid", "locale" => "fr"}
        ] do
      assert {:error, %Ecto.Changeset{}} = Administration.edit(owner, target.id, attrs)
      u = Repo.get!(User, target.id)
      assert {u.nick, u.email, u.locale} == {target.nick, target.email, target.locale}
      assert Tokens.user(session)
    end

    refute Repo.exists?(
             from a in Audit, where: a.action == "users.user.edit" and a.result == :success
           )
  end

  test "stale editor baseline is refused and changing only locale preserves login" do
    owner = role_user("owner")
    target = user()
    {:ok, {raw, _}} = Accounts.create_session(target, false, meta())
    baseline = Map.take(target, [:nick, :email, :locale])

    assert {:ok, _} =
             Administration.edit(owner, target.id, %{"locale" => "en"}, %{
               expected_user_fields: baseline
             })

    assert Tokens.user(raw)

    assert {:error, :stale_account} =
             Administration.edit(owner, target.id, %{"nick" => "stale_nick", "locale" => "ru"}, %{
               expected_user_fields: baseline
             })

    assert Repo.get!(User, target.id).locale == :en
    assert Repo.get!(User, target.id).nick == target.nick
  end

  test "all operations protect self and stronger users; permissions are reread under the lock" do
    owner = role_user("owner")
    admin = role_user("admin")
    target = user()

    for operation <- [
          fn a, u -> Administration.edit(a, u.id, %{"locale" => "en"}) end,
          fn a, u -> Administration.request_deletion(a, u.id, u.nick) end,
          fn a, u -> Administration.cancel_deletion(a, u.id) end
        ] do
      assert {:error, :self_action} = operation.(owner, owner)
      assert {:error, :protected_owner} = operation.(admin, owner)
      assert {:error, :forbidden} = operation.(target, admin)
    end

    for code <- ~w(users.user.edit users.user.delete) do
      p = Repo.get_by!(Permission, code: code)

      Repo.delete_all(
        from rp in RolePermission,
          where: rp.role_id == ^admin.role_id and rp.permission_id == ^p.id
      )
    end

    assert {:error, :forbidden} = Administration.edit(admin, target.id, %{"locale" => "en"})
    assert {:error, :forbidden} = Administration.request_deletion(admin, target.id, target.nick)
    assert {:error, :forbidden} = Administration.cancel_deletion(admin, target.id)
  end

  test "activity is permission-gated and projects neither old/new values nor unrelated events" do
    reader = user()
    admin = role_user("admin")
    assert {:error, :forbidden} = Activity.list(reader)

    own =
      Audit.record(reader, "password_change", "User", reader.id, :success, %{
        ip: "203.0.113.9",
        old_value: %{email: "secret-old@example.test"},
        new_value: %{anything: "private"}
      })

    Audit.record(reader, "roles.matrix.edit", "Role", reader.role_id, :success)
    Audit.record(admin, "password_change", "User", admin.id, :success, %{ip: "203.0.113.9"})

    params = %{
      "user_id" => to_string(reader.id),
      "action" => ["password_change"],
      "result" => ["success"],
      "ip" => "203.0.113.9",
      "from" => Date.to_iso8601(Date.utc_today()),
      "to" => Date.to_iso8601(Date.utc_today())
    }

    {:ok, listing} = Activity.list(admin, params)
    assert Enum.map(listing.rows, & &1.id) == [own.id]
    refute Map.has_key?(hd(listing.rows), :old_value)
    refute Map.has_key?(hd(listing.rows), :new_value)
    {:ok, empty} = Activity.list(admin, %{"user_id" => "invalid"})
    assert empty.rows == []
    p = Repo.get_by!(Permission, code: "users.activity.view")

    Repo.delete_all(
      from rp in RolePermission, where: rp.role_id == ^admin.role_id and rp.permission_id == ^p.id
    )

    assert {:error, :forbidden} = Activity.list(admin, params)
  end

  test "activity paginates deterministically and keeps anonymized and failed-login records" do
    admin = role_user("admin")
    now = DateTime.utc_now()

    for _ <- 1..51 do
      Repo.insert!(%Audit{
        occurred_at: now,
        actor_label: "deleted-sample",
        action: "login",
        result: :denied,
        object_type: "User"
      })
    end

    {:ok, first} = Activity.list(admin, %{"action" => "login"})
    {:ok, last} = Activity.list(admin, %{"action" => "login", "page" => "2"})
    assert first.count == 51 && first.pages == 2
    assert length(first.rows) == 50 && length(last.rows) == 1
    ids = Enum.map(first.rows ++ last.rows, & &1.id)
    assert Enum.sort(ids, :desc) == ids
    assert Enum.all?(first.rows ++ last.rows, &(&1.actor_label == "deleted-sample"))
  end
end
