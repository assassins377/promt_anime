defmodule AnimeWeb.AuthLive do
  use AnimeWeb, :live_view
  alias Anime.Accounts
  alias Anime.Accounts.User

  def handle_params(_, _, socket),
    do:
      {:noreply,
       assign(socket, :page_title, AnimeWeb.PageTitles.auth(socket.assigns.live_action))}

  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    if socket.assigns.current_user && action in [:login, :register] do
      {:ok, redirect(socket, to: AnimeWeb.Auth.localized(socket.assigns.locale, "/profile"))}
    else
      {:ok,
       socket
       |> assign(:form, form(action, %{}))
       |> assign(:trigger, false)
       |> assign(:reset_token, params["token"])
       |> assign(
         :opened,
         Phoenix.Token.sign(AnimeWeb.Endpoint, "registration-form", System.system_time(:second))
       )}
    end
  end

  defp form(:register, attrs),
    do: User.registration_changeset(%User{}, attrs) |> to_form(as: :user)

  defp form(_, attrs), do: to_form(attrs, as: :user)

  def handle_event("validate", %{"user" => attrs}, socket) do
    f =
      if socket.assigns.live_action == :register do
        User.registration_changeset(%User{}, attrs)
        |> Map.put(:action, :validate)
        |> to_form(as: :user)
      else
        form(socket.assigns.live_action, attrs)
      end

    {:noreply, assign(socket, :form, f)}
  end

  def handle_event("submit", %{"user" => attrs}, socket) do
    case socket.assigns.live_action do
      :request_reset ->
        Accounts.request_reset(attrs["email"], socket.assigns.client_meta)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Если такой email зарегистрирован, письмо отправлено"))
         |> assign(:form, form(:request_reset, %{}))}

      :reset ->
        case Accounts.reset_password(
               socket.assigns.reset_token,
               attrs,
               socket.assigns.client_meta
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Пароль изменён"))
             |> redirect(to: AnimeWeb.Auth.localized(socket.assigns.locale, "/login"))}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Не удалось изменить пароль"))}
        end

      :register ->
        cs = User.registration_changeset(%User{}, attrs)

        if cs.valid? do
          {:noreply, assign(socket, :trigger, true)}
        else
          {:noreply, assign(socket, :form, cs |> Map.put(:action, :insert) |> to_form(as: :user))}
        end

      _ ->
        {:noreply, assign(socket, :trigger, true)}
    end
  end

  def handle_info(:access_changed, socket),
    do:
      {:noreply, redirect(socket, to: AnimeWeb.Auth.localized(socket.assigns.locale, "/profile"))}

  def render(assigns) do
    assigns =
      assign(
        assigns,
        :title,
        case assigns.live_action do
          :register -> gettext("Создать аккаунт")
          :login -> gettext("С возвращением")
          :request_reset -> gettext("Восстановление пароля")
          _ -> gettext("Новый пароль")
        end
      )

    assigns =
      assign(
        assigns,
        :action_path,
        case assigns.live_action do
          :register -> "/register"
          :change -> "/password/change"
          _ -> "/login"
        end
      )

    ~H"""
    <section class="auth-grid">
      <aside class="auth-aside">
        <span class="eyebrow">ANIME · {gettext("Ваше пространство")}</span><h1>{@title}</h1><p>
          {gettext("Всё, что вы любите, — в одном месте.")}
        </p><div class="aside-mark" aria-hidden="true">A<span>nime</span></div>
      </aside>
      <div class="form-card">
        <h2>{@title}</h2>
        <div :if={@live_action == :login} class="login-mobile-options">
          <a href={AnimeWeb.Auth.localized(@locale, "/register")}>{gettext("Регистрация")}</a>
          <AnimeWeb.PublicComponents.locale_form
            id="login-locale-form"
            locale={@locale}
            current_path={@current_path}
          />
        </div>
        <p :if={@live_action == :change} class="muted">
          {gettext("Для продолжения измените пароль владельца.")}
        </p>
        <.form
          for={@form}
          id="auth-form"
          action={AnimeWeb.Auth.localized(@locale, @action_path)}
          method="post"
          phx-change="validate"
          phx-submit="submit"
          phx-trigger-action={@trigger}
        >
          <input :if={@live_action == :register} type="hidden" name="opened" value={@opened} />
          <label :if={@live_action == :register} class="honeypot" aria-hidden="true">Website<input
            name="user[website]"
            tabindex="-1"
            autocomplete="off"
          /></label>
          <.field
            :if={@live_action in [:register, :request_reset]}
            form={@form}
            name={:email}
            label="Email"
            type="email"
            autocomplete="email"
          />
          <.field
            :if={@live_action == :register}
            form={@form}
            name={:nick}
            label={gettext("Ник")}
            autocomplete="username"
          />
          <.field
            :if={@live_action == :login}
            form={@form}
            name={:login}
            label={gettext("Email или ник")}
            autocomplete="username"
          />
          <.field
            :if={@live_action == :change}
            form={@form}
            name={:current_password}
            label={gettext("Текущий пароль")}
            type="password"
            autocomplete="current-password"
          />
          <.field
            :if={@live_action != :request_reset}
            form={@form}
            name={:password}
            label={gettext("Пароль")}
            type="password"
            autocomplete={if @live_action == :login, do: "current-password", else: "new-password"}
          />
          <.field
            :if={@live_action in [:register, :reset, :change]}
            form={@form}
            name={:password_confirmation}
            label={gettext("Повтор пароля")}
            type="password"
            autocomplete="new-password"
          />
          <p :if={@live_action in [:register, :reset, :change]} class="hint">
            {gettext("От 12 символов: хотя бы одна буква и цифра.")}
          </p>
          <label :if={@live_action == :register} class="check"><input
            type="checkbox"
            name="user[consent]"
            value="true"
            required
          />{gettext("Я принимаю условия использования и политику конфиденциальности")}</label>
          <label :if={@live_action == :login} class="check"><input
            type="checkbox"
            name="user[remember]"
            value="true"
          />{gettext("Запомнить меня")}</label>
          <button class="button" type="submit" phx-disable-with={gettext("Подождите…")}>{gettext(
            "Продолжить"
          )} <span aria-hidden="true">→</span></button>
        </.form>
        <a
          :if={@live_action == :login}
          href={AnimeWeb.Auth.localized(@locale, "/password/reset")}
          class="form-link"
        >{gettext("Забыли пароль?")}</a>
        <p class="hint">{gettext("Локальная версия · очередь 1")}</p>
      </div>
    </section>
    """
  end
end
