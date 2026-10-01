defmodule AnimeWeb.BulkUsersTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.Accounts.{Administration, User, Tokens}
  alias Anime.Access.{Role, Permission, RolePermission}

  test "confirmation is mandatory and cancel preserves selection without changing data", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users")
    render_submit(view, "confirm_bulk", %{"role_id" => owner.role_id})
    assert has_element?(view, "[role=alert]", "Сначала выберите действие и подтвердите его")
    view |> element("#select-user-#{target.id}") |> render_click()
    view |> element("#bulk-role") |> render_click()
    assert has_element?(view, "#bulk-confirm", "Выбрано: 1")
    view |> element("button[data-dialog-cancel]") |> render_click()
    refute has_element?(view, "#bulk-confirm")
    assert has_element?(view, "#select-user-#{target.id}[checked]")
    assert Repo.get!(User, target.id).role_id == target.role_id
  end

  test "mixed results retain refused selections and ignore injected target IDs", %{conn: conn} do
    owner = role_user("owner")
    target = user()
    outside = user()
    editor = Repo.get_by!(Role, code: "content_editor")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users")
    for id <- [target.id, owner.id], do: view |> element("#select-user-#{id}") |> render_click()
    view |> element("#bulk-role") |> render_click()

    render_submit(view, "confirm_bulk", %{
      "role_id" => to_string(editor.id),
      "ids" => [outside.id]
    })

    render_async(view, 2000)

    assert has_element?(view, "#bulk-result", "Применено: 1")

    assert has_element?(
             view,
             "#bulk-result",
             "Действие над собственным аккаунтом запрещено. Для личных настроек откройте профиль."
           )

    assert has_element?(view, "#select-user-#{owner.id}[checked]")
    refute has_element?(view, "#select-user-#{target.id}[checked]")
    assert Repo.get!(User, target.id).role_id == editor.id
    assert Repo.get!(User, outside.id).role_id == outside.role_id
    render_submit(view, "confirm_bulk", %{"role_id" => to_string(owner.role_id)})
    assert Repo.get!(User, target.id).role_id == editor.id
  end

  test "PubSub refresh does not replace the selected record version", %{conn: conn} do
    owner = role_user("owner")
    target = user()
    editor = Repo.get_by!(Role, code: "content_editor")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users")
    view |> element("#select-user-#{target.id}") |> render_click()
    assert {:ok, _} = Administration.edit(owner, target.id, %{"locale" => "en"})
    render(view)
    render_async(view, 2000)
    view |> element("#bulk-role") |> render_click()
    view |> form("#bulk-form", %{role_id: editor.id}) |> render_submit()
    render_async(view, 2000)

    assert has_element?(
             view,
             "#bulk-result",
             "Запись изменилась после открытия формы. Обновите данные и повторите действие."
           )

    assert has_element?(view, "#select-user-#{target.id}[checked]")
    assert Repo.get!(User, target.id).role_id == target.role_id
    view |> element("#select-user-#{target.id}") |> render_click()
    view |> element("#select-user-#{target.id}") |> render_click()
    view |> element("#bulk-role") |> render_click()
    view |> form("#bulk-form", %{role_id: editor.id}) |> render_submit()
    render_async(view, 2000)
    assert Repo.get!(User, target.id).role_id == editor.id
  end

  test "search, sorting and navigation clear selection and pending confirmation", %{conn: conn} do
    owner = role_user("owner")
    target = user()
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users")
    view |> element("#select-user-#{target.id}") |> render_click()
    render_change(view, "filter", %{"filters" => %{"q" => target.nick}})
    assert_patch(view)
    render_async(view, 2000)
    refute has_element?(view, "#bulk-actions")
    render_click(view, "select", %{"id" => to_string(owner.id)})
    assert render(view) =~ "Выберите от 1 до 50 записей на текущей странице и повторите действие."
    view |> element("#select-page") |> render_click()
    assert has_element?(view, "#bulk-actions", "Выбрано: 1")
    view |> element("#users-table th a", "Ник") |> render_click()
    assert_patch(view)
    render_async(view, 2000)
    refute has_element?(view, "#bulk-actions")
    view |> element("#select-page") |> render_click()
    view |> element("#bulk-role") |> render_click()
    render_patch(view, "/admin/users?page=2")
    render_async(view, 2000)
    refute has_element?(view, "#bulk-confirm")
    refute has_element?(view, "#bulk-actions")
  end

  test "row role action and block link use only the visible account", %{conn: conn} do
    owner = role_user("owner")
    target = user()
    editor = Repo.get_by!(Role, code: "content_editor")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users?q=#{target.nick}")

    assert has_element?(
             view,
             "#user-#{target.id} a[href='/admin/users/#{target.id}?tab=blocks'][title='Заблокировать']"
           )

    render_click(view, "prepare_bulk", %{"action" => "role", "id" => to_string(owner.id)})
    refute has_element?(view, "#bulk-confirm")
    view |> element("#row-role-#{target.id}") |> render_click()
    view |> form("#bulk-form", %{role_id: editor.id}) |> render_submit()
    render_async(view, 2000)
    assert Repo.get!(User, target.id).role_id == editor.id
  end

  test "session action preserves owner login and mail confirmation tokens", %{conn: conn} do
    owner = role_user("owner")
    target = user()
    {:ok, {raw, remember}} = Anime.Accounts.create_session(target, true, meta())
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users")
    view |> element("#select-user-#{target.id}") |> render_click()
    view |> element("#bulk-revoke") |> render_click()
    view |> form("#bulk-form") |> render_submit()
    render_async(view, 2000)
    refute Tokens.user(raw)
    refute Tokens.find(remember, [:remember_me])
    assert has_element?(view, "#bulk-result", "Применено: 1")
  end

  test "forged actions and stale permission cannot bypass current authorization", %{conn: conn} do
    moderator = role_user("comment_moderator")
    target = user()
    {:ok, view, _} = live(login_conn(conn, moderator), "/admin/users")
    view |> element("#select-user-#{target.id}") |> render_click()
    refute has_element?(view, "#bulk-role")
    render_click(view, "prepare_bulk", %{"action" => "role"})
    refute has_element?(view, "#bulk-confirm")
    admin = role_user("admin")
    {:ok, view, _} = live(login_conn(conn, admin), "/admin/users")
    view |> element("#select-user-#{target.id}") |> render_click()
    view |> element("#bulk-role") |> render_click()
    permission = Repo.get_by!(Permission, code: "users.role.assign")

    Repo.delete_all(
      from rp in RolePermission,
        where: rp.role_id == ^admin.role_id and rp.permission_id == ^permission.id
    )

    view |> form("#bulk-form", %{role_id: target.role_id}) |> render_submit()
    render_async(view, 2000)

    assert render(view) =~
             "Недостаточно прав для этого действия. Проверьте доступ или обратитесь к владельцу сайта."

    refute has_element?(view, "#bulk-result")
  end

  test "English controls and partial-error explanation are localized", %{conn: conn} do
    owner = role_user("owner") |> Ecto.Changeset.change(locale: :en) |> Repo.update!()
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users")
    view |> element("#select-user-#{owner.id}") |> render_click()
    assert has_element?(view, "#bulk-actions", "Selected: 1")
    view |> element("#bulk-role") |> render_click()
    assert has_element?(view, "#bulk-confirm", "First 10 IDs")
    view |> form("#bulk-form", %{role_id: owner.role_id}) |> render_submit()
    render_async(view, 2000)
    assert has_element?(view, "#bulk-result", "Operation result")
    assert has_element?(view, "#bulk-result", "own account")
  end

  test "select page affects exactly fifty visible records, never the next page", %{conn: conn} do
    owner = role_user("owner")
    template = user()
    now = DateTime.utc_now()

    rows =
      for n <- 1..50 do
        %{
          email: "page#{template.id}-#{n}@example.com",
          nick: "page#{template.id}-#{n}",
          hashed_password: template.hashed_password,
          role_id: template.role_id,
          consent_accepted_at: now,
          consent_version: template.consent_version,
          inserted_at: now,
          updated_at: now
        }
      end

    {50, _} = Repo.insert_all(User, rows)
    editor = Repo.get_by!(Role, code: "content_editor")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users")
    refute has_element?(view, "#user-#{template.id}")
    view |> element("#select-page") |> render_click()
    assert has_element?(view, "#bulk-actions", "Выбрано: 50")
    view |> element("#bulk-role") |> render_click()
    assert has_element?(view, "#bulk-confirm", "Выбрано: 50")
    view |> form("#bulk-form", %{role_id: editor.id}) |> render_submit()
    render_async(view, 2000)
    assert has_element?(view, "#bulk-result", "Применено: 50")
    refute has_element?(view, "#bulk-actions")
    assert Repo.get!(User, template.id).role_id == template.role_id
    assert Repo.get!(User, owner.id).role_id == owner.role_id
    assert Repo.aggregate(from(u in User, where: u.role_id == ^editor.id), :count) == 50
  end
end
