defmodule AnimeWeb.AdminUserTablesTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.Accounts.{Administration, UserToken}
  alias Anime.Access.{Permission, RolePermission}

  defp tokens(user, count, overrides \\ %{}) do
    now = DateTime.utc_now()

    rows =
      for n <- 1..count do
        Map.merge(
          %{
            user_id: user.id,
            context: if(rem(n, 2) == 0, do: :remember_me, else: :session),
            token: :crypto.strong_rand_bytes(32),
            issue_nonce: :crypto.strong_rand_bytes(32),
            sent_to: "PRIVATE_DESTINATION",
            ip: "192.0.2.1",
            user_agent: "Browser <script>unsafe()</script>",
            last_used_at: now,
            expires_at: DateTime.add(now, 3600),
            inserted_at: now,
            updated_at: now
          },
          overrides
        )
      end

    {^count, rows} = Repo.insert_all(UserToken, rows, returning: [:id])
    rows |> Enum.map(& &1.id) |> Enum.sort(:desc)
  end

  test "session projection is bounded, deterministic, target-scoped and free of secrets" do
    owner = role_user("owner")
    target = user()
    foreign = user()
    ids = tokens(target, 51)
    tokens(foreign, 1)
    tokens(target, 1, %{expires_at: DateTime.add(DateTime.utc_now(), -1)})

    for context <- [:confirm, :reset_password, :change_email, :delete_cancel],
        do: tokens(target, 1, %{context: context})

    assert {:ok, first} = Administration.sessions(owner, target.id, %{"user_id" => foreign.id})
    assert first.count == 51
    assert first.pages == 2
    assert first.page == 1
    assert Enum.map(first.rows, & &1.id) == Enum.take(ids, 50)

    for row <- first.rows do
      assert Enum.sort(Map.keys(row)) ==
               Enum.sort(~w(id context inserted_at last_used_at expires_at ip user_agent)a)
    end

    assert {:ok, last} = Administration.sessions(owner, target.id, %{"page" => "999999"})
    assert last.page == 2
    assert Enum.map(last.rows, & &1.id) == [List.last(ids)]
    assert {:ok, ^last} = Administration.sessions(owner, target.id, %{"page" => "2"})

    for invalid <- [nil, "0", "-2", "bad", ["2"], %{"page" => "2"}] do
      assert {:ok, %{page: 1}} = Administration.sessions(owner, target.id, %{"page" => invalid})
    end

    assert {:error, :not_found} = Administration.sessions(owner, "bad")
    assert {:error, :forbidden} = Administration.sessions(target, target.id)
    assert {:ok, detail} = Administration.get(owner, target.id)
    assert detail.session_count == 51
    refute Map.has_key?(detail, :sessions)
  end

  test "session pages keep the card target and tab while other tabs reset the page", %{conn: conn} do
    owner = role_user("owner")
    target = user()
    foreign = user()
    ids = tokens(target, 51)
    [foreign_id] = tokens(foreign, 1)

    {:ok, view, _} =
      live(
        login_conn(conn, owner),
        "/admin/users/#{target.id}?tab=sessions&user_id=#{foreign.id}"
      )

    assert has_element?(view, "#session-pages", "1 / 2")
    assert has_element?(view, "#session-#{hd(ids)}")
    refute has_element?(view, "#session-#{List.last(ids)}")
    refute has_element?(view, "#session-#{foreign_id}")
    assert has_element?(view, "#admin-sessions thead th:first-child", "ID")
    assert has_element?(view, "[role=region][tabindex='0'] #admin-sessions")
    assert has_element?(view, "#revoke-session-#{hd(ids)}[title][aria-label]")
    assert render(view) =~ "&lt;script&gt;"
    refute render(view) =~ "<script>unsafe()"
    refute render(view) =~ "PRIVATE_DESTINATION"
    refute has_element?(view, ".admin-skeleton")

    view |> element("#session-pages a", "Далее") |> render_click()
    assert_patch(view, "/admin/users/#{target.id}?page=2&tab=sessions")
    assert has_element?(view, "#session-#{List.last(ids)}")
    refute has_element?(view, "#session-#{hd(ids)}")
    view |> form("#admin-locale", locale: "en") |> render_change()
    assert has_element?(view, "#session-pages", "2 / 2")
    assert has_element?(view, "[aria-label=Sessions] #admin-sessions")
    view |> element(".profile-nav a", "Overview") |> render_click()
    assert_patch(view, "/admin/users/#{target.id}?tab=overview")
    refute has_element?(view, "#admin-sessions")
    view |> element(".profile-nav a", "Sessions") |> render_click()
    assert_patch(view, "/admin/users/#{target.id}?tab=sessions")
    assert has_element?(view, "#session-pages", "1 / 2")
  end

  test "revoking the last-page session clamps the page and preserves the other fifty", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()
    ids = tokens(target, 51)
    last = List.last(ids)

    {:ok, view, _} =
      live(login_conn(conn, owner), "/admin/users/#{target.id}?tab=sessions&page=2")

    render_click(view, "prepare", %{"action" => "revoke", "session_id" => to_string(hd(ids))})
    refute has_element?(view, "#user-confirm")
    view |> element("#revoke-session-#{last}") |> render_click()
    assert Repo.get(UserToken, last)
    view |> element("button[data-dialog-cancel]") |> render_click()
    assert Repo.get(UserToken, last)
    view |> element("#revoke-session-#{last}") |> render_click()
    view |> form("#user-action") |> render_submit()
    refute Repo.get(UserToken, last)
    assert has_element?(view, "#session-pages", "1 / 1")
    assert has_element?(view, "#session-#{hd(ids)}")
    assert {:ok, %{count: 50}} = Administration.sessions(owner, target.id)
  end

  test "header revokes all pages with confirmation, never mail tokens or another user", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()
    foreign = user()
    tokens(target, 51)
    [foreign_id] = tokens(foreign, 1)
    confirm = Repo.get_by!(UserToken, user_id: target.id, context: :confirm)
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/#{target.id}")
    assert has_element?(view, ".user-card-heading .user-status.active", "Активен")
    assert has_element?(view, ".user-card-heading .role-badge", "Пользователь")
    assert has_element?(view, "#public-user-profile[href='/u/#{target.nick}']")
    view |> element("#revoke-all") |> render_click()
    assert {:ok, %{count: 51}} = Administration.sessions(owner, target.id)
    view |> form("#user-action") |> render_submit()
    assert {:ok, %{count: 0}} = Administration.sessions(owner, target.id)
    assert Repo.get(UserToken, foreign_id)
    assert Repo.get(UserToken, confirm.id)
    refute has_element?(view, "#revoke-all")
    render_patch(view, "/admin/users/#{target.id}?tab=sessions")
    assert render(view) =~ "Активных сессий нет"
    assert has_element?(view, "#admin-sessions thead")
    assert has_element?(view, "#session-pages", "1 / 1")
  end

  test "self and read-only operators never receive revocation controls", %{conn: conn} do
    owner = role_user("owner")
    {:ok, self_view, _} = live(login_conn(conn, owner), "/admin/users/#{owner.id}?tab=sessions")
    refute has_element?(self_view, "#revoke-all")
    refute has_element?(self_view, "#admin-sessions button")
    render_click(self_view, "prepare", %{"action" => "revoke"})
    refute has_element?(self_view, "#user-confirm")
    moderator = role_user("comment_moderator")
    target = user()
    [id] = tokens(target, 1)
    {:ok, view, _} = live(login_conn(conn, moderator), "/admin/users/#{target.id}?tab=sessions")
    assert has_element?(view, "#session-#{id}")
    refute has_element?(view, "#revoke-all")
    refute has_element?(view, "#admin-sessions button")
    render_click(view, "prepare", %{"action" => "revoke", "session_id" => to_string(id)})
    refute has_element?(view, "#user-confirm")
    assert Repo.get(UserToken, id)
  end

  test "revoked view permission cannot fetch a new page even without PubSub", %{conn: conn} do
    admin = role_user("admin")
    target = user()
    ids = tokens(target, 51)
    {:ok, view, _} = live(login_conn(conn, admin), "/admin/users/#{target.id}?tab=sessions")
    permission = Repo.get_by!(Permission, code: "users.user.view")

    Repo.delete_all(
      from rp in RolePermission,
        where: rp.role_id == ^admin.role_id and rp.permission_id == ^permission.id
    )

    assert {:error, :forbidden} = Administration.sessions(admin, target.id, %{"page" => "2"})
    render_patch(view, "/admin/users/#{target.id}?tab=sessions&page=2")
    refute has_element?(view, "#session-#{List.last(ids)}")
    assert render(view) =~ "Недостаточно прав"
  end

  test "both user lists keep status before actions, with dedicated confirmation and deletion marks",
       %{conn: conn} do
    owner = role_user("owner")

    target =
      user()
      |> Ecto.Changeset.change(
        email_confirmed_at: DateTime.utc_now(),
        deletion_requested: true,
        deletion_requested_at: DateTime.utc_now()
      )
      |> Repo.update!()

    blocked =
      user() |> Ecto.Changeset.change(status: :blocked, block_reason: "test") |> Repo.update!()

    conn = login_conn(conn, owner)
    {:ok, view, _} = live(conn, "/admin/users?q=#{target.nick}")
    assert has_element?(view, "#users-table th:nth-last-child(2)[data-sort=status]")
    assert has_element?(view, "#user-#{target.id} td:nth-last-child(2) .user-status.active")
    assert has_element?(view, "#user-#{target.id} td:nth-last-child(2) .user-status.deletion")
    assert has_element?(view, "#user-#{target.id} .email-confirmed", "Подтверждён")
    {:ok, view, _} = live(conn, "/admin/users/blocked")
    assert has_element?(view, "#users-table th:nth-last-child(2)", "Статус")
    assert has_element?(view, "#user-#{blocked.id} td:nth-last-child(2) .user-status.blocked")
  end

  test "block history shows record IDs in an accessible bounded region without skeletons", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user()
    {:ok, _} = Administration.ban(owner, target.id, %{"reason" => "spam", "days" => "1"})
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/#{target.id}?tab=blocks")
    assert has_element?(view, "[role=region][tabindex='0'] #block-history")
    assert has_element?(view, "#block-history th:first-child", "ID")
    assert has_element?(view, "#block-history tbody tr td:first-child")
    refute has_element?(view, ".admin-skeleton")
  end
end
