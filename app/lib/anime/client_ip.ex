defmodule Anime.ClientIP do
  @moduledoc """
  Shared HTTP/WebSocket trust boundary. Only transport metadata and configured
  CIDRs are inputs, never form params, cookies, session data or client JS.
  """
  import Bitwise

  def configured, do: Application.get_env(:anime, :trusted_proxies, [])

  def parse_trusted!(value) when value in [nil, ""], do: []

  def parse_trusted!(value) when is_binary(value) do
    if String.valid?(value) and not Regex.match?(~r/[\x00-\x1f\x7f]/, value) do
      case String.trim(value) do
        "" -> []
        value -> value |> String.split(",") |> Enum.map(&cidr!/1) |> Enum.uniq()
      end
    else
      invalid_config!()
    end
  end

  def parse_trusted!(_), do: invalid_config!()

  def resolve(peer, headers, trusted \\ configured()) do
    peer = normalize(peer)
    trusted_peer = trusted?(peer, trusted)
    values = for {"x-forwarded-for", value} <- headers, do: value
    {ip, forwarded} = forwarded(peer, values, trusted_peer, trusted)

    country =
      case for({"x-geo-country", value} <- headers, do: value) do
        [<<a, b>> = code] when forwarded == :accepted and a in ?A..?Z and b in ?A..?Z -> code
        _ -> "unknown"
      end

    %{ip: ip, country: country, forwarded: forwarded, trusted_peer: trusted_peer}
  end

  def text(nil), do: nil
  def text(ip), do: ip |> :inet.ntoa() |> to_string()

  def trusted?(nil, _), do: false

  def trusted?(ip, ranges) do
    {bits, address} = ip |> normalize() |> number()

    Enum.any?(ranges, fn {size, network, prefix} ->
      size == bits and bsr(address, bits - prefix) == bsr(network, bits - prefix)
    end)
  end

  # Fixed labels only: never emit the header, IP, URI, cookie or secret as a log
  # message or metric label. Metrics exporters are a separate operations slice.
  def observe(%{forwarded: status}, transport) when status not in [:absent, :accepted] do
    Anime.Log.proxy_rejected(status)

    :telemetry.execute([:anime, :client_ip, :rejected], %{count: 1}, %{
      reason: status,
      transport: transport
    })
  end

  def observe(_, _), do: :ok

  defp forwarded(peer, [], _, _), do: {peer, :absent}
  defp forwarded(peer, _, false, _), do: {peer, :untrusted_peer}

  defp forwarded(peer, [value], true, trusted)
       when is_binary(value) and byte_size(value) <= 2048 do
    parts = String.split(value, ",")

    if length(parts) > 20 do
      {peer, :too_many}
    else
      parsed = Enum.map(parts, &(trim_ows(&1) |> parse_ip()))

      if Enum.any?(parsed, &is_nil/1) do
        {peer, :invalid}
      else
        case parsed |> Enum.reverse() |> Enum.find(&(not trusted?(&1, trusted))) do
          nil -> {peer, :all_trusted}
          ip -> {ip, :accepted}
        end
      end
    end
  end

  defp forwarded(peer, _, true, _), do: {peer, :invalid}

  defp trim_ows(value), do: Regex.replace(~r/\A[ \t]+|[ \t]+\z/, value, "")
  defp parse_ip(value), do: value |> raw_ip() |> normalize()

  defp raw_ip(value) do
    # inet accepts zone identifiers; reject them, ports, brackets, shorthand IPv4
    # and any nonliteral syntax here so there is only one interpretation.
    if byte_size(value) in 2..45 and Regex.match?(~r/\A[0-9a-fA-F:.]+\z/, value) do
      case :inet.parse_strict_address(String.to_charlist(value)) do
        {:ok, ip} -> ip
        _ -> nil
      end
    end
  end

  defp normalize({0, 0, 0, 0, 0, 65_535, hi, lo}),
    do: {bsr(hi, 8), band(hi, 255), bsr(lo, 8), band(lo, 255)}

  defp normalize(ip), do: ip

  defp cidr!(value) do
    with [address, prefix] <- value |> String.trim() |> String.split("/"),
         true <- Regex.match?(~r/\A[0-9]{1,3}\z/, prefix),
         ip when not is_nil(ip) <- raw_ip(address) do
      prefix = String.to_integer(prefix)
      {bits, _} = number(ip)
      if prefix > bits, do: invalid_config!()

      normalized = normalize(ip)
      # IPv4-mapped ranges have an IPv4 equivalent only at /96 or narrower.
      if ip != normalized and prefix < 96, do: invalid_config!()
      prefix = if ip != normalized, do: prefix - 96, else: prefix
      {bits, address} = number(normalized)
      {bits, bsl(bsr(address, bits - prefix), bits - prefix), prefix}
    else
      _ -> invalid_config!()
    end
  end

  defp number(ip) do
    width = if tuple_size(ip) == 4, do: 8, else: 16
    {tuple_size(ip) * width, Enum.reduce(Tuple.to_list(ip), 0, &bor(bsl(&2, width), &1))}
  end

  defp invalid_config!,
    do:
      raise(
        "Invalid runtime configuration: TRUSTED_PROXIES: expected comma-separated IP/CIDR ranges"
      )
end
