defmodule AnimeWeb.ErrorHTML do
  use AnimeWeb, :html

  def render(template, assigns) do
    conn = Map.get(assigns, :conn, %Plug.Conn{request_path: "/"})

    locale =
      if template == "404.html",
        do: AnimeWeb.Locale.error_locale(conn),
        else:
          AnimeWeb.Locale.normalize(conn.assigns[:locale]) || AnimeWeb.Locale.error_locale(conn)

    # Never copy reason, stack, params or a database-backed user into error assigns.
    # This renderer must also work while Repo and the session parser are unavailable.
    safe = %{
      conn: Plug.Conn.assign(conn, :locale, locale),
      locale: locale,
      current_user: nil,
      current_path: AnimeWeb.Locale.localized(locale, "/"),
      flash: %{},
      request_id: List.first(Plug.Conn.get_resp_header(conn, "x-request-id")) || "—"
    }

    Gettext.with_locale(AnimeWeb.Gettext, locale, fn ->
      case template do
        "404.html" -> not_found(safe)
        "403.html" -> forbidden(safe)
        _ -> failure(Map.put(safe, :text, message(template)))
      end
    end)
  end

  defp not_found(assigns) do
    assigns =
      assigns
      |> Map.put(:page_title, AnimeWeb.PageTitles.title(gettext("Страница не найдена")))
      |> Map.put(:robots, "noindex,follow")

    chrome(assigns, AnimeWeb.PageHTML.not_found(assigns))
  end

  defp forbidden(assigns) do
    assigns =
      assigns
      |> Map.put(:page_title, AnimeWeb.PageTitles.title(gettext("Недостаточно прав")))
      |> Map.put(:robots, "noindex,nofollow")

    chrome(assigns, AnimeWeb.PageHTML.forbidden(assigns))
  end

  defp chrome(assigns, content) do
    body = AnimeWeb.Layouts.app(Map.put(assigns, :inner_content, content))
    AnimeWeb.Layouts.root(Map.put(assigns, :inner_content, body))
  end

  defp message("400.html"), do: gettext("Некорректный запрос")
  defp message("413.html"), do: gettext("Запрос слишком большой")
  defp message(_), do: gettext("Не удалось выполнить запрос")

  defp failure(assigns) do
    ~H"""
    <!doctype html>
    <html lang={@locale}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex,nofollow" />
        <title>{AnimeWeb.PageTitles.title(@text)}</title>
        <link rel="stylesheet" href="/assets/app.css" />
      </head>
      <body>
        <main class="container error-page">
          <h1>{@text}</h1>
          <p class="muted">{gettext("Номер запроса")}: <span id="request-id">{@request_id}</span></p>
        </main>
      </body>
    </html>
    """
  end
end

defmodule AnimeWeb.ErrorJSON do
  def render(_template, _assigns), do: %{error: "Request failed"}
end
