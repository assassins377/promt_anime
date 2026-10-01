defmodule AnimeWeb.AdminUsersTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.Accounts.{User, Administration, Tokens}
  alias Anime.Access.{Role, Permission, RolePermission}

  for path <- ["/admin/users", "/admin/users/blocked", "/admin/users/1"] do
    test "#{path} rejects guests and ordinary users", %{conn: conn} do
      assert redirected_to(get(conn, unquote(path))) == "/login"
      assert {:error, {:redirect, %{to: "/403"}}} = live(login_conn(conn, user()), unquote(path))
    end
  end

  test "list search and sort retain URL state; blocked view constrains forged status", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()
    c = login_conn(conn, owner)
    {:ok, view, _} = live(c, "/admin/users")
    assert has_element?(view, "#user-#{target.id}", target.email)
    render_change(view, "filter", %{"filters" => %{"q" => target.nick}})
    assert_patch(view, "/admin/users?q=#{target.nick}")
    render_async(view, 2000)
    assert has_element?(view, "#user-#{target.id}")
    refute has_element?(view, "#user-#{owner.id}")
    {:ok, blocked, _} = live(c, "/admin/users/blocked?status[]=active")
    refute has_element?(blocked, "#user-#{target.id}")
    Administration.ban(owner, target.id, %{"reason" => "spam", "days" => "1"})
    render(blocked)
    render_async(blocked, 2000)
    render(view)
    render_async(view, 2000)
    assert has_element?(blocked, "#user-#{target.id}")
  end

  test "card performs confirmed ban, unban, role change and session revocation", %{conn: conn} do
    owner = role_user("owner")
    target = user()
    {:ok, {raw, _}} = Anime.Accounts.create_session(target, false, meta())
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/#{target.id}")
    view |> element("#ban-user") |> render_click()
    assert Repo.get!(User, target.id).status == :active
    view |> element("button[data-dialog-cancel]") |> render_click()
    refute has_element?(view, "#user-confirm")
    view |> element("#ban-user") |> render_click()
    view |> form("#user-action", %{reason: "spam", days: "1", comment: ""}) |> render_submit()
    assert Repo.get!(User, target.id).status == :blocked
    refute Tokens.user(raw)
    view |> element("#unban-user") |> render_click()
    view |> form("#user-action") |> render_submit()
    assert Repo.get!(User, target.id).status == :active
    view |> element("#change-role") |> render_click()
    editor = Repo.get_by!(Role, code: "content_editor")
    view |> form("#user-action", %{role_id: editor.id}) |> render_submit()
    assert Repo.get!(User, target.id).role_id == editor.id
    {:ok, {raw, remember}} = Anime.Accounts.create_session(target, true, meta())
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/#{target.id}?tab=sessions")
    assert has_element?(view, "#admin-sessions", "Запомнить меня")
    view |> element("#revoke-all") |> render_click()
    assert Tokens.user(raw)
    view |> form("#user-action") |> render_submit()
    refute Tokens.user(raw)
    refute Tokens.find(remember, [:remember_me])
  end

  test "forged saves without confirmation and self controls do not mutate", %{conn: conn} do
    owner = role_user("owner")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/#{owner.id}?tab=sessions")
    refute has_element?(view, "#change-role")
    refute has_element?(view, "#ban-user")
    refute has_element?(view, "#revoke-all")
    render_click(view, "prepare", %{"action" => "ban"})
    refute has_element?(view, "#user-confirm")
    render_submit(view, "confirm", %{"reason" => "spam", "days" => "1"})
    assert Repo.get!(User, owner.id).status == :active
  end

  test "moderator cannot forge role/session actions or block a protected user", %{conn: conn} do
    moderator = role_user("comment_moderator")
    target = role_user("content_editor")
    {:ok, view, _} = live(login_conn(conn, moderator), "/admin/users/#{target.id}")
    refute has_element?(view, "#change-role")
    render_click(view, "prepare", %{"action" => "role"})
    refute has_element?(view, "#user-confirm")
    render_click(view, "prepare", %{"action" => "revoke"})
    refute has_element?(view, "#user-confirm")
    view |> element("#ban-user") |> render_click()
    view |> form("#user-action", %{reason: "spam", days: "1"}) |> render_submit()
    assert Repo.get!(User, target.id).status == :active

    assert render(view) =~
             "Недостаточно прав для этой цели или роли. Нельзя управлять более привилегированным пользователем или назначать недоступную роль."
  end

  test "stale open form cannot save after action permission is removed without pubsub", %{
    conn: conn
  } do
    admin = role_user("admin")
    target = user()
    {:ok, view, _} = live(login_conn(conn, admin), "/admin/users/#{target.id}")
    view |> element("#ban-user") |> render_click()
    p = Repo.get_by!(Permission, code: "users.user.ban")

    Repo.delete_all(
      from rp in RolePermission, where: rp.role_id == ^admin.role_id and rp.permission_id == ^p.id
    )

    view |> form("#user-action", %{reason: "spam", days: "1"}) |> render_submit()
    assert Repo.get!(User, target.id).status == :active

    assert render(view) =~
             "Недостаточно прав для этого действия. Проверьте доступ или обратитесь к владельцу сайта."

    assert Repo.exists?(
             from a in Anime.Audit, where: a.action == "users.user.ban" and a.result == :denied
           )
  end

  test "access notification closes admin page and invalid IDs do not crash", %{conn: conn} do
    owner = role_user("owner")
    c = login_conn(conn, owner)
    assert {:error, {:redirect, %{to: "/admin/users"}}} = live(c, "/admin/users/bogus")
    {:ok, view, _} = live(c, "/admin/users")
    Phoenix.PubSub.broadcast(Anime.PubSub, "user:#{owner.id}:access", :access_changed)
    assert_redirect(view, "/")
  end

  test "English account administration uses translated controls", %{conn: conn} do
    owner = role_user("owner")
    owner = Repo.update!(Ecto.Changeset.change(owner, locale: :en))
    target = user()
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/#{target.id}")
    assert has_element?(view, "#change-role", "Change role")
    assert has_element?(view, "#ban-user", "Block")
    view |> element("#ban-user") |> render_click()
    assert has_element?(view, "#user-confirm", "Send email notification")
    assert has_element?(view, "#user-confirm", "Other")
  end
end
