defmodule Anime.LiveTransportsTest do
  use ExUnit.Case, async: true

  test "tracks each transport once and removes it when it exits" do
    server = start_supervised!({Anime.LiveTransports, name: __MODULE__.Registry})

    transport =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    ref = Process.monitor(transport)
    assert :ok = Anime.LiveTransports.track(transport, server)
    assert :ok = Anime.LiveTransports.track(transport, server)
    assert [^transport] = Anime.LiveTransports.snapshot(server)
    send(server, {:DOWN, make_ref(), :process, transport, :forged})
    assert [^transport] = Anime.LiveTransports.snapshot(server)
    send(transport, :finish)
    assert_receive {:DOWN, ^ref, :process, ^transport, :normal}
    await_empty(server, 100)
  end

  defp await_empty(server, remaining) do
    if Anime.LiveTransports.snapshot(server) != [] do
      assert remaining > 0
      Process.sleep(10)
      await_empty(server, remaining - 1)
    end
  end
end
