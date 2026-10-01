defmodule AnimeWeb.PageHTML do
  use AnimeWeb, :html

  def not_found(assigns) do
    ~H"""
    <section class="empty-state" id="not-found">
      <span class="eyebrow">404</span>
      <h1>{gettext("Страница не найдена")}</h1>
      <p>{gettext("Возможно, ссылка устарела или в адресе есть опечатка.")}</p>
      <div class="error-links">
        <a class="button" href={AnimeWeb.Auth.localized(@locale, "/")}>{gettext("На главную")}</a>
        <a href={AnimeWeb.Auth.localized(@locale, "/catalog")}>{gettext("Каталог")}</a>
      </div>
    </section>
    """
  end

  def forbidden(assigns) do
    ~H"""
    <section class="empty-state">
      <h1>{gettext("Недостаточно прав")}</h1>
      <a href={AnimeWeb.Auth.localized(@locale, "/")}>{gettext("На главную")}</a>
      · <a href={AnimeWeb.Auth.localized(@locale, "/feedback")}>{gettext("Обратная связь")}</a>
    </section>
    """
  end
end
