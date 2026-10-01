defmodule AnimeWeb.AdminDatesTest do
  use AnimeWeb.ConnCase
  alias Anime.Accounts.{User, UserToken}
  alias Anime.{Accounts, Audit}

  @date ~U[2026-09-28 14:30:12.345678Z]
  @iso "2026-09-28T14:30:12.345678Z"

  test "user list changes dates in place but keeps query, selection, IDs and database timestamps",
       %{conn: conn} do
    owner = role_user("owner")
    target = user() |> Ecto.Changeset.change(inserted_at: @date) |> Repo.update!()

    {:ok, view, _} =
      live(login_conn(conn, owner), "/admin/users?q=#{target.nick}&sort=nick&dir=asc")

    selector = "#user-#{target.id} time[datetime='#{@iso}']"
    assert has_element?(view, selector, "28.09.2026 14:30 UTC")
    view |> element("#select-user-#{target.id}") |> render_click()
    view |> form("#admin-locale", locale: "en") |> render_change()
    assert has_element?(view, selector, "Sep 28, 2026, 14:30 UTC")
    assert has_element?(view, selector <> "[title='#{@iso} (UTC)']")
    assert has_element?(view, "#select-user-#{target.id}[checked]")
    assert has_element?(view, ".filter-chips a[data-filter=q]", target.nick)
    assert has_element?(view, "th[data-sort=nick][aria-sort=ascending]")
    assert Repo.get!(User, target.id).inserted_at == @date
    refute has_element?(view, "time[datetime='']")
  end

  test "user overview and session dates follow locale without modifying session values", %{
    conn: conn
  } do
    owner = role_user("owner")
    target = user() |> Ecto.Changeset.change(inserted_at: @date) |> Repo.update!()
    {:ok, _} = Accounts.create_session(target, false, meta())
    token = Repo.get_by!(UserToken, user_id: target.id, context: :session)
    Repo.get!(UserToken, token.id) |> Ecto.Changeset.change(last_used_at: @date) |> Repo.update!()
    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/#{target.id}")
    view |> form("#admin-locale", locale: "en") |> render_change()
    assert has_element?(view, ".user-details time[datetime='#{@iso}']", "Sep 28, 2026, 14:30 UTC")
    render_patch(view, "/admin/users/#{target.id}?tab=sessions")
    render_async(view, 2000)

    assert has_element?(
             view,
             "#admin-sessions time[datetime='#{@iso}']",
             "Sep 28, 2026, 14:30 UTC"
           )

    view |> form("#admin-locale", locale: "ru") |> render_change()
    assert has_element?(view, "#admin-sessions time[datetime='#{@iso}']", "28.09.2026 14:30 UTC")
    assert Repo.get!(UserToken, token.id).last_used_at == @date
  end

  test "blocked registry and history normalize ISO deadlines and keep permanent labels", %{
    conn: conn
  } do
    owner = role_user("owner")

    target =
      user() |> Ecto.Changeset.change(status: :blocked, blocked_at: @date) |> Repo.update!()

    audit =
      Audit.record(owner, "users.user.ban", "User", target.id, :success, %{
        new_value: %{blocked_until: "2026-09-28T23:30:12.345678+09:00", block_reason: "spam"}
      })

    {:ok, view, _} = live(login_conn(conn, owner), "/admin/users/blocked?q=#{target.nick}")
    assert has_element?(view, "#user-#{target.id}", "Бессрочно")
    view |> form("#admin-locale", locale: "en") |> render_change()

    assert has_element?(
             view,
             "#user-#{target.id} time[datetime='#{@iso}']",
             "Sep 28, 2026, 14:30 UTC"
           )

    {:ok, card, _} =
      live(login_conn(conn, Repo.get!(User, owner.id)), "/admin/users/#{target.id}?tab=blocks")

    assert has_element?(
             card,
             "#block-event-#{audit.id} time[datetime='#{@iso}']",
             "Sep 28, 2026, 14:30 UTC"
           )

    card |> form("#admin-locale", locale: "ru") |> render_change()

    assert has_element?(
             card,
             "#block-event-#{audit.id} time[datetime='#{@iso}']",
             "28.09.2026 14:30 UTC"
           )
  end

  test "activity panel uses seconds in both standalone and fixed-user views", %{conn: conn} do
    owner = role_user("owner")
    audit = Audit.record(owner, "preferences_change", "User", owner.id, :success)
    audit |> Ecto.Changeset.change(occurred_at: @date) |> Repo.update!()

    for path <- [
          "/admin/users/activity?user_id=#{owner.id}",
          "/admin/users/#{owner.id}?tab=activity"
        ] do
      owner = Repo.get!(User, owner.id)
      {:ok, view, _} = live(login_conn(conn, owner), path)
      view |> form("#admin-locale", locale: "en") |> render_change()

      assert has_element?(
               view,
               "#activity-#{audit.id} time[datetime='#{@iso}']",
               "Sep 28, 2026, 14:30:12 UTC"
             )

      assert has_element?(view, "#activity-#{audit.id}", "preferences_change")
      view |> form("#admin-locale", locale: "ru") |> render_change()

      assert has_element?(
               view,
               "#activity-#{audit.id} time[datetime='#{@iso}']",
               "28.09.2026 14:30:12 UTC"
             )
    end
  end
end
