defmodule AnimeWeb.AdminSortingTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.Accounts.{Administration, Activity, User}
  alias Anime.Access.{Roles, Role}

  defp batch(prefix, count) do
    base = user() |> Map.from_struct() |> Map.take(User.__schema__(:fields)) |> Map.delete(:id)

    rows =
      for n <- 1..count do
        Map.merge(base, %{
          nick: prefix <> Integer.to_string(n),
          email: "#{prefix}#{n}@example.test",
          inserted_at: ~U[2026-01-01 00:00:00.000000Z]
        })
      end

    {^count, rows} = Repo.insert_all(User, rows, returning: [:id])
    Enum.map(rows, & &1.id)
  end

  test "registration ties paginate deterministically in both SQL directions" do
    owner = role_user("owner")
    ids = batch("sortbatch", 56)

    for dir <- ["asc", "desc"] do
      params = %{"q" => "sortbatch", "sort" => "inserted_at", "dir" => dir}
      {:ok, first} = Administration.list(owner, params)
      {:ok, second} = Administration.list(owner, Map.put(params, "page", "2"))
      actual = Enum.map(first.rows ++ second.rows, & &1.id)
      expected = Enum.sort(ids, if(dir == "asc", do: :asc, else: :desc))
      assert actual == expected
      assert length(Enum.uniq(actual)) == 56
      assert {first.count, first.page, second.page} == {56, 1, 2}
      {:ok, repeated} = Administration.list(owner, params)
      assert repeated.rows == first.rows
    end
  end

  test "block ordering handles ties and missing dates without widening the registry" do
    owner = role_user("owner")
    [a, b, empty, active] = batch("sortblock", 4)

    Repo.update_all(from(u in User, where: u.id in ^[a, b]),
      set: [status: :blocked, blocked_at: ~U[2026-01-02 00:00:00.000000Z]]
    )

    Repo.update_all(from(u in User, where: u.id == ^empty),
      set: [status: :blocked, blocked_at: nil]
    )

    {:ok, descending} =
      Administration.blocked(owner, %{"q" => "sortblock", "status" => ["active"]})

    assert Enum.map(descending.rows, & &1.id) == [b, a, empty]

    {:ok, ascending} =
      Administration.blocked(owner, %{"q" => "sortblock", "sort" => "blocked_at", "dir" => "asc"})

    assert Enum.map(ascending.rows, & &1.id) == [empty, a, b]
    refute Enum.any?(ascending.rows, &(&1.id == active))
  end

  test "role ordering breaks equal role positions by role ID then user ID" do
    owner = role_user("owner")
    {:ok, r1} = Roles.create(owner, %{code: "sortfirst", name: "First"})
    {:ok, r2} = Roles.create(owner, %{code: "sortsecond", name: "Second"})
    Repo.update_all(from(r in Role, where: r.id in ^[r1, r2]), set: [position: 500])
    [u1, u2, u3] = batch("sortrole", 3)
    Repo.update_all(from(u in User, where: u.id in ^[u1, u3]), set: [role_id: r2])
    Repo.update_all(from(u in User, where: u.id == ^u2), set: [role_id: r1])
    {:ok, up} = Administration.list(owner, %{"q" => "sortrole", "sort" => "role", "dir" => "asc"})

    {:ok, down} =
      Administration.list(owner, %{"q" => "sortrole", "sort" => "role", "dir" => "desc"})

    assert Enum.map(up.rows, & &1.id) == [u2, u1, u3]
    assert Enum.map(down.rows, & &1.id) == [u3, u1, u2]
  end

  test "headers show one active arrow, switch desc then asc, reset page and selection", %{
    conn: conn
  } do
    owner = role_user("owner")
    ids = batch("sortui", 53)
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users?q=sortui&page=2")

    assert has_element?(
             view,
             "th[data-sort=inserted_at][aria-sort=descending] .sort-arrow.active",
             "↓"
           )

    assert has_element?(view, "th[data-sort=nick][aria-sort=none] .sort-arrow", "↕")
    refute has_element?(view, "th:not([data-sort=inserted_at]) .sort-arrow.active")
    view |> element("#select-user-#{hd(ids)}") |> render_click()
    view |> element("th[data-sort=nick] a") |> render_click()
    assert_patch(view, "/admin/users?dir=desc&q=sortui&sort=nick")
    render_async(view, 2000)
    assert has_element?(view, "th[data-sort=nick][aria-sort=descending]")
    refute has_element?(view, ".bulk-actions")
    refute has_element?(view, "input[id^=select-user-][checked]")
    view |> element("th[data-sort=nick] a") |> render_click()
    assert_patch(view, "/admin/users?dir=asc&q=sortui&sort=nick")
    render_async(view, 2000)
    assert has_element?(view, "th[data-sort=nick][aria-sort=ascending]", "↑")
    render_patch(view, "/admin/users?q=sortui&page=2")
    render_async(view, 2000)
    assert has_element?(view, "th[data-sort=inserted_at][aria-sort=descending]")
    assert has_element?(view, "#user-#{hd(ids)}")
  end

  test "sort choices survive filtering, locale switching and a fresh mount", %{conn: conn} do
    owner = role_user("owner")
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users?sort=nick&dir=asc")
    render_change(view, "filter", %{"filters" => %{"status" => ["active"]}})
    assert_patch(view, "/admin/users?dir=asc&sort=nick&status[]=active")
    render_async(view, 2000)
    view |> form("#admin-locale", locale: "en") |> render_change()

    assert has_element?(
             view,
             "th[data-sort=nick][aria-sort=ascending] a[aria-label='Nickname: Sort descending']"
           )

    fresh = Repo.get!(User, owner.id)

    {:ok, again, _} =
      live(login_conn(conn, fresh), "/admin/users?dir=asc&sort=nick&status[]=active")

    assert has_element?(again, "th[data-sort=nick][aria-sort=ascending]")
    assert has_element?(again, "input[name='filters[status][]'][value=active][checked]")
  end

  test "each screen discards unsupported sort columns instead of showing a false active header",
       %{conn: conn} do
    owner = role_user("owner")

    for {path, invalid, fallback, table} <- [
          {"/admin/users", "blocked_at", "inserted_at", "users-table"},
          {"/admin/users/blocked", "role", "blocked_at", "users-table"},
          {"/admin/roles", "nick", "position", "roles-table"},
          {"/admin/roles/permissions", "position", "code", "permissions-table"},
          {"/admin/users/activity", "status", "occurred_at", "activity-table"}
        ] do
      {:ok, view, _} = live(login_conn(conn, owner), "#{path}?sort=#{invalid}&dir=asc")
      assert has_element?(view, "##{table} th[data-sort=#{fallback}] .sort-arrow.active")
      refute has_element?(view, "##{table} th[data-sort=#{invalid}]")
    end

    {:ok, listing} =
      Administration.list(owner, %{"sort" => "id; DROP TABLE users", "dir" => "drop"})

    assert listing.params.sort == "inserted_at"
    assert listing.params.dir == "desc"
    assert {:error, :forbidden} = Administration.list(user(), %{"sort" => "id"})
  end

  test "role and permission SQL sorting stays paginated and exposes IDs, not fake name sorting",
       %{conn: conn} do
    owner = role_user("owner")
    {:ok, up} = Roles.list_page(owner, %{"sort" => "code", "dir" => "asc"})
    {:ok, down} = Roles.list_page(owner, %{"sort" => "code", "dir" => "desc"})
    assert Enum.map(up.rows, & &1.role.id) == Enum.reverse(Enum.map(down.rows, & &1.role.id))
    {:ok, first} = Roles.permissions_page(owner, %{"sort" => "id", "dir" => "desc"})

    {:ok, second} =
      Roles.permissions_page(owner, %{"sort" => "id", "dir" => "desc", "page" => "2"})

    ids = Enum.map(first.rows ++ second.rows, & &1.id)
    assert ids == Enum.sort(ids, :desc)
    assert length(ids) == 99
    assert length(Enum.uniq(ids)) == 99
    {:ok, roles, _} = live(login_conn(conn, owner), "/admin/roles?sort=code&dir=desc")
    assert has_element?(roles, "#roles-table th[data-sort=id]", "ID")
    assert has_element?(roles, "#roles-table th[data-sort=code][aria-sort=descending]")
    assert has_element?(roles, "#role-#{owner.role_id} td:first-child", to_string(owner.role_id))
    refute has_element?(roles, "#roles-table th[data-sort=name]")
    render_change(roles, "filter", %{"q" => "owner"})
    assert_patch(roles, "/admin/roles?dir=desc&q=owner&sort=code")
    render_async(roles, 2000)

    {:ok, perms, _} =
      live(login_conn(conn, owner), "/admin/roles/permissions?group=roles&sort=id&dir=desc")

    assert has_element?(perms, "#permissions-table th[data-sort=id][aria-sort=descending]")
    refute has_element?(perms, "#permissions-table th[data-sort=group]")
    render_change(perms, "filter", %{"q" => "role", "group" => "roles"})
    assert_patch(perms, "/admin/roles/permissions?dir=desc&group=roles&q=role&sort=id")
    render_async(perms, 2000)
  end

  test "activity ties are stable and sorting the embedded history cannot change its user", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()
    other = user()
    a = Anime.Audit.record(target, "login", "User", target.id, :success)
    b = Anime.Audit.record(target, "logout", "User", target.id, :success)

    Repo.update_all(from(a in Anime.Audit, where: a.id in ^[a.id, b.id]),
      set: [occurred_at: ~U[2026-01-01 00:00:00.000000Z]]
    )

    params = %{"user_id" => to_string(target.id), "action" => ["login", "logout"], "dir" => "asc"}
    {:ok, ascending} = Activity.list(owner, params)
    assert Enum.map(ascending.rows, & &1.id) == [a.id, b.id]
    {:ok, descending} = Activity.list(owner, Map.put(params, "dir", "desc"))
    assert Enum.map(descending.rows, & &1.id) == [b.id, a.id]

    {:ok, view, _} =
      live(login_conn(conn, owner), "/admin/users/#{target.id}?tab=activity&user_id=#{other.id}")

    view |> element("#activity-table th[data-sort=occurred_at] a") |> render_click()

    assert_patch(
      view,
      "/admin/users/#{target.id}?dir=asc&sort=occurred_at&tab=activity&user_id=#{target.id}"
    )

    render_change(view, "activity_filter", %{
      "filters" => %{"action" => ["login"], "user_id" => to_string(other.id)}
    })

    assert_patch(
      view,
      "/admin/users/#{target.id}?action[]=login&dir=asc&sort=occurred_at&tab=activity"
    )

    assert has_element?(view, "#activity-#{a.id}")
    refute has_element?(view, "#activity-#{b.id}")
    assert has_element?(view, "#activity-table th[data-sort=occurred_at][aria-sort=ascending]")
  end

  test "new indexes are valid and support ordered access paths in both directions" do
    # This tests eligibility, not a performance claim on a production-sized database.
    Ecto.Adapters.SQL.query!(Repo, "SET LOCAL enable_seqscan = off", [])
    Ecto.Adapters.SQL.query!(Repo, "SET LOCAL enable_sort = off", [])
    Ecto.Adapters.SQL.query!(Repo, "SET LOCAL enable_incremental_sort = off", [])

    for {name, statement} <- [
          {"users_registration_order_idx",
           "SELECT id FROM users ORDER BY inserted_at DESC, id DESC LIMIT 50"},
          {"users_registration_order_idx",
           "SELECT id FROM users ORDER BY inserted_at ASC, id ASC LIMIT 50"},
          {"users_block_order_idx",
           "SELECT id FROM users WHERE status = 'blocked' ORDER BY blocked_at DESC NULLS LAST, id DESC LIMIT 50"},
          {"users_block_order_idx",
           "SELECT id FROM users WHERE status = 'blocked' ORDER BY blocked_at ASC NULLS FIRST, id ASC LIMIT 50"},
          {"users_status_order_idx", "SELECT id FROM users ORDER BY status, id LIMIT 50"},
          {"roles_position_order_idx", "SELECT id FROM roles ORDER BY position, id LIMIT 50"},
          {"users_role_order_idx", "SELECT id FROM users ORDER BY role_id, id LIMIT 50"}
        ] do
      %{rows: [[true, true]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT indisvalid, indisready FROM pg_index WHERE indexrelid = $1::text::regclass",
          [name]
        )

      %{rows: [[plan]]} =
        Ecto.Adapters.SQL.query!(Repo, "EXPLAIN (FORMAT JSON) " <> statement, [])

      assert Jason.encode!(plan) =~ name
    end
  end
end
