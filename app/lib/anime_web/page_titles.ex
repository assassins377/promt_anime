defmodule AnimeWeb.PageTitles do
  use Gettext, backend: AnimeWeb.Gettext

  # Queue 1 service pages have fixed, translated labels; never use request params
  # (especially bearer tokens) as titles. Public SEO templates arrive in queue 3.
  def title(label), do: label <> " · Anime"

  def auth(action) do
    title(
      case action do
        :login -> gettext("Вход")
        :register -> gettext("Регистрация")
        :request_reset -> gettext("Восстановление пароля")
        :reset -> gettext("Новый пароль")
        :change -> gettext("Смена пароля")
      end
    )
  end

  def profile(:settings), do: title(gettext("Настройки"))
  def profile(_), do: title(gettext("Мой профиль"))

  def placeholder(action) do
    label =
      case action do
        :home -> gettext("Главная")
        :catalog -> gettext("Каталог")
        :genres -> gettext("Жанры")
        :blog -> gettext("Блог")
        :donate -> gettext("Донаты")
        :feedback -> gettext("Обратная связь")
        :terms -> gettext("Условия использования")
        :privacy -> gettext("Конфиденциальность")
        :bookmarks -> gettext("Избранное")
      end

    title(label <> " · " <> gettext("В разработке"))
  end
end
