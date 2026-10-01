defmodule AnimeWeb.ShutdownGateTest do
  use AnimeWeb.ConnCase, async: false
  alias Anime.{Shutdown}
  alias AnimeWeb.ShutdownGate

  setup do
    Shutdown.reset()
    on_exit(&Shutdown.reset/0)
  end

  test "withdrawal permits requests; rejection blocks new work but not health checks" do
    assert ShutdownGate.init([]) == []
    Shutdown.begin_drain()
    refute Shutdown.rejecting?()
    refute ShutdownGate.call(Plug.Test.conn(:get, "/login"), []).halted
    Shutdown.begin_rejection()

    for path <- ["/login", "/en/profile/settings", "/admin/users", "/live/websocket"] do
      response = ShutdownGate.call(Plug.Test.conn(:get, path), [])
      assert response.halted
      assert response.status == 503
      assert get_resp_header(response, "retry-after") == ["1"]
      assert get_resp_header(response, "cache-control") == ["no-store"]
    end

    for path <- ["/healthz", "/readyz"] do
      refute ShutdownGate.call(Plug.Test.conn(:get, path), []).halted
    end
  end

  test "existing LiveView events work but a new mount from signed HTML is refused", %{conn: conn} do
    page = get(conn, "/en/password/reset")
    assert {:ok, view, _} = live(page)
    Shutdown.begin_rejection()
    assert render(view) =~ "Reset your password"
    assert render_submit(view, "submit", %{"user" => %{"email" => "unknown@example.test"}})
    assert {:error, {:redirect, %{to: "/en/password/reset"}}} = live(page)
  end

  test "signed return path preserves admin filters and has a safe missing-value fallback" do
    socket = %Phoenix.LiveView.Socket{}
    assert {:cont, ^socket} = ShutdownGate.on_mount(:default, %{}, %{}, socket)
    Shutdown.begin_rejection()
    path = "/admin/users?page=2&sort=nick"

    assert {:halt, result} =
             ShutdownGate.on_mount(:default, %{}, %{"shutdown_return_to" => path}, socket)

    assert result.redirected == {:redirect, %{to: path, status: 302}}
    assert {:halt, result} = ShutdownGate.on_mount(:default, %{}, %{}, socket)
    assert result.redirected == {:redirect, %{to: "/", status: 302}}
  end

  test "endpoint returns 503 with security headers without running login", %{conn: conn} do
    Shutdown.begin_rejection()
    response = post(conn, "/login", %{})
    assert response.status == 503
    assert get_resp_header(response, "content-security-policy") != []
    assert get_resp_header(response, "x-request-id") != []
  end
end
