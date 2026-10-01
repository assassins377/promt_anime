defmodule AnimeWeb.BlockRegistryTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.{Audit, Repo}
  alias Anime.Accounts.{Administration, User}
  alias Anime.Access.{Permission, RolePermission}

  test "registry renders dedicated columns and filters block dates with the operator", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()
    {:ok, _} = Administration.ban(owner, target.id, %{"reason" => "spam", "days" => "2"})

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(User, target.id),
        blocked_at: ~U[2025-03-02 15:30:00.000000Z]
      )
    )

    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/blocked?status[]=active")
    assert has_element?(view, "#users-table th", "Кто заблокировал")
    refute has_element?(view, "#users-table th", "Email")
    refute has_element?(view, "#users-filter", "Дата регистрации")
    assert has_element?(view, "#user-#{target.id} a[href='/admin/users/#{owner.id}']", owner.nick)
    assert has_element?(view, "#user-#{target.id}", "спам")
    view |> element("#select-user-#{target.id}") |> render_click()

    render_change(view, "filter", %{
      "filters" => %{
        "blocked_by" => to_string(owner.id),
        "from" => "2025-03-02",
        "to" => "2025-03-02",
        "term" => "temporary"
      }
    })

    assert_patch(
      view,
      "/admin/users/blocked?blocked_by=#{owner.id}&from=2025-03-02&term=temporary&to=2025-03-02"
    )

    render_async(view, 2000)
    assert has_element?(view, "#user-#{target.id}")
    refute has_element?(view, "#bulk-actions")
    view |> element("#users-table th a", "Дата блокировки") |> render_click()

    assert_patch(
      view,
      "/admin/users/blocked?blocked_by=#{owner.id}&dir=asc&from=2025-03-02&sort=blocked_at&term=temporary&to=2025-03-02"
    )

    render_async(view, 2000)
    render_change(view, "filter", %{"filters" => %{"to" => "2025-03-01"}})
    assert_patch(view)
    render_async(view, 2000)
    refute has_element?(view, "#user-#{target.id}")
  end

  test "block history pages use the route target and do not expose arbitrary audit values", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()
    now = DateTime.utc_now()

    rows =
      for n <- 1..51 do
        entry =
          Audit.record(owner, "users.user.ban", "User", target.id, :success, %{
            new_value: %{
              block_reason: "history #{n}",
              blocked_until: nil,
              password: "secret-history-value"
            }
          })

        Repo.update!(Ecto.Changeset.change(entry, occurred_at: now))
      end

    foreign = Audit.record(owner, "users.user.ban", "User", owner.id, :success)

    {:ok, view, _} =
      live(login_conn(conn, owner), "/admin/users/#{target.id}?tab=blocks&user_id=#{owner.id}")

    assert has_element?(view, "#block-history-pages", "1 / 2")
    assert has_element?(view, "#block-event-#{List.last(rows).id}", "history 51")
    refute has_element?(view, "#block-event-#{hd(rows).id}")
    refute has_element?(view, "#block-event-#{foreign.id}")
    refute render(view) =~ "secret-history-value"
    view |> element("#block-history-pages a", "Далее") |> render_click()
    assert_patch(view, "/admin/users/#{target.id}?page=2&tab=blocks")
    assert has_element?(view, "#block-history-pages", "2 / 2")
    assert has_element?(view, "#block-event-#{hd(rows).id}", "history 1")
    refute has_element?(view, "#block-event-#{List.last(rows).id}")
    view |> element("#block-history-pages a", "Назад") |> render_click()
    assert_patch(view, "/admin/users/#{target.id}?tab=blocks")
  end

  test "unblocking refreshes registry and card without erasing history", %{conn: conn} do
    owner = role_user("owner")
    target = user()
    {:ok, _} = Administration.ban(owner, target.id, %{"reason" => "spam", "permanent" => "true"})
    conn = login_conn(conn, owner)
    {:ok, registry, _} = live(conn, "/admin/users/blocked")
    {:ok, card, _} = live(conn, "/admin/users/#{target.id}?tab=blocks")
    assert has_element?(card, "#current-block", owner.nick)
    assert has_element?(card, "#current-block", "Бессрочно")
    card |> element("#unban-user") |> render_click()
    card |> form("#user-action") |> render_submit()
    render(registry)
    render_async(registry, 2000)
    refute has_element?(registry, "#user-#{target.id}")
    refute has_element?(card, "#current-block")
    assert render(card) =~ "Сейчас не заблокирован"
    assert has_element?(card, "#block-history", "Разблокировка")
    assert has_element?(card, "#block-history", "Блокировка")
    assert has_element?(card, "#block-history", "спам")
  end

  test "missing operator and automatic expiry are explained in English", %{conn: conn} do
    owner = role_user("owner") |> Ecto.Changeset.change(locale: :en) |> Repo.update!()
    target = user()
    {:ok, _} = Administration.ban(owner, target.id, %{"reason" => "spam", "days" => "1"})

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(User, target.id),
        blocked_by_id: nil,
        blocked_until: DateTime.add(DateTime.utc_now(), -1)
      )
    )

    conn = login_conn(conn, owner)
    {:ok, registry, _} = live(conn, "/admin/users/blocked?blocked_by=missing")
    assert has_element?(registry, "#users-table th", "Blocked by")
    assert has_element?(registry, "#user-#{target.id}", "Not specified")
    assert has_element?(registry, "#users-filter", "Blocked from")
    {:ok, _} = Administration.unblock_expired(target.id)
    render(registry)
    render_async(registry, 2000)
    {:ok, card, _} = live(conn, "/admin/users/#{target.id}?tab=blocks")
    assert has_element?(card, "#block-history", "Automatically on expiry")
    assert render(card) =~ "Not currently blocked"
  end

  test "empty and malformed history pages are safe and tabs do not carry the history page", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()

    {:ok, card, _} =
      live(login_conn(conn, owner), "/admin/users/#{target.id}?tab=blocks&page[]=bad")

    assert render(card) =~ "История блокировок пуста"
    assert has_element?(card, "#block-history-pages", "1 / 1")
    card |> element("nav a", "Обзор") |> render_click()
    assert_patch(card, "/admin/users/#{target.id}?tab=overview")
    refute has_element?(card, "#block-history")
    card |> element("#admin-content nav a", "Блокировки") |> render_click()
    assert_patch(card, "/admin/users/#{target.id}?tab=blocks")
    assert has_element?(card, "#block-history-pages", "1 / 1")
  end

  test "rights revoked without pubsub prevent history and registry refresh", %{conn: conn} do
    admin = role_user("admin")
    target = user()
    conn = login_conn(conn, admin)
    {:ok, card, _} = live(conn, "/admin/users/#{target.id}?tab=blocks")
    {:ok, registry, _} = live(conn, "/admin/users/blocked")
    permission = Repo.get_by!(Permission, code: "users.user.view")

    Repo.delete_all(
      from rp in RolePermission,
        where: rp.role_id == ^admin.role_id and rp.permission_id == ^permission.id
    )

    entry = Audit.record(admin, "users.user.ban", "User", target.id, :success)
    render_patch(card, "/admin/users/#{target.id}?tab=blocks&page=2")

    assert render(card) =~
             "Недостаточно прав для этого действия. Проверьте доступ или обратитесь к владельцу сайта."

    refute has_element?(card, "#block-event-#{entry.id}")
    send(registry.pid, :users_changed)

    assert render(registry) =~
             "Недостаточно прав для этого действия. Проверьте доступ или обратитесь к владельцу сайта."
  end
end
