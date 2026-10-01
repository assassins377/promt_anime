defmodule Anime.RuntimeConfig do
  @moduledoc """
  Pure preflight for the currently implemented web/dev runtime.

  No connections, environment mutations, logging or application startup. Errors
  contain only a known variable name and a fixed explanation, never its value.
  Staging/prod and media remain disabled until their deployment requirements exist.
  """
  @derive {Inspect, only: [:environment, :node_role, :host, :port]}
  defstruct [
    :environment,
    :node_role,
    :host,
    :port,
    :metrics_port,
    :server,
    :origin,
    :secret_key_base,
    :live_view_signing_salt,
    :database_url,
    :database_ssl,
    :pool_size,
    :minio_endpoint,
    :minio_public_url,
    :minio_region,
    :minio_access_key_id,
    :minio_secret_access_key,
    :log_level,
    :trusted_proxies
  ]

  def load!(env \\ System.get_env()) do
    environment = choice!(env, "APP_ENV", ~w(dev staging prod))

    if environment != "dev",
      do: invalid!("APP_ENV", "staging/prod remain disabled; see IMPLEMENTATION.md")

    node_role = choice!(env, "NODE_ROLE", ~w(web media))
    if node_role != "web", do: invalid!("NODE_ROLE", "media is not implemented in this slice")

    secret = secret!(env, "SECRET_KEY_BASE", 64)
    salt = secret!(env, "LIVE_VIEW_SIGNING_SALT", 32)

    if secret == salt,
      do: invalid!("LIVE_VIEW_SIGNING_SALT", "must differ from SECRET_KEY_BASE")

    host = required!(env, "PHX_HOST")

    unless dns_or_ipv4?(host),
      do: invalid!("PHX_HOST", "expected a bare DNS name or IPv4 address")

    host = String.downcase(host)
    port = integer!(env, "PORT", "4000", 1..65_535)
    metrics_port = integer!(env, "METRICS_PORT", "9568", 1..65_535)
    if metrics_port == port, do: invalid!("METRICS_PORT", "must differ from PORT")
    pool_size = integer!(env, "POOL_SIZE", "10")
    database_url = required!(env, "DATABASE_URL")
    url_ssl = database!(database_url)

    database_ssl =
      if Map.has_key?(env, "DATABASE_SSL"),
        do: boolean!(env, "DATABASE_SSL", "false"),
        else: url_ssl || false

    if not is_nil(url_ssl) and database_ssl != url_ssl,
      do: invalid!("DATABASE_SSL", "conflicts with DATABASE_URL ssl option")

    minio_endpoint = origin!(env, "MINIO_ENDPOINT")
    minio_public = origin!(env, "MINIO_PUBLIC_URL")
    region = value!(env, "MINIO_REGION", "us-east-1")

    unless Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/, region),
      do: invalid!("MINIO_REGION", "expected an alphanumeric region identifier")

    # Never silently accept SMTP/test settings while actually using local mail.
    choice!(env, "MAIL_ADAPTER", ["local"], "local")
    choice!(env, "TZ", ["UTC"], "UTC")

    # Validate the shared environment knob, but p.21 fixes dev at debug.
    choice!(env, "LOG_LEVEL", ~w(debug info warning error), "info")

    %__MODULE__{
      environment: environment,
      node_role: node_role,
      host: host,
      port: port,
      metrics_port: metrics_port,
      server: boolean!(env, "PHX_SERVER", "false"),
      origin: "http://#{host}:#{port}",
      secret_key_base: secret,
      live_view_signing_salt: salt,
      database_url: database_url,
      database_ssl: database_ssl,
      pool_size: pool_size,
      minio_endpoint: minio_endpoint,
      minio_public_url: URI.to_string(minio_public),
      minio_region: region,
      minio_access_key_id: secret!(env, "MINIO_ACCESS_KEY_ID", 1),
      minio_secret_access_key: secret!(env, "MINIO_SECRET_ACCESS_KEY", 1),
      trusted_proxies: Anime.ClientIP.parse_trusted!(Map.get(env, "TRUSTED_PROXIES")),
      log_level: :debug
    }
  end

  defp required!(env, key), do: value!(env, key, nil)

  defp value!(env, key, default) do
    value = Map.get(env, key, default)

    unless is_binary(value) and String.valid?(value) and String.trim(value) != "" and
             not Regex.match?(~r/[\x00-\x1f\x7f]/, value),
           do: invalid!(key, "required nonblank value without control characters")

    value
  end

  defp secret!(env, key, min) do
    value = required!(env, key)
    if String.length(value) < min, do: invalid!(key, "too short")
    value
  end

  defp choice!(env, key, choices, default \\ nil) do
    value = value!(env, key, default)
    unless value in choices, do: invalid!(key, "unsupported value")
    value
  end

  defp boolean!(env, key, default), do: choice!(env, key, ~w(true false), default) == "true"

  defp integer!(env, key, default, range \\ nil) do
    value = value!(env, key, default)

    unless Regex.match?(~r/\A[0-9]+\z/, value),
      do: invalid!(key, "expected a positive decimal integer")

    {number, ""} = Integer.parse(value)

    if number < 1 or (not is_nil(range) and number not in range),
      do: invalid!(key, "integer outside the allowed range")

    number
  end

  defp uri!(value, key) do
    # Reject whitespace, backslashes and malformed percent escapes before URI/Ecto
    # can raise an exception that embeds the original URL (including credentials).
    if Regex.match?(~r/[\s\\]/u, value) or Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value),
      do: invalid!(key, "invalid URL")

    case URI.new(value) do
      {:ok, uri} -> uri
      {:error, _} -> invalid!(key, "invalid URL")
    end
  end

  defp origin!(env, key) do
    uri = env |> required!(key) |> uri!(key)

    unless uri.scheme in ~w(http https) and address?(uri.host) and
             uri.port in 1..65_535 and uri.userinfo == nil and uri.query == nil and
             uri.fragment == nil and uri.path in [nil, "/"],
           do:
             invalid!(
               key,
               "expected an HTTP(S) origin without credentials, path, query or fragment"
             )

    # An explicit URI is also used by SecurityHeaders, so no authority/path data
    # supplied by the operator can become an extra CSP source or directive.
    %URI{scheme: uri.scheme, host: String.downcase(uri.host), port: uri.port}
  end

  @doc "Validate a migration URL without exposing credentials in errors."
  def migration_database!(value) when is_binary(value) do
    database!(value)
  rescue
    error in [ArgumentError, RuntimeError] ->
      _ = error
      raise ArgumentError, "MIGRATION_DATABASE_URL: invalid PostgreSQL URL"
  end

  def migration_database!(_),
    do: raise(ArgumentError, "MIGRATION_DATABASE_URL: required")

  defp database!(value) do
    key = "DATABASE_URL"
    uri = uri!(value, key)
    path = uri.path || ""
    username = uri.userinfo && uri.userinfo |> String.split(":", parts: 2) |> hd()

    unless uri.scheme in ~w(ecto postgres postgresql) and address?(uri.host) and
             (is_nil(uri.port) or uri.port in 1..65_535) and is_binary(username) and
             username != "" and Regex.match?(~r/\A\/[^\/]+\z/, path) and uri.fragment == nil,
           do: invalid!(key, "expected a PostgreSQL URL with user, host and one database name")

    for part <- [uri.userinfo, path, uri.query], not is_nil(part) do
      decoded = URI.decode(part)

      unless String.valid?(decoded) and not Regex.match?(~r/[\x00-\x1f\x7f]/, decoded),
        do: invalid!(key, "invalid URL encoding")
    end

    # This slice supports Ecto's typed options, not arbitrary query keys that
    # Ecto would turn into atoms or unsupported driver settings.
    pairs = URI.query_decoder(uri.query || "") |> Enum.to_list()
    names = Enum.map(pairs, &elem(&1, 0))
    unless length(names) == length(Enum.uniq(names)), do: invalid!(key, "duplicate URL option")

    Enum.each(pairs, fn
      {"ssl", value} when value in ~w(true false) -> :ok
      {name, value} when name in ~w(timeout idle_interval) -> integer!(%{key => value}, key, nil)
      _ -> invalid!(key, "unsupported URL option; use ssl, timeout or idle_interval")
    end)

    case List.keyfind(pairs, "ssl", 0) do
      nil -> nil
      {_, value} -> value == "true"
    end
  end

  defp address?(host) when is_binary(host) do
    dns_or_ipv4?(host) or match?({:ok, _}, :inet.parse_ipv6_address(String.to_charlist(host)))
  end

  defp address?(_), do: false

  defp dns_or_ipv4?(host) do
    if Regex.match?(~r/\A[0-9.]+\z/, host) do
      match?({:ok, _}, :inet.parse_ipv4strict_address(String.to_charlist(host)))
    else
      byte_size(host) <= 253 and
        Enum.all?(String.split(host, "."), fn label ->
          byte_size(label) in 1..63 and
            Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/, label)
        end)
    end
  end

  defp invalid!(key, reason), do: raise("Invalid runtime configuration: #{key}: #{reason}")
end
