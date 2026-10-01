defmodule AnimeWeb.AdminNavigation do
  use Gettext, backend: AnimeWeb.Gettext

  # Only implemented screens belong here. This snapshot drives presentation, not authorization.
  def sections(permissions) do
    [
      {"dashboard", gettext("Дашборд"), "▦",
       [
         {"/admin/dashboard", gettext("Дашборд"), "admin.dashboard.view"}
       ]},
      {"users", gettext("Пользователи"), "◎",
       [
         {"/admin/users", gettext("Все пользователи"), "users.user.view"},
         {"/admin/users/blocked", gettext("Блокировки"), "users.user.view"},
         {"/admin/users/activity", gettext("История активности"), "users.activity.view"}
       ]},
      {"roles", gettext("Роли и права"), "◇",
       [
         {"/admin/roles", gettext("Роли"), "roles.role.view"},
         {"/admin/roles/permissions", gettext("Разрешения"), "roles.permission.view"},
         {"/admin/roles/matrix", gettext("Матрица прав"), "roles.matrix.edit"}
       ]}
    ]
    |> Enum.flat_map(fn {key, label, icon, items} ->
      items =
        for {path, title, permission} <- items,
            permission in permissions,
            do: %{path: path, title: title}

      if items == [], do: [], else: [%{key: key, label: label, icon: icon, items: items}]
    end)
  end

  def first_path(permissions) do
    case sections(permissions) do
      [%{items: [%{path: path} | _]} | _] -> path
      _ -> "/403"
    end
  end

  def current(permissions, path) do
    matches =
      for section <- sections(permissions),
          item <- section.items,
          path == item.path or String.starts_with?(path, item.path <> "/"),
          do: Map.merge(item, %{section: section.key, section_label: section.label})

    Enum.max_by(matches, &String.length(&1.path), fn ->
      %{path: "/admin", title: gettext("Админ-панель"), section: "", section_label: ""}
    end)
  end
end
