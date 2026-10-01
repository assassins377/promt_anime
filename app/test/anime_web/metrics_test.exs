defmodule AnimeWeb.MetricsTest do
  use AnimeWeb.ConnCase
  import Anime.MetricsProbe
  @secret "PRIVATE-METRIC-SENTINEL"

  defmodule FailureHarness do
    use Plug.Builder

    use Phoenix.Endpoint.RenderErrors,
      formats: [html: AnimeWeb.ErrorHTML, json: AnimeWeb.ErrorJSON],
      log: false

    plug :endpoint
    plug AnimeWeb.Metrics
    plug AnimeWeb.SecurityHeaders
    plug AnimeWeb.ClientIP
    plug :fail
    defp endpoint(conn, _), do: put_private(conn, :phoenix_endpoint, AnimeWeb.Endpoint)

    defp fail(conn, _) do
      try do
        raise "PRIVATE-METRIC-SENTINEL"
      rescue
        e -> Plug.Conn.WrapperError.reraise(conn, :error, e, __STACKTRACE__)
      end
    end
  end

  defp http!(records, status) do
    refute inspect(records) =~ @secret
    assert [{%{count: 1, duration_ms: duration}, %{status: ^status}}] = rows(records, :http)
    assert duration >= 0
  end

  test "real endpoint success, redirect, 404 and missing assets each count once" do
    for {path, status} <- [
          {"/login?private=#{@secret}", 200},
          {"/profile", 302},
          {"/u/#{@secret}", 404},
          {"/#{@secret}", 404},
          {"/assets/#{@secret}.js", 404}
        ] do
      {c, records} = capture(fn -> get(build_conn(), path) end)
      assert c.status == status
      http!(records, status)
    end
  end

  test "real router dimensions use templates and retain original HEAD" do
    {_, records} = capture(fn -> get(build_conn(), "/u/#{@secret}?email=#{@secret}") end)
    assert [{_, %{route: "/u/:nick", method: "GET"}}] = rows(records, :router)
    refute inspect(records) =~ @secret
    {c, records} = capture(fn -> head(build_conn(), "/u/#{@secret}") end)
    assert c.resp_body == ""
    assert [{_, %{route: "/u/:nick", method: "HEAD"}}] = rows(records, :router)
    http!(records, 404)
  end

  test "parser failure has one HTTP metric and no imaginary router completion" do
    {_, records} =
      capture(fn ->
        assert_error_sent 400, fn ->
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/en/login", ~s({"password":"#{@secret}"))
        end
      end)

    http!(records, 400)
    assert rows(records, :router) == []
  end

  test "CSRF rejection and caught 500 produce HTTP observations without exceptions or body" do
    {_, records} =
      capture(fn ->
        assert_error_sent 403, fn ->
          build_conn()
          |> put_private(:plug_skip_csrf_protection, false)
          |> post("/login", %{"password" => @secret})
        end
      end)

    http!(records, 403)

    {_, records} =
      capture(fn ->
        assert_error_sent 500, fn ->
          build_conn(:get, "/" <> @secret)
          |> put_req_header("accept", "text/html")
          |> FailureHarness.call([])
        end
      end)

    http!(records, 500)
  end

  test "actual static and connected LiveView mounts, form event and patch" do
    {{:ok, view, _}, records} = capture(fn -> live(build_conn(), "/login") end)
    mounts = rows(records, :live_mount)

    assert Enum.any?(mounts, fn {_, tags} ->
             tags == %{view: "AnimeWeb.AuthLive", connection: "static"}
           end)

    assert Enum.any?(mounts, fn {_, tags} ->
             tags == %{view: "AnimeWeb.AuthLive", connection: "connected"}
           end)

    {_, records} =
      capture(fn -> render_change(view, "validate", %{"user" => %{"email" => @secret}}) end)

    assert [{_, %{view: "AnimeWeb.AuthLive"}}] = rows(records, :live_event)
    refute inspect(records) =~ @secret

    {:ok, admin, _} = build_conn() |> login_conn(role_user("owner")) |> live("/admin/roles")
    {_, records} = capture(fn -> render_patch(admin, "/admin/roles?q=#{@secret}") end)
    assert [{_, %{view: "AnimeWeb.RolesLive"}}] = rows(records, :live_params)
    refute inspect(records) =~ @secret
  end

  test "actual crashing LiveView event emits one safe exception observation" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)
    {:ok, view, _} = live(build_conn(), "/login")

    {_, records} =
      capture(fn -> catch_exit(render_click(view, @secret, %{"password" => @secret})) end)

    assert rows(records, :live_event_exception) == [
             {%{count: 1}, %{view: "AnimeWeb.AuthLive", event: "[unknown]"}}
           ]

    refute inspect(records) =~ @secret
  end

  test "rejected untrusted forwarded header is observed without IP or header value" do
    {_, records} =
      capture(fn ->
        build_conn() |> put_req_header("x-forwarded-for", @secret) |> get("/login")
      end)

    assert rows(records, :proxy_rejected) == [
             {%{count: 1}, %{reason: "untrusted_peer", transport: "http"}}
           ]

    refute inspect(records) =~ @secret
  end

  test "public metrics URL is absent, not a new data exposure" do
    c = get(build_conn(), "/metrics")
    assert c.status == 404
    refute c.resp_body =~ "duration_ms"
  end

  test "real denied on_mount redirects are counted as a subset, without redirect URL" do
    u = user()

    {_, records} =
      capture(fn ->
        assert {:error, {:redirect, _}} = build_conn() |> login_conn(u) |> live("/admin/users")
      end)

    assert [{%{count: 1}, %{view: "AnimeWeb.UsersLive", connection: "static"}}] =
             rows(records, :live_mount_redirect)

    assert length(rows(records, :live_mount)) == 1
    assert rows(records, :live_mount_exception) == []
    refute inspect(records) =~ u.email
    refute inspect(records) =~ "return_to"
  end
end
