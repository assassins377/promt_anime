defmodule AnimeWeb.UserAdminLive do
  use AnimeWeb.AdminPage, permission: "users.user.view"
  alias Anime.Accounts.{Administration, Activity, User}

  def mount(_, _, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Anime.PubSub, "users:changed")
      Phoenix.PubSub.subscribe(Anime.PubSub, "roles:changed")
    end

    {:ok,
     assign(socket,
       detail: nil,
       pending: nil,
       tab: "overview",
       user_id: nil,
       activity: nil,
       activity_query: %{},
       block_history: nil,
       block_query: %{},
       sessions: nil,
       session_query: %{},
       edit_form: nil,
       page_title: gettext("Пользователи")
     ), layout: {AnimeWeb.Layouts, :admin}}
  end

  def handle_params(%{"id" => id} = params, _, socket) do
    tab =
      if params["tab"] in ~w(overview blocks sessions activity),
        do: params["tab"],
        else: "overview"

    query =
      AnimeWeb.AdminQuery.clean(params, ~w(action result ip from to page sort dir))
      |> AnimeWeb.AdminQuery.sort_query(~w(id occurred_at))
      |> Map.merge(%{"tab" => "activity", "user_id" => id})

    with_access(socket, __admin_permission__(), fn a ->
      reload(
        assign(socket,
          user_id: id,
          tab: tab,
          pending: nil,
          activity_query: query,
          activity: nil,
          block_query: Map.take(params, ["page"]),
          block_history: nil,
          session_query: Map.take(params, ["page"]),
          sessions: nil
        ),
        a
      )
    end)
  end

  def handle_event("prepare", %{"action" => action} = params, socket)
      when action in ~w(ban unban revoke role edit delete restore) do
    with_access(socket, __admin_permission__(), fn _ ->
      with_access(socket, permission(action), fn _ ->
        cond do
          socket.assigns.current_user.id == socket.assigns.detail.user.id ->
            failure(socket, :self_action)

          action == "revoke" && !visible_session?(socket, params["session_id"]) ->
            failure(socket, :not_found)

          true ->
            baseline = Map.take(socket.assigns.detail.user, [:nick, :email, :locale])
            form = User.admin_changeset(struct(User, baseline), %{}) |> to_form(as: :user)

            {:noreply,
             assign(socket,
               edit_form: form,
               pending: %{
                 action: action,
                 session_id: params["session_id"] || "all",
                 baseline: baseline
               }
             )}
        end
      end)
    end)
  end

  def handle_event("cancel", _, socket),
    do:
      with_access(socket, __admin_permission__(), fn _ ->
        {:noreply, assign(socket, :pending, nil)}
      end)

  def handle_event(
        "confirm",
        params,
        %{assigns: %{pending: %{action: action} = pending}} = socket
      ) do
    with_access(socket, __admin_permission__(), fn a ->
      meta = Map.put(socket.assigns.client_meta, :session_token, socket.assigns.session_token)
      id = socket.assigns.user_id

      result =
        case action do
          "ban" ->
            Administration.ban(a, id, params, meta)

          "unban" ->
            Administration.unban(a, id, meta)

          "role" ->
            Administration.change_role(a, id, params["role_id"], meta)

          "edit" ->
            Administration.edit(
              a,
              id,
              params["user"] || %{},
              Map.put(meta, :expected_user_fields, pending.baseline)
            )

          "delete" ->
            Administration.request_deletion(a, id, params["nick"], meta)

          "restore" ->
            Administration.cancel_deletion(a, id, meta)

          "revoke" ->
            Administration.revoke_sessions(
              a,
              id,
              if(pending.session_id == "all", do: :all, else: pending.session_id),
              meta
            )
        end

      case result do
        {:ok, _} ->
          reload(
            socket |> assign(:pending, nil) |> put_flash(:info, gettext("Изменения сохранены")),
            a
          )

        {:error, %Ecto.Changeset{} = cs} ->
          safe_data = struct(User, Map.take(cs.data, [:id, :nick, :email, :locale]))

          {:noreply,
           socket
           |> assign(
             :edit_form,
             to_form(%{cs | data: safe_data, action: cs.action || :validate}, as: :user)
           )
           |> put_flash(:error, gettext("Проверьте поля формы"))}

        {:error, reason} ->
          failure(socket, reason)
      end
    end)
  end

  def handle_event(
        "validate_edit",
        %{"user" => attrs},
        %{assigns: %{pending: %{action: "edit", baseline: baseline}}} = socket
      )
      when is_map(attrs) do
    with_access(socket, __admin_permission__(), fn _ ->
      with_access(socket, "users.user.edit", fn _ ->
        cs = User.admin_changeset(struct(User, baseline), attrs) |> Map.put(:action, :validate)
        {:noreply, assign(socket, :edit_form, to_form(cs, as: :user))}
      end)
    end)
  end

  def handle_event(
        "activity_filter",
        %{"filters" => params},
        %{assigns: %{tab: "activity"}} = socket
      ) do
    with_access(socket, __admin_permission__(), fn _ ->
      with_access(socket, "users.activity.view", fn _ ->
        params =
          AnimeWeb.AdminQuery.clean(params, ~w(action result ip from to))
          |> then(&Map.merge(Map.take(socket.assigns.activity_query, ~w(sort dir)), &1))
          |> Map.merge(%{"tab" => "activity", "page" => "1"})

        {:noreply,
         push_patch(socket, to: activity_url("/admin/users/#{socket.assigns.user_id}", params))}
      end)
    end)
  end

  def handle_event("confirm", _, socket), do: failure(socket, :confirmation_required)
  def handle_event(_, _, socket), do: failure(socket, :invalid_action)

  def handle_info(message, socket) when message in [:users_changed, :roles_changed] do
    with_access(socket, __admin_permission__(), fn a -> reload(socket, a) end)
  end

  defp reload(socket, a) do
    case Administration.get(a, socket.assigns.user_id) do
      {:ok, detail} ->
        socket =
          assign(socket,
            detail: detail,
            permissions: Anime.Access.permissions(a),
            activity: nil,
            block_history: nil,
            sessions: nil
          )

        case socket.assigns.tab do
          "activity" ->
            case Activity.list(a, socket.assigns.activity_query) do
              {:ok, activity} -> {:noreply, assign(socket, :activity, activity)}
              {:error, reason} -> failure(socket, reason)
            end

          "sessions" ->
            case Administration.sessions(a, socket.assigns.user_id, socket.assigns.session_query) do
              {:ok, sessions} -> {:noreply, assign(socket, :sessions, sessions)}
              {:error, reason} -> failure(socket, reason)
            end

          "blocks" ->
            case Administration.block_history(
                   a,
                   socket.assigns.user_id,
                   socket.assigns.block_query
                 ) do
              {:ok, history} -> {:noreply, assign(socket, :block_history, history)}
              {:error, reason} -> failure(socket, reason)
            end

          _ ->
            {:noreply, socket}
        end

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Пользователь не найден"))
         |> redirect(to: "/admin/users")}

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  defp visible_session?(_, id) when id in [nil, "all"], do: true

  defp visible_session?(%{assigns: %{tab: "sessions", sessions: %{rows: rows}}}, id),
    do: Enum.any?(rows, &(to_string(&1.id) == id))

  defp visible_session?(_, _), do: false

  defp permission("ban"), do: "users.user.ban"
  defp permission("unban"), do: "users.user.unban"
  defp permission("role"), do: "users.role.assign"
  defp permission("revoke"), do: "users.session.revoke"
  defp permission("edit"), do: "users.user.edit"
  defp permission("delete"), do: "users.user.delete"
  defp permission("restore"), do: "users.user.delete"
  defp block_action("users.user.ban"), do: gettext("Блокировка")
  defp block_action("users.user.unban"), do: gettext("Разблокировка")
  defp audit_result(:success), do: gettext("Успех")
  defp audit_result(:denied), do: gettext("Отказ")
  defp audit_result(:error), do: gettext("Ошибка")
  defp operator_label("users_unblock_expired"), do: gettext("Автоматически по сроку")
  defp operator_label(value), do: value
  defp yes(true), do: gettext("Да")
  defp yes(_), do: gettext("Нет")
  defp reason_label("spam"), do: gettext("Спам")
  defp reason_label("insults"), do: gettext("Оскорбления")
  defp reason_label("rating_manipulation"), do: gettext("Накрутка оценок")
  defp reason_label("ban_evasion"), do: gettext("Обход блокировки")
  defp reason_label("prohibited_content"), do: gettext("Запрещённый контент")
  defp reason_label("other"), do: gettext("Другое")

  defp session_label(:session), do: gettext("Вход в браузере")
  defp session_label(:remember_me), do: gettext("Запомнить меня")
  defp session_label(_), do: gettext("Сессия")

  def render(assigns) do
    ~H"""
    <section :for={locale <- [@locale]} :key={locale} class="admin admin-users">
      <section :if={@detail}>
        <header class="user-card-heading">
          <span class="user-initial" aria-hidden="true">{String.first(@detail.user.nick)}</span>
          <h1>{@detail.user.nick} <small>#{@detail.user.id}</small></h1>
          <.user_status user={@detail.user} />
          <span class="role-badge">{role_name(@detail.user.role)}</span>
          <a
            id="public-user-profile"
            href={AnimeWeb.Auth.localized(@locale, "/u/#{@detail.user.nick}")}
          >{gettext("Открыть публичный профиль")}</a>
        </header>
        <nav class="profile-nav">
          <a href="/admin/users">← {gettext("Пользователи")}</a><.link patch={"/admin/users/#{@user_id}?tab=overview"}>{gettext(
            "Обзор"
          )}</.link><.link patch={"/admin/users/#{@user_id}?tab=blocks"}>{gettext("Блокировки")}</.link><.link patch={"/admin/users/#{@user_id}?tab=sessions"}>{gettext(
            "Сессии"
          )}</.link>
          <.link
            :if={"users.activity.view" in @permissions}
            patch={"/admin/users/#{@user_id}?tab=activity"}
          >{gettext("Активность")}</.link>
        </nav>
        <div :if={@current_user.id != @detail.user.id} class="admin-actions">
          <button
            :if={"users.user.edit" in @permissions}
            id="edit-user"
            phx-click="prepare"
            phx-value-action="edit"
          >{gettext("Править")}</button>
          <button
            :if={"users.role.assign" in @permissions}
            id="change-role"
            phx-click="prepare"
            phx-value-action="role"
          >{gettext("Сменить роль")}</button>
          <button
            :if={"users.user.ban" in @permissions && @detail.user.status == :active}
            id="ban-user"
            phx-click="prepare"
            phx-value-action="ban"
          >{gettext("Заблокировать")}</button>
          <button
            :if={"users.user.unban" in @permissions && @detail.user.status == :blocked}
            id="unban-user"
            phx-click="prepare"
            phx-value-action="unban"
          >{gettext("Разблокировать")}</button>
          <button
            :if={"users.session.revoke" in @permissions && @detail.session_count > 0}
            id="revoke-all"
            phx-click="prepare"
            phx-value-action="revoke"
          >{gettext("Завершить все сессии")}</button>
          <button
            :if={"users.user.delete" in @permissions && !@detail.user.deletion_requested}
            id="delete-user"
            phx-click="prepare"
            phx-value-action="delete"
          >{gettext("Удалить аккаунт")}</button>
          <button
            :if={"users.user.delete" in @permissions && @detail.user.deletion_requested}
            id="restore-user"
            phx-click="prepare"
            phx-value-action="restore"
          >{gettext("Отменить удаление")}</button>
        </div>
        <dl :if={@tab == "overview"} class="user-details">
          <dt>Email</dt><dd>
            {@detail.user.email} · {if @detail.user.email_confirmed_at,
              do: gettext("Подтверждён"),
              else: gettext("Не подтверждён")}
          </dd>
          <dt>{gettext("Роль")}</dt><dd>{role_name(@detail.user.role)}</dd><dt>
            {gettext("Статус")}
          </dt><dd>
            {if @detail.user.status == :active, do: gettext("Активен"), else: gettext("Заблокирован")}
          </dd>
          <dt>{gettext("Дата регистрации")}</dt><dd>
            <.admin_datetime value={@detail.user.inserted_at} locale={@locale} />
          </dd><dt>
            {gettext("Предыдущий ник")}
          </dt><dd>
            {@detail.user.previous_nick || "—"} ·
            <.admin_datetime value={@detail.user.previous_nick_until} locale={@locale} />
          </dd>
          <dt>{gettext("Смена ника")}</dt><dd>
            <.admin_datetime value={@detail.user.nick_changed_at} locale={@locale} />
          </dd><dt>
            {gettext("Язык")}
          </dt><dd>{@detail.user.locale}</dd><dt>{gettext("Сторонник до")}</dt><dd>
            <.admin_datetime value={@detail.user.supporter_until} locale={@locale} />
          </dd>
          <dt>{gettext("Согласие")}</dt><dd>
            <.admin_datetime value={@detail.user.consent_accepted_at} locale={@locale} />
            · {@detail.user.consent_version}
          </dd><dt>{gettext("Возраст подтверждён")}</dt><dd>
            <.admin_datetime value={@detail.user.age_confirmed_at} locale={@locale} />
          </dd>
          <dt>{gettext("Избранное видно всем")}</dt><dd>{yes(@detail.user.show_bookmarks_public)}</dd><dt>
            {gettext("Сохранять историю просмотра")}
          </dt><dd>{yes(@detail.user.keep_watch_history)}</dd><dt>
            {gettext("Продолжить просмотр на главной")}
          </dt><dd>{yes(@detail.user.show_continue_watching)}</dd>
          <dt>{gettext("Требуется смена пароля")}</dt><dd>
            {yes(@detail.user.must_change_password)}
          </dd><dt>{gettext("Удаление запрошено")}</dt><dd>
            {yes(@detail.user.deletion_requested)} ·
            <.admin_datetime value={@detail.user.deletion_requested_at} locale={@locale} />
          </dd>
        </dl>
        <section :if={@tab == "blocks"}>
          <h2>{gettext("Блокировки")}</h2>
          <dl :if={@detail.user.status == :blocked} class="user-details" id="current-block">
            <dt>{gettext("Причина блокировки")}</dt><dd>{@detail.user.block_reason || "—"}</dd>
            <dt>{gettext("Дата блокировки")}</dt><dd>
              <.admin_datetime value={@detail.user.blocked_at} locale={@locale} />
            </dd>
            <dt>{gettext("Дата окончания")}</dt><dd>
              <.admin_datetime
                value={@detail.user.blocked_until}
                locale={@locale}
                empty={gettext("Бессрочно")}
              />
            </dd>
            <dt>{gettext("Кто заблокировал")}</dt><dd>
              <a :if={@detail.block_operator} href={"/admin/users/#{@detail.block_operator.id}"}>{@detail.block_operator.nick}</a>
              <span :if={is_nil(@detail.block_operator)}>{gettext("Не указан")}</span>
            </dd>
          </dl>
          <p :if={@detail.user.status != :blocked}>{gettext("Сейчас не заблокирован")}</p>
          <h3>{gettext("История блокировок")}</h3>
          <p :if={@block_history}>{gettext("Найдено")}: {number(@block_history.count, @locale)}</p>
          <div
            :if={@block_history}
            class="admin-table-wrap admin-list-scroll"
            tabindex="0"
            role="region"
            aria-label={gettext("История блокировок")}
          >
            <table class="admin-table" id="block-history">
              <thead>
                <tr>
                  <th>ID</th><th>{gettext("Дата")}</th><th>{gettext("Оператор")}</th><th>
                    {gettext("Действие")}
                  </th><th>{gettext("Результат")}</th><th>{gettext("Причина блокировки")}</th><th>
                    {gettext("Дата окончания")}
                  </th>
                </tr>
              </thead><tbody>
                <tr :for={a <- @block_history.rows} id={"block-event-#{a.id}"}>
                  <td>{a.id}</td><td><.admin_datetime value={a.occurred_at} locale={@locale} /></td><td>
                    {operator_label(a.actor_label)}
                  </td><td>
                    {block_action(a.action)}
                  </td><td>
                    {audit_result(a.result)}
                  </td><td>{a.block_reason || "—"}</td><td>
                    <.admin_datetime
                      :if={a.has_deadline && a.result == :success}
                      value={a.blocked_until}
                      locale={@locale}
                      empty={gettext("Бессрочно")}
                    />
                    <span :if={!(a.has_deadline && a.result == :success)}>—</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p :if={@block_history && @block_history.rows == []}>
            {gettext("История блокировок пуста")}
          </p>
          <div
            :if={@block_history}
            id="block-history-pages"
          >
            <.pagination
              listing={@block_history}
              query={%{"tab" => "blocks"}}
              path={"/admin/users/#{@user_id}"}
              locale={@locale}
            />
          </div>
        </section>
        <section :if={@tab == "sessions" && @sessions}>
          <.admin_list_heading
            title={gettext("Сессии")}
            count={@sessions.count}
            locale={@locale}
            level={2}
          />
          <div
            class="admin-table-wrap admin-list-scroll"
            tabindex="0"
            role="region"
            aria-label={gettext("Сессии")}
          >
            <table class="admin-table" id="admin-sessions">
              <thead>
                <tr>
                  <th>ID</th><th>{gettext("Контекст")}</th><th>{gettext("Создана")}</th><th>
                    {gettext("Последняя активность")}
                  </th><th>{gettext("Истекает")}</th><th>IP</th><th>User-Agent</th><th class="row-actions">
                    {gettext("Действия")}
                  </th>
                </tr>
              </thead><tbody>
                <tr :for={t <- @sessions.rows} id={"session-#{t.id}"}>
                  <td>{t.id}</td><td>{session_label(t.context)}</td><td>
                    <.admin_datetime value={t.inserted_at} locale={@locale} />
                  </td><td>
                    <.admin_datetime value={t.last_used_at} locale={@locale} />
                  </td><td>
                    <.admin_datetime value={t.expires_at} locale={@locale} />
                  </td><td>{t.ip || "—"}</td><td>{t.user_agent || "—"}</td><td class="row-actions">
                    <button
                      :if={
                        "users.session.revoke" in @permissions && @current_user.id != @detail.user.id
                      }
                      phx-click="prepare"
                      phx-value-action="revoke"
                      phx-value-session_id={t.id}
                      id={"revoke-session-#{t.id}"}
                      title={gettext("Завершить сессию")}
                      aria-label={gettext("Завершить сессию") <> " #" <> to_string(t.id)}
                    ><span aria-hidden="true">×</span></button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p :if={@sessions.rows == []} role="status">{gettext("Активных сессий нет")}</p>
          <div id="session-pages">
            <.pagination
              listing={@sessions}
              query={%{"tab" => "sessions"}}
              path={"/admin/users/#{@user_id}"}
              locale={@locale}
            />
          </div>
        </section>
        <.activity_panel
          :if={@tab == "activity" && @activity}
          listing={@activity}
          query={@activity_query}
          path={"/admin/users/#{@user_id}"}
          fixed_user
          locale={@locale}
        />
        <dialog
          :if={@pending}
          id="user-confirm"
          class="admin-dialog"
          x-data="{}"
          x-init="$el.showModal()"
          x-on:cancel.prevent="$el.querySelector('[data-dialog-cancel]').click()"
          aria-labelledby="confirm-title"
        >
          <h2 id="confirm-title">{gettext("Подтвердите действие")}: {@detail.user.nick}</h2>
          <p :if={Phoenix.Flash.get(@flash, :error)} role="alert">
            {Phoenix.Flash.get(@flash, :error)}
          </p>
          <form
            id="user-action"
            phx-submit="confirm"
            phx-change={if @pending.action == "edit", do: "validate_edit"}
          >
            <fieldset :if={@pending.action == "edit"}>
              <legend>{gettext("Правка пользователя")}</legend>
              <.field form={@edit_form} name={:nick} label={gettext("Ник")} />
              <.field form={@edit_form} name={:email} label="Email" type="email" />
              <label>{gettext("Язык")}<select name="user[locale]"><option
                :for={locale <- ~w(ru en)}
                value={locale}
                selected={to_string(Phoenix.HTML.Form.input_value(@edit_form, :locale)) == locale}
              >
                {locale}
              </option></select></label>
              <p>
                {gettext(
                  "При смене email подтверждение сбрасывается, сессии и старые ссылки отзываются. Письмо не отправляется."
                )}
              </p>
            </fieldset>
            <fieldset :if={@pending.action == "delete"}>
              <legend>{gettext("Удаление аккаунта")}</legend>
              <p>
                {gettext(
                  "Вход будет закрыт сразу. Окончательное удаление — через 30 суток; до этого оператор может отменить запрос."
                )}
              </p>
              <label>{gettext("Введите точный ник пользователя")}<input
                name="nick"
                required
                autocomplete="off"
              /></label>
            </fieldset>
            <p :if={@pending.action == "restore"}>
              {gettext(
                "Отменить запрос удаления? Старые сессии не восстановятся; действующая блокировка останется."
              )}
            </p>
            <fieldset :if={@pending.action == "ban"}>
              <legend>{gettext("Блокировка")}</legend>
              <label>{gettext("Причина")}<select name="reason"><option
                :for={{code, _} <- Administration.reasons()}
                value={code}
              >
                {reason_label(code)}
              </option></select></label>
              <label>{gettext("Срок в сутках")}<input
                name="days"
                type="number"
                min="1"
                max="3650"
                value="1"
              /></label><label><input type="checkbox" name="permanent" value="true" />{gettext(
                "Бессрочно"
              )}</label>
              <label>{gettext("Комментарий оператора")}<textarea name="comment" maxlength="300"></textarea></label><p>
                {gettext("Для причины «Другое» нужен комментарий от 10 до 300 символов.")}
              </p>
              <label><input type="checkbox" name="notify" value="true" />{gettext("Уведомить письмом")}</label>
            </fieldset>
            <label :if={@pending.action == "role"}>{gettext("Новая роль")}<select name="role_id"><option
              :for={r <- @detail.roles}
              value={r.id}
              selected={r.id == @detail.user.role.id}
            >
              {role_name(r)}
            </option></select></label>
            <p :if={@pending.action == "unban"}>{gettext("Снять блокировку пользователя?")}</p>
            <p :if={@pending.action == "revoke"}>
              {if @pending.session_id == "all",
                do: gettext("Завершить все сессии этого пользователя?"),
                else: gettext("Завершить выбранную сессию?")}
            </p>
            <div class="admin-actions">
              <button type="submit" id="confirm-user-action">{gettext("Подтвердить")}</button><button
                type="button"
                phx-click="cancel"
                data-dialog-cancel
              >{gettext("Отмена")}</button>
            </div>
          </form>
        </dialog>
      </section>
    </section>
    """
  end
end
