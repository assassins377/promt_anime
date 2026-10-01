defmodule Anime.Access.Roles do
  import Ecto.Query
  alias Anime.{Access, Repo, Audit}
  alias Anime.Accounts.User
  alias Anime.Access.{Role, Permission, RolePermission, Catalog, Labels}
  alias Anime.Settings.Setting

  def list(actor) do
    Access.protect(actor, "roles.role.view", "Role", nil, fn _ ->
      Repo.all(
        from r in Role,
          left_join: u in User,
          on: u.role_id == r.id,
          group_by: r.id,
          order_by: [asc: r.position, asc: r.id],
          select: %{role: r, user_count: count(u.id)}
      )
    end)
  end

  def permissions(actor) do
    Access.protect(actor, "roles.permission.view", "Permission", nil, fn _ ->
      Repo.all(from p in Permission, order_by: [asc: p.group, asc: p.code])
    end)
  end

  def list_page(actor, params \\ %{}) do
    Access.protect(actor, "roles.role.view", "Role", nil, fn _ ->
      sort = if params["sort"] in ~w(id code position), do: params["sort"], else: "position"
      field = %{"id" => :id, "code" => :code, "position" => :position}[sort]
      dir = if params["dir"] == "desc", do: :desc, else: :asc
      q = search(params)
      query = from(r in Role)
      translated_codes = Labels.matching_system_roles(q)

      query =
        if q == "",
          do: query,
          else:
            where(
              query,
              [r],
              ilike(r.code, ^pattern(q)) or ilike(r.name, ^pattern(q)) or
                (r.system and r.name == r.code and r.code in ^translated_codes)
            )

      {count, page, pages} = page_info(query, params)

      rows =
        Repo.all(
          from r in query,
            left_join: u in User,
            on: u.role_id == r.id,
            group_by: r.id,
            order_by: [{^dir, field(r, ^field)}, {^dir, r.id}],
            limit: 50,
            offset: ^((page - 1) * 50),
            select: %{role: r, user_count: count(u.id)}
        )

      %{rows: rows, count: count, page: page, pages: pages, q: q, sort: sort, dir: to_string(dir)}
    end)
  end

  def permissions_page(actor, params \\ %{}) do
    Access.protect(actor, "roles.permission.view", "Permission", nil, fn _ ->
      sort = if params["sort"] == "id", do: "id", else: "code"
      field = if sort == "id", do: :id, else: :code
      dir = if params["dir"] == "desc", do: :desc, else: :asc
      q = search(params)

      groups =
        Repo.all(from p in Permission, distinct: true, order_by: p.group, select: p.group)
        |> Enum.map(&to_string/1)

      group = if params["group"] in groups, do: params["group"], else: ""
      query = from(p in Permission)
      translated_codes = Labels.matching_permissions(q)

      query =
        if q == "",
          do: query,
          else:
            where(
              query,
              [p],
              ilike(p.code, ^pattern(q)) or ilike(p.name, ^pattern(q)) or
                p.code in ^translated_codes
            )

      query = if group == "", do: query, else: where(query, [p], p.group == ^group)
      {count, page, pages} = page_info(query, params)

      rows =
        Repo.all(
          from p in query,
            order_by: [{^dir, field(p, ^field)}, {^dir, p.id}],
            limit: 50,
            offset: ^((page - 1) * 50)
        )

      %{
        rows: rows,
        count: count,
        page: page,
        pages: pages,
        q: q,
        group: group,
        groups: groups,
        sort: sort,
        dir: to_string(dir)
      }
    end)
  end

  defp search(params) do
    q = params["q"]
    q = if is_binary(q), do: String.slice(String.trim(q), 0, 100), else: ""
    if String.length(q) >= 2, do: q, else: ""
  end

  defp pattern(q), do: "%" <> String.replace(q, ["\\", "%", "_"], &("\\" <> &1)) <> "%"

  defp page_info(query, params) do
    count = Repo.aggregate(query, :count)
    pages = max(1, ceil(count / 50))

    page =
      case params["page"] do
        value when is_binary(value) ->
          case Integer.parse(value) do
            {n, ""} -> max(1, min(n, pages))
            _ -> 1
          end

        _ ->
          1
      end

    {count, page, pages}
  end

  def matrix(actor) do
    Access.protect(actor, "roles.matrix.edit", "Role", nil, fn _ ->
      roles =
        Repo.all(
          from r in Role,
            order_by: [asc: fragment("? = 'owner'", r.code), asc: r.position, asc: r.id]
        )

      %{
        roles: roles,
        permissions: Catalog.permissions(),
        grants: Map.new(roles, &{&1.id, MapSet.new(Access.codes_for_role(&1))})
      }
    end)
  end

  def create(actor, attrs, meta \\ %{}) do
    mutate(actor, "roles.role.create", nil, meta, fn fresh ->
      position = (Repo.aggregate(Role, :max, :position) || 0) + 1
      role = save!(Role.changeset(%Role{position: position}, attrs))

      Audit.record(
        fresh,
        "roles.role.create",
        "Role",
        role.id,
        :success,
        Map.put(meta, :new_value, snapshot(role))
      )

      role.id
    end)
  end

  def edit(actor, id, attrs, meta \\ %{}) do
    mutate(actor, "roles.role.edit", id, meta, fn fresh ->
      role = role!(id)
      owner_guard!(role)
      cs = Role.changeset(role, attrs)

      if role.system && Ecto.Changeset.get_field(cs, :code) != role.code,
        do: Repo.rollback(:system_code)

      updated = save!(cs)

      if role.is_default do
        Repo.get_by!(Setting, key: "registration_default_role")
        |> Ecto.Changeset.change(value: updated.code)
        |> Repo.update!()
      end

      Audit.record(
        fresh,
        "roles.role.edit",
        "Role",
        id,
        :success,
        Map.merge(meta, %{old_value: snapshot(role), new_value: snapshot(updated)})
      )

      id
    end)
  end

  def delete(actor, id, meta \\ %{}) do
    mutate(actor, "roles.role.delete", id, meta, fn fresh ->
      role = role!(id)
      owner_guard!(role)
      if role.system, do: Repo.rollback(:system_role)
      if role.is_default, do: Repo.rollback(:default_role)
      if Repo.exists?(from u in User, where: u.role_id == ^id), do: Repo.rollback(:role_in_use)
      # Convert a concurrent FK claimant into a domain error, never a database crash.
      cs =
        role
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.no_assoc_constraint(:users,
          name: :users_role_id_fkey
        )

      case Repo.delete(cs) do
        {:ok, _} -> :ok
        {:error, _} -> Repo.rollback(:role_in_use)
      end

      Audit.record(
        fresh,
        "roles.role.delete",
        "Role",
        id,
        :success,
        Map.put(meta, :old_value, snapshot(role))
      )

      id
    end)
  end

  def default(actor, id, meta \\ %{}) do
    mutate(actor, "roles.role.edit", id, meta, fn fresh ->
      role = role!(id)
      owner_guard!(role)

      if Access.codes_for_role(role) -- Access.codes_for_role(fresh.role) != [],
        do: Repo.rollback(:cannot_grant)

      setting = Repo.get_by!(Setting, key: "registration_default_role")

      Repo.update_all(from(r in Role, where: r.is_default),
        set: [is_default: false, updated_at: DateTime.utc_now()]
      )

      role |> Ecto.Changeset.change(is_default: true) |> Repo.update!()
      setting |> Ecto.Changeset.change(value: role.code) |> Repo.update!()

      Audit.record(
        fresh,
        "roles.role.edit",
        "Role",
        id,
        :success,
        Map.merge(meta, %{
          old_value: %{registration_default_role: setting.value},
          new_value: %{registration_default_role: role.code}
        })
      )

      id
    end)
  end

  def update_matrix(actor, id, codes) do
    case update_matrices(actor, [{id, codes}]) do
      {:ok, _} -> {:ok, id}
      error -> error
    end
  end

  def update_matrices(actor, changes, expected \\ nil, meta \\ %{}) do
    targets =
      if is_list(changes),
        do: for({id, _} <- changes, is_integer(id) and id > 0, do: id),
        else: []

    meta = Map.put(meta, :audit_role_ids, Enum.uniq(targets))

    mutate(actor, "roles.matrix.edit", nil, meta, fn fresh ->
      unless is_list(changes) && Enum.all?(changes, &valid_change?/1),
        do: Repo.rollback(:invalid_changes)

      ids = Enum.map(changes, &elem(&1, 0))
      if length(Enum.uniq(ids)) != length(ids), do: Repo.rollback(:invalid_changes)
      allowed = Access.codes_for_role(fresh.role)

      plan =
        for {id, requested} <- Enum.sort(changes) do
          role = role!(id)
          owner_guard!(role)
          before = Enum.sort(Access.codes_for_role(role))
          requested = requested |> Enum.uniq() |> Enum.sort()

          cond do
            requested -- Catalog.codes() != [] ->
              Repo.rollback(:unknown_permission)

            role.id == fresh.role_id && before -- requested != [] ->
              Repo.rollback(:self_permission_removal)

            requested -- allowed != [] ->
              Repo.rollback(:cannot_grant)

            expected != nil && Map.get(expected, id) != MapSet.new(before) ->
              Repo.rollback(:stale_matrix)

            true ->
              {role, before, requested}
          end
        end

      for {role, before, requested} <- plan, before != requested do
        Repo.delete_all(from rp in RolePermission, where: rp.role_id == ^role.id)
        now = DateTime.utc_now()
        pids = Repo.all(from p in Permission, where: p.code in ^requested, select: p.id)

        Repo.insert_all(
          RolePermission,
          Enum.map(
            pids,
            &%{role_id: role.id, permission_id: &1, inserted_at: now, updated_at: now}
          )
        )

        Audit.record(
          fresh,
          "roles.matrix.edit",
          "Role",
          role.id,
          :success,
          Map.merge(meta, %{old_value: %{codes: before}, new_value: %{codes: requested}})
        )

        role.id
      end
    end)
  end

  defp valid_change?({id, codes}),
    do: is_integer(id) && id > 0 && is_list(codes) && Enum.all?(codes, &is_binary/1)

  defp valid_change?(_), do: false

  defp mutate(actor, permission, id, meta, fun) do
    result =
      Repo.transaction(fn ->
        # Same global ordering as seed and owner lifecycle; serialize rare role edits
        # before locking actor/role, avoiding cross-role lock upgrades and deadlocks.
        Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(7317, 1)", [])
        u = actor && Repo.one(from u in User, where: u.id == ^actor.id, lock: "FOR SHARE")
        unless User.active?(u), do: Repo.rollback(:forbidden)
        role = Repo.one!(from r in Role, where: r.id == ^u.role_id, lock: "FOR SHARE")
        u = %{u | role: role}

        unless role.code == "owner" || permission in Access.codes_for_role(role),
          do: Repo.rollback(:forbidden)

        # Web entrypoints also require panel and screen permissions. Recheck those
        # under the same role lock as the mutation, not just in LiveView before it.
        required = Map.get(meta, :required_permissions, [])

        unless role.code == "owner" || required -- Access.codes_for_role(role) == [],
          do: Repo.rollback(:forbidden)

        fun.(u)
      end)

    case result do
      {:ok, affected} ->
        ids = List.wrap(affected)

        Repo.after_commit(fn ->
          Anime.Cache.invalidate_permissions()

          Repo.all(from u in User, where: u.role_id in ^ids, select: u.id)
          |> Enum.each(
            &Phoenix.PubSub.broadcast(Anime.PubSub, "user:#{&1}:access", :access_changed)
          )

          # The mutating screen reloads directly; avoid cancelling that fresh request
          # with its own notification. Access revocations above still reach the caller.
          Phoenix.PubSub.broadcast_from(Anime.PubSub, self(), "roles:changed", :roles_changed)
        end)

      {:error, reason} ->
        fresh = actor && Repo.get(User, actor.id) |> Repo.preload(:role)
        targets = Map.get(meta, :audit_role_ids, [id])

        for target <- if(targets == [], do: [id], else: targets),
            do:
              Audit.record(
                fresh,
                permission,
                "Role",
                target,
                :denied,
                Map.put(meta, :new_value, %{
                  reason: if(is_atom(reason), do: Atom.to_string(reason), else: "validation")
                })
              )
    end

    result
  end

  defp role!(id) do
    Repo.one(from r in Role, where: r.id == ^id, lock: "FOR UPDATE") || Repo.rollback(:not_found)
  end

  defp owner_guard!(%Role{code: "owner"}), do: Repo.rollback(:protected_owner)
  defp owner_guard!(_), do: :ok

  defp save!(cs) do
    case Repo.insert_or_update(cs) do
      {:ok, role} -> role
      {:error, cs} -> Repo.rollback(cs)
    end
  end

  defp snapshot(r), do: Map.take(r, [:code, :name, :show_badge, :is_default, :position, :system])
end
