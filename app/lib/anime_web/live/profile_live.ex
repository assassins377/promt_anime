defmodule AnimeWeb.ProfileLive do
  use AnimeWeb, :live_view
  alias Anime.Accounts

  def handle_params(_, _, socket),
    do:
      {:noreply,
       assign(socket, :page_title, AnimeWeb.PageTitles.profile(socket.assigns.live_action))}

  def mount(_, _, socket) do
    user = socket.assigns.current_user

    if user.must_change_password do
      {:ok,
       redirect(socket, to: AnimeWeb.Auth.localized(socket.assigns.locale, "/password/change"))}
    else
      {:ok,
       socket
       |> assign(:sessions, Accounts.sessions(user, socket.assigns.session_token))
       |> assign(:pending_email, Accounts.pending_email(user))
       |> assign(:nick_form, to_form(Accounts.User.nick_changeset(user, %{}), as: :nickname))
       |> assign(:email_form, to_form(%{}, as: :email_change))
       |> assign(:delete_form, to_form(%{}, as: :deletion))
       |> assign(:next_nick_change, Accounts.Lifecycle.next_nick_change(user))}
    end
  end

  def handle_event("confirm", _, socket) do
    if u = Accounts.Tokens.user(socket.assigns.session_token), do: Accounts.resend(u)

    {:noreply,
     put_flash(socket, :info, gettext("Если отправка разрешена, письмо будет доставлено"))}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    with u when not is_nil(u) <- Accounts.Tokens.user(socket.assigns.session_token),
         {id, ""} <- Integer.parse(id) do
      Accounts.revoke_session(u, id, socket.assigns.client_meta)
    end

    {:noreply, socket}
  end

  def handle_event("revoke_others", _, socket) do
    with_actor(socket, fn u ->
      case Accounts.revoke_other_sessions(
             u,
             socket.assigns.session_token,
             socket.assigns.client_meta
           ) do
        {:ok, _} ->
          {:noreply, put_flash(socket, :info, gettext("Остальные сессии завершены"))}

        {:error, :invalid_session} ->
          {:noreply,
           redirect(socket, to: AnimeWeb.Auth.localized(socket.assigns.locale, "/login"))}

        {:error, reason} ->
          failure(socket, reason)
      end
    end)
  end

  def handle_event("preferences", %{"preferences" => attrs}, socket) do
    case Accounts.Tokens.user(socket.assigns.session_token) do
      nil ->
        {:noreply, redirect(socket, to: "/login")}

      user ->
        case Accounts.update_preferences(user, attrs, socket.assigns.client_meta) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:current_user, Anime.Repo.preload(updated, :role))
             |> put_flash(:info, gettext("Настройки сохранены"))}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Не удалось сохранить"))}
        end
    end
  end

  def handle_event("validate_nick", %{"nickname" => attrs}, socket) do
    cs =
      Accounts.User.nick_changeset(socket.assigns.current_user, attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :nick_form, to_form(cs, as: :nickname))}
  end

  def handle_event("validate_email", %{"email_change" => attrs}, socket) do
    # Never retain the current password in server-rendered form values.
    cs =
      Accounts.User.email_changeset(socket.assigns.current_user, Map.take(attrs, ["email"]))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :email_form, to_form(cs, as: :email_change))}
  end

  def handle_event("validate_deletion", %{"deletion" => attrs}, socket),
    do:
      {:noreply, assign(socket, :delete_form, to_form(Map.take(attrs, ["nick"]), as: :deletion))}

  def handle_event("change_nick", %{"nickname" => attrs}, socket) do
    with_actor(socket, fn u ->
      case Accounts.change_nick(u, attrs, socket.assigns.client_meta) do
        {:ok, _} -> {:noreply, put_flash(socket, :info, gettext("Ник изменён"))}
        {:error, reason} -> failure(socket, reason)
      end
    end)
  end

  def handle_event("change_email", %{"email_change" => attrs}, socket) do
    with_actor(socket, fn u ->
      case Accounts.request_email_change(
             u,
             attrs["current_password"],
             attrs,
             socket.assigns.client_meta
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:pending_email, Accounts.pending_email(u))
           |> assign(:email_form, to_form(%{}, as: :email_change))
           |> put_flash(:info, gettext("Подтвердите новый адрес по ссылке в письме"))}

        {:error, reason} ->
          failure(socket, reason)
      end
    end)
  end

  def handle_event(event, _, socket) when event in ["resend_email", "cancel_email"] do
    with_actor(socket, fn u ->
      result =
        if event == "resend_email",
          do: Accounts.resend_email_change(u),
          else: Accounts.cancel_email_change(u)

      case result do
        {:ok, _} -> {:noreply, assign(socket, :pending_email, Accounts.pending_email(u))}
        {:error, reason} -> failure(socket, reason)
      end
    end)
  end

  def handle_event("delete_account", %{"deletion" => attrs}, socket) do
    with_actor(socket, fn u ->
      case Accounts.request_deletion(
             u,
             attrs["current_password"],
             attrs["nick"],
             socket.assigns.client_meta
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Удаление запрошено. Ссылка отмены отправлена на email."))
           |> redirect(to: AnimeWeb.Auth.localized(socket.assigns.locale, "/login"))}

        {:error, reason} ->
          failure(socket, reason)
      end
    end)
  end

  defp with_actor(socket, action) do
    case Accounts.Tokens.user(socket.assigns.session_token) do
      nil ->
        {:noreply, redirect(socket, to: AnimeWeb.Auth.localized(socket.assigns.locale, "/login"))}

      u ->
        action.(u)
    end
  end

  defp failure(socket, reason) do
    text =
      case reason do
        :nick_cooldown -> gettext("Ник можно менять один раз в 30 суток")
        :last_owner -> gettext("Нельзя удалить последнего активного владельца")
        :invalid_password -> gettext("Неверный текущий пароль")
        :nickname_mismatch -> gettext("Введите свой ник без изменений")
        :rate_limited -> gettext("Слишком много запросов. Попробуйте позже.")
        _ -> gettext("Не удалось сохранить. Проверьте поля и доступность значения.")
      end

    {:noreply, put_flash(socket, :error, text)}
  end

  def handle_info(:access_changed, socket) do
    case Accounts.Tokens.user(socket.assigns.session_token) do
      nil ->
        {:noreply, redirect(socket, to: AnimeWeb.Auth.localized(socket.assigns.locale, "/login"))}

      u ->
        {:noreply,
         socket
         |> assign(:current_user, u)
         |> assign(:nick_form, to_form(Accounts.User.nick_changeset(u, %{}), as: :nickname))
         |> assign(:sessions, Accounts.sessions(u, socket.assigns.session_token))
         |> assign(:next_nick_change, Accounts.Lifecycle.next_nick_change(u))}
    end
  end

  def render(assigns) do
    ~H"""
    <section class="profile">
      <div class="profile-heading">
        <span class="avatar large">{String.first(@current_user.nick)}</span><div>
          <span class="eyebrow">{gettext("Личный кабинет")}</span><h1>{@current_user.nick}</h1><p class="muted">
            {@current_user.email} · {@current_user.role.name}
          </p>
        </div>
      </div>
      <nav class="profile-nav">
        <a href={AnimeWeb.Auth.localized(@locale, "/profile")}>{gettext("Обзор")}</a><a href={
          AnimeWeb.Auth.localized(@locale, "/profile/settings")
        }>{gettext("Настройки")}</a><a
          :if={Anime.Access.allowed?(@current_user, "admin.panel.access")}
          href="/admin"
        >{gettext("Админ-панель")}</a>
        <a
          id="public-profile-link"
          href={AnimeWeb.Auth.localized(@locale, "/u/" <> @current_user.nick)}
        >
          {gettext("Открыть публичный профиль")}
        </a>
      </nav>
      <div :if={is_nil(@current_user.email_confirmed_at)} class="flash">
        <span>{gettext("Email не подтверждён")}</span><button class="quiet" phx-click="confirm">{gettext(
          "Отправить письмо"
        )}</button>
      </div>
      <div :if={@live_action == :overview} class="panel">
        <h2>{gettext("Аккаунт готов")}</h2><p>
          {gettext("Каталог, избранное и история появятся в следующих очередях.")}
        </p>
      </div>
      <div :if={@live_action == :settings} class="settings-grid">
        <section class="panel">
          <h2>{gettext("Ник")}</h2>
          <p class="hint">{gettext("Прежний ник резервируется за вами на 30 суток.")}</p>
          <p :if={@next_nick_change} class="hint">
            {gettext("Следующая смена доступна:")} {Calendar.strftime(
              @next_nick_change,
              "%d.%m.%Y %H:%M UTC"
            )}
          </p>
          <.form
            for={@nick_form}
            id="nickname-form"
            phx-change="validate_nick"
            phx-submit="change_nick"
          >
            <.field
              form={@nick_form}
              name={:nick}
              label={gettext("Новый ник")}
              autocomplete="username"
            />
            <button class="button small" type="submit">{gettext("Изменить ник")}</button>
          </.form>
        </section>
        <section class="panel">
          <h2>Email</h2>
          <p class="hint">{gettext("Текущий адрес не изменится до подтверждения нового.")}</p>
          <div :if={@pending_email} class="flash" id="pending-email">
            <p>{gettext("Ожидает подтверждения:")} {@pending_email.sent_to}</p>
            <button type="button" class="quiet" phx-click="resend_email">{gettext(
              "Отправить повторно"
            )}</button>
            <button type="button" class="quiet" phx-click="cancel_email">{gettext("Отменить")}</button>
          </div>
          <.form
            for={@email_form}
            id="email-change-form"
            phx-change="validate_email"
            phx-submit="change_email"
          >
            <.field
              form={@email_form}
              name={:email}
              type="email"
              label={gettext("Новый email")}
              autocomplete="email"
            />
            <.field
              form={@email_form}
              name={:current_password}
              type="password"
              label={gettext("Текущий пароль")}
              autocomplete="current-password"
            />
            <button class="button small" type="submit">{gettext("Подтвердить новый email")}</button>
          </.form>
        </section>
        <section class="panel">
          <h2>{gettext("Конфиденциальность")}</h2>
          <.form for={%{}} as={:preferences} phx-submit="preferences">
            <input type="hidden" name="preferences[show_bookmarks_public]" value="false" />
            <label class="check"><input
              type="checkbox"
              name="preferences[show_bookmarks_public]"
              value="true"
              checked={@current_user.show_bookmarks_public}
            />{gettext("Показывать избранное в публичном профиле")}</label>
            <button class="button small" type="submit">{gettext("Сохранить")}</button>
          </.form>
          <a href={AnimeWeb.Auth.localized(@locale, "/password/change")}>{gettext("Изменить пароль")}</a>
        </section>
        <section class="panel" id="active-sessions">
          <h2>{gettext("Активные сессии")}</h2>
          <p class="hint">
            {gettext(
              "Завершение остальных сессий также отключает все сохранённые входы «запомнить меня»."
            )}
          </p>
          <button type="button" class="quiet" id="revoke-other-sessions" phx-click="revoke_others">
            {gettext("Завершить все, кроме текущей")}
          </button>
          <ul class="sessions">
            <li :for={s <- @sessions} id={"session-#{s.id}"}>
              <div class="session-details">
                <span :if={s.current?} class="badge current-session">{gettext("Текущая")}</span>
                <p class="hint">
                  {if s.context == :remember_me,
                    do: gettext("Запомнить меня"),
                    else: gettext("Сессия")}
                </p>
                <strong>{s.ip || "—"}</strong>
                <p class="hint">{s.user_agent || "—"}</p>
                <p class="hint">
                  {gettext("Создана:")}
                  <time datetime={DateTime.to_iso8601(s.inserted_at)}>
                    {Calendar.strftime(s.inserted_at, "%d.%m.%Y %H:%M UTC")}
                  </time>
                </p>
                <p class="hint">
                  {gettext("Последнее использование:")}
                  <time :if={s.last_used_at} datetime={DateTime.to_iso8601(s.last_used_at)}>
                    {Calendar.strftime(s.last_used_at, "%d.%m.%Y %H:%M UTC")}
                  </time>
                  <span :if={!s.last_used_at}>—</span>
                </p>
              </div>
              <button type="button" class="quiet" phx-click="revoke" phx-value-id={s.id}>
                {gettext("Завершить")}
              </button>
            </li>
          </ul>
        </section>
        <section class="panel">
          <h2>{gettext("Удаление аккаунта")}</h2>
          <p>
            {gettext(
              "Все сессии завершатся. В течение 30 суток удаление можно отменить по ссылке из письма."
            )}
          </p>
          <.form
            for={@delete_form}
            id="deletion-form"
            phx-change="validate_deletion"
            phx-submit="delete_account"
          >
            <.field
              form={@delete_form}
              name={:nick}
              label={gettext("Введите свой ник для подтверждения")}
              autocomplete="off"
            />
            <.field
              form={@delete_form}
              name={:current_password}
              type="password"
              label={gettext("Текущий пароль")}
              autocomplete="current-password"
            />
            <button class="button small" type="submit">{gettext("Запросить удаление аккаунта")}</button>
          </.form>
        </section>
      </div>
      <form method="post" action="/logout">
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} /><button
          type="submit"
          class="quiet"
        >{gettext("Выйти")}</button>
      </form>
    </section>
    """
  end
end
