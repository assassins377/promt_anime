defmodule AnimeWeb.AdminListHarness do
  @moduledoc false
  use AnimeWeb.AdminPage, permission: "users.user.view"

  def mount(_, session, socket) do
    Gettext.put_locale(AnimeWeb.Gettext, "ru")

    {:ok,
     socket
     |> AnimeWeb.AdminList.init()
     |> assign(
       session_token: session["token"],
       tester: session["tester"],
       listing: %{rows: ["initial"]},
       query: %{},
       writes: 0
     )}
  end

  def handle_event("filter", %{"q" => q}, socket) do
    tester = socket.assigns.tester

    fetch = fn _ ->
      send(tester, {:fetch, q, self()})

      receive do
        {:result, value} -> value
        :crash -> exit(:simulated_failure)
      end
    end

    AnimeWeb.AdminList.load(socket, %{"q" => q}, fetch, fn socket, listing, _ ->
      {:noreply, assign(socket, :listing, listing)}
    end)
  end

  def handle_event("write", _, socket),
    do: {:noreply, assign(socket, :writes, socket.assigns.writes + 1)}

  def render(assigns) do
    ~H"""
    <section>
      <p :if={Phoenix.Flash.get(@flash, :error)} role="alert">{Phoenix.Flash.get(@flash, :error)}</p>
      <span id="writes">{@writes}</span>
      <input id="query" value={@query["q"]} />
      <.admin_list_feedback loading={@list_loading} failed={@list_failed} />
      <div id="region" aria-busy={to_string(@list_loading)}>
        <table>
          <thead>
            <tr>
              <th>Rows</th>
            </tr>
          </thead>
          <.admin_skeleton :if={@list_loading} rows={length(@listing.rows)} columns={1} />
          <tbody :if={!@list_loading && !@list_failed} id="rows">
            <tr :for={row <- @listing.rows}>
              <td>{row}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end
end
