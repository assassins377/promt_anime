defmodule AnimeWeb.Layouts do
  use AnimeWeb, :html

  def root(assigns) do
    assigns =
      assigns
      |> Map.put_new(:__changed__, nil)
      |> assign(:locale, assigns.conn.assigns[:locale] || "ru")
      |> assign(:nonce, assigns.conn.assigns[:csp_nonce])
      |> assign_new(:page_title, fn -> "Anime" end)
      |> assign_new(:robots, fn -> "noindex,nofollow" end)

    ~H"""
    <!doctype html>
    <html lang={@locale}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <meta name="robots" content={@robots} />
        <title>{@page_title}</title>
        <script nonce={@nonce}>
          try {const t=localStorage.getItem('anime-theme')||'system';document.documentElement.dataset.theme=(t==='dark'||(t==='system'&&matchMedia('(prefers-color-scheme: dark)').matches))?'dark':'light'}catch(e){}
        </script>
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer src="/assets/app.js">
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  def app(assigns) do
    assigns =
      assigns
      |> Map.put_new(:__changed__, nil)
      |> assign_new(:current_user, fn -> nil end)
      |> assign_new(:locale, fn -> "ru" end)
      |> assign_new(:current_path, fn -> url(assigns[:locale], "/") end)

    ~H"""
    <AnimeWeb.PublicComponents.header
      current_user={@current_user}
      locale={@locale}
      current_path={@current_path}
    />
    <main class="container main">
      <.connection_status />
      <div :if={Phoenix.Flash.get(@flash, :info)} class="flash success" role="status">
        {Phoenix.Flash.get(@flash, :info)}
      </div>
      <div :if={Phoenix.Flash.get(@flash, :error)} class="flash error" role="alert">
        {Phoenix.Flash.get(@flash, :error)}
      </div>
      {@inner_content}
    </main>
    <footer class="container footer">
      <a href={url(@locale, "/catalog")}>{gettext("Каталог")}</a>
      <a href={url(@locale, "/genres")}>{gettext("Жанры")}</a>
      <a href={url(@locale, "/blog")}>{gettext("Блог")}</a>
      <a href={url(@locale, "/feedback")}>{gettext("Обратная связь")}</a>
      <a href={url(@locale, "/terms")}>{gettext("Условия использования")}</a>
      <a href={url(@locale, "/privacy")}>{gettext("Конфиденциальность")}</a>
    </footer>
    """
  end

  def url(locale, path), do: AnimeWeb.Auth.localized(locale, path)

  # A quiet, shared status strip, driven by LiveView's actual connection classes.
  def connection_status(assigns) do
    ~H"""
    <div id="connection-status" class="connection-status" role="status" aria-live="polite">
      {gettext("Связь с сервером потеряна. Переподключаемся…")}
    </div>
    """
  end

  def admin(assigns), do: AnimeWeb.AdminComponents.shell(assigns)
end
