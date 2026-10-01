defmodule Anime.ShutdownListenerTest do
  use ExUnit.Case, async: false

  setup do
    Anime.Shutdown.reset()
    on_exit(&Anime.Shutdown.reset/0)
    :ok
  end

  defmodule GuardedEndpoint do
    def init(opts), do: opts
    def call(conn, _), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  test "internal Bandit restart cannot reopen the port during drain" do
    children =
      AnimeWeb.DrainingAdapter.child_specs(GuardedEndpoint,
        otp_app: :anime,
        code_reloader: false,
        http: [ip: {127, 0, 0, 1}, port: 0, startup_log: false]
      )

    supervisor =
      start_supervised!(%{
        id: GuardedEndpoint,
        start:
          {Supervisor, :start_link, [children, [strategy: :one_for_one, name: GuardedEndpoint]]}
      })

    {:ok, server} = Bandit.PhoenixAdapter.bandit_pid(GuardedEndpoint, :http)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Anime.Shutdown.begin_rejection()
    :ok = Anime.Shutdown.stop_accepting(GuardedEndpoint)
    ref = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^ref, :process, ^server, :killed}, 2000
    children = Supervisor.which_children(supervisor)

    assert Enum.any?(children, fn {id, pid, _, _} ->
             id == {GuardedEndpoint, :http} and pid == :undefined
           end)

    assert :ok = Anime.Shutdown.stop_accepting(GuardedEndpoint)

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)
  end

  test "already terminated endpoint has no listener to withdraw" do
    assert :ok = Anime.Shutdown.stop_accepting(__MODULE__.MissingEndpoint)
  end

  defmodule HeldRequest do
    def init(parent), do: parent

    def call(conn, parent) do
      send(parent, {:request_started, self()})

      receive do
        :finish -> Plug.Conn.send_resp(conn, 200, "drained")
      after
        5000 -> Plug.Conn.send_resp(conn, 500, "fixture timeout")
      end
    end
  end

  test "closing listeners rejects new connections but preserves an active request" do
    child =
      Supervisor.child_spec(
        {Bandit, plug: {HeldRequest, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: {ProbeEndpoint, :http}
      )

    start_endpoint([child])

    {:ok, server} = Bandit.PhoenixAdapter.bandit_pid(ProbeEndpoint, :http)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    assert_receive {:request_started, handler}, 2000

    assert :ok = Anime.Shutdown.stop_accepting(ProbeEndpoint)

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)

    assert Process.alive?(handler)
    send(handler, :finish)
    assert {:ok, response} = :gen_tcp.recv(socket, 0, 2000)
    assert response =~ "200 OK"
    assert response =~ "drained"
  end

  test "a non-serving endpoint has no listeners to close" do
    start_endpoint([])
    assert :ok = Anime.Shutdown.stop_accepting(ProbeEndpoint)
  end

  test "a server that completes shutdown during grace does not abort draining" do
    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: {HeldRequest, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: :draining_server
        )
      )

    assert :ok =
             Anime.Shutdown.drain_connections([server], fn 30_000 ->
               stop_supervised!(:draining_server)
               refute Process.alive?(server)
             end)
  end

  defp start_endpoint(children) do
    start_supervised!(%{
      id: ProbeEndpoint,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one, name: ProbeEndpoint]]}
    })
  end
end
