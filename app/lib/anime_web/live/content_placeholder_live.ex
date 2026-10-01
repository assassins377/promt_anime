defmodule AnimeWeb.ContentPlaceholderLive do
  use AnimeWeb.AdminPage, permission: "content.anime.create"

  def mount(_, _, socket), do: {:ok, socket}
  def handle_params(_, _, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <section class="admin">
      <h1>{gettext("Добавить аниме")}</h1>
      <p>{gettext("Раздел появится позже")}</p>
    </section>
    """
  end
end
