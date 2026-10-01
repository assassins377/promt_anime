defmodule AnimeWeb.AdminListAsyncTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  alias Anime.Access.{Permission, RolePermission}

  defp open(conn) do
    actor = role_user("admin")
    {:ok, {token, _}} = Anime.Accounts.create_session(actor, false, meta())

    {:ok, view, _} =
      live_isolated(conn, AnimeWeb.AdminListHarness,
        session: %{"token" => token, "tester" => self()}
      )

    {view, actor, token}
  end

  defp fetch(view, q) do
    render_change(view, "filter", %{"q" => q})
    assert_receive {:fetch, ^q, pid}, 2000
    pid
  end

  test "latest filter cancels the old task and never renders the old result", %{conn: conn} do
    {view, _, _} = open(conn)
    first = fetch(view, "first")
    monitor = Process.monitor(first)
    assert has_element?(view, "#region[aria-busy=true]")
    assert has_element?(view, ".admin-skeleton tr")
    refute has_element?(view, "#rows")
    render_click(view, "write")
    assert has_element?(view, "#writes", "0")
    second = fetch(view, "second")
    assert_receive {:DOWN, ^monitor, :process, ^first, _}, 2000
    send(first, {:result, {:ok, %{rows: ["stale"]}}})
    send(view.pid, {:admin_list_timeout, 1})
    assert has_element?(view, "#region[aria-busy=true]")
    send(second, {:result, {:ok, %{rows: ["latest"]}}})
    render_async(view, 2000)
    assert has_element?(view, "#rows", "latest")
    refute render(view) =~ "stale"
    refute has_element?(view, ".admin-list-error")
    refute has_element?(view, "[role=alert]")
    render_click(view, "write")
    assert has_element?(view, "#writes", "1")
  end

  test "timeout cancels task, hides stale rows and allows a fresh retry", %{conn: conn} do
    {view, _, _} = open(conn)
    first = fetch(view, "retry-me")
    monitor = Process.monitor(first)
    send(view.pid, {:admin_list_timeout, 1})
    assert has_element?(view, ".admin-list-error")
    assert_receive {:DOWN, ^monitor, :process, ^first, _}, 2000
    refute has_element?(view, "#rows")
    refute has_element?(view, ".admin-skeleton")
    render_click(view, "write")
    assert has_element?(view, "#writes", "0")
    view |> element("button[phx-click=retry_list]") |> render_click()
    assert_receive {:fetch, "retry-me", second}, 2000
    send(view.pid, {:admin_list_timeout, 1})
    send(second, {:result, {:ok, %{rows: ["retried"]}}})
    render_async(view, 2000)
    assert has_element?(view, "#rows", "retried")
    refute has_element?(view, ".admin-list-error")
  end

  test "revoked permission while querying cannot publish the fetched records", %{conn: conn} do
    {view, actor, _} = open(conn)
    task = fetch(view, "secret-result")
    permission = Repo.get_by!(Permission, code: "users.user.view")

    Repo.delete_all(
      from rp in RolePermission,
        where: rp.role_id == ^actor.role_id and rp.permission_id == ^permission.id
    )

    send(task, {:result, {:ok, %{rows: ["should-not-render"]}}})
    render_async(view, 2000)
    refute render(view) =~ "should-not-render"
    assert has_element?(view, "[role=alert]", "Недостаточно прав")
    assert has_element?(view, ".admin-list-error")
    render_click(view, "retry_list")
    refute_receive {:fetch, _, _}, 50
  end

  test "revoking the session while querying also prevents applying the result", %{conn: conn} do
    {view, actor, _} = open(conn)
    task = fetch(view, "session")

    Repo.delete_all(
      from t in Anime.Accounts.UserToken, where: t.user_id == ^actor.id and t.context == :session
    )

    send(task, {:result, {:ok, %{rows: ["should-not-render"]}}})
    render_async(view, 2000)
    refute has_element?(view, "#rows")
    assert has_element?(view, "[role=alert]", "Недостаточно прав")
  end

  @tag capture_log: true
  test "failure and task exit show a safe retry state instead of a fake empty result", %{
    conn: conn
  } do
    {view, _, _} = open(conn)
    first = fetch(view, "error")
    send(first, {:result, {:error, %{private: "DO_NOT_RENDER"}}})
    render_async(view, 2000)
    refute render(view) =~ "DO_NOT_RENDER"
    assert has_element?(view, ".admin-list-error")
    refute has_element?(view, "#rows")
    second = fetch(view, "crash")
    send(second, :crash)
    render_async(view, 2000)
    assert has_element?(view, ".admin-list-error")
    refute has_element?(view, ".admin-skeleton")
  end

  test "skeleton rows follow the prior page length, capped at ten and decorative" do
    for {count, expected} <- [{0, 0}, {1, 1}, {7, 7}, {50, 10}] do
      html = render_component(&AnimeWeb.AdminComponents.admin_skeleton/1, rows: count, columns: 9)
      assert length(Regex.scan(~r/<tr>/, html)) == expected
      assert html =~ ~s(aria-hidden="true")
      refute html =~ "button"
    end
  end

  test "loading and retry feedback are translated in English" do
    Gettext.with_locale(AnimeWeb.Gettext, "en", fn ->
      loading =
        render_component(&AnimeWeb.AdminComponents.admin_list_feedback/1,
          loading: true,
          failed: false
        )

      failed =
        render_component(&AnimeWeb.AdminComponents.admin_list_feedback/1,
          loading: false,
          failed: true
        )

      assert loading =~ "Loading"
      assert failed =~ "retry_list"
      refute loading =~ ~r/[А-Яа-яЁё]/u
      refute failed =~ ~r/[А-Яа-яЁё]/u
    end)
  end

  test "cards and permission matrix never become asynchronous skeleton lists", %{conn: conn} do
    owner = role_user("owner")
    {:ok, card, _} = live(login_conn(conn, owner), "/admin/users/#{owner.id}?tab=activity")
    render_change(card, "activity_filter", %{"filters" => %{"ip" => "192.0.2.255"}})
    refute has_element?(card, ".admin-skeleton")
    {:ok, matrix, _} = live(login_conn(conn, owner), "/admin/roles/matrix")
    render_change(matrix, "filter", %{"q" => "roles"})
    refute has_element?(matrix, ".admin-skeleton")
  end
end
