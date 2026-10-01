defmodule Anime.PermissionCacheTest do
  use Anime.DataCase

  alias Anime.{Access, Cache}
  alias Anime.Access.{Role, RolePermission, Roles}
  alias Anime.Accounts.{Administration, User}

  setup do
    on_exit(fn -> Cache.invalidate_permissions() end)
    :ok
  end

  defp lookup(id), do: :ets.lookup(Cache.permissions_table(), id)
  defp sync, do: :sys.get_state(Cache)

  def capture_query(_event, _measurements, metadata, pid) do
    if self() == pid, do: send(pid, {:query, metadata.query})
  end

  defp drain_queries(acc \\ []) do
    receive do
      {:query, query} -> drain_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a warm UI lookup removes the grants join but still queries the account" do
    u = user()
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, [:anime, :repo, :query], &__MODULE__.capture_query/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    Access.permissions(u)
    cold = drain_queries()
    assert Enum.any?(cold, &String.contains?(&1, "role_permissions"))
    Access.permissions(u)
    warm = drain_queries()
    refute Enum.any?(warm, &String.contains?(&1, "role_permissions"))
    assert Enum.any?(warm, &String.contains?(&1, "FROM \"users\""))
  end

  test "supervised named public ETS stores role-keyed sets and reuses a warm entry" do
    table = Cache.permissions_table()
    assert :ets.info(table, :owner) == Process.whereis(Cache)
    assert :ets.info(table, :named_table)
    assert :ets.info(table, :protection) == :public
    assert :ets.info(table, :read_concurrency)
    assert :ets.info(table, :write_concurrency)
    role = Repo.get_by!(Role, code: "user")

    loader = fn ->
      send(self(), :loaded)
      ["video.watch.play"]
    end

    assert Cache.role_permissions(role.id, loader) == MapSet.new(["video.watch.play"])
    assert_received :loaded
    assert Cache.role_permissions(role.id, loader) == MapSet.new(["video.watch.play"])
    refute_received :loaded
    assert lookup(role.id) == [{role.id, MapSet.new(["video.watch.play"])}]
  end

  test "UI permissions use the cache while each lookup still reads current account state" do
    u = user()
    assert Access.permissions(u) == ["video.watch.play"]
    assert lookup(u.role_id) == [{u.role_id, MapSet.new(["video.watch.play"])}]
    Repo.update!(Ecto.Changeset.change(u, status: :blocked))
    assert Access.permissions(u) == []
    Repo.update!(Ecto.Changeset.change(u, status: :active, deletion_requested: true))
    assert Access.permissions(u) == []
    Repo.delete!(Repo.get!(User, u.id))
    assert Access.permissions(u) == []
    assert Access.permissions(nil) == []
  end

  test "poisoned or stale presentation grants cannot authorize reads or mutations" do
    u = user()
    :ets.insert(Cache.permissions_table(), {u.role_id, MapSet.new(Access.Catalog.codes())})
    refute Access.allowed?(u, "users.user.edit")
    assert Access.codes_for_role(u.role) == ["video.watch.play"]

    assert {:error, :forbidden} =
             Access.protect(u, "users.user.edit", "User", u.id, fn _ ->
               flunk("cached presentation rights authorized a protected mutation")
             end)

    assert {:error, :forbidden} = Administration.list(u)
    assert {:error, :forbidden} = Roles.create(u, %{code: "bypass", name: "Never"})
    refute Repo.get_by(Role, code: "bypass")
  end

  test "in-transaction reads bypass the shared cache and never publish rolled-back grants" do
    u = user()
    assert Access.permissions(u) == ["video.watch.play"]

    assert {:error, :cancel} =
             Repo.transaction(fn ->
               Repo.delete_all(from rp in RolePermission, where: rp.role_id == ^u.role_id)
               assert Access.permissions(u) == []
               assert lookup(u.role_id) == [{u.role_id, MapSet.new(["video.watch.play"])}]
               Repo.rollback(:cancel)
             end)

    assert Access.permissions(u) == ["video.watch.play"]
  end

  test "keyed and table-wide PubSub invalidation remove only the specified entries" do
    u = user()
    owner = role_user("owner")
    Access.permissions(u)
    Access.permissions(owner)
    Phoenix.PubSub.subscribe(Anime.PubSub, "cache:invalidate")
    table = Cache.permissions_table()

    Cache.invalidate_permissions(u.role_id)
    assert lookup(u.role_id) == []
    assert [_] = lookup(owner.role_id)
    assert_receive {:cache_invalidate, ^table, role_id, _request_id}
    assert role_id == u.role_id

    # Exercise the subscriber branch as a remote node would, without passing values.
    Phoenix.PubSub.broadcast(Anime.PubSub, "cache:invalidate", {:cache_invalidate, table, :all})
    sync()
    assert :ets.info(table, :size) == 0
    send(Cache, {:cache_invalidate, :unrelated_cache, :all})
    sync()
  end

  test "role edits, matrix changes, deletes and seed invalidate after success" do
    owner = role_user("owner")
    u = user()
    Access.permissions(u)
    assert {:ok, _} = Roles.edit(owner, u.role_id, %{name: "Readers"})
    assert lookup(u.role_id) == []
    Access.permissions(u)
    assert {:ok, _} = Roles.update_matrix(owner, u.role_id, [])
    assert lookup(u.role_id) == []
    assert Access.permissions(u) == []

    assert {:ok, id} = Roles.create(owner, %{code: "cached_custom", name: "Cached"})
    Cache.role_permissions(id, fn -> [] end)
    assert {:ok, _} = Roles.delete(owner, id)
    assert lookup(id) == []
    Access.permissions(u)
    assert {:ok, _} = Anime.Seeds.defaults()
    assert lookup(u.role_id) == []
    # Seed must still preserve the explicitly revoked grant.
    assert Access.permissions(u) == []
  end

  test "role reassignment invalidates before access notification and ignores stale user structs" do
    owner = role_user("owner")
    u = user()
    role = Repo.get_by!(Role, code: "comment_moderator")
    Access.permissions(u)
    Phoenix.PubSub.subscribe(Anime.PubSub, "user:#{u.id}:access")
    assert {:ok, _} = Administration.change_role(owner, u.id, role.id)
    assert_receive :access_changed
    assert lookup(u.role_id) == []
    assert Access.permissions(u) == Enum.sort(Access.codes_for_role(role))
  end

  test "outer rollback neither invalidates nor broadcasts a successful inner matrix edit" do
    owner = role_user("owner")
    u = user()
    Access.permissions(u)
    Phoenix.PubSub.subscribe(Anime.PubSub, "user:#{u.id}:access")
    Phoenix.PubSub.subscribe(Anime.PubSub, "cache:invalidate")

    assert {:error, :cancel} =
             Repo.transaction(fn ->
               assert {:ok, _} = Roles.update_matrix(owner, u.role_id, [])
               assert lookup(u.role_id) != []
               refute_received :access_changed
               refute_received {:cache_invalidate, _, _, _}
               Repo.rollback(:cancel)
             end)

    refute_received :access_changed
    refute_received {:cache_invalidate, _, _, _}
    assert Access.permissions(u) == ["video.watch.play"]
  end

  test "outer commit delivers invalidation after its nested matrix edit" do
    owner = role_user("owner")
    u = user()
    Access.permissions(u)
    Phoenix.PubSub.subscribe(Anime.PubSub, "user:#{u.id}:access")

    assert {:ok, _} =
             Repo.transaction(fn ->
               assert {:ok, _} = Roles.update_matrix(owner, u.role_id, [])
               assert [_] = lookup(u.role_id)
               refute_received :access_changed
             end)

    assert_receive :access_changed
    assert lookup(u.role_id) == []
    assert Access.permissions(u) == []
  end

  test "an invalidation during a cold load prevents stale refill" do
    u = user()
    parent = self()

    task =
      Task.async(fn ->
        Cache.role_permissions(u.role_id, fn ->
          send(parent, {:load, self()})

          receive do
            {:value, codes} -> codes
          after
            5000 -> raise "load barrier timed out"
          end
        end)
      end)

    assert_receive {:load, pid}
    Cache.invalidate_permissions(u.role_id)
    send(pid, {:value, ["stale"]})
    assert_receive {:load, ^pid}
    send(pid, {:value, ["fresh"]})
    assert Task.await(task) == MapSet.new(["fresh"])
    assert lookup(u.role_id) == [{u.role_id, MapSet.new(["fresh"])}]
  end

  test "owner restart changes the generation and rejects an old in-flight result" do
    u = user()
    parent = self()

    task =
      Task.async(fn ->
        Cache.role_permissions(u.role_id, fn ->
          send(parent, {:load, self()})

          receive do
            {:value, codes} -> codes
          after
            5000 -> raise "load barrier timed out"
          end
        end)
      end)

    assert_receive {:load, pid}
    old_owner = Process.whereis(Cache)
    ref = Process.monitor(old_owner)
    Process.exit(old_owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_owner, :killed}
    wait_for_owner(old_owner, 100)
    assert :ets.info(Cache.permissions_table(), :size) == 0
    send(pid, {:value, ["stale"]})
    assert_receive {:load, ^pid}
    send(pid, {:value, ["fresh"]})
    assert Task.await(task) == MapSet.new(["fresh"])
  end

  test "missing owner falls back to database and unblocks on restart" do
    u = user()
    Access.permissions(u)
    :ok = Supervisor.terminate_child(Anime.Supervisor, Cache)

    try do
      assert Access.permissions(u) == ["video.watch.play"]
      refute Access.allowed?(u, "users.user.edit")
    after
      {:ok, _} = Supervisor.restart_child(Anime.Supervisor, Cache)
    end

    assert :ets.info(Cache.permissions_table(), :size) == 0
    assert Access.permissions(u) == ["video.watch.play"]
  end

  test "a stalled owner times out to fresh database grants, not stale UI grants" do
    u = user()
    :ets.insert(Cache.permissions_table(), {u.role_id, MapSet.new(["stale"])})
    :ok = :sys.suspend(Cache)

    try do
      assert Access.permissions(u) == ["video.watch.play"]
      refute Access.allowed?(u, "users.user.edit")
    after
      :ok = :sys.resume(Cache)
    end
  end

  test "repeated invalidations bound retries and return an uncached fresh value" do
    u = user()
    counter = :counters.new(1, [])

    assert Cache.role_permissions(u.role_id, fn ->
             :counters.add(counter, 1, 1)
             Cache.invalidate_permissions()
             [Integer.to_string(:counters.get(counter, 1))]
           end) == MapSet.new(["3"])

    assert :counters.get(counter, 1) == 3
    assert lookup(u.role_id) == []
  end

  test "loader failures are not cached or mistaken for an empty set" do
    u = user()

    assert_raise RuntimeError, "database unavailable", fn ->
      Cache.role_permissions(u.role_id, fn -> raise "database unavailable" end)
    end

    assert lookup(u.role_id) == []
  end

  defp wait_for_owner(_, 0), do: flunk("ETS owner did not restart")

  defp wait_for_owner(old, attempts) do
    case Process.whereis(Cache) do
      pid when is_pid(pid) and pid != old ->
        sync()

      _ ->
        Process.sleep(10)
        wait_for_owner(old, attempts - 1)
    end
  end
end
