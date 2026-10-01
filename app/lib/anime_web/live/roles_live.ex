defmodule AnimeWeb.RolesLive do
  use AnimeWeb.AdminPage, permission: "roles.role.view"
  alias Anime.Access.{Roles, Role}
  alias Phoenix.LiveView.JS

  def mount(_, _, socket) do
    socket = AnimeWeb.AdminList.init(socket)
    if connected?(socket), do: Phoenix.PubSub.subscribe(Anime.PubSub, "roles:changed")

    {:ok,
     assign(socket,
       listing: nil,
       query: %{},
       editing: nil,
       pending: nil,
       role_form: to_form(Role.changeset(%Role{}, %{}), as: :role)
     ), layout: {AnimeWeb.Layouts, :admin}}
  end

  def handle_params(params, _, socket) do
    query =
      AnimeWeb.AdminQuery.clean(params, ~w(q page sort dir))
      |> AnimeWeb.AdminQuery.sort_query(~w(id code position))

    with_access(socket, __admin_permission__(), &reload(assign(socket, :query, query), &1))
  end

  def handle_event("filter", %{"q" => q}, socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      query =
        Map.merge(
          Map.take(socket.assigns.query, ~w(sort dir)),
          AnimeWeb.AdminQuery.clean(%{"q" => q}, ["q"])
        )

      {:noreply, push_patch(socket, to: activity_url("/admin/roles", query))}
    end)
  end

  def handle_event("page", %{"page" => page}, socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      {:noreply,
       push_patch(socket,
         to:
           activity_url(
             "/admin/roles",
             Map.put(socket.assigns.query, "page", to_string(max(1, int(page))))
           )
       )}
    end)
  end

  def handle_event("new", _, socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      with_access(socket, "roles.role.create", fn _ ->
        {:noreply, clear_form(socket)}
      end)
    end)
  end

  def handle_event("edit", %{"id" => id}, socket) do
    with_access(socket, __admin_permission__(), fn u ->
      if Anime.Access.allowed?(u, "roles.role.edit") do
        {:ok, rows} = Roles.list(u)

        case Enum.find(rows, &(&1.role.id == int(id))) do
          %{role: %{code: code} = role} when code != "owner" ->
            {:noreply,
             assign(socket,
               editing: role,
               role_form: to_form(Role.changeset(role, %{}), as: :role)
             )}

          %{role: %{code: "owner"}} ->
            failure(socket, :protected_owner)

          _ ->
            failure(socket, :not_found)
        end
      else
        Anime.Audit.record(
          u,
          "roles.role.edit",
          "Role",
          int(id),
          :denied,
          socket.assigns.client_meta
        )

        failure(socket, :forbidden)
      end
    end)
  end

  def handle_event("cancel_edit", _, socket) do
    with_access(socket, __admin_permission__(), fn _ -> {:noreply, clear_form(socket)} end)
  end

  def handle_event("validate", %{"role" => attrs}, socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      permission = if socket.assigns.editing, do: "roles.role.edit", else: "roles.role.create"

      with_access(socket, permission, fn _ ->
        cs =
          Role.changeset(socket.assigns.editing || %Role{}, attrs) |> Map.put(:action, :validate)

        {:noreply, assign(socket, :role_form, to_form(cs, as: :role))}
      end)
    end)
  end

  def handle_event("save", %{"role" => attrs}, socket) do
    with_access(socket, __admin_permission__(), fn u ->
      result =
        if socket.assigns.editing,
          do: Roles.edit(u, socket.assigns.editing.id, attrs, socket.assigns.client_meta),
          else: Roles.create(u, attrs, socket.assigns.client_meta)

      case result do
        {:ok, _} ->
          reload(clear_form(socket), u)

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, assign(socket, :role_form, to_form(cs, as: :role))}

        {:error, reason} ->
          failure(socket, reason)
      end
    end)
  end

  def handle_event("prepare", %{"id" => id, "action" => action}, socket)
      when action in ["delete", "default"] do
    with_access(socket, __admin_permission__(), fn u ->
      permission = if action == "delete", do: "roles.role.delete", else: "roles.role.edit"

      if Anime.Access.allowed?(u, permission) do
        {:ok, rows} = Roles.list(u)

        case Enum.find(rows, &(&1.role.id == int(id))) do
          %{role: role} -> {:noreply, assign(socket, :pending, %{role: role, action: action})}
          _ -> failure(socket, :not_found)
        end
      else
        Anime.Audit.record(u, permission, "Role", int(id), :denied, socket.assigns.client_meta)
        failure(socket, :forbidden)
      end
    end)
  end

  def handle_event("cancel", _, socket),
    do:
      with_access(socket, __admin_permission__(), fn _ ->
        {:noreply, assign(socket, :pending, nil)}
      end)

  def handle_event("confirm", _, socket) do
    with_access(socket, __admin_permission__(), fn u ->
      case socket.assigns.pending do
        %{action: action, role: role} ->
          result =
            if action == "delete",
              do: Roles.delete(u, role.id, socket.assigns.client_meta),
              else: Roles.default(u, role.id, socket.assigns.client_meta)

          case result do
            {:ok, _} -> reload(assign(socket, :pending, nil), u)
            {:error, reason} -> failure(socket, reason)
          end

        _ ->
          failure(socket, :invalid_changes)
      end
    end)
  end

  def handle_info(:roles_changed, socket) do
    with_access(socket, __admin_permission__(), &reload(socket, &1))
  end

  defp reload(socket, _u) do
    query = socket.assigns.query

    AnimeWeb.AdminList.load(socket, query, fn u -> Roles.list_page(u, query) end, fn socket,
                                                                                     listing,
                                                                                     _actor ->
      {:noreply,
       assign(socket,
         listing: listing,
         query: Map.put(socket.assigns.query, "page", to_string(listing.page))
       )}
    end)
  end

  defp clear_form(socket),
    do: assign(socket, editing: nil, role_form: to_form(Role.changeset(%Role{}, %{}), as: :role))

  defp int(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 and n < 9_223_372_036_854_775_807 -> n
      _ -> 0
    end
  end

  def render(assigns) do
    ~H"""
    <section :for={locale <- [@locale]} :key={locale} class="admin">
      <.admin_list_heading title={gettext("Роли")} count={@listing.count} locale={@locale}>
        <:action :if={"roles.role.create" in @permissions}>
          <button
            class="button small"
            disabled={@list_loading || @list_failed}
            phx-click={JS.push("new") |> JS.focus(to: "#role_code")}
          >{gettext("Создать роль")}</button>
        </:action>
      </.admin_list_heading>
      <details
        class="admin-filter-details"
        open
        x-data="adminFilters"
        x-bind:open="expanded"
      >
        <summary x-on:click.prevent="expanded=!expanded">{gettext("Фильтры")}</summary>
        <form id="admin-filters" phx-change="filter" class="admin-filters">
          <label>{gettext("Поиск")}
          <input name="q" value={@query["q"]} phx-debounce="300" maxlength="100" /></label>
        </form>
      </details>
      <.filter_chips query={@query} path="/admin/roles" />
      <.admin_list_feedback loading={@list_loading} failed={@list_failed} />
      <div
        class="admin-table-wrap admin-list-scroll"
        id="roles-region"
        phx-hook="AdminTable"
        aria-busy={to_string(@list_loading)}
        tabindex="0"
        role="region"
        aria-label={gettext("Роли")}
      >
        <table class="admin-table" id="roles-table">
          <thead>
            <tr>
              <.sort_header
                column="id"
                label="ID"
                current={@listing}
                query={@query}
                path="/admin/roles"
              />
              <.sort_header
                column="code"
                label={gettext("Код")}
                current={@listing}
                query={@query}
                path="/admin/roles"
              />
              <th>{gettext("Название")}</th>
              <.sort_header
                column="position"
                label={gettext("Порядок")}
                current={@listing}
                query={@query}
                path="/admin/roles"
              />
              <th>
                {gettext("Пользователи")}
              </th><th>{gettext("Действия")}</th>
            </tr>
          </thead>
          <.admin_skeleton :if={@list_loading} rows={length(@listing.rows)} columns={6} />
          <tbody :if={!@list_loading && !@list_failed}>
            <tr :for={row <- @listing.rows} id={"role-#{row.role.id}"}>
              <td>{row.role.id}</td>
              <td>
                {row.role.code}<span :if={row.role.system} class="badge">{gettext("Системная")}</span>
              </td>
              <td>
                {role_name(row.role)}<span :if={row.role.is_default} class="badge">{gettext(
                  "По умолчанию"
                )}</span><span
                  :if={row.role.show_badge}
                  class="badge"
                >{gettext("Значок")}</span>
              </td>
              <td>{number(row.role.position, @locale)}</td><td>{number(row.user_count, @locale)}</td>
              <td class="role-actions row-actions">
                <button
                  :if={row.role.code != "owner" && "roles.role.edit" in @permissions}
                  phx-click="edit"
                  phx-value-id={row.role.id}
                  title={gettext("Изменить")}
                  aria-label={gettext("Изменить") <> ": " <> role_name(row.role)}
                ><span aria-hidden="true">✎</span></button>
                <button
                  :if={
                    row.role.code != "owner" && !row.role.is_default &&
                      "roles.role.edit" in @permissions
                  }
                  phx-click="prepare"
                  phx-value-id={row.role.id}
                  phx-value-action="default"
                  title={gettext("По умолчанию")}
                  aria-label={gettext("По умолчанию") <> ": " <> role_name(row.role)}
                ><span aria-hidden="true">☆</span></button>
                <button
                  :if={
                    !row.role.system && !row.role.is_default && row.user_count == 0 &&
                      "roles.role.delete" in @permissions
                  }
                  phx-click="prepare"
                  phx-value-id={row.role.id}
                  phx-value-action="delete"
                  title={gettext("Удалить")}
                  aria-label={gettext("Удалить") <> ": " <> role_name(row.role)}
                ><span aria-hidden="true">×</span></button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.admin_empty
        :if={@listing.rows == [] && !@list_loading && !@list_failed}
        query={@query}
        path="/admin/roles"
      >
        <:create :if={"roles.role.create" in @permissions}>
          <button class="button small" phx-click={JS.push("new") |> JS.focus(to: "#role_code")}>{gettext(
            "Создать роль"
          )}</button>
        </:create>
      </.admin_empty>
      <.pagination listing={@listing} query={@query} path="/admin/roles" locale={@locale} />
      <section :if={@editing || "roles.role.create" in @permissions} class="panel">
        <h2>{if @editing, do: gettext("Изменить роль"), else: gettext("Создать роль")}</h2>
        <.form for={@role_form} id="role-form" phx-change="validate" phx-submit="save">
          <fieldset class="admin-form-controls" disabled={@list_loading || @list_failed}>
            <.field form={@role_form} name={:code} label={gettext("Код")} />
            <p :if={@editing && @editing.system} class="hint">
              {gettext("Код системной роли менять нельзя")}
            </p>
            <.field form={@role_form} name={:name} label={gettext("Название")} />
            <p :if={@editing && @editing.system} class="hint">
              {gettext(
                "Исходное название системной роли переводится автоматически. Заданное вами название показывается без перевода."
              )}
            </p>
            <input type="hidden" name="role[show_badge]" value="false" />
            <label class="check"><input
              type="checkbox"
              name="role[show_badge]"
              value="true"
              checked={Phoenix.HTML.Form.input_value(@role_form, :show_badge) in [true, "true"]}
            />{gettext("Показывать значок роли")}</label>
            <button class="button small" type="submit">{gettext("Сохранить")}</button>
            <button :if={@editing} type="button" class="quiet" phx-click="cancel_edit">{gettext(
              "Отменить"
            )}</button>
          </fieldset>
        </.form>
      </section>
      <dialog
        :if={@pending}
        id="role-confirm"
        x-data="{}"
        x-init="$el.showModal()"
        x-on:cancel.prevent="$el.querySelector('[data-dialog-cancel]').click()"
        aria-labelledby="role-confirm-title"
      >
        <h2 id="role-confirm-title">{gettext("Подтвердите действие")}</h2>
        <p>
          {role_name(@pending.role)} · {if @pending.action == "delete",
            do: gettext("Удалить"),
            else: gettext("Роль новых регистраций")}
        </p>
        <button id="confirm-role-action" phx-click="confirm" disabled={@list_loading || @list_failed}>{gettext(
          "Подтвердить"
        )}</button>
        <p :if={Phoenix.Flash.get(@flash, :error)} class="error" role="alert">
          {Phoenix.Flash.get(@flash, :error)}
        </p>
        <button phx-click="cancel" data-dialog-cancel>{gettext("Отменить")}</button>
      </dialog>
    </section>
    """
  end
end
