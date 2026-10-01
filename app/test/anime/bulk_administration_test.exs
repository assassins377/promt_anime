defmodule Anime.BulkAdministrationTest do
  use Anime.DataCase
  alias Anime.Accounts.{Administration, User, UserToken, Tokens}
  alias Anime.Access.{Role, Permission, RolePermission}
  alias Anime.{Accounts, Audit}

  test "mixed role batch commits successes and audits each independent refusal" do
    owner = role_user("owner")
    first = user()
    unchanged = role_user("content_editor")
    stale = new_user()
    last = new_user()
    editor = Repo.get_by!(Role, code: "content_editor")
    selection = snapshots([first, owner, unchanged, stale, last])
    Repo.update!(Ecto.Changeset.change(stale, locale: :en))

    assert {:ok, result} = Administration.bulk(owner, selection, :role, %{"role_id" => editor.id})
    assert result.applied == 2
    assert result.denied == 3
    assert result.changed == 1
    assert Enum.map(result.failures, & &1.reason) == [:self_action, :unchanged, :stale_record]
    assert Repo.get!(User, first.id).role_id == editor.id
    assert Repo.get!(User, last.id).role_id == editor.id
    assert Repo.get!(User, stale.id).role_id == stale.role_id
    ids = Enum.map(selection, &to_string(&1.id))

    entries =
      Repo.all(from a in Audit, where: a.action == "users.role.assign" and a.object_id in ^ids)

    assert length(entries) == 5
    assert Enum.count(entries, &(&1.result == :success)) == 2
    assert Enum.count(entries, &(&1.result == :denied)) == 3
  end

  test "session batch removes session and remember-me but not mail links or other users" do
    owner = role_user("owner")
    target = user()
    empty = user()
    other = new_user()
    {:ok, {raw, remember}} = Accounts.create_session(target, true, meta())
    {:ok, {other_raw, _}} = Accounts.create_session(other, false, meta())

    mail_ids =
      Repo.all(
        from t in UserToken,
          where: t.user_id == ^target.id and t.context == :confirm,
          select: t.id
      )

    assert {:ok, result} = Administration.bulk(owner, snapshots([target, empty]), :revoke)
    assert result.applied == 1 && result.denied == 1
    assert hd(result.failures).reason == :no_sessions
    refute Tokens.user(raw)
    refute Tokens.find(remember, [:remember_me])
    assert Tokens.user(other_raw)

    assert Repo.aggregate(from(t in UserToken, where: t.id in ^mail_ids), :count) ==
             length(mail_ids)
  end

  test "an intervening operator revocation invalidates a displayed snapshot" do
    owner = role_user("owner")
    target = user()
    {:ok, _} = Accounts.create_session(target, false, meta())
    selected = snapshots([target])
    assert {:ok, _} = Administration.revoke_sessions(owner, target.id)
    {:ok, {new_raw, _}} = Accounts.create_session(Repo.get!(User, target.id), false, meta())
    assert {:ok, %{applied: 0, changed: 1}} = Administration.bulk(owner, selected, :revoke)
    assert Tokens.user(new_raw)
  end

  test "invalid, duplicate, empty and over-limit selections never partially execute" do
    owner = role_user("owner")
    target = user()
    [entry] = snapshots([target])

    for invalid <- [
          [],
          nil,
          [entry, entry],
          List.duplicate(entry, 51),
          [%{id: target.id}],
          [%{entry | updated_at: "forged"}],
          [%{entry | id: "invalid"}]
        ] do
      assert {:error, :invalid_selection} =
               Administration.bulk(owner, invalid, :role, %{"role_id" => owner.role_id})
    end

    assert {:error, :invalid_action} = Administration.bulk(owner, [entry], :ban)
    assert {:error, :invalid_fields} = Administration.bulk(owner, [entry], :role, nil)
    assert Repo.get!(User, target.id).role_id == target.role_id
  end

  test "operation permissions and revoked web session are checked before the batch" do
    admin = role_user("admin")
    target = user()
    selected = snapshots([target])
    editor = Repo.get_by!(Role, code: "content_editor")
    {:ok, {raw, _}} = Accounts.create_session(admin, false, meta())
    Repo.delete_all(from t in UserToken, where: t.user_id == ^admin.id and t.context == :session)

    assert {:error, :forbidden} =
             Administration.bulk(admin, selected, :role, %{"role_id" => editor.id}, %{
               session_token: raw
             })

    permission = Repo.get_by!(Permission, code: "users.role.assign")

    Repo.delete_all(
      from rp in RolePermission,
        where: rp.role_id == ^admin.role_id and rp.permission_id == ^permission.id
    )

    assert {:error, :forbidden} =
             Administration.bulk(admin, selected, :role, %{"role_id" => editor.id})

    assert Repo.get!(User, target.id).role_id == target.role_id
  end

  test "owner targets and privilege escalation do not cancel other batch items" do
    owner = role_user("owner")
    admin = role_user("admin")
    target = user()
    editor = Repo.get_by!(Role, code: "content_editor")

    assert {:ok, %{applied: 1, denied: 1, failures: [%{reason: :protected_owner}]}} =
             Administration.bulk(admin, snapshots([owner, target]), :role, %{
               "role_id" => editor.id
             })

    assert {:ok, %{applied: 0, failures: [%{reason: :privilege_escalation}]}} =
             Administration.bulk(admin, snapshots([Repo.get!(User, target.id)]), :role, %{
               "role_id" => owner.role_id
             })
  end

  test "fifty records are allowed, failures show only the first ten IDs" do
    owner = role_user("owner")
    template = user()
    now = DateTime.utc_now()

    entries =
      for n <- 1..50 do
        %{
          email: "bulk#{template.id}-#{n}@example.com",
          nick: "bulk#{template.id}-#{n}",
          hashed_password: template.hashed_password,
          role_id: template.role_id,
          consent_accepted_at: now,
          consent_version: template.consent_version,
          inserted_at: now,
          updated_at: now
        }
      end

    {50, rows} = Repo.insert_all(User, entries, returning: [:id, :updated_at])

    assert {:ok, result} =
             Administration.bulk(owner, rows, :role, %{"role_id" => template.role_id})

    assert result.applied == 0 && result.denied == 50
    assert length(result.failures) == 10 && length(result.failed_ids) == 50
  end

  test "a missing selected account is denied without losing later work" do
    owner = role_user("owner")
    target = user()
    absent = %{id: 9_223_372_036_854_775_806, updated_at: DateTime.utc_now()}
    editor = Repo.get_by!(Role, code: "content_editor")

    assert {:ok, %{applied: 1, failures: [%{id: id, reason: :not_found}]}} =
             Administration.bulk(owner, [absent | snapshots([target])], :role, %{
               "role_id" => editor.id
             })

    assert id == absent.id
  end

  defp snapshots(users), do: Enum.map(users, &Map.take(&1, [:id, :updated_at]))

  defp new_user do
    {:ok, u} =
      Accounts.register(
        attrs(),
        Map.put(meta(), :ip, "fixture-#{System.unique_integer([:positive])}")
      )

    u
  end
end
