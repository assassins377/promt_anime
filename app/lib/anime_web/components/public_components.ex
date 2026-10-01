defmodule AnimeWeb.PublicComponents do
  use AnimeWeb, :html
  alias AnimeWeb.Layouts

  attr :current_user, :any, required: true
  attr :locale, :string, required: true
  attr :current_path, :string, required: true

  def header(assigns) do
    assigns = assign(assigns, :grants, Anime.Access.permissions(assigns.current_user))

    ~H"""
    <header class="site-header" id="site-header" x-data="siteHeader" x-on:focusin="tabsHidden=false">
      <div class="container topbar">
        <a class="wordmark" href={Layouts.url(@locale, "/")}>Anime</a>
        <div class="desktop-language" x-data="publicDropdown" x-on:keydown="keydown($event)">
          <button
            type="button"
            class="quiet locale-trigger"
            x-ref="trigger"
            x-on:click="toggle()"
            x-bind:aria-expanded="opened"
            aria-expanded="false"
            aria-controls="language-options"
          >
            {if @locale == "en", do: "English", else: "Русский"}<.icon name="expand_more" />
          </button>
          <div
            id="language-options"
            class="public-dropdown language-options"
            x-ref="panel"
            x-show="opened"
            x-cloak
            x-on:click.outside="close(false)"
          >
            <.locale_form id="locale-form" locale={@locale} current_path={@current_path} />
          </div>
        </div>
        <span class="topbar-space"></span>
        <a
          :if={"content.anime.create" in @grants}
          id="header-add-anime"
          class="icon-button desktop-add"
          href="/admin/content/anime/new"
          aria-label={gettext("Добавить аниме")}
          title={gettext("Добавить аниме")}
        >
          <.icon name="add" />
        </a>
        <%= unless @current_user do %>
          <a href={Layouts.url(@locale, "/register")} class="quiet signup">{gettext("Регистрация")}</a>
          <a href={Layouts.url(@locale, "/login")} class="button small login-button">
            {gettext("Войти")}<.icon name="arrow_forward" />
          </a>
        <% end %>
        <div
          id="profile-menu"
          class="public-menu"
          x-data="publicDropdown"
          x-on:keydown="keydown($event)"
        >
          <button
            id="profile-menu-toggle"
            type="button"
            class="profile-trigger"
            x-ref="trigger"
            x-on:click="toggle()"
            x-bind:aria-expanded="opened"
            aria-expanded="false"
            aria-controls="profile-menu-panel"
            aria-label={if @current_user, do: gettext("Меню профиля"), else: gettext("Тема")}
          >
            <%= if @current_user do %>
              <span class="avatar" aria-hidden="true">{String.first(@current_user.nick)}</span>
              <span class="profile-name">{@current_user.nick}</span><.icon name="expand_more" />
            <% else %>
              <.icon name="contrast" />
            <% end %>
          </button>
          <div
            id="profile-menu-panel"
            class="public-dropdown"
            x-ref="panel"
            x-show="opened"
            x-cloak
            x-on:click.outside="close(false)"
          >
            <%= if @current_user do %>
              <p class="menu-nick">{@current_user.nick}</p>
              <a href={Layouts.url(@locale, "/profile")}>{gettext("Мой профиль")}</a>
              <a href={Layouts.url(@locale, "/profile/bookmarks")}>{gettext("Избранное")}</a>
              <a href={Layouts.url(@locale, "/profile/settings")}>{gettext("Настройки")}</a>
              <a :if={"admin.panel.access" in @grants} href="/admin">{gettext("Админ-панель")}</a>
              <a
                :if={"content.anime.create" in @grants}
                class="mobile-add"
                href="/admin/content/anime/new"
              >
                <.icon name="add" />{gettext("Добавить аниме")}
              </a>
              <div class="mobile-language">
                <.locale_form id="profile-locale-form" locale={@locale} current_path={@current_path} />
              </div>
            <% end %>
            <fieldset class="theme-choices">
              <legend>{gettext("Тема")}</legend>
              <button
                type="button"
                x-bind:aria-pressed="$store.theme.value === 'system'"
                x-on:click="$store.theme.set('system');close()"
              >{gettext("Как в системе")}</button>
              <button
                type="button"
                x-bind:aria-pressed="$store.theme.value === 'light'"
                x-on:click="$store.theme.set('light');close()"
              >{gettext("Светлая")}</button>
              <button
                type="button"
                x-bind:aria-pressed="$store.theme.value === 'dark'"
                x-on:click="$store.theme.set('dark');close()"
              >{gettext("Тёмная")}</button>
            </fieldset>
            <form
              :if={@current_user}
              id="menu-logout"
              method="post"
              action="/logout"
              class="menu-logout"
            >
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <button type="submit"><.icon name="logout" />{gettext("Выйти")}</button>
            </form>
          </div>
        </div>
      </div>
      <div class="type-row" x-bind:class="{ 'types-hidden': tabsHidden }">
        <nav class="container types" x-ref="types" aria-label={gettext("Тип аниме")}>
          <a
            :for={{code, label} <- types()}
            href={Layouts.url(@locale, "/catalog/" <> code)}
            aria-current={
              if URI.parse(@current_path).path == Layouts.url(@locale, "/catalog/" <> code),
                do: "page"
            }
          >
            {label}
          </a>
        </nav>
      </div>
    </header>
    """
  end

  attr :id, :string, required: true
  attr :locale, :string, required: true
  attr :current_path, :string, required: true

  def locale_form(assigns) do
    ~H"""
    <form id={@id} method="post" action="/locale" class="locale-options" aria-label={gettext("Язык")}>
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <input type="hidden" name="return_to" value={@current_path} />
      <button
        :for={{code, label} <- [{"ru", "Русский"}, {"en", "English"}]}
        type="submit"
        name="locale"
        value={code}
        aria-pressed={to_string(@locale == code)}
        lang={code}
      >{label}</button>
    </form>
    """
  end

  attr :name, :string, required: true, values: ~w(add arrow_forward contrast expand_more logout)

  def icon(assigns) do
    ~H"""
    <span class="material-symbol" aria-hidden="true">{@name}</span>
    """
  end

  defp types do
    [
      {"tv", gettext("ТВ")},
      {"movie", gettext("Фильм")},
      {"ova", "OVA"},
      {"ona", "ONA"},
      {"special", gettext("Спешл")}
    ]
  end
end
