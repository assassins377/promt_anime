defmodule AnimeWeb.AdminLifecycleTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.{Accounts, Audit}
  alias Anime.Accounts.{User, Administration, Tokens}
  alias Anime.Access.{Roles, Permission, RolePermission}

  test "operator edits with live validation and schema rejects injected protected fields", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/#{target.id}")
    view |> element("#edit-user") |> render_click()
    refute has_element?(view, "input[type=password]")
    refute has_element?(view, "[name='user[consent_version]']")

    view
    |> form("#user-action", user: %{nick: "a", email: "bad", locale: "ru"})
    |> render_change()

    assert has_element?(view, "#user_nick[aria-invalid=true]")

    view
    |> form("#user-action",
      user: %{nick: "edited_user", email: "edited@example.test", locale: "en"}
    )
    |> render_submit()

    u = Repo.get!(User, target.id)
    assert u.nick == "edited_user" && u.locale == :en
    refute has_element?(view, "#user-confirm")
    assert render(view) =~ "edited@example.test"
  end

  test "invalid submission shows field errors and remains editable", %{conn: conn} do
    owner = role_user("owner")
    target = user()
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/#{target.id}")
    view |> element("#edit-user") |> render_click()

    view
    |> form("#user-action", user: %{nick: "admin", email: target.email, locale: "ru"})
    |> render_submit()

    assert has_element?(view, "#user-confirm")
    assert has_element?(view, "#user_nick[aria-invalid=true]")
    assert Repo.get!(User, target.id).nick == target.nick
    refute render(view) =~ target.hashed_password
  end

  test "stale form cannot silently overwrite an external edit", %{conn: conn} do
    owner = role_user("owner")
    target = user()
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/#{target.id}")
    view |> element("#edit-user") |> render_click()
    Administration.edit(owner, target.id, %{"locale" => "en"})

    view
    |> form("#user-action", user: %{nick: target.nick, email: target.email, locale: "ru"})
    |> render_submit()

    assert Repo.get!(User, target.id).locale == :en

    assert render(view) =~
             "Данные пользователя изменились в другом окне. Откройте форму заново и проверьте изменения."
  end

  test "delete requires exact nick and confirmation, cancellation does not restore sessions", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()
    {:ok, {raw, _}} = Accounts.create_session(target, false, meta())
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/#{target.id}")
    view |> element("#delete-user") |> render_click()
    refute Repo.get!(User, target.id).deletion_requested
    view |> form("#user-action", nick: "wrong") |> render_submit()
    refute Repo.get!(User, target.id).deletion_requested
    view |> form("#user-action", nick: target.nick) |> render_submit()
    assert Repo.get!(User, target.id).deletion_requested
    refute Tokens.user(raw)
    assert has_element?(view, "#restore-user")
    view |> element("#restore-user") |> render_click()
    view |> element("[data-dialog-cancel]") |> render_click()
    assert Repo.get!(User, target.id).deletion_requested
    view |> element("#restore-user") |> render_click()
    view |> form("#user-action") |> render_submit()
    refute Repo.get!(User, target.id).deletion_requested
    refute Tokens.user(raw)
  end

  test "self actions and forged moderator requests do not open protected forms", %{conn: conn} do
    moderator = role_user("comment_moderator")
    target = user()
    {:ok, view, _} = live(login_conn(conn, moderator), "/admin/users/#{target.id}")

    for action <- ~w(edit delete restore) do
      render_click(view, "prepare", %{"action" => action})
      refute has_element?(view, "#user-confirm")
    end

    render_submit(view, "confirm", %{
      "user" => %{"email" => "forged@example.test"},
      "nick" => target.nick
    })

    assert Repo.get!(User, target.id).email == target.email
    refute Repo.get!(User, target.id).deletion_requested
    {:ok, view, _} = live(login_conn(conn, moderator), "/admin/users/#{moderator.id}")
    refute has_element?(view, "#edit-user")
    refute has_element?(view, "#delete-user")
  end

  test "open edit and deletion forms fail after permission revocation without pubsub", %{
    conn: conn
  } do
    admin = role_user("admin")
    target = user()
    c = login_conn(conn, admin)
    {:ok, editing, _} = live(c, "/admin/users/#{target.id}")
    {:ok, deleting, _} = live(c, "/admin/users/#{target.id}")
    editing |> element("#edit-user") |> render_click()
    deleting |> element("#delete-user") |> render_click()

    ids =
      Repo.all(
        from p in Permission,
          where: p.code in ["users.user.edit", "users.user.delete"],
          select: p.id
      )

    Repo.delete_all(
      from rp in RolePermission, where: rp.role_id == ^admin.role_id and rp.permission_id in ^ids
    )

    editing
    |> form("#user-action", user: %{nick: "forged_nick", email: target.email, locale: "ru"})
    |> render_submit()

    deleting |> form("#user-action", nick: target.nick) |> render_submit()
    assert Repo.get!(User, target.id).nick == target.nick
    refute Repo.get!(User, target.id).deletion_requested
  end

  test "activity route and per-user tab are independently permission-gated", %{conn: conn} do
    assert redirected_to(get(conn, "/admin/users/activity")) == "/login"
    reader = user()

    assert {:error, {:redirect, %{to: "/403"}}} =
             live(login_conn(conn, reader), "/admin/users/activity")

    owner = role_user("owner")
    {:ok, role_id} = Roles.create(owner, %{code: "user_viewer", name: "User viewer"})
    Roles.update_matrix(owner, role_id, ["admin.panel.access", "users.user.view"])
    reader = Repo.update!(Ecto.Changeset.change(reader, role_id: role_id))
    {:ok, view, _} = live(login_conn(conn, reader), "/admin/users/#{owner.id}?tab=activity")
    refute has_element?(view, "#activity-table")
    refute has_element?(view, "a[href='/admin/users/activity']")
    assert render(view) =~ "Недостаточно прав"

    assert {:error, {:redirect, %{to: "/403"}}} =
             live(login_conn(conn, reader), "/admin/users/activity")
  end

  test "activity filters only actor events and never renders before/after values", %{conn: conn} do
    owner = role_user("owner")
    target = user()

    target_event =
      Audit.record(target, "password_change", "User", target.id, :success, %{
        ip: "203.0.113.17",
        old_value: %{secret: "do-not-render-this"}
      })

    owner_event = Audit.record(owner, "password_change", "User", owner.id, :success)
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/activity")
    assert has_element?(view, "#activity-#{owner_event.id}")
    refute render(view) =~ "do-not-render-this"

    render_change(view, "activity_filter", %{
      "filters" => %{"user_id" => to_string(target.id), "action" => ["password_change"]}
    })

    render_async(view, 2000)

    assert has_element?(view, "#activity-#{target_event.id}")
    refute has_element?(view, "#activity-#{owner_event.id}")

    {:ok, card, _} =
      live(login_conn(conn, owner), "/admin/users/#{target.id}?tab=activity&user_id=#{owner.id}")

    assert has_element?(card, "#activity-#{target_event.id}")
    refute has_element?(card, "#activity-#{owner_event.id}")

    render_change(card, "activity_filter", %{
      "filters" => %{"user_id" => to_string(owner.id), "action" => ["password_change"]}
    })

    assert has_element?(card, "#activity-#{target_event.id}")
    refute has_element?(card, "#activity-#{owner_event.id}")
  end

  test "English edit, deletion and activity controls are translated", %{conn: conn} do
    owner = role_user("owner") |> Ecto.Changeset.change(locale: :en) |> Repo.update!()
    target = user()
    c = login_conn(conn, owner)
    {:ok, view, _} = live(c, "/admin/users/#{target.id}")
    assert has_element?(view, "#edit-user", "Edit")
    assert has_element?(view, "#delete-user", "Delete account")
    view |> element("#delete-user") |> render_click()
    assert render(view) =~ "30 days"
    {:ok, activity, _} = live(c, "/admin/users/activity")
    assert has_element?(activity, "h1", "User activity history")
  end

  test "activity-only role can read the report without user-card access", %{conn: conn} do
    owner = role_user("owner")
    reader = user()
    {:ok, role_id} = Roles.create(owner, %{code: "activity_reader", name: "Activity reader"})
    Roles.update_matrix(owner, role_id, ["admin.panel.access", "users.activity.view"])
    reader = Repo.update!(Ecto.Changeset.change(reader, role_id: role_id))
    c = login_conn(conn, reader)
    {:ok, view, _} = live(c, "/admin/users/activity")
    assert has_element?(view, "#activity-table")
    refute has_element?(view, "a[href='/admin/users']")
    assert {:error, {:redirect, %{to: "/403"}}} = live(c, "/admin/users/#{owner.id}")
  end
end
