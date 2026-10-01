defmodule AnimeWeb.SessionController do
  use AnimeWeb, :controller
  alias AnimeWeb.Auth
  alias Anime.Accounts

  def login(conn, %{"user" => attrs}) do
    case Accounts.authenticate(attrs["login"], attrs["password"], Auth.meta(conn)) do
      {:ok, user} ->
        Auth.establish(conn, user, attrs["remember"] == "true")

      {:error, :rate_limited} ->
        conn
        |> put_flash(:error, gettext("Слишком много попыток. Попробуйте через 15 минут."))
        |> redirect(to: Auth.path(conn, "/login"))

      _ ->
        conn
        |> put_flash(:error, gettext("Неверный логин или пароль"))
        |> redirect(to: Auth.path(conn, "/login"))
    end
  end

  def login(conn, _), do: conn |> put_status(400) |> text("Bad request")

  def register(conn, %{"user" => attrs, "opened" => opened}) do
    with {:ok, timestamp} <-
           Phoenix.Token.verify(AnimeWeb.Endpoint, "registration-form", opened, max_age: 3600),
         true <- is_integer(timestamp) && System.system_time(:second) - timestamp >= 3,
         true <- Map.get(attrs, "website", "") == "",
         {:ok, user} <-
           Accounts.register(Map.put(attrs, "locale", conn.assigns.locale), Auth.meta(conn)) do
      Auth.establish(conn, user, false)
    else
      _ ->
        conn
        |> put_flash(
          :error,
          gettext("Регистрация не выполнена. Проверьте поля и попробуйте снова.")
        )
        |> redirect(to: Auth.path(conn, "/register"))
    end
  end

  def register(conn, _), do: conn |> put_status(400) |> text("Bad request")

  def logout(conn, _) do
    Accounts.logout(
      get_session(conn, :user_token),
      conn.cookies["_anime_remember"],
      Auth.meta(conn)
    )

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> delete_resp_cookie("_anime_remember")
    |> put_flash(:info, gettext("Вы вышли из аккаунта"))
    |> redirect(to: Auth.path(conn, "/"))
  end

  def confirm(conn, %{"token" => token}) do
    case Accounts.confirm(token, Auth.meta(conn)) do
      {:ok, _} ->
        conn
        |> put_flash(:info, gettext("Email подтверждён"))
        |> redirect(to: Auth.path(conn, "/profile"))

      _ ->
        conn
        |> put_flash(:error, gettext("Ссылка недействительна или истекла"))
        |> redirect(to: Auth.path(conn, "/login"))
    end
  end

  def password(conn, %{"user" => attrs}) do
    case Accounts.change_password(
           conn.assigns.current_user,
           attrs["current_password"],
           attrs,
           conn.assigns.session_token,
           Auth.meta(conn)
         ) do
      {:ok, _} ->
        conn
        |> delete_resp_cookie("_anime_remember")
        |> put_flash(:info, gettext("Пароль изменён"))
        |> redirect(to: Auth.path(conn, "/profile"))

      _ ->
        conn
        |> put_flash(:error, gettext("Не удалось изменить пароль"))
        |> redirect(to: Auth.path(conn, "/password/change"))
    end
  end

  def restore(conn, %{"token" => token}) do
    case Accounts.restore_account(token, Auth.meta(conn)) do
      {:ok, _} ->
        conn
        |> put_flash(:info, gettext("Удаление аккаунта отменено. Войдите заново."))
        |> redirect(to: Auth.path(conn, "/login"))

      _ ->
        conn
        |> put_status(:not_found)
        |> put_root_layout(false)
        |> put_view(html: AnimeWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  def locale(conn, %{"locale" => locale} = params) when locale in ["ru", "en"] do
    result =
      if conn.assigns.current_user do
        Accounts.update_preferences(
          conn.assigns.current_user,
          %{"locale" => locale},
          Auth.meta(conn)
        )
      else
        {:ok, nil}
      end

    case result do
      {:ok, user} ->
        conn =
          if is_nil(user) do
            put_resp_cookie(conn, "locale", locale,
              max_age: 365 * 86400,
              http_only: true,
              secure: true,
              same_site: "Lax"
            )
          else
            conn
          end

        conn
        |> put_session(:locale, locale)
        |> redirect(to: AnimeWeb.Locale.switch_path(locale, params["return_to"]))

      {:error, _} ->
        conn
        |> put_flash(:error, gettext("Не удалось сохранить"))
        |> redirect(to: Auth.safe_return(params["return_to"]))
    end
  end

  def locale(conn, _), do: conn |> put_status(:bad_request) |> text("Bad request")
end
