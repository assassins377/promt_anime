defmodule AnimeWeb.AdminLocalizationTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.Access.{Catalog, Labels, Role, Roles, Permission, RolePermission}
  alias Anime.Accounts.User
  alias AnimeWeb.AdminErrors

  defp locale(locale, fun), do: Gettext.with_locale(AnimeWeb.Gettext, locale, fun)

  test "all fixed permission and group labels have both translations without changing codes" do
    assert length(Catalog.codes()) == 99

    for {code, description} <- Catalog.permissions() do
      assert locale("ru", fn -> Labels.permission_name(code) end) == description
      english = locale("en", fn -> Labels.permission_name(code) end)
      assert english != code
      assert english != description
      refute english =~ ~r/[А-Яа-яЁё]/u
    end

    groups = Catalog.codes() |> Enum.map(&(String.split(&1, ".") |> hd())) |> Enum.uniq()
    assert length(groups) == 13

    for group <- groups, language <- ["ru", "en"] do
      name = locale(language, fn -> Labels.group_name(group) end)
      assert name != group
      refute name =~ "group."
    end
  end

  test "default system names translate but renamed and custom roles remain verbatim" do
    for {code, en} <- [
          {"user", "User"},
          {"owner", "Owner"},
          {"admin", "Administrator"},
          {"content_editor", "Content editor"},
          {"comment_moderator", "Comment moderator"}
        ] do
      role = Repo.get_by!(Role, code: code)
      assert locale("en", fn -> Labels.role_name(role) end) == en
      assert locale("ru", fn -> Labels.role_name(role) end) != code

      assert locale("en", fn -> Labels.role_name(%{role | name: "Моя команда"}) end) ==
               "Моя команда"
    end

    assert locale("ru", fn ->
             Labels.role_name(%Role{system: false, code: "helpers", name: "admin"})
           end) == "admin"
  end

  test "each domain refusal has an explanation in both locales, unknown payloads stay private" do
    reasons =
      ~w(confirmation_required forbidden not_found stale_record stale_account stale_matrix self_action
      protected_owner last_owner privilege_escalation no_sessions unchanged system_code
      system_role default_role role_in_use cannot_grant unknown_permission self_permission_removal
      invalid_changes invalid_fields invalid_action invalid_selection nickname_mismatch
      already_requested not_requested already_blocked not_blocked invalid_reason invalid_duration
      not_due rate_limited list_loading list_failed)a

    for reason <- reasons do
      ru = locale("ru", fn -> AdminErrors.message(reason) end)
      en = locale("en", fn -> AdminErrors.message(reason) end)
      assert String.length(ru) > 15
      assert String.length(en) > 15
      assert ru != en
      refute ru =~ Atom.to_string(reason)
      refute en =~ ~r/[А-Яа-яЁё]/u
    end

    for language <- ["ru", "en"] do
      message = locale(language, fn -> AdminErrors.message({:driver_failure, "PRIVATE_DATA"}) end)
      refute message =~ "PRIVATE_DATA"
      refute message =~ "driver_failure"
      cs = Ecto.Changeset.change(%User{email: "PRIVATE_DATA"})

      assert locale(language, fn -> AdminErrors.message(cs) end) ==
               locale(language, fn -> AdminErrors.message(:invalid_fields) end)
    end
  end

  test "permission screen translates descriptions, groups and chips in place without writes", %{
    conn: conn
  } do
    owner = role_user("owner")

    before_permissions =
      Repo.all(from p in Permission, order_by: p.id, select: {p.id, p.code, p.name, p.group})

    before_grants =
      Repo.all(
        from p in RolePermission,
          order_by: [p.role_id, p.permission_id],
          select: {p.role_id, p.permission_id}
      )

    {:ok, view, _} = live(login_conn(conn, owner), "/admin/roles/permissions?group=roles")
    assert has_element?(view, "#permissions-table", "экран «Роли»")
    assert has_element?(view, "#permissions-table", "Роли и права")
    view |> form("#admin-locale", locale: "en") |> render_change()
    assert has_element?(view, "#permissions-table", "View roles")
    assert has_element?(view, "#permissions-table", "Roles and permissions")
    assert has_element?(view, "#permissions-table", "roles.role.view")
    assert has_element?(view, "[aria-label='Active filters']", "Roles and permissions")

    assert before_permissions ==
             Repo.all(
               from p in Permission, order_by: p.id, select: {p.id, p.code, p.name, p.group}
             )

    assert before_grants ==
             Repo.all(
               from p in RolePermission,
                 order_by: [p.role_id, p.permission_id],
                 select: {p.role_id, p.permission_id}
             )
  end

  test "SQL search includes translated names, keeps stable pages and excludes renamed defaults",
       %{conn: conn} do
    owner = role_user("owner")
    {:ok, permissions} = Roles.permissions_page(owner, %{"q" => "Create a custom role"})
    assert Enum.map(permissions.rows, & &1.code) == ["roles.role.create"]
    {:ok, roles} = Roles.list_page(owner, %{"q" => "Владелец"})
    assert Enum.map(roles.rows, & &1.role.code) == ["owner"]
    before_locale = Gettext.get_locale(AnimeWeb.Gettext)
    assert "owner" in Labels.matching_system_roles("Owner")
    assert Gettext.get_locale(AnimeWeb.Gettext) == before_locale

    admin =
      Repo.get_by!(Role, code: "admin")
      |> Ecto.Changeset.change(name: "Редакция")
      |> Repo.update!()

    {:ok, listing} = Roles.list_page(owner, %{"q" => "Administrator"})
    refute Enum.any?(listing.rows, &(&1.role.id == admin.id))

    {:ok, view, _} =
      live(login_conn(conn, owner), "/admin/roles/permissions?q=Create+a+custom+role")

    assert has_element?(view, "#permissions-table tbody tr:nth-child(1)", "roles.role.create")
    refute has_element?(view, "#permissions-table tbody tr:nth-child(2)")
    view |> form("#admin-locale", locale: "en") |> render_change()
    assert has_element?(view, "#permissions-table", "Create a custom role")
    assert has_element?(view, "input[name=q][value='Create a custom role']")
  end

  test "role and user screens localize default names and escape custom names", %{conn: conn} do
    owner = role_user("owner")
    {:ok, id} = Roles.create(owner, %{code: "customteam", name: "<script>custom</script>"})
    target = role_user("content_editor")
    {:ok, roles, _} = live(login_conn(conn, owner), "/admin/roles")
    assert has_element?(roles, "#role-#{owner.role_id}", "Владелец")
    assert has_element?(roles, "#role-#{id}", "<script>custom</script>")
    refute has_element?(roles, "#role-#{id} script")
    roles |> form("#admin-locale", locale: "en") |> render_change()
    assert has_element?(roles, "#role-#{owner.role_id}", "Owner")
    assert has_element?(roles, "#role-#{id}", "<script>custom</script>")

    {:ok, users, _} =
      live(login_conn(conn, Repo.get!(User, owner.id)), "/admin/users?q=#{target.nick}")

    assert has_element?(users, "#admin-content", "Content editor")

    {:ok, card, _} =
      live(login_conn(conn, Repo.get!(User, owner.id)), "/admin/users/#{target.id}")

    assert has_element?(card, ".user-details", "Content editor")
  end

  test "matrix translations cover search, accessible labels and staged differences", %{conn: conn} do
    owner = role_user("owner")
    role = Repo.get_by!(Role, code: "user")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/roles/matrix")
    render_change(view, "change", %{"grants" => %{to_string(role.id) => [""]}})
    view |> form("#admin-locale", locale: "en") |> render_change()

    render_change(view, "filter", %{"q" => "Watch public video", "group" => "video", "role" => ""})

    assert has_element?(view, "tr:not([hidden]) small", "Watch public video")

    assert has_element?(
             view,
             "input[name='grants[#{owner.role_id}][]'][value='video.watch.play'][aria-label^='Owner: Watch public video'][disabled][checked]"
           )

    view |> form("#matrix-form") |> render_submit()
    assert has_element?(view, "#matrix-confirm", "User")
    assert has_element?(view, "#matrix-confirm", "Watch public video")
    assert has_element?(view, "#matrix-confirm code", "video.watch.play")
    assert Anime.Access.codes_for_role(role) == ["video.watch.play"]
  end

  test "forbidden errors translate after locale switch and never expose backend codes", %{
    conn: conn
  } do
    admin = role_user("admin")
    {:ok, view, _} = live(login_conn(conn, admin), "/admin/roles")
    render_submit(view, "save", %{"role" => %{"code" => "forged", "name" => "Private"}})
    assert has_element?(view, "[role=alert]", "Недостаточно прав для этого действия")
    refute render(view) =~ "forbidden"
    view |> form("#admin-locale", locale: "en") |> render_change()
    assert has_element?(view, "[role=alert]", "You do not have permission for this action")
    refute render(view) =~ "forbidden"
    refute Repo.get_by(Role, code: "forged")

    assert Repo.exists?(
             from a in Anime.Audit, where: a.action == "roles.role.create" and a.result == :denied
           )
  end

  test "busy role refusal and invalid block duration explain recovery without mutation", %{
    conn: conn
  } do
    owner = role_user("owner")
    {:ok, id} = Roles.create(owner, %{code: "busyteam", name: "Busy"})
    target = user() |> Ecto.Changeset.change(role_id: id) |> Repo.update!()
    {:ok, roles, _} = live(login_conn(conn, owner), "/admin/roles")
    render_click(roles, "prepare", %{"id" => to_string(id), "action" => "delete"})
    render_click(roles, "confirm", %{})

    assert has_element?(
             roles,
             "#role-confirm [role=alert]",
             "Перенесите пользователей в другую роль"
           )

    assert Repo.get(Role, id)
    {:ok, card, _} = live(login_conn(conn, owner), "/admin/users/#{target.id}")
    card |> element("#ban-user") |> render_click()
    card |> form("#user-action", %{reason: "spam", days: "0"}) |> render_submit()
    assert has_element?(card, "[role=alert]", "от 1 до 3650 суток")
    assert Repo.get!(User, target.id).status == :active
    refute render(card) =~ "invalid_duration"
  end

  test "form validation renders readable errors in RU and EN without discarding input", %{
    conn: conn
  } do
    owner = role_user("owner")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/roles")
    view |> form("#role-form", role: %{code: "BAD", name: "Черновик"}) |> render_change()
    assert has_element?(view, ".field-error", "Неверный формат")
    view |> form("#admin-locale", locale: "en") |> render_change()
    assert has_element?(view, ".field-error", "has invalid format")
    assert has_element?(view, "input[name='role[name]'][value='Черновик']")
    refute Repo.get_by(Role, code: "BAD")
  end
end
