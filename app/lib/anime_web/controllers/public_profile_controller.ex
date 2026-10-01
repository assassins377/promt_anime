defmodule AnimeWeb.PublicProfileController do
  use AnimeWeb, :controller

  def show(conn, %{"nick" => nick}) do
    conn = put_layout(conn, html: {AnimeWeb.Layouts, :app})

    case Anime.Accounts.public_profile(nick, conn.assigns.current_user) do
      nil ->
        AnimeWeb.PageController.not_found(conn, %{})

      profile ->
        render(conn, :show,
          profile: profile,
          page_title: profile.nick <> " · " <> gettext("Публичный профиль") <> " · Anime",
          robots: "noindex,follow"
        )
    end
  end
end
