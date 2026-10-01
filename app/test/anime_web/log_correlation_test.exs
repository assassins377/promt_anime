defmodule AnimeWeb.LogCorrelationTest do
  use AnimeWeb.ConnCase
  import Ecto.Query
  import ExUnit.CaptureLog
  @fake "FORGED-CORRELATION-123456"
  @secret "PRIVATE-CORRELATION-SENTINEL"
  @moduletag :capture_log

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  defp socket(view), do: :sys.get_state(view.pid).socket

  defp records(log) do
    refute log =~ @secret
    refute log =~ @fake
    log |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "signed per-page session isolates two tabs and rejects cookie/connect-param IDs", %{
    conn: conn
  } do
    conn = conn |> init_test_session(%{"request_id" => @fake}) |> get("/password/reset")
    second = conn |> recycle() |> get("/en/password/reset")
    [id] = get_resp_header(conn, "x-request-id")
    [other_id] = get_resp_header(second, "x-request-id")
    assert id != other_id

    {{:ok, a, _}, output_a} =
      with_log(fn -> conn |> put_connect_params(%{"request_id" => @fake}) |> live() end)

    {{:ok, b, _}, output_b} = with_log(fn -> live(second) end)
    assert socket(a).assigns.request_id == id
    assert socket(b).assigns.request_id == other_id
    assert socket(a).assigns.locale == "ru"
    assert socket(b).assigns.locale == "en"

    for {log, expected} <- [{output_a, id}, {output_b, other_id}] do
      rows = records(log) |> Enum.filter(&(&1["message"] == "LiveView mounted"))
      assert rows != []
      assert Enum.all?(rows, &(&1["request_id"] == expected))
    end

    # Reconnect using the original signed page, even after another tab's GET.
    {{:ok, reconnected, _}, output} = with_log(fn -> live(conn) end)
    assert socket(reconnected).assigns.request_id == id
    assert Enum.any?(records(output), &(&1["request_id"] == id))
  end

  test "LiveView event enqueues real reset mail with original HTTP ID and no form fields in logs",
       %{conn: conn} do
    u = user()
    conn = get(conn, "/password/reset")
    [id] = get_resp_header(conn, "x-request-id")
    {:ok, view, _} = live(conn)

    output =
      capture_log(fn ->
        render_submit(view, "submit", %{
          "user" => %{"email" => u.email, "password" => @secret, "request_id" => @fake}
        })
      end)

    job = Repo.one!(from j in Oban.Job, order_by: [desc: j.id], limit: 1)
    assert job.meta["request_id"] == id
    refute Map.has_key?(job.args, "request_id")
    refute output =~ u.email
    rows = records(output)

    assert Enum.any?(
             rows,
             &(&1["live_event"] == "submit" && &1["request_id"] == id &&
                 &1["socket_id"] == view.id)
           )
  end

  test "HTTP POST also persists its request ID in mail metadata", %{conn: conn} do
    attrs = attrs()
    opened = Phoenix.Token.sign(@endpoint, "registration-form", System.system_time(:second) - 4)
    conn = post(conn, "/register", %{"user" => attrs, "opened" => opened})
    assert conn.status == 302
    job = Repo.one!(from j in Oban.Job, order_by: [desc: j.id], limit: 1)
    assert job.meta["request_id"] == hd(get_resp_header(conn, "x-request-id"))
  end

  test "authenticated/admin sessions and patch retain context", %{conn: conn} do
    owner = role_user("owner")
    c = conn |> login_conn(owner) |> get("/admin/roles")
    {:ok, view, _} = live(c)
    [id] = get_resp_header(c, "x-request-id")
    output = capture_log(fn -> render_patch(view, "/admin/roles?q=#{@secret}") end)
    assert socket(view).assigns.request_id == id

    assert Enum.any?(
             records(output),
             &(&1["message"] == "LiveView parameters handled" && &1["request_id"] == id)
           )

    profile = conn |> login_conn(owner) |> get("/en/profile/settings")
    {:ok, profile_view, _} = live(profile)
    assert socket(profile_view).assigns.request_id == hd(get_resp_header(profile, "x-request-id"))
    assert socket(profile_view).assigns.locale == "en"
  end

  test "unknown event names are not copied to the log", %{conn: conn} do
    conn = conn |> login_conn(role_user("owner")) |> get("/admin/users")
    {:ok, view, _} = live(conn)
    output = capture_log(fn -> render_click(view, @secret, %{"token" => @secret}) end)
    [row] = Enum.filter(records(output), &(&1["message"] == "LiveView event handled"))
    assert row["live_event"] == "[unknown]"
  end

  test "exception telemetry projects no params, URL, reason or stacktrace", %{conn: conn} do
    c = get(conn, "/login")
    {:ok, view, _} = live(c)

    output =
      capture_log(fn ->
        :telemetry.execute([:phoenix, :live_view, :handle_event, :exception], %{}, %{
          socket: socket(view),
          event: @secret,
          params: %{password: @secret},
          uri: @secret,
          reason: %RuntimeError{message: @secret},
          stacktrace: [@secret]
        })
      end)

    [row] = records(output)
    assert row["message"] == "LiveView callback failed"
    assert row["level"] == "error"
    assert row["request_id"] == hd(get_resp_header(c, "x-request-id"))
    assert row["live_event"] == "[unknown]"
  end

  test "actual crashing LiveView callback has the HTTP ID without its secret event or payload", %{
    conn: conn
  } do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)
    c = get(conn, "/login")
    {:ok, view, _} = live(c)

    output =
      capture_log(fn -> catch_exit(render_click(view, @secret, %{"password" => @secret})) end)

    [row] = Enum.filter(records(output), &(&1["message"] == "LiveView callback failed"))
    assert row["request_id"] == hd(get_resp_header(c, "x-request-id"))
    assert row["level"] == "error"
    assert row["live_event"] == "[unknown]"
  end
end
