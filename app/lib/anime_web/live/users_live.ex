defmodule AnimeWeb.UsersLive do
  use AnimeWeb.AdminPage, permission: "users.user.view"
  alias Anime.Accounts.Administration

  def mount(_, _, socket) do
    socket = AnimeWeb.AdminList.init(socket)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Anime.PubSub, "users:changed")
      Phoenix.PubSub.subscribe(Anime.PubSub, "roles:changed")
    end

    {:ok,
     assign(socket,
       listing: nil,
       query: %{},
       selected: %{},
       pending: nil,
       summary: nil,
       page_title: gettext("Пользователи")
     ), layout: {AnimeWeb.Layouts, :admin}}
  end

  def handle_params(params, _, socket) do
    with_access(socket, __admin_permission__(), fn actor ->
      keys =
        if socket.assigns.live_action == :blocked,
          do: ~w(q term blocked_by from to page sort dir),
          else: ~w(q role status confirmed deletion term supporter from to page sort dir)

      params = AnimeWeb.AdminQuery.clean(params, keys)

      columns =
        if socket.assigns.live_action == :blocked,
          do: ~w(id nick blocked_at),
          else: ~w(id nick role status inserted_at)

      params = AnimeWeb.AdminQuery.sort_query(params, columns)

      load(assign(socket, selected: %{}, pending: nil, summary: nil), actor, params)
    end)
  end

  def handle_event("filter", %{"filters" => params}, socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      params =
        Map.merge(Map.take(socket.assigns.query, ~w(sort dir)), params) |> Map.delete("page")

      {:noreply, push_patch(socket, to: address(socket, params))}
    end)
  end

  def handle_event("select", %{"id" => id}, %{assigns: %{pending: nil}} = socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      case Enum.find(socket.assigns.listing.rows, &(to_string(&1.id) == id)) do
        nil ->
          failure(socket, :invalid_selection)

        row ->
          selected = socket.assigns.selected

          selected =
            if Map.has_key?(selected, row.id),
              do: Map.delete(selected, row.id),
              else: Map.put(selected, row.id, row.updated_at)

          {:noreply, assign(socket, selected: selected, summary: nil)}
      end
    end)
  end

  def handle_event("select_page", _, %{assigns: %{pending: nil}} = socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      selected =
        if map_size(socket.assigns.selected) == length(socket.assigns.listing.rows),
          do: %{},
          else: Map.new(socket.assigns.listing.rows, &{&1.id, &1.updated_at})

      {:noreply, assign(socket, selected: selected, summary: nil)}
    end)
  end

  def handle_event(
        "prepare_bulk",
        %{"action" => action} = params,
        %{assigns: %{pending: nil}} = socket
      )
      when action in ~w(role revoke) do
    with_access(socket, __admin_permission__(), fn _ ->
      with_access(socket, bulk_permission(action), fn _ ->
        # IDs and versions come only from this page's server-held selection, never the form.
        selected =
          if Map.has_key?(params, "id") do
            case Enum.find(socket.assigns.listing.rows, &(to_string(&1.id) == params["id"])) do
              nil -> %{}
              row -> %{row.id => row.updated_at}
            end
          else
            socket.assigns.selected
          end

        if map_size(selected) in 1..50 do
          entries =
            selected
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.map(fn {id, version} -> %{id: id, updated_at: version} end)

          {:noreply,
           assign(socket,
             pending: %{action: action, entries: entries},
             summary: nil,
             selected: selected
           )}
        else
          failure(socket, :invalid_selection)
        end
      end)
    end)
  end

  def handle_event("cancel_bulk", _, socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      {:noreply, assign(socket, :pending, nil)}
    end)
  end

  def handle_event("confirm_bulk", params, %{assigns: %{pending: pending}} = socket)
      when not is_nil(pending) do
    with_access(socket, __admin_permission__(), fn actor ->
      action = if pending.action == "role", do: :role, else: :revoke
      meta = Map.put(socket.assigns.client_meta, :session_token, socket.assigns.session_token)

      case Administration.bulk(
             actor,
             pending.entries,
             action,
             Map.take(params, ["role_id"]),
             meta
           ) do
        {:ok, summary} ->
          failed =
            for entry <- pending.entries,
                entry.id in summary.failed_ids,
                into: %{},
                do: {entry.id, entry.updated_at}

          load(
            assign(socket, pending: nil, summary: summary, selected: failed),
            actor,
            socket.assigns.query
          )

        {:error, reason} ->
          failure(socket, reason)
      end
    end)
  end

  def handle_event("confirm_bulk", _, socket), do: failure(socket, :confirmation_required)
  def handle_event(_, _, socket), do: failure(socket, :invalid_action)

  def handle_info(message, socket) when message in [:users_changed, :roles_changed] do
    with_access(socket, __admin_permission__(), fn actor ->
      load(socket, actor, socket.assigns.query)
    end)
  end

  defp load(socket, _actor, params) do
    blocked = socket.assigns.live_action == :blocked

    AnimeWeb.AdminList.load(
      socket,
      params,
      fn actor ->
        if blocked,
          do: Administration.blocked(actor, params),
          else: Administration.list(actor, params)
      end,
      fn socket, listing, actor ->
        selected = Map.take(socket.assigns.selected, Enum.map(listing.rows, & &1.id))

        {:noreply,
         assign(socket,
           listing: listing,
           query: Map.put(params, "page", to_string(listing.page)),
           selected: selected,
           permissions: Anime.Access.permissions(actor)
         )}
      end
    )
  end

  defp address(socket, params) do
    path =
      if socket.assigns.live_action == :blocked, do: "/admin/users/blocked", else: "/admin/users"

    activity_url(path, params)
  end

  defp bulk_permission("role"), do: "users.role.assign"
  defp bulk_permission("revoke"), do: "users.session.revoke"
  defp action_label("role"), do: gettext("Сменить роль")
  defp action_label("revoke"), do: gettext("Завершить все сессии")
  defp reason_label(reason), do: AnimeWeb.AdminErrors.message(reason)

  def render(assigns) do
    assigns =
      assign(
        assigns,
        :list_path,
        if(assigns.live_action == :blocked, do: "/admin/users/blocked", else: "/admin/users")
      )

    ~H"""
    <section :for={locale <- [@locale]} :key={locale} class="admin admin-users">
      <.admin_list_heading
        title={if @live_action == :blocked, do: gettext("Блокировки"), else: gettext("Пользователи")}
        count={@listing && @listing.count}
        locale={@locale}
      />
      <section :if={@listing}>
        <details
          class="admin-filter-details"
          open
          x-data="adminFilters"
          x-bind:open="expanded"
        >
          <summary x-on:click.prevent="expanded=!expanded">{gettext("Фильтры")}</summary>
          <form id="users-filter" phx-change="filter" class="admin-filters">
            <label>{gettext("Поиск")}<input
              name="filters[q]"
              value={@query["q"]}
              phx-debounce="300"
              placeholder={gettext("Ник, email или ID")}
            /></label>
            <label :if={@live_action != :blocked}>{gettext("Роль")}<select name="filters[role]"><option value="">
              {gettext("Все")}
            </option><option
              :for={r <- @listing.roles}
              value={r.id}
              selected={@query["role"] == to_string(r.id)}
            >
              {role_name(r)}
            </option></select></label>
            <fieldset :if={@live_action != :blocked}>
              <legend>{gettext("Статус")}</legend><label><input
                type="checkbox"
                name="filters[status][]"
                value="active"
                checked={"active" in List.wrap(@query["status"])}
              />{gettext("Активен")}</label><label><input
                type="checkbox"
                name="filters[status][]"
                value="blocked"
                checked={"blocked" in List.wrap(@query["status"])}
              />{gettext("Заблокирован")}</label>
            </fieldset>
            <label :if={@live_action != :blocked}>{gettext("Подтверждение email")}<select name="filters[confirmed]"><option value="">
              {gettext("Все")}
            </option><option value="yes" selected={@query["confirmed"] == "yes"}>
              {gettext("Подтверждён")}
            </option><option value="no" selected={@query["confirmed"] == "no"}>
              {gettext("Не подтверждён")}
            </option></select></label>
            <label>{gettext("Срок блокировки")}<select name="filters[term]"><option value="">
              {gettext("Все")}
            </option><option value="permanent" selected={@query["term"] == "permanent"}>
              {gettext("Бессрочно")}
            </option><option value="temporary" selected={@query["term"] == "temporary"}>
              {gettext("С указанным сроком")}
            </option></select></label>
            <label :if={@live_action == :blocked}>
              {gettext("Кто заблокировал")}
              <select name="filters[blocked_by]">
                <option value="">{gettext("Все")}</option>
                <option value="missing" selected={@query["blocked_by"] == "missing"}>
                  {gettext("Не указан")}
                </option>
                <option
                  :if={
                    @query["blocked_by"] not in [nil, "missing"] &&
                      !Enum.any?(@listing.operators, &(to_string(&1.id) == @query["blocked_by"]))
                  }
                  value={@query["blocked_by"]}
                  selected
                >
                  ID {@query["blocked_by"]}
                </option>
                <option
                  :for={operator <- @listing.operators}
                  value={operator.id}
                  selected={@query["blocked_by"] == to_string(operator.id)}
                >
                  {operator.nick} (#{operator.id})
                </option>
              </select>
            </label>
            <label>{if @live_action == :blocked,
              do: gettext("Дата блокировки от"),
              else: gettext("Дата регистрации от")}<input
              type="date"
              name="filters[from]"
              value={@query["from"]}
            /></label><label>{if @live_action == :blocked,
              do: gettext("Дата блокировки до"),
              else: gettext("Дата регистрации до")}<input
              type="date"
              name="filters[to]"
              value={@query["to"]}
            /></label>
            <label :if={@live_action != :blocked}><input
              type="checkbox"
              name="filters[deletion]"
              value="true"
              checked={@query["deletion"] == "true"}
            />{gettext("Удаление запрошено")}</label>
            <label :if={@live_action != :blocked}><input
              type="checkbox"
              name="filters[supporter]"
              value="true"
              checked={@query["supporter"] == "true"}
            />{gettext("Сторонник")}</label>
          </form>
        </details>
        <.filter_chips
          query={@query}
          path={if @live_action == :blocked, do: "/admin/users/blocked", else: "/admin/users"}
        />
        <section :if={@summary} id="bulk-result" class="bulk-result" role="status" aria-live="polite">
          <h2>{gettext("Результат операции")}</h2>
          <p>
            {gettext("Применено")}: {number(@summary.applied, @locale)} · {gettext("Отказов")}: {number(
              @summary.denied,
              @locale
            )} · {gettext("Из них изменены другим оператором")}: {number(@summary.changed, @locale)}
          </p>
          <ul :if={@summary.failures != []}>
            <li :for={entry <- @summary.failures}>
              ID {entry.id}: {reason_label(entry.reason)}
            </li>
          </ul>
          <p :if={@summary.denied > 0}>
            {gettext(
              "Отказавшие записи текущей страницы остаются выделенными. Для повторной попытки после проверки снимите выделение и выберите их заново."
            )}
          </p>
        </section>
        <div :if={map_size(@selected) > 0} id="bulk-actions" class="bulk-actions">
          <strong>{gettext("Выбрано")}: {number(map_size(@selected), @locale)}</strong>
          <button
            :for={action <- ~w(role revoke)}
            :if={bulk_permission(action) in @permissions}
            id={"bulk-#{action}"}
            type="button"
            phx-click="prepare_bulk"
            phx-value-action={action}
            disabled={not is_nil(@pending) || @list_loading || @list_failed}
            phx-disable-with="…"
          >{action_label(action)}</button>
        </div>
        <.admin_list_feedback loading={@list_loading} failed={@list_failed} />
        <div
          class="admin-table-wrap admin-list-scroll"
          id="users-region"
          phx-hook="AdminTable"
          aria-busy={to_string(@list_loading)}
          tabindex="0"
          role="region"
          aria-label={
            if @live_action == :blocked, do: gettext("Блокировки"), else: gettext("Пользователи")
          }
        >
          <table class="admin-table" id="users-table">
            <thead>
              <tr>
                <th class="selection-cell">
                  <input
                    id="select-page"
                    type="checkbox"
                    phx-click="select_page"
                    aria-label={gettext("Выбрать текущую страницу")}
                    aria-checked={
                      if map_size(@selected) > 0 && map_size(@selected) < length(@listing.rows),
                        do: "mixed",
                        else: to_string(map_size(@selected) > 0)
                    }
                    checked={@listing.rows != [] && map_size(@selected) == length(@listing.rows)}
                    disabled={
                      @listing.rows == [] || not is_nil(@pending) || @list_loading || @list_failed
                    }
                  />
                </th>
                <.sort_header
                  column="id"
                  label="ID"
                  current={@listing.params}
                  query={@query}
                  path={@list_path}
                />
                <.sort_header
                  column="nick"
                  label={gettext("Ник")}
                  current={@listing.params}
                  query={@query}
                  path={@list_path}
                />
                <th :if={@live_action != :blocked}>Email</th>
                <.sort_header
                  :if={@live_action != :blocked}
                  column="role"
                  label={gettext("Роль")}
                  current={@listing.params}
                  query={@query}
                  path={@list_path}
                />
                <.sort_header
                  :if={@live_action != :blocked}
                  column="inserted_at"
                  label={gettext("Дата регистрации")}
                  current={@listing.params}
                  query={@query}
                  path={@list_path}
                />
                <th :if={@live_action != :blocked}>{gettext("Последняя активность")}</th>
                <th :if={@live_action == :blocked}>{gettext("Причина блокировки")}</th>
                <.sort_header
                  :if={@live_action == :blocked}
                  column="blocked_at"
                  label={gettext("Дата блокировки")}
                  current={@listing.params}
                  query={@query}
                  path={@list_path}
                />
                <th :if={@live_action == :blocked}>{gettext("Дата окончания")}</th>
                <th :if={@live_action == :blocked}>{gettext("Кто заблокировал")}</th>
                <.sort_header
                  :if={@live_action != :blocked}
                  column="status"
                  label={gettext("Статус")}
                  current={@listing.params}
                  query={@query}
                  path={@list_path}
                />
                <th :if={@live_action == :blocked}>{gettext("Статус")}</th>
                <th class="row-actions">{gettext("Действия")}</th>
              </tr>
            </thead>
            <.admin_skeleton
              :if={@list_loading}
              rows={length(@listing.rows)}
              columns={9}
            />
            <tbody :if={!@list_loading && !@list_failed}>
              <tr :for={u <- @listing.rows} id={"user-#{u.id}"}>
                <td class="selection-cell">
                  <input
                    type="checkbox"
                    id={"select-user-#{u.id}"}
                    aria-label={gettext("Выбрать пользователя") <> " " <> u.nick}
                    phx-click="select"
                    phx-value-id={u.id}
                    checked={Map.has_key?(@selected, u.id)}
                    disabled={not is_nil(@pending)}
                  />
                </td>
                <td>{u.id}</td><td>
                  <a href={"/admin/users/#{u.id}"}><span class="user-initial" aria-hidden="true">{String.first(u.nick)}</span>{u.nick}</a>
                </td><td :if={@live_action != :blocked}>
                  {u.email}<small class={
                    if u.email_confirmed_at, do: "email-confirmed", else: "email-unconfirmed"
                  }>{if u.email_confirmed_at,
                    do: gettext("Подтверждён"),
                    else: gettext("Не подтверждён")}</small>
                </td><td :if={@live_action != :blocked}>{role_name(u)}</td><td :if={
                  @live_action != :blocked
                }>
                  <.admin_datetime value={u.inserted_at} locale={@locale} />
                </td><td :if={@live_action != :blocked}>
                  <.admin_datetime value={u.last_used_at} locale={@locale} />
                </td>
                <td :if={@live_action == :blocked}>{u.block_reason || "—"}</td>
                <td :if={@live_action == :blocked}>
                  <.admin_datetime value={u.blocked_at} locale={@locale} />
                </td>
                <td :if={@live_action == :blocked}>
                  <.admin_datetime
                    value={u.blocked_until}
                    locale={@locale}
                    empty={gettext("Бессрочно")}
                  />
                </td>
                <td :if={@live_action == :blocked}>
                  <a :if={u.blocked_by_id} href={"/admin/users/#{u.blocked_by_id}"}>{u.blocked_by_nick ||
                    gettext("Не указан")}</a>
                  <span :if={is_nil(u.blocked_by_id)}>{gettext("Не указан")}</span>
                </td>
                <td><.user_status user={u} /></td>
                <td class="row-actions">
                  <a
                    href={"/admin/users/#{u.id}"}
                    title={gettext("Открыть")}
                    aria-label={gettext("Открыть")}
                  ><span aria-hidden="true">↗</span></a>
                  <a
                    :if={
                      u.id != @current_user.id &&
                        if(u.status == :active, do: "users.user.ban", else: "users.user.unban") in @permissions
                    }
                    href={"/admin/users/#{u.id}?tab=blocks"}
                    title={
                      if u.status == :active,
                        do: gettext("Заблокировать"),
                        else: gettext("Разблокировать")
                    }
                    aria-label={
                      if u.status == :active,
                        do: gettext("Заблокировать"),
                        else: gettext("Разблокировать")
                    }
                  >
                    <span aria-hidden="true">{if u.status == :active, do: "⊘", else: "✓"}</span>
                  </a>
                  <button
                    :if={u.id != @current_user.id && "users.role.assign" in @permissions}
                    type="button"
                    id={"row-role-#{u.id}"}
                    phx-click="prepare_bulk"
                    phx-value-action="role"
                    phx-value-id={u.id}
                    title={gettext("Сменить роль")}
                    aria-label={gettext("Сменить роль")}
                    disabled={not is_nil(@pending)}
                    phx-disable-with="…"
                  ><span aria-hidden="true">⇄</span></button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <.admin_empty
          :if={@listing.rows == [] && !@list_loading && !@list_failed}
          query={@query}
          path={@list_path}
        />
        <.pagination
          listing={@listing}
          query={@query}
          locale={@locale}
          path={if @live_action == :blocked, do: "/admin/users/blocked", else: "/admin/users"}
        />
        <dialog
          :if={@pending}
          id="bulk-confirm"
          class="admin-dialog"
          x-data="{}"
          x-init="$el.showModal()"
          x-on:cancel.prevent="$el.querySelector('[data-dialog-cancel]').click()"
          aria-labelledby="bulk-confirm-title"
        >
          <h2 id="bulk-confirm-title">{action_label(@pending.action)}</h2>
          <p>
            {gettext("Выбрано")}: {number(length(@pending.entries), @locale)}. {gettext(
              "Первые 10 ID"
            )}: {Enum.map_join(
              Enum.take(@pending.entries, 10),
              ", ",
              & &1.id
            )}
          </p>
          <p>
            {gettext(
              "Каждая запись проверяется отдельно. Отказ по одной не отменяет остальные изменения."
            )}
          </p>
          <p :if={@pending.action == "revoke"}>
            {gettext(
              "Будут завершены обычные сессии и входы «Запомнить меня». Почтовые ссылки не изменятся."
            )}
          </p>
          <p :if={Phoenix.Flash.get(@flash, :error)} role="alert">
            {Phoenix.Flash.get(@flash, :error)}
          </p>
          <form id="bulk-form" phx-submit="confirm_bulk">
            <label :if={@pending.action == "role"}>{gettext("Новая роль")}
            <select name="role_id" required disabled={@list_loading || @list_failed}>
              <option value="">{gettext("Выберите роль")}</option>
              <option :for={role <- @listing.assignable_roles} value={role.id}>
                {role_name(role)}
              </option>
            </select></label>
            <button
              type="submit"
              id="confirm-bulk-action"
              disabled={@list_loading || @list_failed}
              phx-disable-with={gettext("Выполняется…")}
            >{gettext("Подтвердить")}</button>
            <button type="button" phx-click="cancel_bulk" data-dialog-cancel>{gettext("Отмена")}</button>
          </form>
        </dialog>
      </section>
    </section>
    """
  end
end
