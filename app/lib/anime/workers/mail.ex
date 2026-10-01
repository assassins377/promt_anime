defmodule Anime.Workers.Mail do
  use Anime.Worker, queue: :mailers, max_attempts: 5
  use Gettext, backend: AnimeWeb.Gettext
  import Swoosh.Email
  alias Anime.{Repo, Mailer, Accounts.User, Accounts.UserToken, Accounts.Tokens}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    Enum.at([60, 300, 900, 3600, 7200], max(attempt - 1, 0), 7200)
  end

  @impl true
  def perform(%Oban.Job{args: %{"token_id" => id} = args}) do
    Gettext.put_locale(AnimeWeb.Gettext, Map.get(args, "locale", "ru"))

    with %UserToken{} = token <- Repo.get(UserToken, id),
         true <- DateTime.compare(token.expires_at, DateTime.utc_now()) == :gt,
         %User{} = user <- Repo.get(User, token.user_id),
         true <- deliverable?(token, user) do
      raw = Tokens.mail_bytes(token)

      if Plug.Crypto.secure_compare(Tokens.digest(raw), token.token) do
        prefix =
          case token.context do
            :reset_password -> "/password/reset/"
            :delete_cancel -> "/account/restore/"
            _ -> "/confirm/"
          end

        url =
          Application.fetch_env!(:anime, :site_origin) <>
            AnimeWeb.Auth.localized(args["locale"], prefix) <>
            Base.url_encode64(raw, padding: false)

        send_mail(
          token.sent_to,
          gettext("Подтверждение действия"),
          gettext("Откройте ссылку:") <> "\n" <> url
        )
      else
        :ok
      end
    else
      _ -> :ok
    end
  end

  def perform(%Oban.Job{
        args: %{"audit_id" => id, "kind" => "email_change_notice", "locale" => locale}
      }) do
    Gettext.put_locale(AnimeWeb.Gettext, locale)

    case Repo.get(Anime.Audit, id) do
      %Anime.Audit{action: "email_change_request", old_value: %{"email" => address}} ->
        send_mail(
          address,
          gettext("Запрошена смена email"),
          gettext(
            "Для вашего аккаунта запрошена смена email. Если это были не вы, восстановите доступ."
          )
        )

      _ ->
        :ok
    end
  end

  def perform(%Oban.Job{
        args: %{"user_id" => id, "kind" => "password_changed", "locale" => locale}
      }) do
    Gettext.put_locale(AnimeWeb.Gettext, locale)

    case Repo.get(User, id) do
      nil ->
        :ok

      user ->
        send_mail(
          user.email,
          gettext("Пароль изменён"),
          gettext("Пароль вашего аккаунта изменён. Если это были не вы, восстановите доступ.")
        )
    end
  end

  def perform(%Oban.Job{args: %{"audit_id" => id, "kind" => kind, "locale" => locale}})
      when kind in ["account_blocked", "login_after_block"] do
    Gettext.put_locale(AnimeWeb.Gettext, locale)
    action = if kind == "account_blocked", do: "users.user.ban", else: "users.user.unban"

    with %Anime.Audit{action: ^action, object_type: "User", result: :success} = entry <-
           Repo.get(Anime.Audit, id),
         %User{} = user <- Repo.get(User, entry.object_id) do
      subject =
        if kind == "account_blocked",
          do: gettext("Аккаунт заблокирован"),
          else: gettext("Доступ восстановлен")

      reason =
        (entry.new_value || %{})["block_reason"] || (entry.old_value || %{})["block_reason"] || ""

      origin = Application.fetch_env!(:anime, :site_origin)

      body =
        subject <>
          "\n" <>
          DateTime.to_iso8601(entry.occurred_at) <>
          "\n" <>
          reason <>
          "\n" <>
          origin <>
          AnimeWeb.Auth.localized(locale, "/") <>
          "\n" <> origin <> AnimeWeb.Auth.localized(locale, "/feedback")

      send_mail(user.email, subject, body)
    else
      _ -> :ok
    end
  end

  defp deliverable?(%UserToken{context: :change_email}, user), do: User.active?(user)

  defp deliverable?(%UserToken{context: :delete_cancel} = t, user),
    do: user.deletion_requested && user.email == t.sent_to

  defp deliverable?(%UserToken{context: context} = t, user)
       when context in [:confirm, :reset_password],
       do: User.active?(user) && user.email == t.sent_to

  defp deliverable?(_, _), do: false

  defp send_mail(to, subject, body) do
    from = Application.get_env(:anime, :mail_from, {"Anime", "no-reply@localhost"})

    case new()
         |> to(to)
         |> from(from)
         |> subject(subject)
         |> text_body(body)
         |> Mailer.deliver() do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :delivery_failed}
    end
  end
end
