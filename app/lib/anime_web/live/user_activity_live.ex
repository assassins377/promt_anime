defmodule AnimeWeb.UserActivityLive do
  use AnimeWeb.AdminPage, permission: "users.activity.view"
  alias Anime.Accounts.Activity

  def mount(_, _, socket) do
    socket = AnimeWeb.AdminList.init(socket)
    if connected?(socket), do: Phoenix.PubSub.subscribe(Anime.PubSub, "users:changed")

    {:ok, assign(socket, listing: nil, query: %{}, page_title: gettext("История активности")),
     layout: {AnimeWeb.Layouts, :admin}}
  end

  def handle_params(params, _, socket) do
    params =
      AnimeWeb.AdminQuery.clean(params, ~w(user_id action result ip from to page sort dir))
      |> AnimeWeb.AdminQuery.sort_query(~w(id occurred_at))

    load(assign(socket, :query, params))
  end

  def handle_event("activity_filter", %{"filters" => params}, socket) do
    with_access(socket, __admin_permission__(), fn _ ->
      params = AnimeWeb.AdminQuery.clean(params, ~w(user_id action result ip from to))
      params = Map.merge(Map.take(socket.assigns.query, ~w(sort dir)), params)

      {:noreply,
       push_patch(socket, to: activity_url("/admin/users/activity", Map.put(params, "page", "1")))}
    end)
  end

  def handle_info(:users_changed, socket), do: load(socket)

  defp load(socket) do
    query = socket.assigns.query

    with_access(socket, __admin_permission__(), fn _ ->
      AnimeWeb.AdminList.load(socket, query, fn a -> Activity.list(a, query) end, fn socket,
                                                                                     listing,
                                                                                     _actor ->
        {:noreply,
         assign(socket, listing: listing, query: Map.put(query, "page", to_string(listing.page)))}
      end)
    end)
  end

  def render(assigns) do
    ~H"""
    <section :for={locale <- [@locale]} :key={locale} class="admin admin-users">
      <h1 :if={!@listing}>{gettext("История активности пользователей")}</h1>
      <.activity_panel
        :if={@listing}
        listing={@listing}
        query={@query}
        path="/admin/users/activity"
        locale={@locale}
        heading_level={1}
        loading={@list_loading}
        failed={@list_failed}
      />
    </section>
    """
  end
end
