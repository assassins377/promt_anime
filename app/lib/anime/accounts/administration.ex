defmodule Anime.Accounts.Administration do
  @moduledoc "Protected account administration; decisions use locked database state."
  import Ecto.Query
  alias Anime.{Repo, Access, Audit}
  alias Anime.Accounts.{User, UserToken, Lifecycle, Tokens}
  alias Anime.Access.Role
  alias Ecto.Changeset, as: CS

  @reasons ~w(spam insults rating_manipulation ban_evasion prohibited_content other)
  @labels [
    "спам",
    "оскорбления",
    "накрутка оценок",
    "обход блокировки",
    "запрещённый контент",
    "другое"
  ]
  def reasons, do: Enum.zip(@reasons, @labels)

  def list(actor, params \\ %{}), do: list_users(actor, params, :all)

  def blocked(actor, params \\ %{}), do: list_users(actor, params, :blocked)

  defp list_users(actor, params, mode) do
    Access.protect(actor, "users.user.view", "User", nil, fn fresh ->
      # The registry's scope is enforced in the context, not by a hidden form field.
      params =
        if mode == :blocked,
          do: Map.take(params, ~w(q term blocked_by from to page sort dir)),
          else: params

      p = normalize(params)

      p =
        if mode == :blocked,
          do: %{
            p
            | status: ["blocked"],
              sort:
                if(params["sort"] in ~w(id nick blocked_at),
                  do: params["sort"],
                  else: "blocked_at"
                )
          },
          else: p

      query = from u in User, join: r in Role, on: r.id == u.role_id
      query = filters(query, p, mode)
      count = Repo.aggregate(query, :count)
      page = min(p.page, max(1, ceil(count / 50)))

      field =
        %{
          "id" => :id,
          "nick" => :nick,
          "status" => :status,
          "inserted_at" => :inserted_at,
          "blocked_at" => :blocked_at
        }[p.sort]

      direction = if p.dir == "asc", do: :asc, else: :desc

      date_direction =
        case {p.sort, direction} do
          {"blocked_at", :desc} -> :desc_nulls_last
          {"blocked_at", :asc} -> :asc_nulls_first
          _ -> direction
        end

      query =
        if p.sort == "role",
          do:
            order_by(query, [u, r], [
              {^direction, r.position},
              {^direction, r.id},
              {^direction, u.id}
            ]),
          else:
            order_by(query, [u], [
              {^date_direction, field(u, ^field)},
              {^direction, u.id}
            ])

      last_used =
        from t in UserToken,
          where: t.context in [:session, :remember_me],
          group_by: t.user_id,
          select: %{user_id: t.user_id, last_used_at: max(t.last_used_at)}

      rows =
        Repo.all(
          from [u, r] in query,
            left_join: t in subquery(last_used),
            on: t.user_id == u.id,
            left_join: operator in User,
            on: operator.id == u.blocked_by_id,
            limit: 50,
            offset: ^((page - 1) * 50),
            select: %{
              id: u.id,
              updated_at: u.updated_at,
              nick: u.nick,
              email: u.email,
              email_confirmed_at: u.email_confirmed_at,
              role_name: r.name,
              role_code: r.code,
              role_system: r.system,
              status: u.status,
              deletion_requested: u.deletion_requested,
              inserted_at: u.inserted_at,
              last_used_at: t.last_used_at,
              blocked_at: u.blocked_at,
              blocked_until: u.blocked_until,
              block_reason: u.block_reason,
              blocked_by_id: u.blocked_by_id,
              blocked_by_nick: operator.nick
            }
        )

      %{
        rows: rows,
        count: count,
        page: page,
        pages: max(1, ceil(count / 50)),
        params: p,
        operators: if(mode == :blocked, do: block_operators(), else: []),
        roles: Repo.all(from r in Role, order_by: [r.position, r.id]),
        assignable_roles:
          Repo.all(from r in Role, order_by: [r.position, r.id])
          |> Enum.filter(&assignable?(fresh, &1))
      }
    end)
  end

  def get(actor, id) do
    Access.protect(actor, "users.user.view", "User", id, fn fresh ->
      target = Repo.get(User, positive_id(id)) || Repo.rollback(:not_found)
      target = Repo.preload(target, :role)
      # No password hashes or token bytes leave the context for rendering.
      fields =
        ~w(id nick email email_confirmed_at previous_nick previous_nick_until nick_changed_at role status inserted_at locale supporter_until consent_accepted_at consent_version age_confirmed_at show_bookmarks_public keep_watch_history show_continue_watching must_change_password deletion_requested deletion_requested_at blocked_at blocked_until blocked_by_id block_reason)a

      assignable =
        Repo.all(from r in Role, order_by: [r.position, r.id])
        |> Enum.filter(&assignable?(fresh, &1))

      operator =
        Repo.one(
          from u in User,
            where: u.id == ^(target.blocked_by_id || 0),
            select: map(u, [:id, :nick])
        )

      %{
        user: Map.take(target, fields),
        roles: assignable,
        session_count: Repo.aggregate(active_sessions(target.id), :count),
        block_operator: operator
      }
    end)
  end

  def sessions(actor, id, params \\ %{}) do
    Access.protect(actor, "users.user.view", "User", id, fn _ ->
      id = positive_id(id)
      unless Repo.exists?(from u in User, where: u.id == ^id), do: Repo.rollback(:not_found)
      query = active_sessions(id)
      count = Repo.aggregate(query, :count)
      pages = max(1, ceil(count / 50))
      page = min(max(1, positive_id(params["page"])), pages)

      rows =
        Repo.all(
          from t in query,
            order_by: [desc: t.last_used_at, desc: t.id],
            limit: 50,
            offset: ^((page - 1) * 50),
            select:
              map(t, [:id, :context, :inserted_at, :last_used_at, :expires_at, :ip, :user_agent])
        )

      %{rows: rows, count: count, page: page, pages: pages}
    end)
  end

  defp active_sessions(id) do
    from t in UserToken,
      where:
        t.user_id == ^id and t.context in [:session, :remember_me] and
          t.expires_at > ^DateTime.utc_now()
  end

  def block_history(actor, id, params \\ %{}) do
    Access.protect(actor, "users.user.view", "User", id, fn _ ->
      id = positive_id(id)
      unless Repo.exists?(from u in User, where: u.id == ^id), do: Repo.rollback(:not_found)

      query =
        from a in Audit,
          where:
            a.object_type == "User" and a.object_id == ^to_string(id) and
              a.action in ["users.user.ban", "users.user.unban"]

      count = Repo.aggregate(query, :count)
      pages = max(1, ceil(count / 50))
      page = min(max(1, positive_id(params["page"])), pages)

      rows =
        Repo.all(
          from a in query,
            order_by: [desc: a.occurred_at, desc: a.id],
            limit: 50,
            offset: ^((page - 1) * 50),
            select: %{
              id: a.id,
              occurred_at: a.occurred_at,
              actor_label: a.actor_label,
              action: a.action,
              result: a.result,
              has_deadline:
                fragment(
                  "COALESCE(jsonb_exists(?, 'blocked_until'), false) OR COALESCE(jsonb_exists(?, 'blocked_until'), false)",
                  a.new_value,
                  a.old_value
                ),
              block_reason:
                fragment(
                  "COALESCE(?->>'block_reason', ?->>'block_reason')",
                  a.new_value,
                  a.old_value
                ),
              blocked_until:
                fragment(
                  "COALESCE(?->>'blocked_until', ?->>'blocked_until')",
                  a.new_value,
                  a.old_value
                )
            }
        )

      %{rows: rows, count: count, pages: pages, page: page}
    end)
  end

  defp block_operators do
    Repo.all(
      from u in User,
        join: operator in User,
        on: operator.id == u.blocked_by_id,
        where: u.status == :blocked,
        distinct: true,
        order_by: [operator.nick, operator.id],
        select: %{id: operator.id, nick: operator.nick}
    )
  end

  def change_role(actor, id, role_id, meta \\ %{}) do
    mutate(actor, id, "users.role.assign", meta, [positive_id(role_id)], fn a, u, roles ->
      r = roles[positive_id(role_id)] || Repo.rollback(:not_found)
      if u.role.code == "owner" and a.role.code != "owner", do: Repo.rollback(:protected_owner)
      unless assignable?(a, r), do: Repo.rollback(:privilege_escalation)
      if u.role_id == r.id, do: Repo.rollback(:unchanged)
      if u.role.code == "owner", do: protect_owner!(u)
      updated = u |> CS.change(role_id: r.id) |> Repo.update!()
      audit(a, u, "users.role.assign", %{role: u.role.code}, %{role: r.code}, meta)
      updated
    end)
  end

  @doc "Process 1–50 server-held account snapshots, with independent item transactions."
  def bulk(actor, selection, action, attrs \\ %{}, meta \\ %{})

  def bulk(actor, selection, action, attrs, meta) when action in [:role, :revoke] do
    permission = if action == :role, do: "users.role.assign", else: "users.session.revoke"

    # This transaction ends before processing items: partial success is intentional.
    with {:ok, :allowed} <-
           Access.protect(actor, permission, "User", nil, fn fresh ->
             if fresh.must_change_password, do: Repo.rollback(:forbidden)

             unless Map.get(meta, :required_permissions, []) -- Access.codes_for_role(fresh.role) ==
                      [],
                    do: Repo.rollback(:forbidden)

             if Map.has_key?(meta, :session_token) do
               case Tokens.find(meta.session_token, [:session]) do
                 %UserToken{user_id: id} when id == fresh.id -> :ok
                 _ -> Repo.rollback(:forbidden)
               end
             end

             :allowed
           end),
         :ok <- validate_selection(selection),
         true <- is_map(attrs) do
      results =
        Enum.map(selection, fn %{id: id, updated_at: version} ->
          item_meta = Map.put(meta, :expected_updated_at, version)

          result =
            case action do
              :role -> change_role(actor, id, attrs["role_id"], item_meta)
              :revoke -> revoke_sessions(actor, id, :all, item_meta)
            end

          case result do
            {:ok, _} -> %{id: id, result: :success}
            {:error, reason} -> %{id: id, result: :denied, reason: reason}
          end
        end)

      failed = Enum.filter(results, &(&1.result == :denied))

      {:ok,
       %{
         applied: length(results) - length(failed),
         denied: length(failed),
         changed: Enum.count(failed, &(&1.reason == :stale_record)),
         failures: Enum.take(failed, 10),
         failed_ids: Enum.map(failed, & &1.id)
       }}
    else
      false -> {:error, :invalid_fields}
      error -> error
    end
  end

  def bulk(_, _, _, _, _), do: {:error, :invalid_action}

  defp validate_selection(selection) when is_list(selection) do
    valid? =
      length(selection) in 1..50 &&
        Enum.all?(selection, fn
          %{id: id, updated_at: %DateTime{}} -> positive_id(id) == id && id > 0
          _ -> false
        end)

    if valid? && length(Enum.uniq_by(selection, & &1.id)) == length(selection),
      do: :ok,
      else: {:error, :invalid_selection}
  end

  defp validate_selection(_), do: {:error, :invalid_selection}

  def edit(actor, id, attrs, meta \\ %{}) do
    mutate(actor, id, "users.user.edit", meta, [], fn a, u, _ ->
      unless is_map(attrs), do: Repo.rollback(:invalid_fields)
      fields = [:nick, :email, :locale]

      if Map.has_key?(meta, :expected_user_fields) &&
           meta.expected_user_fields != Map.take(u, fields),
         do: Repo.rollback(:stale_account)

      cs = User.admin_changeset(u, attrs)
      unless cs.valid?, do: Repo.rollback(cs)
      changed = Enum.filter(fields, &Map.has_key?(cs.changes, &1))
      if changed == [], do: Repo.rollback(:unchanged)
      now = DateTime.utc_now()
      nick = CS.get_field(cs, :nick)

      cs =
        if :nick in changed && String.downcase(nick) != String.downcase(u.nick) do
          [u.nick, nick]
          |> Enum.map(&String.downcase/1)
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.each(&Anime.Accounts.nick_lock/1)

          if Anime.Accounts.nick_taken?(nick),
            do: Repo.rollback(CS.add_error(cs, :nick, "has already been taken"))

          CS.change(cs,
            previous_nick: u.nick,
            previous_nick_until: DateTime.add(now, 30 * 86400),
            nick_changed_at: now
          )
        else
          cs
        end

      cs = if :email in changed, do: CS.change(cs, email_confirmed_at: nil), else: cs

      updated =
        case Repo.update(cs) do
          {:ok, updated} -> updated
          {:error, cs} -> Repo.rollback(cs)
        end

      if :email in changed, do: Repo.delete_all(from t in UserToken, where: t.user_id == ^u.id)

      for field <- changed do
        audit(
          a,
          u,
          "users.user.edit",
          %{field => Map.fetch!(u, field)},
          %{field => Map.fetch!(updated, field)},
          meta
        )
      end

      updated
    end)
  end

  def request_deletion(actor, id, nick, meta \\ %{}) do
    mutate(actor, id, "users.user.delete", meta, [], fn a, u, _ ->
      unless is_binary(nick) && nick == u.nick, do: Repo.rollback(:nickname_mismatch)
      if u.deletion_requested, do: Repo.rollback(:already_requested)
      protect_owner!(u)

      updated =
        u
        |> CS.change(deletion_requested: true, deletion_requested_at: DateTime.utc_now())
        |> Repo.update!()

      Repo.delete_all(from t in UserToken, where: t.user_id == ^u.id)

      audit(
        a,
        u,
        "account_delete_request",
        deletion_snapshot(u),
        deletion_snapshot(updated),
        meta
      )

      # No restore token or email: only a permitted operator may cancel this request.
      updated
    end)
  end

  def cancel_deletion(actor, id, meta \\ %{}) do
    mutate(actor, id, "users.user.delete", meta, [], fn a, u, _ ->
      unless u.deletion_requested, do: Repo.rollback(:not_requested)

      updated =
        u |> CS.change(deletion_requested: false, deletion_requested_at: nil) |> Repo.update!()

      Repo.delete_all(
        from t in UserToken, where: t.user_id == ^u.id and t.context == :delete_cancel
      )

      audit(a, u, "account_delete_cancel", deletion_snapshot(u), deletion_snapshot(updated), meta)
      # Keep the administrative block and never recreate revoked sessions.
      updated
    end)
  end

  defp deletion_snapshot(u), do: Map.take(u, [:deletion_requested, :deletion_requested_at])

  def ban(actor, id, attrs, meta \\ %{}) do
    mutate(actor, id, "users.user.ban", meta, [], fn a, u, _ ->
      if u.status == :blocked, do: Repo.rollback(:already_blocked)
      protect_owner!(u)
      reason = attrs["reason"]
      comment = attrs["comment"] || ""
      unless is_binary(comment), do: Repo.rollback(:invalid_reason)
      comment = String.trim(comment)

      unless reason in @reasons and String.length(comment) <= 300 and
               (reason != "other" or String.length(comment) >= 10),
             do: Repo.rollback(:invalid_reason)

      now = DateTime.utc_now()

      until =
        if attrs["permanent"] in [true, "true"], do: nil, else: block_until!(attrs["days"], now)

      label = Map.new(reasons())[reason]
      text = if comment == "", do: label, else: label <> ": " <> comment

      updated =
        u
        |> CS.change(
          status: :blocked,
          block_reason: text,
          blocked_at: now,
          blocked_until: until,
          blocked_by_id: a.id
        )
        |> Repo.update!()

      Repo.delete_all(
        from t in UserToken, where: t.user_id == ^u.id and t.context in [:session, :remember_me]
      )

      entry = audit(a, u, "users.user.ban", block_snapshot(u), block_snapshot(updated), meta)
      if attrs["notify"] in [true, "true"], do: queue_notice(entry, u, "account_blocked")
      updated
    end)
  end

  def unban(actor, id, meta \\ %{}) do
    mutate(actor, id, "users.user.unban", meta, [], fn a, u, _ -> unblock!(a, u, meta) end)
  end

  def revoke_sessions(actor, id, session_id \\ :all, meta \\ %{}) do
    mutate(actor, id, "users.session.revoke", meta, [], fn a, u, _ ->
      query =
        from t in UserToken, where: t.user_id == ^u.id and t.context in [:session, :remember_me]

      before = Repo.aggregate(from(t in query, where: t.expires_at > ^DateTime.utc_now()), :count)

      selected =
        if session_id == :all,
          do: query,
          else: from(t in query, where: t.id == ^positive_id(session_id))

      {deleted, _} = Repo.delete_all(selected)

      if deleted == 0,
        do: Repo.rollback(if(session_id == :all, do: :no_sessions, else: :not_found))

      after_count =
        Repo.aggregate(from(t in query, where: t.expires_at > ^DateTime.utc_now()), :count)

      audit(a, u, "users.session.revoke", %{sessions: before}, %{sessions: after_count}, meta)
      # Mark operator revocation as a record change for already displayed bulk selections.
      u |> CS.change(updated_at: DateTime.utc_now()) |> Repo.update!()
    end)
  end

  # Internal worker entrypoint: not exposed as an operator action. Recheck under lock,
  # so a stale cron candidate cannot undo an operator's more recent extension.
  def unblock_expired(id) do
    Repo.transaction(fn ->
      Lifecycle.owner_lock!()
      u = Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE")

      unless u && u.status == :blocked && u.blocked_until &&
               DateTime.compare(u.blocked_until, DateTime.utc_now()) != :gt,
             do: Repo.rollback(:not_due)

      unblock!(nil, u, %{actor_label: "users_unblock_expired"})
    end)
    |> notify()
  end

  defp unblock!(actor, u, meta) do
    if u.status != :blocked, do: Repo.rollback(:not_blocked)

    updated =
      u
      |> CS.change(status: :active, blocked_at: nil, blocked_until: nil, blocked_by_id: nil)
      |> Repo.update!()

    entry = audit(actor, u, "users.user.unban", block_snapshot(u), block_snapshot(updated), meta)
    queue_notice(entry, u, "login_after_block")
    updated
  end

  defp mutate(actor, id, permission, meta, extra_roles, fun) do
    id = positive_id(id)

    result =
      Repo.transaction(fn ->
        Lifecycle.owner_lock!()
        ids = Enum.uniq([actor && actor.id, id]) |> Enum.reject(&is_nil/1)

        users =
          Repo.all(from u in User, where: u.id in ^ids, order_by: u.id, lock: "FOR UPDATE")
          |> Map.new(&{&1.id, &1})

        a = actor && users[actor.id]
        unless User.active?(a) && !a.must_change_password, do: Repo.rollback(:forbidden)

        # Web callers carry their authenticated session, never a form-supplied token.
        # Recheck after the user lock so concurrent revocation cannot be bypassed.
        if Map.has_key?(meta, :session_token) do
          case Tokens.find(meta.session_token, [:session]) do
            %UserToken{user_id: actor_id} when actor_id == a.id -> :ok
            _ -> Repo.rollback(:forbidden)
          end
        end

        role_ids = Enum.uniq(Enum.map(Map.values(users), & &1.role_id) ++ extra_roles)

        roles =
          Repo.all(from r in Role, where: r.id in ^role_ids, order_by: r.id, lock: "FOR SHARE")
          |> Map.new(&{&1.id, &1})

        a = %{a | role: roles[a.role_id]}
        codes = Access.codes_for_role(a.role)
        required = [permission | Map.get(meta, :required_permissions, [])]
        unless required -- codes == [], do: Repo.rollback(:forbidden)
        u = users[id] || Repo.rollback(:not_found)
        u = %{u | role: roles[u.role_id]}
        if a.id == u.id, do: Repo.rollback(:self_action)
        if u.role.code == "owner" && a.role.code != "owner", do: Repo.rollback(:protected_owner)

        unless Access.codes_for_role(u.role) -- codes == [],
          do: Repo.rollback(:privilege_escalation)

        if Map.has_key?(meta, :expected_updated_at) && meta.expected_updated_at != u.updated_at,
          do: Repo.rollback(:stale_record)

        fun.(a, u, roles)
      end)

    if match?({:error, _}, result) do
      {:error, reason} = result
      fresh = actor && Repo.get(User, actor.id) |> Repo.preload(:role)

      Audit.record(
        fresh,
        permission,
        "User",
        id,
        :denied,
        Map.put(meta, :new_value, %{
          reason: if(is_atom(reason), do: Atom.to_string(reason), else: "validation")
        })
      )
    end

    notify(result)
  end

  defp protect_owner!(u) do
    if u.role.code == "owner" && User.active?(u) &&
         !Repo.exists?(
           from other in User,
             where:
               other.role_id == ^u.role_id and other.id != ^u.id and other.status == :active and
                 not other.deletion_requested
         ),
       do: Repo.rollback(:last_owner)
  end

  defp assignable?(a, r),
    do:
      (r.code != "owner" || a.role.code == "owner") &&
        Access.codes_for_role(r) -- Access.codes_for_role(a.role) == []

  defp block_until!(days, now) do
    n = positive_id(days)
    unless n in 1..3650, do: Repo.rollback(:invalid_duration)
    DateTime.add(now, n * 86400)
  end

  defp block_snapshot(u), do: Map.take(u, [:status, :blocked_until, :block_reason])

  defp audit(a, u, action, before, after_value, meta),
    do:
      Audit.record(
        a,
        action,
        "User",
        u.id,
        :success,
        Map.merge(meta, %{old_value: before, new_value: after_value})
      )

  defp queue_notice(entry, user, kind),
    do:
      %{audit_id: entry.id, kind: kind, locale: to_string(user.locale)}
      |> Anime.Workers.Mail.new()
      |> Oban.insert!()

  defp notify({:ok, u}) do
    Repo.after_commit(fn ->
      Anime.Cache.invalidate_permissions()
      Phoenix.PubSub.broadcast(Anime.PubSub, "user:#{u.id}:access", :access_changed)
      # The caller reloads its own screen after the mutation. Other tabs still refresh.
      Phoenix.PubSub.broadcast_from(Anime.PubSub, self(), "users:changed", :users_changed)
    end)

    {:ok, u.id}
  end

  defp notify(result), do: result

  defp normalize(p) do
    %{
      q: if(is_binary(p["q"]), do: String.slice(p["q"], 0, 100), else: ""),
      role: positive_id(p["role"]),
      status: Enum.filter(List.wrap(p["status"]), &(&1 in ["active", "blocked"])),
      confirmed: p["confirmed"],
      deletion: p["deletion"],
      term: p["term"],
      blocked_by:
        if(p["blocked_by"] == "missing", do: :missing, else: positive_id(p["blocked_by"])),
      supporter: p["supporter"],
      from: date(p["from"]),
      to: date(p["to"]),
      page: max(1, positive_id(p["page"])),
      sort:
        if(p["sort"] in ~w(id nick role status inserted_at),
          do: p["sort"],
          else: "inserted_at"
        ),
      dir: if(p["dir"] == "asc", do: "asc", else: "desc")
    }
  end

  defp filters(q, p, mode) do
    # Escape LIKE metacharacters: search is literal, not a wildcard language.
    pattern = "%" <> String.replace(p.q, ["\\", "%", "_"], fn c -> "\\" <> c end) <> "%"

    q =
      if String.length(p.q) >= 2 || positive_id(p.q) > 0,
        do:
          where(
            q,
            [u],
            ilike(u.nick, ^pattern) or ilike(u.email, ^pattern) or
              ilike(u.previous_nick, ^pattern) or u.id == ^positive_id(p.q)
          ),
        else: q

    q = if p.role > 0, do: where(q, [u], u.role_id == ^p.role), else: q
    q = if p.status != [], do: where(q, [u], u.status in ^p.status), else: q

    q =
      case p.confirmed do
        "yes" -> where(q, [u], not is_nil(u.email_confirmed_at))
        "no" -> where(q, [u], is_nil(u.email_confirmed_at))
        _ -> q
      end

    q = if p.deletion == "true", do: where(q, [u], u.deletion_requested), else: q

    q =
      case p.term do
        "permanent" -> where(q, [u], u.status == :blocked and is_nil(u.blocked_until))
        "temporary" -> where(q, [u], u.status == :blocked and not is_nil(u.blocked_until))
        _ -> q
      end

    q =
      if p.supporter == "true",
        do: where(q, [u], u.supporter_until > ^DateTime.utc_now()),
        else: q

    q =
      if mode == :blocked do
        case p.blocked_by do
          :missing -> where(q, [u], is_nil(u.blocked_by_id))
          id when id > 0 -> where(q, [u], u.blocked_by_id == ^id)
          _ -> q
        end
      else
        q
      end

    date_field = if mode == :blocked, do: :blocked_at, else: :inserted_at

    q =
      if p.from,
        do: where(q, [u], field(u, ^date_field) >= ^DateTime.new!(p.from, ~T[00:00:00])),
        else: q

    if p.to,
      do: where(q, [u], field(u, ^date_field) < ^DateTime.new!(Date.add(p.to, 1), ~T[00:00:00])),
      else: q
  end

  defp date(v) when is_binary(v) do
    case Date.from_iso8601(v) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp date(_), do: nil
  defp positive_id(v) when is_integer(v) and v > 0 and v < 9_223_372_036_854_775_807, do: v

  defp positive_id(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> positive_id(n)
      _ -> 0
    end
  end

  defp positive_id(_), do: 0
end
