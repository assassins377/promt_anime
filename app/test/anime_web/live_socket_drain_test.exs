defmodule AnimeWeb.LiveSocketDrainTest do
  use AnimeWeb.ConnCase, async: false

  setup do
    Anime.Shutdown.reset()
    on_exit(&Anime.Shutdown.reset/0)
    :ok
  end

  @tag timeout: 45_000
  test "real LiveView handles events during thirty-second grace and closes with 1012", %{
    conn: conn
  } do
    page = get(conn, "/en/password/reset")
    html = html_response(page, 200)
    csrf = capture!(~r/name="csrf-token" content="([^"]+)"/, html)
    session = capture!(~r/data-phx-session="([^"]+)"/, html)
    static = capture!(~r/data-phx-static="([^"]+)"/, html)
    id = capture!(~r/id="(phx-[^"]+)"/, html)

    cookie =
      page
      |> get_resp_header("set-cookie")
      |> Enum.map(&hd(String.split(&1, ";")))
      |> Enum.join("; ")

    server =
      start_supervised!(
        {Bandit, plug: AnimeWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :line], 2000)

    on_exit(fn -> :gen_tcp.close(socket) end)
    query = URI.encode_query(%{"vsn" => "2.0.0", "_csrf_token" => csrf})

    :ok =
      :gen_tcp.send(
        socket,
        "GET /live/websocket?#{query} HTTP/1.1\r\nHost: localhost:4002\r\nOrigin: http://localhost:4002\r\nCookie: #{cookie}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      )

    assert {:ok, status} = :gen_tcp.recv(socket, 0, 2000)
    assert status =~ "101 Switching Protocols"
    headers(socket)
    :ok = :inet.setopts(socket, packet: :raw)
    topic = "lv:#{id}"

    send_json(socket, [
      "1",
      "1",
      topic,
      "phx_join",
      %{
        "session" => session,
        "static" => static,
        "url" => "http://localhost:4002/en/password/reset",
        "params" => %{"_csrf_token" => csrf, "_mounts" => 0}
      }
    ])

    assert {1, joined} = frame(socket)
    assert ["1", "1", ^topic, "phx_reply", %{"status" => "ok"}] = Jason.decode!(joined)
    {:ok, connections} = ThousandIsland.connection_pids(server)
    assert Enum.any?(connections, &(&1 in Anime.LiveTransports.snapshot()))
    Anime.Shutdown.begin_rejection()
    :ok = ThousandIsland.suspend(server)
    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> Anime.Shutdown.drain_connections([server]) end)
    Process.sleep(25_000)

    send_json(socket, [
      "1",
      "2",
      topic,
      "event",
      %{
        "type" => "form",
        "event" => "submit",
        "value" => "user%5Bemail%5D=unknown%40example.test"
      }
    ])

    assert {1, reply} = frame(socket)
    assert ["1", "2", ^topic, "phx_reply", %{"status" => "ok"}] = Jason.decode!(reply)
    assert {8, <<1012::16, _::binary>>} = frame(socket, 10_000)
    assert :ok = Task.await(task)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 30_000
    assert elapsed < 35_000
  end

  defp capture!(regex, text) do
    [_, value] = Regex.run(regex, text)
    value
  end

  defp headers(socket) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, "\r\n"} -> :ok
      {:ok, _} -> headers(socket)
    end
  end

  defp send_json(socket, value) do
    data = Jason.encode!(value)
    length = byte_size(data)
    size = if length < 126, do: <<length + 128>>, else: <<254, length::16>>
    :ok = :gen_tcp.send(socket, [<<0x81>>, size, <<0, 0, 0, 0>>, data])
  end

  defp frame(socket, timeout \\ 5000) do
    {:ok, <<1::1, 0::3, opcode::4, 0::1, size::7>>} = :gen_tcp.recv(socket, 2, timeout)

    length =
      case size do
        126 ->
          {:ok, <<n::16>>} = :gen_tcp.recv(socket, 2, 2000)
          n

        127 ->
          {:ok, <<n::64>>} = :gen_tcp.recv(socket, 8, 2000)
          n

        n ->
          n
      end

    {:ok, data} = :gen_tcp.recv(socket, length, 5000)
    {opcode, data}
  end
end
