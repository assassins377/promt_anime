defmodule AnimeWeb.PublicProfileHTML do
  use AnimeWeb, :html

  def show(assigns) do
    ~H"""
    <section class="profile" id="public-profile">
      <div class="profile-heading">
        <span class="avatar large" aria-hidden="true">{String.first(@profile.nick)}</span>
        <div>
          <span class="eyebrow">{gettext("Публичный профиль")}</span>
          <h1>{@profile.nick}</h1>
          <span :if={@profile.role_badge} class="badge" id="role-badge">{@profile.role_badge}</span>
          <p class="muted">
            {gettext("Дата регистрации:")}
            <time datetime={DateTime.to_iso8601(@profile.registered_at)}>
              {Calendar.strftime(@profile.registered_at, "%d.%m.%Y")}
            </time>
          </p>
        </div>
      </div>
      <p :if={@profile.restricted} class="flash" id="restricted-profile">
        {gettext("Профиль скрыт. Вам он доступен по праву просмотра пользователей.")}
      </p>
      <div class="settings-grid">
        <section class="panel" id="public-bookmarks">
          <h2>{gettext("Избранное")}</h2>
          <p :if={!@profile.show_bookmarks_public} class="muted">{gettext("Избранное скрыто")}</p>
          <p :if={@profile.show_bookmarks_public} class="muted">
            {gettext("Избранное будет доступно после подключения каталога и закладок.")}
          </p>
        </section>
        <section class="panel" id="public-activity-placeholder">
          <h2>{gettext("Оценки и комментарии")}</h2>
          <p class="muted">
            {gettext(
              "Оценки, комментарии и жалобы появятся в очереди 4. Статистика пока не рассчитывается."
            )}
          </p>
        </section>
      </div>
    </section>
    """
  end

  def not_found(assigns) do
    ~H"""
    <section class="empty-state">
      <span class="eyebrow">404</span>
      <h1>{gettext("Профиль не найден")}</h1>
      <a href={AnimeWeb.Auth.localized(@locale, "/")}>{gettext("На главную")}</a>
    </section>
    """
  end
end
