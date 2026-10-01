defmodule Anime.HTTPSecurityTest do
  use ExUnit.Case, async: true

  # Small loopback responses reproduce the three Mint advisories. No external
  # hosts, giant frames, memory exhaustion or dependency internals are patched.
  test "HTTP/1 non-final chunked coding does not end the response early (CVE-2026-94194)" do
    for encoding <- ["chunked, gzip", "chunked\r\nTransfer-Encoding: gzip"] do
      {conn, peer} = pair(:http1)
      {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/", [], nil)
      body = "3\r\nabc\r\n0\r\n\r\n"
      response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: #{encoding}\r\n\r\n" <> body
      {:ok, conn, events} = exchange(conn, peer, response)
      refute {:done, ref} in events
      assert data(events, ref) == body
      :ok = :gen_tcp.close(peer)
      assert {:ok, conn, [{:done, ^ref}]} = Mint.HTTP.recv(conn, 0, 2_000)
      refute Mint.HTTP.open?(conn)
    end
  end

  test "HTTP/2 rejects declared oversized frames before reading payload (CVE-2026-92103)" do
    {conn, peer} = http2()
    # Only the 9-byte header is sent; the claimed payload is never allocated.
    header = <<16_385::24, 0::8, 0::8, 0::1, 3::31>>

    assert {:error, conn, %Mint.HTTPError{reason: {:frame_size_error, _}}, _} =
             exchange(conn, peer, header)

    refute Mint.HTTP.open?(conn)
  end

  test "HTTP/2 bounds decoded indexed cookies before joining (CVE-2026-91043)" do
    {conn, peer} = http2()
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/", [], nil)
    headers = [{":status", "200"} | List.duplicate({"cookie", String.duplicate("a", 128)}, 8)]
    {block, _} = HPAX.encode(:store, headers, HPAX.new(4096))
    assert IO.iodata_length(block) < 512

    assert Enum.sum(
             Enum.map(headers, fn {name, value} -> byte_size(name) + byte_size(value) + 32 end)
           ) > 512

    assert {:ok, conn, events} = exchange(conn, peer, frame(1, 5, 3, block))

    assert [{:error, ^ref, %Mint.HTTPError{reason: {:max_header_list_size_exceeded, 1370, 512}}}] =
             events

    assert Mint.HTTP.open?(conn)
    assert Mint.HTTP.open_request_count(conn) == 0
    refute Enum.any?(events, &match?({:headers, ^ref, _}, &1))
  end

  test "ordinary final chunked responses still decode and keep the connection usable" do
    {conn, peer} = pair(:http1)
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/", [], nil)
    response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
    {:ok, conn, events} = exchange(conn, peer, response)
    assert data(events, ref) == "abc"
    assert {:done, ref} in events
    assert Mint.HTTP.open?(conn)
  end

  test "HTTP/2 headers below the declared limit still complete successfully" do
    {conn, peer} = http2()
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/", [], nil)

    {block, _} =
      HPAX.encode(
        :store,
        [{":status", "200"}, {"cookie", "a=1"}, {"cookie", "b=2"}],
        HPAX.new(4096)
      )

    {:ok, conn, events} = exchange(conn, peer, frame(1, 5, 3, block))
    assert {:status, ref, 200} in events
    assert {:headers, ref, [{"cookie", "a=1; b=2"}]} in events
    assert {:done, ref} in events
    assert Mint.HTTP.open?(conn)
  end

  defp pair(protocol, options \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    {:ok, conn} =
      Mint.HTTP.connect(
        :http,
        "127.0.0.1",
        port,
        [protocols: [protocol], mode: :passive] ++ options
      )

    {:ok, peer} = :gen_tcp.accept(listener, 2_000)
    :gen_tcp.close(listener)

    on_exit(fn ->
      Mint.HTTP.close(conn)
      :gen_tcp.close(peer)
    end)

    {conn, peer}
  end

  defp http2 do
    {conn, peer} = pair(:http2, client_settings: [max_header_list_size: 512])
    # Server SETTINGS and acknowledgement activate the client's small limit.
    {:ok, conn, []} = exchange(conn, peer, frame(4, 0, 0, "") <> frame(4, 1, 0, ""))
    {conn, peer}
  end

  defp frame(type, flags, stream, payload) do
    bytes = IO.iodata_to_binary(payload)
    <<byte_size(bytes)::24, type::8, flags::8, 0::1, stream::31, bytes::binary>>
  end

  defp exchange(conn, peer, response) do
    :ok = :gen_tcp.send(peer, response)
    Mint.HTTP.recv(conn, byte_size(response), 2_000)
  end

  defp data(events, ref), do: for({:data, ^ref, bytes} <- events, into: "", do: bytes)
end
