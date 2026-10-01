defmodule Anime.ClientIPTest do
  use ExUnit.Case, async: true
  alias Anime.ClientIP
  @peer {10, 0, 0, 2}
  @client {203, 0, 113, 7}

  defp trusted, do: ClientIP.parse_trusted!("10.0.0.0/8, 2001:db8:10::/48")
  defp headers(value), do: [{"x-forwarded-for", value}, {"x-geo-country", "RU"}]
  defp resolve(value), do: ClientIP.resolve(@peer, headers(value), trusted())

  test "no proxy is trusted implicitly, including loopback and private peers" do
    for peer <- [@peer, {127, 0, 0, 1}, {192, 168, 1, 1}] do
      assert %{ip: ^peer, country: "unknown", forwarded: :untrusted_peer, trusted_peer: false} =
               ClientIP.resolve(peer, headers("203.0.113.7"), [])
    end
  end

  test "CIDRs support both families, host boundaries and normalized host bits" do
    ranges = ClientIP.parse_trusted!("192.0.2.129/24,2001:db8:10::1/48,::1/128")
    assert ClientIP.trusted?({192, 0, 2, 0}, ranges)
    assert ClientIP.trusted?({192, 0, 2, 255}, ranges)
    refute ClientIP.trusted?({192, 0, 3, 0}, ranges)
    assert ClientIP.trusted?({0x2001, 0xDB8, 0x10, 0xFFFF, 0, 0, 0, 1}, ranges)
    refute ClientIP.trusted?({0x2001, 0xDB8, 0x11, 0, 0, 0, 0, 1}, ranges)
    assert ClientIP.trusted?({0, 0, 0, 0, 0, 0, 0, 1}, ranges)
    refute ClientIP.trusted?({0, 0, 0, 0, 0, 0, 0, 2}, ranges)
    assert ClientIP.trusted?(@peer, ClientIP.parse_trusted!("10.0.0.2/32"))
    refute ClientIP.trusted?({10, 0, 0, 3}, ClientIP.parse_trusted!("10.0.0.2/32"))
    assert ClientIP.trusted?(@client, ClientIP.parse_trusted!("0.0.0.0/0"))
    assert ClientIP.trusted?({0x2001, 0, 0, 0, 0, 0, 0, 1}, ClientIP.parse_trusted!("::/0"))
  end

  test "missing and blank dev CIDRs are empty but malformed lists fail without values" do
    for value <- [nil, "", "   "], do: assert(ClientIP.parse_trusted!(value) == [])

    for value <- [
          "10.0.0.1",
          "SECRET-SENTINEL/8",
          "10.0.0.0/-1",
          "10.0.0.0/33",
          "::1/129",
          "10.0.0.1/1.0",
          "127.1/8",
          "010.0.0.1/8",
          "::ffff:192.0.2.0/80",
          "[::1]/128",
          "fe80::1%eth0/64",
          "10.0.0.0/8,",
          ",10.0.0.0/8",
          "10.0.0.0/8,,::1/128",
          "10.0.0.0/8\n",
          <<255>>,
          1
        ] do
      error = assert_raise RuntimeError, fn -> ClientIP.parse_trusted!(value) end
      assert error.message =~ "TRUSTED_PROXIES:"
      refute error.message =~ "SENTINEL"
    end
  end

  test "rightmost untrusted hop wins, not the arbitrary leftmost header value" do
    assert %{ip: @client, country: "RU", forwarded: :accepted} =
             resolve("198.51.100.99, 203.0.113.7, 10.1.0.1, 2001:db8:10::2")

    assert %{ip: @client} = resolve(" \t203.0.113.7\t , 10.0.0.1 ")
  end

  test "all elements must validate, even to the left of the first untrusted hop" do
    for value <- [
          "bad,203.0.113.7",
          "203.0.113.7,",
          ",203.0.113.7",
          "unknown",
          "203.0.113.7:443",
          "[2001:db8::1]",
          "fe80::1%eth0",
          "127.1",
          "010.0.0.1",
          "0x7f000001",
          "2130706433",
          "203.0.113.7\r\n",
          "\"203.0.113.7\"",
          "_hidden",
          "203.0.113.7,\t",
          <<255>>,
          ""
        ] do
      assert %{ip: @peer, country: "unknown", forwarded: :invalid} = resolve(value)
    end
  end

  test "duplicate headers are ambiguous and reject the complete chain" do
    assert %{ip: @peer, country: "unknown", forwarded: :invalid} =
             ClientIP.resolve(
               @peer,
               headers("203.0.113.7") ++ [{"x-forwarded-for", "198.51.100.3"}],
               trusted()
             )
  end

  test "twenty hops allowed, twenty one rejected, oversized value bounded" do
    assert %{ip: @client, forwarded: :accepted} =
             resolve(Enum.join(["203.0.113.7" | List.duplicate("10.0.0.1", 19)], ","))

    assert %{ip: @peer, country: "unknown", forwarded: :too_many} =
             resolve(Enum.join(["203.0.113.7" | List.duplicate("10.0.0.1", 20)], ","))

    assert %{ip: @peer, forwarded: :invalid} = resolve(String.duplicate("1", 2049))
  end

  test "absent and fully trusted chains fall back to transport peer with unknown country" do
    assert %{ip: @peer, country: "unknown", forwarded: :absent} =
             ClientIP.resolve(@peer, [{"x-geo-country", "RU"}], trusted())

    assert %{ip: @peer, country: "unknown", forwarded: :all_trusted} = resolve("10.0.0.1")

    assert %{ip: nil, country: "unknown", trusted_peer: false} =
             ClientIP.resolve(nil, headers("203.0.113.7"), trusted())
  end

  test "country is single uppercase ASCII and never inferred from IP" do
    for value <- ["ru", " RU", "RUS", "12", "РФ", "", "RU,US"] do
      assert %{ip: @client, country: "unknown"} =
               ClientIP.resolve(
                 @peer,
                 [{"x-forwarded-for", "203.0.113.7"}, {"x-geo-country", value}],
                 trusted()
               )
    end

    assert %{country: "unknown"} =
             ClientIP.resolve(
               @peer,
               headers("203.0.113.7") ++ [{"x-geo-country", "US"}],
               trusted()
             )
  end

  test "IPv4-mapped IPv6 shares the IPv4 trust and rate-limit identity" do
    peer = {0, 0, 0, 0, 0, 65_535, 2560, 2}

    assert %{ip: @client, forwarded: :accepted} =
             ClientIP.resolve(peer, headers("::ffff:203.0.113.7"), trusted())

    assert ClientIP.parse_trusted!("::ffff:10.0.0.0/104") == ClientIP.parse_trusted!("10.0.0.0/8")
    assert ClientIP.text(@client) == "203.0.113.7"
    assert ClientIP.text(nil) == nil
  end

  test "IPv6 visitor stays IPv6 through mixed-family trusted hops" do
    peer = {0x2001, 0xDB8, 0x10, 0, 0, 0, 0, 1}
    result = ClientIP.resolve(peer, headers("2001:DB8:20::5,10.0.0.1"), trusted())
    assert result.forwarded == :accepted
    assert result.country == "RU"
    assert ClientIP.text(result.ip) == "2001:db8:20::5"
  end

  test "alternative headers are not read" do
    headers =
      for key <- ~w(x-real-ip forwarded true-client-ip cf-connecting-ip), do: {key, "203.0.113.7"}

    assert %{ip: @peer, country: "unknown", forwarded: :absent} =
             ClientIP.resolve(@peer, headers, trusted())
  end
end
