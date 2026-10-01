defmodule AnimeWeb.AdminComponents do
  use AnimeWeb, :html
  import AnimeWeb.AdminFormat, only: [number: 2]

  attr :user, :map, required: true

  def user_status(assigns) do
    ~H"""
    <span class={"user-status #{if @user.status == :active, do: "active", else: "blocked"}"}>
      {if @user.status == :active, do: gettext("Активен"), else: gettext("Заблокирован")}
    </span>
    <span :if={@user.deletion_requested} class="user-status deletion">{gettext("Удаление запрошено")}</span>
    """
  end

  attr :loading, :boolean, required: true
  attr :failed, :boolean, required: true

  def admin_list_feedback(assigns) do
    ~H"""
    <p :if={@loading} class="admin-list-loading" role="status">{gettext("Загрузка списка…")}</p>
    <div :if={@failed} class="admin-list-error" role="status">
      <p>{gettext("Список не загружен. Измените фильтры или повторите запрос.")}</p>
      <button type="button" phx-click="retry_list">{gettext("Повторить загрузку")}</button>
    </div>
    """
  end

  attr :rows, :integer, required: true
  attr :columns, :integer, required: true

  def admin_skeleton(assigns) do
    assigns =
      assign(
        assigns,
        :numbers,
        if(assigns.rows > 0, do: Enum.to_list(1..min(assigns.rows, 10)), else: [])
      )

    ~H"""
    <tbody class="admin-skeleton" aria-hidden="true">
      <tr :for={_ <- @numbers}>
        <td colspan={@columns}><span class="skeleton-bar"></span></td>
      </tr>
    </tbody>
    """
  end

  attr :title, :string, required: true
  attr :count, :integer, default: nil
  attr :locale, :string, required: true
  attr :level, :integer, default: 1, values: [1, 2]
  slot :action

  def admin_list_heading(assigns) do
    ~H"""
    <header class="admin-list-heading">
      <h1 :if={@level == 1}>{@title}</h1>
      <h2 :if={@level == 2}>{@title}</h2>
      <p :if={@count != nil} class="admin-list-count" role="status">
        {gettext("Найдено")}: {number(@count, @locale)}
      </p>
      <div :if={@action != []} class="admin-list-primary">{render_slot(@action)}</div>
    </header>
    """
  end

  attr :query, :map, required: true
  attr :path, :string, required: true
  attr :fixed, :list, default: []
  slot :create

  def admin_empty(assigns) do
    filtered =
      assigns.query
      |> Map.drop(~w(page sort dir tab) ++ assigns.fixed)
      |> Enum.any?(fn {_, value} -> value not in [nil, "", []] end)

    assigns = assign(assigns, :filtered, filtered)

    ~H"""
    <div class="admin-empty" role="status" data-filtered={to_string(@filtered)}>
      <p>
        {if @filtered,
          do: gettext("Под текущие фильтры ничего не подошло"),
          else: gettext("Записей пока нет")}
      </p>
      <.link
        :if={@filtered}
        class="button small"
        patch={activity_url(@path, Map.take(@query, ["tab"] ++ @fixed))}
      >{gettext("Сбросить фильтры")}</.link>
      <div :if={!@filtered && @create != []}>{render_slot(@create)}</div>
    </div>
    """
  end

  attr :value, :any, required: true
  attr :locale, :string, required: true
  attr :seconds, :boolean, default: false
  attr :empty, :string, default: "—"

  def admin_datetime(assigns) do
    assigns =
      assign(
        assigns,
        :date,
        AnimeWeb.AdminFormat.datetime(assigns.value, assigns.locale, assigns.seconds)
      )

    ~H"""
    <time :if={@date} datetime={@date.iso} title={@date.title}>{@date.text}</time><span :if={!@date}>{@empty}</span>
    """
  end

  def shell(assigns) do
    assigns =
      assigns
      |> assign(:sections, AnimeWeb.AdminNavigation.sections(assigns.permissions))
      |> assign(
        :current,
        AnimeWeb.AdminNavigation.current(assigns.permissions, assigns.admin_path)
      )

    ~H"""
    <div
      :for={locale <- [@locale]}
      :key={locale}
      id="admin-shell"
      class="admin-shell"
      x-data="adminShell"
      x-on:keydown.escape.window="close()"
    >
      <a href="#admin-content" class="skip-link">{gettext("К содержимому")}</a>
      <dialog
        id="admin-mobile-menu"
        x-ref="drawer"
        class="admin-drawer"
        aria-label={gettext("Администрирование")}
        x-on:cancel.prevent="close()"
        x-on:click="$event.target === $el && close()"
      >
        <div class="admin-drawer-panel">
          <button type="button" x-on:click="close()">{gettext("Закрыть меню")}</button>
          <.sidebar sections={@sections} current={@current} mobile={true} />
        </div>
      </dialog>
      <aside class="admin-sidebar">
        <a href="/admin" class="wordmark">Anime</a>
        <.sidebar sections={@sections} current={@current} />
      </aside>
      <div class="admin-workspace">
        <header class="admin-topbar">
          <button
            type="button"
            id="admin-menu-button"
            x-ref="menuButton"
            class="admin-menu-button"
            x-on:click="open()"
            aria-controls="admin-mobile-menu"
            x-bind:aria-expanded="opened"
            aria-label={gettext("Открыть меню")}
          ><span aria-hidden="true">☰</span></button>
          <span class="admin-location">{@current.title}</span>
          <form id="admin-locale" phx-change="admin_locale">
            <label class="sr-only" for="admin-locale-select">{gettext("Язык")}</label>
            <select name="locale" id="admin-locale-select">
              <option value="ru" selected={@locale == "ru"}>Русский</option>
              <option value="en" selected={@locale == "en"}>English</option>
            </select>
          </form>
          <div id="admin-theme" x-data="{}">
            <label class="sr-only" for="admin-theme-select">{gettext("Тема")}</label>
            <select
              id="admin-theme-select"
              aria-label={gettext("Тема")}
              x-model="$store.theme.value"
              x-on:change="$store.theme.set($el.value)"
            >
              <option value="system">{gettext("Как в системе")}</option>
              <option value="light">{gettext("Светлая")}</option><option value="dark">
                {gettext("Тёмная")}
              </option>
            </select>
          </div>
          <div class="admin-account" x-data="publicDropdown" x-on:keydown="keydown($event)">
            <button
              type="button"
              id="admin-account-toggle"
              x-ref="trigger"
              aria-label={gettext("Меню профиля") <> ": " <> @current_user.nick}
              x-on:click="toggle()"
              x-bind:aria-expanded="opened"
              aria-controls="admin-account-menu"
            >
              <span class="avatar" aria-hidden="true">{String.first(@current_user.nick)}</span>
              <span class="admin-nick">{@current_user.nick}</span>
            </button>
            <div
              id="admin-account-menu"
              class="dropdown"
              x-ref="panel"
              x-cloak
              x-show="opened"
              x-on:click.outside="close(false)"
            >
              <a href={AnimeWeb.Auth.localized(@locale, "/")}>{gettext("На сайт")}</a>
              <a href={AnimeWeb.Auth.localized(@locale, "/profile")}>{gettext("Мой профиль")}</a>
              <form method="post" action="/logout">
                <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                <button type="submit">{gettext("Выйти")}</button>
              </form>
            </div>
          </div>
        </header>
        <main id="admin-content" x-ref="content" tabindex="-1">
          <AnimeWeb.Layouts.connection_status />
          <div :if={Phoenix.Flash.get(@flash, :info)} class="flash success" role="status">
            {Phoenix.Flash.get(@flash, :info)}
          </div>
          <div :if={Phoenix.Flash.get(@flash, :error)} class="flash error" role="alert">
            {Phoenix.Flash.get(@flash, :error)}
          </div>
          {@inner_content}
        </main>
      </div>
    </div>
    """
  end

  attr :sections, :list, required: true
  attr :current, :map, required: true
  attr :mobile, :boolean, default: false

  def sidebar(assigns) do
    ~H"""
    <nav aria-label={gettext("Администрирование")}>
      <div :for={section <- @sections} class="admin-nav-group" data-section={section.key}>
        <.link
          navigate={hd(section.items).path}
          class="admin-section-link"
          title={section.label}
          aria-label={section.label}
          data-active={to_string(section.key == @current.section)}
        >
          <span class="admin-nav-icon" aria-hidden="true">{section.icon}</span>
          <span class="admin-nav-label">{section.label}</span>
        </.link>
        <ul :if={section.key == @current.section} class="admin-subnav">
          <li :for={item <- section.items}>
            <.link navigate={item.path} aria-current={if item.path == @current.path, do: "page"}>
              {item.title}
            </.link>
          </li>
        </ul>
      </div>
    </nav>
    """
  end

  attr :listing, :map, required: true
  attr :query, :map, required: true
  attr :path, :string, required: true
  attr :locale, :string, required: true

  def pagination(assigns) do
    assigns =
      assign(
        assigns,
        :numbers,
        Enum.uniq(
          [1, assigns.listing.pages] ++
            Enum.to_list(
              max(1, assigns.listing.page - 2)..min(
                assigns.listing.pages,
                assigns.listing.page + 2
              )
            )
        )
        |> Enum.sort()
      )

    ~H"""
    <nav class="admin-pagination" aria-label={gettext("Страницы")}>
      <.link :if={@listing.page > 1} patch={activity_url(@path, Map.put(@query, "page", 1))}>{gettext(
        "Первая"
      )}</.link>
      <.link
        :if={@listing.page > 1}
        patch={activity_url(@path, Map.put(@query, "page", @listing.page - 1))}
      >{gettext("Назад")}</.link>
      <.link
        :for={page <- @numbers}
        patch={activity_url(@path, Map.put(@query, "page", page))}
        aria-current={if page == @listing.page, do: "page"}
      >{number(page, @locale)}</.link>
      <.link
        :if={@listing.page < @listing.pages}
        patch={activity_url(@path, Map.put(@query, "page", @listing.page + 1))}
      >{gettext("Далее")}</.link>
      <.link
        :if={@listing.page < @listing.pages}
        patch={activity_url(@path, Map.put(@query, "page", @listing.pages))}
      >{gettext("Последняя")}</.link>
      <span class="muted">{number(@listing.page, @locale)} / {number(@listing.pages, @locale)}</span>
    </nav>
    """
  end

  attr :query, :map, required: true
  attr :path, :string, required: true
  attr :fixed, :list, default: []

  def filter_chips(assigns) do
    entries =
      for {key, value} <- Enum.sort(assigns.query),
          key not in (["page", "sort", "dir", "tab"] ++ assigns.fixed),
          v <- List.wrap(value),
          v not in [nil, ""],
          do: %{key: key, value: v, label: filter_label(key) <> ": " <> filter_value(key, v)}

    assigns = assign(assigns, :entries, entries)

    ~H"""
    <div :if={@entries != []} class="filter-chips" aria-label={gettext("Активные фильтры")}>
      <.link
        :for={entry <- @entries}
        data-filter={entry.key}
        data-value={entry.value}
        patch={activity_url(@path, AnimeWeb.AdminQuery.remove(@query, entry.key, entry.value))}
        aria-label={gettext("Снять фильтр") <> ": " <> entry.label}
      >
        {entry.label} <span aria-hidden="true">×</span>
      </.link>
      <.link class="reset-filters" patch={activity_url(@path, Map.take(@query, ["tab"] ++ @fixed))}>{gettext(
        "Сбросить"
      )}</.link>
    </div>
    """
  end

  defp filter_label("q"), do: gettext("Поиск")
  defp filter_label("role"), do: gettext("Роль")
  defp filter_label("status"), do: gettext("Статус")
  defp filter_label("confirmed"), do: gettext("Подтверждение email")
  defp filter_label("term"), do: gettext("Срок блокировки")
  defp filter_label("blocked_by"), do: gettext("Кто заблокировал")
  defp filter_label("from"), do: gettext("С даты")
  defp filter_label("to"), do: gettext("По дату")
  defp filter_label("deletion"), do: gettext("Удаление запрошено")
  defp filter_label("supporter"), do: gettext("Сторонник")
  defp filter_label("user_id"), do: gettext("Пользователь (ID)")
  defp filter_label("action"), do: gettext("Действие")
  defp filter_label("result"), do: gettext("Результат")
  defp filter_label("group"), do: gettext("Область")
  defp filter_label(key), do: key
  defp filter_value("status", "active"), do: gettext("Активен")
  defp filter_value("status", "blocked"), do: gettext("Заблокирован")
  defp filter_value("result", value), do: activity_result(value)
  defp filter_value("group", value), do: Anime.Access.Labels.group_name(value)
  defp filter_value("confirmed", "yes"), do: gettext("Подтверждён")
  defp filter_value("confirmed", "no"), do: gettext("Не подтверждён")
  defp filter_value("term", "permanent"), do: gettext("Бессрочно")
  defp filter_value("term", "temporary"), do: gettext("С указанным сроком")
  defp filter_value("blocked_by", "missing"), do: gettext("Не указан")
  defp filter_value(_, "true"), do: gettext("Да")
  defp filter_value(_, value), do: to_string(value)

  attr :listing, :map, required: true
  attr :query, :map, required: true
  attr :path, :string, required: true
  attr :fixed_user, :boolean, default: false
  attr :locale, :string, required: true
  attr :heading_level, :integer, default: 2, values: [1, 2]
  attr :loading, :boolean, default: false
  attr :failed, :boolean, default: false

  def activity_panel(assigns) do
    ~H"""
    <section>
      <.admin_list_heading
        title={
          if @heading_level == 1,
            do: gettext("История активности пользователей"),
            else: gettext("История активности")
        }
        count={@listing.count}
        locale={@locale}
        level={@heading_level}
      />
      <details
        class="admin-filter-details"
        open
        x-data="adminFilters"
        x-bind:open="expanded"
      >
        <summary x-on:click.prevent="expanded=!expanded">{gettext("Фильтры")}</summary>
        <form id="activity-filter" phx-change="activity_filter" class="admin-filters">
          <label>{gettext("Пользователь (ID)")}<input
            name="filters[user_id]"
            type="number"
            min="1"
            value={@query["user_id"]}
            readonly={@fixed_user}
            phx-debounce="300"
          /></label>
          <label>{gettext("Действие")}<select multiple name="filters[action][]" size="3"><option
            :for={action <- Anime.Accounts.Activity.actions()}
            value={action}
            selected={action in List.wrap(@query["action"])}
          >
            {action}
          </option></select></label>
          <label>{gettext("Результат")}<select multiple name="filters[result][]" size="3"><option
            :for={result <- ~w(success denied error)}
            value={result}
            selected={result in List.wrap(@query["result"])}
          >
            {activity_result(result)}
          </option></select></label>
          <label>IP<input
            name="filters[ip]"
            value={@query["ip"]}
            phx-debounce="300"
            maxlength="64"
          /></label>
          <label>{gettext("С даты")}<input
            type="date"
            name="filters[from]"
            value={@query["from"]}
          /></label>
          <label>{gettext("По дату")}<input type="date" name="filters[to]" value={@query["to"]} /></label>
        </form>
      </details>
      <.filter_chips query={@query} path={@path} fixed={if @fixed_user, do: ["user_id"], else: []} />
      <.admin_list_feedback loading={@loading} failed={@failed} />
      <div
        class="admin-table-wrap admin-list-scroll"
        id="activity-region"
        phx-hook="AdminTable"
        aria-busy={to_string(@loading)}
        tabindex="0"
        role="region"
        aria-label={gettext("История активности")}
      >
        <table class="admin-table" id="activity-table">
          <thead>
            <tr>
              <.sort_header
                column="id"
                label="ID"
                current={@listing.params}
                query={@query}
                path={@path}
              />
              <.sort_header
                column="occurred_at"
                label={gettext("Дата")}
                current={@listing.params}
                query={@query}
                path={@path}
              />
              <th>{gettext("Пользователь")}</th><th>{gettext("Роль")}</th><th>
                IP
              </th><th>{gettext("Действие")}</th><th>{gettext("Результат")}</th>
            </tr>
          </thead>
          <.admin_skeleton :if={@loading} rows={length(@listing.rows)} columns={7} />
          <tbody :if={!@loading && !@failed}>
            <tr :for={a <- @listing.rows} id={"activity-#{a.id}"}>
              <td>{a.id}</td>
              <td><.admin_datetime value={a.occurred_at} locale={@locale} seconds /></td><td>
                {a.actor_label}<small :if={a.user_id}>#{a.user_id}</small>
              </td><td>{a.role_code || "—"}</td><td>{a.ip || "—"}</td><td>{a.action}</td><td>
                {activity_result(to_string(a.result))}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.admin_empty
        :if={@listing.rows == [] && !@loading && !@failed}
        query={@query}
        path={@path}
        fixed={if @fixed_user, do: ["user_id"], else: []}
      />
      <.pagination listing={@listing} query={@query} path={@path} locale={@locale} />
    </section>
    """
  end

  def activity_url(path, params), do: AnimeWeb.AdminQuery.url(path, params)

  attr :column, :string, required: true
  attr :label, :string, required: true
  attr :current, :map, required: true
  attr :query, :map, required: true
  attr :path, :string, required: true

  def sort_header(assigns) do
    active = assigns.current.sort == assigns.column
    dir = assigns.current.dir
    next = if active && dir == "desc", do: "asc", else: "desc"
    state = if active, do: if(dir == "asc", do: "ascending", else: "descending"), else: "none"
    label = if next == "asc", do: gettext("По возрастанию"), else: gettext("По убыванию")

    query =
      assigns.query |> Map.delete("page") |> Map.merge(%{"sort" => assigns.column, "dir" => next})

    assigns =
      assign(assigns,
        active: active,
        state: state,
        next_label: label,
        url: activity_url(assigns.path, query),
        arrow: if(active, do: if(dir == "asc", do: "↑", else: "↓"), else: "↕")
      )

    ~H"""
    <th scope="col" aria-sort={@state} data-sort={@column}>
      <.link
        class="admin-sort"
        patch={@url}
        title={@next_label}
        aria-label={@label <> ": " <> @next_label}
      >
        {@label}<span
          class={if @active, do: "sort-arrow active", else: "sort-arrow"}
          aria-hidden="true"
        >{@arrow}</span>
      </.link>
    </th>
    """
  end

  defp activity_result("success"), do: gettext("Успех")
  defp activity_result("denied"), do: gettext("Отказ")
  defp activity_result("error"), do: gettext("Ошибка")
end
