defmodule AnimeWeb.AdminErrors do
  @moduledoc "Safe operator-facing explanations. Never render arbitrary backend errors."
  use Gettext, backend: AnimeWeb.Gettext

  def message(:list_loading),
    do:
      dgettext(
        "admin_errors",
        "Дождитесь загрузки списка. Если запрос завершился ошибкой, повторите его."
      )

  def message(:list_failed),
    do: dgettext("admin_errors", "Не удалось загрузить список. Повторите запрос.")

  def message(:confirmation_required),
    do:
      dgettext("admin_errors", "Сначала выберите действие и подтвердите его в открывшемся окне.")

  def message(:forbidden),
    do:
      dgettext(
        "admin_errors",
        "Недостаточно прав для этого действия. Проверьте доступ или обратитесь к владельцу сайта."
      )

  def message(:not_found),
    do: dgettext("admin_errors", "Запись не найдена. Обновите список: её могли удалить.")

  def message(:stale_record),
    do:
      dgettext(
        "admin_errors",
        "Запись изменилась после открытия формы. Обновите данные и повторите действие."
      )

  def message(:stale_account),
    do:
      dgettext(
        "admin_errors",
        "Данные пользователя изменились в другом окне. Откройте форму заново и проверьте изменения."
      )

  def message(:stale_matrix),
    do:
      dgettext(
        "admin_errors",
        "Матрица прав изменилась в другом окне. Отмените черновик, перечитайте матрицу и внесите изменения заново."
      )

  def message(:self_action),
    do:
      dgettext(
        "admin_errors",
        "Действие над собственным аккаунтом запрещено. Для личных настроек откройте профиль."
      )

  def message(:protected_owner),
    do:
      dgettext(
        "admin_errors",
        "Владелец защищён. Это действие над ролью или аккаунтом владельца недоступно."
      )

  def message(:last_owner),
    do:
      dgettext(
        "admin_errors",
        "Нельзя убрать последнего активного владельца. Сначала назначьте другого владельца."
      )

  def message(:privilege_escalation),
    do:
      dgettext(
        "admin_errors",
        "Недостаточно прав для этой цели или роли. Нельзя управлять более привилегированным пользователем или назначать недоступную роль."
      )

  def message(:no_sessions), do: dgettext("admin_errors", "Активных сессий для завершения нет.")

  def message(:unchanged),
    do: dgettext("admin_errors", "Изменений нет: запись уже содержит выбранные значения.")

  def message(:system_code),
    do:
      dgettext(
        "admin_errors",
        "Код системной роли менять нельзя. Измените только её название или значок."
      )

  def message(:system_role), do: dgettext("admin_errors", "Системную роль удалить нельзя.")

  def message(:default_role),
    do:
      dgettext(
        "admin_errors",
        "Это роль новых регистраций. Сначала выберите другую роль по умолчанию."
      )

  def message(:role_in_use),
    do:
      dgettext(
        "admin_errors",
        "Роль назначена пользователям или ещё используется. Перенесите пользователей в другую роль и обновите список."
      )

  def message(:cannot_grant),
    do:
      dgettext(
        "admin_errors",
        "Нельзя выдать разрешения, которых нет у вас. Уберите их из изменений."
      )

  def message(:unknown_permission),
    do:
      dgettext(
        "admin_errors",
        "В изменениях есть неизвестное разрешение. Перечитайте матрицу и повторите выбор."
      )

  def message(:self_permission_removal),
    do:
      dgettext(
        "admin_errors",
        "Нельзя снять собственные разрешения через матрицу. Обратитесь к другому владельцу."
      )

  def message(:invalid_changes),
    do:
      dgettext(
        "admin_errors",
        "Нет подтверждённого набора изменений. Проверьте выбор и откройте подтверждение заново."
      )

  def message(:invalid_fields),
    do: dgettext("admin_errors", "Проверьте поля формы и исправьте отмеченные значения.")

  def message(:invalid_action),
    do:
      dgettext(
        "admin_errors",
        "Это действие недоступно. Обновите страницу и выберите действие из списка."
      )

  def message(:invalid_selection),
    do:
      dgettext(
        "admin_errors",
        "Выберите от 1 до 50 записей на текущей странице и повторите действие."
      )

  def message(:nickname_mismatch),
    do:
      dgettext(
        "admin_errors",
        "Ник не совпадает. Для подтверждения введите точный ник пользователя."
      )

  def message(:already_requested),
    do:
      dgettext(
        "admin_errors",
        "Удаление этого аккаунта уже запрошено. Обновите карточку пользователя."
      )

  def message(:not_requested),
    do: dgettext("admin_errors", "У аккаунта нет запроса на удаление, который можно отменить.")

  def message(:already_blocked),
    do:
      dgettext(
        "admin_errors",
        "Пользователь уже заблокирован. Обновите карточку и проверьте срок блокировки."
      )

  def message(:not_blocked),
    do: dgettext("admin_errors", "Пользователь не заблокирован. Снимать блокировку не требуется.")

  def message(:invalid_reason),
    do:
      dgettext(
        "admin_errors",
        "Выберите причину блокировки. Для «Другое» нужен комментарий от 10 до 300 символов."
      )

  def message(:invalid_duration),
    do:
      dgettext(
        "admin_errors",
        "Укажите срок блокировки от 1 до 3650 суток или выберите бессрочную блокировку."
      )

  def message(:not_due),
    do:
      dgettext(
        "admin_errors",
        "Срок ещё не наступил. Обновите данные и проверьте дату окончания."
      )

  def message(:rate_limited),
    do: dgettext("admin_errors", "Слишком много попыток. Подождите и повторите действие позже.")

  def message(%Ecto.Changeset{}), do: message(:invalid_fields)

  def message(_),
    do:
      dgettext(
        "admin_errors",
        "Не удалось выполнить действие. Обновите страницу и повторите попытку; если ошибка останется, обратитесь к владельцу сайта."
      )
end
