defmodule Anime.LifecycleConcurrencyTest do
  # Deliberately NOT DataCase/shared Sandbox: each task checks out an independent
  # PostgreSQL connection with committed writes, confined to the dedicated test DB.
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Anime.{Repo, Accounts, Audit}
  alias Anime.Accounts.{User, UserToken, Tokens}
  @password "InitialExample123"

  setup do
    database = Repo.config()[:database] || ""

    unless String.ends_with?(database, "_test"),
      do: raise("Concurrency tests require a dedicated *_test database")

    users =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, _} = Anime.Seeds.defaults()
        role = Repo.get_by!(Anime.Access.Role, code: "user")

        for _ <- 1..2 do
          %User{}
          |> User.registration_changeset(Anime.Fixtures.attrs())
          |> User.hash_password()
          |> Ecto.Changeset.change(
            role_id: role.id,
            consent_accepted_at: DateTime.utc_now(),
            consent_version: "test",
            email_confirmed_at: DateTime.utc_now()
          )
          |> Repo.insert!()
        end
      end)

    ids = Enum.map(users, & &1.id)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        token_ids =
          Repo.all(from t in UserToken, where: t.user_id in ^ids, select: t.id)
          |> Enum.map(&to_string/1)

        audit_ids =
          Repo.all(from a in Audit, where: a.user_id in ^ids, select: a.id)
          |> Enum.map(&to_string/1)

        Repo.delete_all(
          from j in Oban.Job,
            where:
              fragment("?->>'token_id'", j.args) in ^token_ids or
                fragment("?->>'audit_id'", j.args) in ^audit_ids
        )

        object_ids = Enum.map(ids, &to_string/1)

        Repo.delete_all(
          from a in Audit,
            where: a.user_id in ^ids or (a.object_type == "User" and a.object_id in ^object_ids)
        )

        subjects = Enum.map(ids, &"user:#{&1}")

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM rate_limit_counters WHERE subject=ANY($1)", [
          subjects
        ])

        Repo.delete_all(from u in User, where: u.id in ^ids)
      end)
    end)

    %{users: users}
  end

  defp race(users, fun) do
    parent = self()

    tasks =
      for user <- users do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
            send(parent, {:ready, self(), backend})

            receive do
              :go -> fun.(user)
            after
              5000 -> raise "race barrier timeout"
            end
          end)
        end)
      end

    backends =
      for task <- tasks do
        pid = task.pid
        assert_receive {:ready, ^pid, backend}, 5000
        backend
      end

    assert length(Enum.uniq(backends)) == length(tasks)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  test "remember-me request waiting for revocation cannot create a new session", %{users: [u | _]} do
    {current, remember} =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, pair} = Accounts.create_session(u, true, Anime.Fixtures.meta())
        pair
      end)

    parent = self()

    revoke =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Accounts.lock_active!(u.id)
            assert {:ok, _} = Accounts.revoke_other_sessions(u, current)
            %{rows: [[backend]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
            send(parent, {:revocation_pending, backend})

            receive do
              :commit -> :ok
            after
              5000 -> raise "revocation barrier timeout"
            end
          end)
        end)
      end)

    assert_receive {:revocation_pending, revoke_backend}, 5000

    restore =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
          send(parent, {:restore_started, backend})
          Accounts.restore_session(remember, Anime.Fixtures.meta())
        end)
      end)

    try do
      assert_receive {:restore_started, restore_backend}, 5000
      refute restore_backend == revoke_backend
      # The uncommitted delete is invisible to the initial token lookup; wait until
      # restoration actually blocks on the account row before committing revocation.
      assert waiting_for_lock?(restore_backend, 100)
    after
      send(revoke.pid, :commit)
    end

    assert {:ok, :ok} = Task.await(revoke, 5000)
    assert {:error, :invalid_session} = Task.await(restore, 5000)

    Sandbox.unboxed_run(Repo, fn ->
      assert Tokens.user(current)
      assert length(Accounts.sessions(u)) == 1
    end)
  end

  test "simultaneous matrix saves do not deadlock or overwrite a newer version", %{users: users} do
    {owner, role_id, baseline} =
      Sandbox.unboxed_run(Repo, fn ->
        r = Repo.get_by!(Anime.Access.Role, code: "owner")

        owner =
          hd(users)
          |> Ecto.Changeset.change(role_id: r.id)
          |> Repo.update!()
          |> Repo.preload(:role)

        code = "concurrent_#{System.unique_integer([:positive])}"
        {:ok, id} = Anime.Access.Roles.create(owner, %{code: code, name: "Concurrent"})
        {owner, id, %{id => MapSet.new()}}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from r in Anime.Access.Role, where: r.id == ^role_id)
      end)
    end)

    results =
      race(users, fn u ->
        code = if u.id == owner.id, do: "video.watch.play", else: "admin.panel.access"
        Anime.Access.Roles.update_matrices(owner, [{role_id, [code]}], baseline)
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_matrix})) == 1

    Sandbox.unboxed_run(Repo, fn ->
      role = Repo.get!(Anime.Access.Role, role_id)
      assert Anime.Access.codes_for_role(role) in [["video.watch.play"], ["admin.panel.access"]]
      object_id = to_string(role_id)

      assert Repo.aggregate(
               from(a in Audit,
                 where:
                   a.object_id == ^object_id and
                     a.action == "roles.matrix.edit" and a.result == :success
               ),
               :count
             ) == 1
    end)
  end

  test "cache invalidation lets an independent reader observe the committed matrix", %{
    users: users
  } do
    {owner, viewer, role} = cached_role_fixture(users)
    parent = self()
    table = Anime.Cache.permissions_table()
    request_id = "committed-cache-context-123456"
    Anime.LogContext.put(request_id)

    reader =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Phoenix.PubSub.subscribe(Anime.PubSub, "cache:invalidate")
          %{rows: [[backend]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
          send(parent, :reader_ready)

          receive do
            {:cache_invalidate, ^table, :all, ^request_id} ->
              {backend, Anime.Access.codes_for_role(role), Anime.Access.permissions(viewer)}
          after
            5000 -> raise "committed invalidation was not delivered"
          end
        end)
      end)

    assert_receive :reader_ready, 5000

    writer_backend =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])

        assert {:ok, _} =
                 Repo.transaction(fn ->
                   assert {:ok, _} = Anime.Access.Roles.update_matrix(owner, role.id, [])

                   assert :ets.lookup(table, role.id) == [
                            {role.id, MapSet.new(["users.user.view"])}
                          ]
                 end)

        backend
      end)

    assert {reader_backend, [], []} = Task.await(reader, 5000)
    assert reader_backend != writer_backend
  end

  test "waiting authorization rejects a revoked grant despite a warm presentation cache", %{
    users: users
  } do
    {owner, viewer, role} = cached_role_fixture(users)
    parent = self()

    revoke =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            assert {:ok, _} = Anime.Access.Roles.update_matrix(owner, role.id, [])
            send(parent, :matrix_uncommitted)

            receive do
              :commit -> :ok
            after
              5000 -> raise "commit barrier timed out"
            end
          end)
        end)
      end)

    assert_receive :matrix_uncommitted, 5000
    assert [_] = :ets.lookup(Anime.Cache.permissions_table(), role.id)

    protected =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
          send(parent, {:protected_started, backend})

          Anime.Access.protect(viewer, "users.user.view", "User", viewer.id, fn _ ->
            send(parent, :incorrectly_authorized)
          end)
        end)
      end)

    assert_receive {:protected_started, backend}, 5000

    try do
      assert waiting_for_lock?(backend, 100)
    after
      send(revoke.pid, :commit)
    end

    assert {:ok, :ok} = Task.await(revoke, 5000)
    assert {:error, :forbidden} = Task.await(protected, 5000)
    refute_received :incorrectly_authorized
  end

  defp cached_role_fixture([actor, viewer]) do
    {owner, viewer, role} =
      Sandbox.unboxed_run(Repo, fn ->
        owner_role = Repo.get_by!(Anime.Access.Role, code: "owner")
        owner = actor |> Ecto.Changeset.change(role_id: owner_role.id) |> Repo.update!()

        role =
          Repo.insert!(%Anime.Access.Role{
            code: "cache_#{viewer.id}",
            name: "Cache test",
            position: 100
          })

        permission = Repo.get_by!(Anime.Access.Permission, code: "users.user.view")
        Repo.insert!(%Anime.Access.RolePermission{role_id: role.id, permission_id: permission.id})
        viewer = viewer |> Ecto.Changeset.change(role_id: role.id) |> Repo.update!()
        assert Anime.Access.permissions(viewer) == ["users.user.view"]
        {owner, viewer, role}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        default = Repo.get_by!(Anime.Access.Role, code: "user")
        Repo.update_all(from(u in User, where: u.id == ^viewer.id), set: [role_id: default.id])
        object_id = to_string(role.id)

        Repo.delete_all(
          from a in Audit, where: a.object_type == "Role" and a.object_id == ^object_id
        )

        Repo.delete_all(from r in Anime.Access.Role, where: r.id == ^role.id)
        Anime.Cache.invalidate_permissions()
      end)
    end)

    {owner, viewer, role}
  end

  defp waiting_for_lock?(_, 0), do: false

  test "competing bulk role changes recheck the snapshot on independent connections", %{
    users: [actor, target] = users
  } do
    {owner, role_ids, snapshot} =
      Sandbox.unboxed_run(Repo, fn ->
        owner_role = Repo.get_by!(Anime.Access.Role, code: "owner")
        owner = actor |> Ecto.Changeset.change(role_id: owner_role.id) |> Repo.update!()

        roles =
          Repo.all(
            from r in Anime.Access.Role,
              where: r.code in ["content_editor", "comment_moderator"],
              order_by: r.id,
              select: r.id
          )

        {owner, roles, Map.take(target, [:id, :updated_at])}
      end)

    results =
      race(users, fn participant ->
        role_id = if participant.id == actor.id, do: hd(role_ids), else: List.last(role_ids)
        Anime.Accounts.Administration.bulk(owner, [snapshot], :role, %{"role_id" => role_id})
      end)

    assert Enum.count(results, &match?({:ok, %{applied: 1, denied: 0}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{applied: 0, denied: 1, changed: 1}}, &1)) == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(User, target.id).role_id in role_ids
      id = to_string(target.id)

      assert Repo.aggregate(
               from(a in Audit, where: a.action == "users.role.assign" and a.object_id == ^id),
               :count
             ) == 2
    end)
  end

  for action <- [:ban, :demote] do
    test "operator deletion racing with owner #{action} preserves one active owner", %{
      users: users
    } do
      {users, reader_role} =
        Sandbox.unboxed_run(Repo, fn ->
          owner = Repo.get_by!(Anime.Access.Role, code: "owner")
          reader = Repo.get_by!(Anime.Access.Role, code: "user")

          {Enum.map(users, &Repo.update!(Ecto.Changeset.change(&1, role_id: owner.id))),
           reader.id}
        end)

      results =
        race(users, fn actor ->
          target = Enum.find(users, &(&1.id != actor.id))

          if actor.id == hd(users).id do
            Anime.Accounts.Administration.request_deletion(actor, target.id, target.nick)
          else
            case unquote(action) do
              :ban ->
                Anime.Accounts.Administration.ban(actor, target.id, %{
                  "reason" => "spam",
                  "days" => "1"
                })

              :demote ->
                Anime.Accounts.Administration.change_role(actor, target.id, reader_role)
            end
          end
        end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert {:error, :forbidden} in results

      Sandbox.unboxed_run(Repo, fn ->
        ids = Enum.map(users, & &1.id)

        assert Repo.aggregate(
                 from(u in User,
                   join: r in Anime.Access.Role,
                   on: r.id == u.role_id,
                   where:
                     u.id in ^ids and r.code == "owner" and u.status == :active and
                       not u.deletion_requested
                 ),
                 :count
               ) == 1
      end)
    end
  end

  test "simultaneous editor forms cannot overwrite a newer account snapshot", %{
    users: [actor, target] = users
  } do
    actor =
      Sandbox.unboxed_run(Repo, fn ->
        role = Repo.get_by!(Anime.Access.Role, code: "owner")
        Repo.update!(Ecto.Changeset.change(actor, role_id: role.id))
      end)

    baseline = Map.take(target, [:nick, :email, :locale])

    results =
      race(users, fn variant ->
        Anime.Accounts.Administration.edit(
          actor,
          target.id,
          %{"nick" => "concurrent_edit_#{variant.id}"},
          %{expected_user_fields: baseline}
        )
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :stale_account} in results
  end

  test "cancel deletion and final cleanup serialize without partial restoration", %{
    users: [actor, target] = users
  } do
    actor =
      Sandbox.unboxed_run(Repo, fn ->
        role = Repo.get_by!(Anime.Access.Role, code: "owner")
        actor = Repo.update!(Ecto.Changeset.change(actor, role_id: role.id))
        {:ok, _} = Anime.Accounts.Administration.request_deletion(actor, target.id, target.nick)

        Repo.update!(
          Ecto.Changeset.change(Repo.get!(User, target.id),
            deletion_requested_at: DateTime.add(DateTime.utc_now(), -31 * 86400)
          )
        )

        actor
      end)

    results =
      race(users, fn participant ->
        if participant.id == actor.id,
          do: Anime.Accounts.Administration.cancel_deletion(actor, target.id),
          else: Anime.Accounts.Lifecycle.delete_due_account(target.id)
      end)

    Sandbox.unboxed_run(Repo, fn ->
      case Repo.get(User, target.id) do
        nil ->
          assert {:ok, :deleted} in results
          assert {:error, :not_found} in results

        user ->
          refute user.deletion_requested
          assert {:ok, target.id} in results
          assert {:ok, :not_due} in results
      end
    end)
  end

  test "admin mutation waiting for a revoked session cannot commit", %{users: [actor, target]} do
    {actor, raw, token_id} =
      Sandbox.unboxed_run(Repo, fn ->
        owner = Repo.get_by!(Anime.Access.Role, code: "owner")
        actor = Repo.update!(Ecto.Changeset.change(actor, role_id: owner.id))
        {:ok, {raw, _}} = Accounts.create_session(actor, false, Anime.Fixtures.meta())
        {actor, raw, Tokens.find(raw, [:session]).id}
      end)

    parent = self()

    revoke =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Accounts.lock_active!(actor.id)
            {:ok, _} = Accounts.revoke_session(actor, token_id)
            send(parent, :revoked_uncommitted)

            receive do
              :commit -> :ok
            after
              5000 -> raise "barrier timeout"
            end
          end)
        end)
      end)

    assert_receive :revoked_uncommitted, 5000

    mutation =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
          send(parent, {:mutation_started, backend})

          Anime.Accounts.Administration.ban(
            actor,
            target.id,
            %{"reason" => "spam", "days" => "1"},
            %{session_token: raw}
          )
        end)
      end)

    try do
      assert_receive {:mutation_started, backend}, 5000
      assert waiting_for_lock?(backend, 100)
    after
      send(revoke.pid, :commit)
    end

    assert {:ok, :ok} = Task.await(revoke, 5000)
    assert {:error, :forbidden} = Task.await(mutation, 5000)
    Sandbox.unboxed_run(Repo, fn -> assert Repo.get!(User, target.id).status == :active end)
  end

  for action <- [:ban, :demote] do
    test "concurrent owner #{action} preserves an active owner", %{users: users} do
      {users, reader_role} =
        Sandbox.unboxed_run(Repo, fn ->
          owner = Repo.get_by!(Anime.Access.Role, code: "owner")
          reader = Repo.get_by!(Anime.Access.Role, code: "user")
          users = Enum.map(users, &Repo.update!(Ecto.Changeset.change(&1, role_id: owner.id)))
          {users, reader.id}
        end)

      results =
        race(users, fn actor ->
          target = Enum.find(users, &(&1.id != actor.id))

          case unquote(action) do
            :ban ->
              Anime.Accounts.Administration.ban(actor, target.id, %{
                "reason" => "spam",
                "days" => "1"
              })

            :demote ->
              Anime.Accounts.Administration.change_role(actor, target.id, reader_role)
          end
        end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert {:error, :forbidden} in results

      Sandbox.unboxed_run(Repo, fn ->
        ids = Enum.map(users, & &1.id)

        assert Repo.aggregate(
                 from(u in User,
                   join: r in Anime.Access.Role,
                   on: r.id == u.role_id,
                   where:
                     u.id in ^ids and r.code == "owner" and u.status == :active and
                       not u.deletion_requested
                 ),
                 :count
               ) == 1
      end)
    end
  end

  defp waiting_for_lock?(backend, tries) do
    locked =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: rows} =
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1",
            [backend]
          )

        rows == [[true]]
      end)

    if locked do
      true
    else
      Process.sleep(10)
      waiting_for_lock?(backend, tries - 1)
    end
  end

  test "two independent nickname claims produce exactly one winner", %{users: users} do
    nick = "claim#{System.unique_integer([:positive])}"
    results = race(users, &Accounts.change_nick(&1, %{nick: nick}))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Ecto.Changeset{}}, &1)) == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(from(u in User, where: u.nick == ^nick), :count) == 1
    end)
  end

  test "two pending email confirmations cannot claim the same email", %{users: users} do
    address = "claim#{System.unique_integer([:positive])}@example.com"

    {links, jobs} =
      Sandbox.unboxed_run(Repo, fn ->
        links =
          for u <- users, into: %{} do
            {:ok, _} = Accounts.request_email_change(u, @password, %{email: address})

            token =
              Repo.one!(
                from t in UserToken, where: t.user_id == ^u.id and t.context == :change_email
              )

            {u.id, Base.url_encode64(Tokens.mail_bytes(token), padding: false)}
          end

        ids = Enum.map(users, & &1.id)

        token_ids =
          Repo.all(from t in UserToken, where: t.user_id in ^ids, select: t.id)
          |> Enum.map(&to_string/1)

        jobs =
          Repo.all(
            from j in Oban.Job,
              where: fragment("?->>'token_id'", j.args) in ^token_ids,
              select: j.id
          )

        {links, jobs}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from j in Oban.Job, where: j.id in ^jobs)
      end)
    end)

    results = race(users, &Accounts.confirm(Map.fetch!(links, &1.id)))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Ecto.Changeset{}}, &1)) == 1
  end

  test "simultaneous logouts revoke once and produce only one success event", %{users: users} do
    [u | _] = users

    {session, remember, other} =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, {session, remember}} = Accounts.create_session(u, true, Anime.Fixtures.meta())
        {:ok, {other, _}} = Accounts.create_session(u, false, Anime.Fixtures.meta())
        {session, remember, other}
      end)

    results = race(users, fn _ -> Accounts.logout(session, remember, Anime.Fixtures.meta()) end)
    assert Enum.count(results, &match?({:ok, %User{}}, &1)) == 1
    assert {:ok, nil} in results

    Sandbox.unboxed_run(Repo, fn ->
      refute Tokens.find(session, [:session])
      refute Tokens.find(remember, [:remember_me])
      assert Tokens.user(other)

      assert Repo.aggregate(
               from(a in Audit, where: a.user_id == ^u.id and a.action == "logout"),
               :count
             ) == 1
    end)
  end

  test "simultaneous owner deletion requests leave one active owner", %{users: users} do
    users =
      Sandbox.unboxed_run(Repo, fn ->
        owner = Repo.get_by!(Anime.Access.Role, code: "owner")

        Enum.map(users, fn u ->
          u |> Ecto.Changeset.change(role_id: owner.id) |> Repo.update!()
        end)
      end)

    results = race(users, &Accounts.request_deletion(&1, @password, &1.nick))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :last_owner} in results
  end
end
