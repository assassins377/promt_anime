defmodule AnimeWeb.AsyncLogContextTest do
  use AnimeWeb.ConnCase
  import ExUnit.CaptureLog
  alias Anime.LogContext
  @moduletag :capture_log

  def query_context(_, _, _, observer),
    do: send(observer, {:query_context, self(), LogContext.current()})

  defp collect(acc \\ []) do
    receive do
      {:query_context, pid, id} -> collect([{pid, id} | acc])
    after
      0 -> acc
    end
  end

  defp observe do
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, [:anime, :repo, :query], &__MODULE__.query_context/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "real admin start_async queries inherit the signed HTTP ID across patch and PubSub", %{
    conn: conn
  } do
    conn = conn |> login_conn(role_user("owner")) |> get("/admin/users/blocked")
    [id] = get_resp_header(conn, "x-request-id")
    {:ok, view, _} = live(conn)
    observe()
    render_patch(view, "/admin/users/blocked?q=PRIVATE_SEARCH")
    render_async(view, 2000)
    children = Enum.reject(collect(), fn {pid, _} -> pid in [self(), view.pid] end)
    assert children != []
    assert Enum.all?(children, fn {_, observed} -> observed == id end)

    # Simulate unrelated metadata before an incoming message, outside an event.
    :sys.replace_state(view.pid, fn state ->
      LogContext.put("unrelated-process-context-12345")
      state
    end)

    send(view.pid, :users_changed)
    render(view)
    render_async(view, 2000)
    queries = collect()
    assert queries != []
    assert Enum.all?(queries, fn {_, observed} -> observed == id end)
  end

  test "handle_info and handle_async hooks restore page context before later hooks", %{conn: conn} do
    {:ok, view, _} = live(conn, "/login")
    socket = :sys.get_state(view.pid).socket
    id = socket.assigns.request_id

    for call <- [
          fn -> Phoenix.LiveView.Lifecycle.handle_info({:arbitrary, "PRIVATE"}, socket) end,
          fn ->
            Phoenix.LiveView.Lifecycle.handle_async(:arbitrary, {:exit, "PRIVATE"}, socket)
          end
        ] do
      LogContext.put("unrelated-process-context-12345")
      assert {:cont, _} = call.()
      assert LogContext.current() == id
    end
  end

  test "revoked access on an incoming refresh logs the original page ID without payload", %{
    conn: conn
  } do
    actor = role_user("admin")
    c = conn |> login_conn(actor) |> get("/admin/users")
    [id] = get_resp_header(c, "x-request-id")
    {:ok, view, _} = live(c)
    Repo.update!(Ecto.Changeset.change(actor, status: :blocked))

    :sys.replace_state(view.pid, fn state ->
      LogContext.put("unrelated-process-context-12345")
      state
    end)

    output =
      capture_log(fn ->
        send(view.pid, :users_changed)
        render(view)
      end)

    rows = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    [row] = Enum.filter(rows, &(&1["message"] == "Access denied"))
    assert row["request_id"] == id
    # A blocked account no longer resolves from its session. Do not resurrect
    # the stale socket actor merely to fill a log field.
    refute Map.has_key?(row, "user_id")
    refute output =~ actor.email
    refute output =~ actor.nick
    refute output =~ "unrelated-process-context"
    assert has_element?(view, "[role=alert]", "Недостаточно прав")
  end
end
