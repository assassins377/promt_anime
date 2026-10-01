defmodule AnimeWeb.PageController do
  use AnimeWeb, :controller

  def not_found(conn, _) do
    locale = AnimeWeb.Locale.error_locale(conn)
    Gettext.put_locale(AnimeWeb.Gettext, locale)

    conn
    |> assign(:locale, locale)
    |> put_status(:not_found)
    |> put_view(html: AnimeWeb.PageHTML)
    |> put_layout(html: {AnimeWeb.Layouts, :app})
    |> render(:not_found,
      page_title: AnimeWeb.PageTitles.title(gettext("Страница не найдена")),
      robots: "noindex,follow"
    )
  end

  def forbidden(conn, _) do
    conn
    |> put_status(:forbidden)
    |> put_layout(html: {AnimeWeb.Layouts, :app})
    |> render(:forbidden, page_title: gettext("Недостаточно прав") <> " · Anime")
  end
end
