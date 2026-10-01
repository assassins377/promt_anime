defmodule Anime.ShutdownTest do
  use ExUnit.Case, async: false
  alias Anime.Shutdown

  setup do
    Shutdown.reset()
    on_exit(&Shutdown.reset/0)
  end

  test "shutdown intent remains set until application reset" do
    refute Shutdown.draining?()
    Shutdown.begin_drain()
    Shutdown.begin_drain()
    assert Shutdown.draining?()
    Shutdown.reset()
    refute Shutdown.draining?()
  end

  test "withdrawal flag precedes the exact ten second wait" do
    parent = self()

    assert :ok =
             Shutdown.prepare(fn ms ->
               send(parent, {ms, Shutdown.draining?(), Shutdown.rejecting?()})
             end)

    assert_receive {10_000, true, false}
    assert Shutdown.rejecting?()
    Shutdown.reset()
    refute Shutdown.rejecting?()
  end

  test "draining never invokes database or storage checks" do
    Shutdown.begin_drain()
    assert Shutdown.failures(fn -> flunk("dependency queried") end) == [:shutdown]
    conn = AnimeWeb.HealthController.ready(Plug.Test.conn(:get, "/readyz"), %{})
    assert conn.status == 503
    assert Jason.decode!(conn.resp_body) == %{"failed" => ["shutdown"], "ready" => false}
    conn = AnimeWeb.HealthController.live(Plug.Test.conn(:get, "/healthz"), %{})
    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "in-flight checks cannot advertise success after shutdown starts" do
    assert Shutdown.failures(fn ->
             Shutdown.begin_drain()
             [database: true]
           end) == [:shutdown]
  end

  test "normal operation preserves failed check names" do
    assert Shutdown.failures(fn -> [database: true, migrations: false, storage: false] end) == [
             :migrations,
             :storage
           ]

    assert Shutdown.failures(fn -> [database: true, storage: true] end) == []
    assert Anime.Application.prep_stop(:state) == :state
    refute Shutdown.draining?()
  end
end
