defmodule AnimeWeb.PermissionsLive do
  use AnimeWeb.AdminPage, permission: "roles.permission.view"
  alias Anime.Access.Roles

  def mount(_, _, socket) do
    socket = AnimeWeb.AdminList.init(socket)
    {:ok, assign(socket, listing: nil, query: %{}), layout: {AnimeWeb.Layouts, :admin}}
  end

  def handle_params(params, _, socket) do
    query =
      AnimeWeb.AdminQuery.clean(params, ~w(q group page sort dir))
      |> AnimeWeb.AdminQuery.sort_query(~w(id code))

    with_access(socket, __admin_permission__(), fn _ ->
      AnimeWeb.AdminList.load(
        socket,
        query,
        fn u -> Roles.permissions_page(u, query) end,
        fn socket, listing, _actor ->
          {:noreply,
           assign(socket,
             listing: listing,
             query: Map.put(query, "page", to_string(listing.page))
           )}
        end
      )
    end)
  end

  def handle_event("filter", %{"q" => q, "group" => group}, socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      query =
        Map.merge(
          Map.take(socket.assigns.query, ~w(sort dir)),
          AnimeWeb.AdminQuery.clean(%{"q" => q, "group" => group}, ~w(q group))
        )

      {:noreply, push_patch(socket, to: activity_url("/admin/roles/permissions", query))}
    end)
  end

  def render(assigns) do
    ~H"""
    <section :for={locale <- [@locale]} :key={locale} class="admin">
      <.admin_list_heading title={gettext("Разрешения")} count={@listing.count} locale={@locale} />
      <p class="hint">{gettext("Справочник только для чтения")}</p>
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
          <label>{gettext("Область")}
          <select name="group"><option value="">{gettext("Все")}</option><option
            :for={g <- @listing.groups}
            value={g}
            selected={g == @query["group"]}
          >
            {group_name(g)}
          </option></select></label>
        </form>
      </details>
      <.filter_chips query={@query} path="/admin/roles/permissions" />
      <.admin_list_feedback loading={@list_loading} failed={@list_failed} />
      <div
        class="admin-table-wrap admin-list-scroll"
        id="permissions-region"
        phx-hook="AdminTable"
        aria-busy={to_string(@list_loading)}
        tabindex="0"
        role="region"
        aria-label={gettext("Разрешения")}
      >
        <table class="admin-table" id="permissions-table">
          <thead>
            <tr>
              <.sort_header
                column="id"
                label="ID"
                current={@listing}
                query={@query}
                path="/admin/roles/permissions"
              />
              <.sort_header
                column="code"
                label={gettext("Код")}
                current={@listing}
                query={@query}
                path="/admin/roles/permissions"
              />
              <th>{gettext("Название")}</th><th>{gettext("Область")}</th>
            </tr>
          </thead>
          <.admin_skeleton :if={@list_loading} rows={length(@listing.rows)} columns={4} />
          <tbody :if={!@list_loading && !@list_failed}>
            <tr :for={p <- @listing.rows}>
              <td>{p.id}</td><td>{p.code}</td><td>{permission_name(p.code)}</td><td>
                {group_name(p.group)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.admin_empty
        :if={@listing.rows == [] && !@list_loading && !@list_failed}
        query={@query}
        path="/admin/roles/permissions"
      />
      <.pagination listing={@listing} query={@query} path="/admin/roles/permissions" locale={@locale} />
    </section>
    """
  end
end
