defmodule Anime.ShutdownWebSocketTest do
  use ExUnit.Case, async: false

  defmodule Socket do
    @behaviour WebSock
    def init(parent) do
      :ok = Anime.LiveTransports.track(self())
      send(parent, {:transport, self()})
      {:ok, parent}
    end

    def handle_in({data, [opcode: :text]}, state), do: {:push, {:text, data}, state}
    def handle_info(:socket_drain, state), do: Phoenix.Socket.__info__(:socket_drain, state)
    def terminate(_, _), do: :ok
  end

  defmodule Upgrade do
    def init(parent), do: parent

    def call(%{request_path: "/http"} = conn, parent),
      do: Anime.ShutdownWebSocketTest.HeldHTTP.call(conn, parent)

    def call(conn, parent),
      do: WebSockAdapter.upgrade(conn, Socket, parent, []) |> Plug.Conn.halt()
  end

  @tag timeout: 45_000
  test "real grace serves a completed HTTP request and WebSocket events before the deadline" do
    server =
      start_supervised!(
        {Bandit, plug: {Upgrade, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    sockets =
      for _ <- 1..3 do
        {:ok, socket} =
          :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :line], 2000)

        socket
      end

    on_exit(fn -> Enum.each(sockets, &:gen_tcp.close/1) end)
    [finishing, held, websocket] = sockets

    :ok =
      :gen_tcp.send(
        finishing,
        "GET /http HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
      )

    assert_receive {:request, finishing_pid}, 2000
    :ok = :gen_tcp.send(held, "GET /http HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_receive {:request, held_pid}, 2000

    :ok =
      :gen_tcp.send(
        websocket,
        "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      )

    assert {:ok, status} = :gen_tcp.recv(websocket, 0, 2000)
    assert status =~ "101 Switching Protocols"
    read_headers(websocket)
    :ok = :inet.setopts(websocket, packet: :raw)
    assert_receive {:transport, _}, 2000
    :ok = ThousandIsland.suspend(server)
    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> Anime.Shutdown.drain_connections([server]) end)
    Process.sleep(1000)
    send(finishing_pid, :finish)
    assert {:ok, status} = :gen_tcp.recv(finishing, 0, 2000)
    assert status =~ "200 OK"
    read_headers(finishing)
    :ok = :inet.setopts(finishing, packet: :raw)
    assert {:ok, "finished"} = :gen_tcp.recv(finishing, 8, 2000)
    Process.sleep(24_000)
    assert Process.alive?(held_pid)
    :ok = :gen_tcp.send(websocket, <<0x81, 0x82, 0, 0, 0, 0, "ok">>)
    assert {:ok, <<0x81, 2, "ok">>} = :gen_tcp.recv(websocket, 4, 2000)
    assert {:ok, <<0x88, size>>} = :gen_tcp.recv(websocket, 2, 10_000)
    assert {:ok, <<1012::16, _::binary>>} = :gen_tcp.recv(websocket, size, 2000)
    assert {:error, :closed} = :gen_tcp.recv(held, 0, 2000)
    assert :ok = Task.await(task, 2000)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 30_000
    assert elapsed < 35_000
  end

  defmodule HeldHTTP do
    def init(parent), do: parent

    def call(conn, parent) do
      send(parent, {:request, self()})

      receive do
        :finish -> Plug.Conn.send_resp(conn, 200, "finished")
      end
    end
  end

  test "unfinished HTTP remains alive during grace and closes at the deadline" do
    server =
      start_supervised!(
        {Bandit, plug: {HeldHTTP, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_receive {:request, request}, 2000
    :ok = ThousandIsland.suspend(server)
    parent = self()

    task =
      Task.async(fn ->
        Anime.Shutdown.drain_connections([server], fn 30_000 ->
          send(parent, :waiting)

          receive do
            :deadline -> :ok
          end
        end)
      end)

    assert_receive :waiting
    assert Process.alive?(request)
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 50)
    send(task.pid, :deadline)
    assert :ok = Task.await(task)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
  end

  test "tracked WebSocket is a connection process and Phoenix drain writes close code 1012" do
    server =
      start_supervised!(
        {Bandit, plug: {Upgrade, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :line], 2000)

    on_exit(fn -> :gen_tcp.close(socket) end)

    :ok =
      :gen_tcp.send(
        socket,
        "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      )

    {:ok, status} = :gen_tcp.recv(socket, 0, 2000)
    assert status =~ "101 Switching Protocols"
    read_headers(socket)
    :ok = :inet.setopts(socket, packet: :raw)
    assert_receive {:transport, transport}, 2000
    assert transport in Anime.LiveTransports.snapshot()
    {:ok, connections} = ThousandIsland.connection_pids(server)
    assert transport in connections
    :ok = ThousandIsland.suspend(server)
    # The listener is withdrawn, but the existing socket still handles events.
    :ok = :gen_tcp.send(socket, <<0x81, 0x82, 0, 0, 0, 0, "ok">>)
    assert {:ok, <<0x81, 2, "ok">>} = :gen_tcp.recv(socket, 4, 2000)
    parent = self()

    drainer =
      Task.async(fn ->
        Anime.Shutdown.drain_connections([server], fn milliseconds ->
          send(parent, {:grace, milliseconds})
        end)
      end)

    assert_receive {:grace, 30_000}
    assert {:ok, <<0x88, size>>} = :gen_tcp.recv(socket, 2, 2000)
    assert size >= 2
    assert {:ok, <<1012::16, _reason::binary>>} = :gen_tcp.recv(socket, size, 2000)
    assert :ok = Task.await(drainer)
  end

  defp read_headers(socket) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, "\r\n"} -> :ok
      {:ok, _} -> read_headers(socket)
    end
  end
end
