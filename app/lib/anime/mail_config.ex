defmodule Anime.MailConfig do
  @moduledoc "Mail preflight without network calls; diagnostics never contain supplied values."
  @derive {Inspect, only: [:adapter]}
  defstruct [:adapter, :options, :return_path]

  def load!(env, environment, site_host) when environment in ["dev", "test", "staging", "prod"] do
    expected =
      case environment do
        "dev" -> "local"
        "test" -> "test"
        _ -> "smtp"
      end

    if Map.get(env, "MAIL_ADAPTER", expected) != expected,
      do: invalid!("MAIL_ADAPTER")

    case expected do
      "local" -> %__MODULE__{adapter: :local, options: [adapter: Swoosh.Adapters.Local]}
      "test" -> %__MODULE__{adapter: :test, options: [adapter: Swoosh.Adapters.Test]}
      "smtp" -> smtp!(env, site_host)
    end
  end

  defp smtp!(env, site_host) do
    host = required!(env, "SMTP_HOST")

    unless Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/, host),
      do: invalid!("SMTP_HOST")

    port = Map.get(env, "SMTP_PORT", "587")
    unless is_binary(port) and Regex.match?(~r/\A[0-9]{1,5}\z/, port), do: invalid!("SMTP_PORT")
    port = String.to_integer(port)
    unless port in 1..65535, do: invalid!("SMTP_PORT")

    tls =
      case Map.get(env, "SMTP_TLS", "always") do
        "always" -> :always
        "never" -> :never
        _ -> invalid!("SMTP_TLS")
      end

    username = required!(env, "SMTP_USERNAME")
    password = required!(env, "SMTP_PASSWORD")
    path = required!(env, "MAIL_RETURN_PATH")

    path =
      case Anime.MailSender.validate("Return path", path, site_host) do
        {:ok, {_, normalized}} -> normalized
        _ -> invalid!("MAIL_RETURN_PATH")
      end

    %__MODULE__{
      adapter: :smtp,
      return_path: path,
      options: [
        adapter: Swoosh.Adapters.SMTP,
        relay: host,
        port: port,
        username: username,
        password: password,
        auth: :always,
        tls: tls,
        ssl: false,
        retries: 0,
        no_mx_lookups: true,
        tls_options: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(host),
          depth: 99,
          versions: [:"tlsv1.2", :"tlsv1.3"],
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]
    }
  end

  defp required!(env, key) do
    value = Map.get(env, key)

    unless is_binary(value) and String.valid?(value) and String.trim(value) != "" and
             not Regex.match?(~r/[\x00-\x1f\x7f]/, value),
           do: invalid!(key)

    value
  end

  defp invalid!(key), do: raise(ArgumentError, key <> ": invalid or missing mail configuration")
end
