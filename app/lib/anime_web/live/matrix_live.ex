defmodule AnimeWeb.MatrixLive do
  use AnimeWeb.AdminPage, permission: "roles.matrix.edit"
  alias Anime.Access.Roles

  def mount(_, _, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Anime.PubSub, "roles:changed")
    {:ok, data} = Roles.matrix(socket.assigns.current_user)

    {:ok, put_data(socket, data) |> assign(q: "", group: "", role_filter: "", query: %{}),
     layout: {AnimeWeb.Layouts, :admin}}
  end

  def handle_params(params, _, socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      query = filter_query(params, socket.assigns.roles)

      {:noreply,
       assign(socket,
         query: query,
         q: query["q"] || "",
         group: query["group"] || "",
         role_filter: query["role"] || ""
       )}
    end)
  end

  def handle_event("filter", params, socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      query = filter_query(params, socket.assigns.roles)
      {:noreply, push_patch(socket, to: activity_url("/admin/roles/matrix", query))}
    end)
  end

  def handle_event("change", %{"grants" => grants}, socket) when is_map(grants) do
    with_access(socket, __admin_permission__(), fn _ ->
      draft =
        Enum.reduce(socket.assigns.roles, socket.assigns.draft, fn role, acc ->
          case grants[to_string(role.id)] do
            values when is_list(values) and role.code != "owner" ->
              Map.put(acc, role.id, MapSet.new(Enum.filter(values, &(is_binary(&1) && &1 != ""))))

            _ ->
              acc
          end
        end)

      {:noreply, assign(socket, draft: draft, pending: nil)}
    end)
  end

  def handle_event("review", _, socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      {:noreply, assign(socket, :pending, differences(socket.assigns))}
    end)
  end

  def handle_event("cancel", _, socket),
    do:
      with_access(socket, __admin_permission__(), fn _ ->
        {:noreply, assign(socket, :pending, nil)}
      end)

  def handle_event("reset", _, socket),
    do: with_access(socket, __admin_permission__(), &reload(socket, &1))

  def handle_event("save", _, socket) do
    with_access(socket, __admin_permission__(), fn u ->
      if socket.assigns.pending && socket.assigns.pending != [] do
        changes =
          Enum.map(socket.assigns.pending, fn d ->
            {d.role.id, MapSet.to_list(socket.assigns.draft[d.role.id])}
          end)

        case Roles.update_matrices(u, changes, socket.assigns.base, socket.assigns.client_meta) do
          {:ok, _} -> reload(put_flash(socket, :info, gettext("Матрица сохранена")), u)
          {:error, reason} -> failure(socket, reason)
        end
      else
        failure(socket, :invalid_changes)
      end
    end)
  end

  def handle_info(:roles_changed, socket) do
    with_access(socket, __admin_permission__(), fn u ->
      if differences(socket.assigns) == [],
        do: reload(socket, u),
        else:
          {:noreply,
           put_flash(
             socket,
             :info,
             gettext(
               "Роли изменились в другом окне. Проверьте изменения или перечитайте матрицу."
             )
           )}
    end)
  end

  defp filter_query(params, roles) do
    query = AnimeWeb.AdminQuery.clean(params, ~w(q group role))

    if Enum.any?(roles, &(to_string(&1.id) == query["role"])),
      do: query,
      else: Map.delete(query, "role")
  end

  defp reload(socket, u) do
    case Roles.matrix(u) do
      {:ok, data} -> {:noreply, put_data(socket, data)}
      {:error, reason} -> failure(socket, reason)
    end
  end

  defp put_data(socket, data),
    do:
      assign(socket,
        roles: data.roles,
        all_permissions: data.permissions,
        base: data.grants,
        draft: data.grants,
        pending: nil
      )

  defp differences(a) do
    for r <- a.roles, a.base[r.id] != a.draft[r.id] do
      %{
        role: r,
        added: MapSet.difference(a.draft[r.id], a.base[r.id]) |> Enum.sort(),
        removed: MapSet.difference(a.base[r.id], a.draft[r.id]) |> Enum.sort()
      }
    end
  end

  defp locked?(a, role, code),
    do:
      role.code == "owner" || code not in a.permissions ||
        (role.id == a.current_user.role_id && MapSet.member?(a.base[role.id], code))

  defp visible?(a, code, name),
    do:
      (a.group == "" || String.starts_with?(code, a.group <> ".")) &&
        (String.contains?(String.downcase(code <> " " <> name), String.downcase(a.q)) ||
           code in a.matched_permissions)

  def render(assigns) do
    assigns =
      assign(assigns, :matched_permissions, Anime.Access.Labels.matching_permissions(assigns.q))

    assigns =
      assign(
        assigns,
        :groups,
        Enum.group_by(assigns.all_permissions, fn {code, _} -> hd(String.split(code, ".")) end)
        |> Enum.sort()
      )

    ~H"""
    <section :for={locale <- [@locale]} :key={locale} class="admin">
      <h1>{gettext("Матрица прав")}</h1>
      <details class="admin-filter-details" open x-data="adminFilters" x-bind:open="expanded">
        <summary x-on:click.prevent="expanded=!expanded">{gettext("Фильтры")}</summary>
        <form id="admin-filters" phx-change="filter" class="admin-filters">
          <label>{gettext("Поиск")} <input name="q" value={@q} phx-debounce="300" maxlength="100" /></label>
          <label>{gettext("Область")}
          <select name="group"><option value="">{gettext("Все")}</option><option
            :for={{g, _} <- @groups}
            value={g}
            selected={g == @group}
          >
            {group_name(g)}
          </option></select></label>
          <label>{gettext("Роль")}
          <select name="role"><option value="">{gettext("Все")}</option><option
            :for={r <- @roles}
            value={r.id}
            selected={to_string(r.id) == @role_filter}
          >
            {role_name(r)}
          </option></select></label>
        </form>
      </details>
      <.filter_chips query={@query} path="/admin/roles/matrix" />
      <form id="matrix-form" phx-change="change" phx-submit="review">
        <input
          :for={r <- @roles}
          :if={r.code != "owner"}
          type="hidden"
          name={"grants[#{r.id}][]"}
          value=""
        />
        <div
          class="admin-table-wrap matrix-wrap"
          tabindex="0"
          role="region"
          aria-label={gettext("Матрица прав")}
        >
          <table class="admin-table matrix-table">
            <thead>
              <tr>
                <th>{gettext("Разрешения")}</th><th
                  :for={r <- @roles}
                  hidden={@role_filter != "" && @role_filter != to_string(r.id)}
                >
                  {role_name(r)}<small>{number(MapSet.size(@draft[r.id]), @locale)} / {number(
                    length(@all_permissions),
                    @locale
                  )}</small>
                </th>
              </tr>
            </thead>
            <tbody :for={{group, rows} <- @groups}>
              <tr class="matrix-group" hidden={@group != "" && @group != group}>
                <th colspan={1 + length(@roles)}>{group_name(group)}</th>
              </tr>
              <tr :for={{code, name} <- rows} hidden={!visible?(assigns, code, name)}>
                <th scope="row"><code>{code}</code><small>{permission_name(code)}</small></th>
                <td :for={r <- @roles} hidden={@role_filter != "" && @role_filter != to_string(r.id)}>
                  <input
                    :if={
                      r.code != "owner" && locked?(assigns, r, code) &&
                        MapSet.member?(@draft[r.id], code)
                    }
                    type="hidden"
                    name={"grants[#{r.id}][]"}
                    value={code}
                  />
                  <input
                    type="checkbox"
                    name={"grants[#{r.id}][]"}
                    value={code}
                    checked={MapSet.member?(@draft[r.id], code)}
                    disabled={locked?(assigns, r, code)}
                    aria-label={role_name(r) <> ": " <> permission_name(code) <> " (" <> code <> ")"}
                  />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="matrix-actions">
          <button class="button small" type="submit">{gettext("Проверить изменения")}</button><button
            type="button"
            phx-click="reset"
            class="quiet"
          >{gettext("Отменить изменения")}</button>
        </div>
      </form>
      <dialog
        :if={@pending != nil}
        id="matrix-confirm"
        x-data="{}"
        x-init="$el.showModal()"
        x-on:cancel.prevent="$el.querySelector('[data-dialog-cancel]').click()"
        aria-labelledby="matrix-confirm-title"
      >
        <h2 id="matrix-confirm-title">{gettext("Подтвердите изменения")}</h2>
        <p :if={@pending == []}>{gettext("Изменений нет")}</p>
        <section :for={d <- @pending}>
          <h3>{role_name(d.role)}</h3>
          <p :for={code <- d.added}>+ <code>{code}</code> — {permission_name(code)}</p>
          <p :for={code <- d.removed}>− <code>{code}</code> — {permission_name(code)}</p>
        </section>
        <button :if={@pending != []} id="save-matrix" phx-click="save">{gettext("Сохранить")}</button>
        <p :if={Phoenix.Flash.get(@flash, :error)} class="error" role="alert">
          {Phoenix.Flash.get(@flash, :error)}
        </p>
        <button phx-click="cancel" data-dialog-cancel>{gettext("Отменить")}</button>
      </dialog>
    </section>
    """
  end
end
