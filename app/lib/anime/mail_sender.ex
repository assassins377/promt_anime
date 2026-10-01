defmodule Anime.MailSender do
  @moduledoc "Reads the configured sender and rejects foreign domains and header injection."

  def load do
    host = URI.parse(Application.fetch_env!(:anime, :site_origin)).host
    name = Anime.Settings.get("email_from_name")
    address = Anime.Settings.get("email_from_address")
    validate(name, address, host)
  end

  def validate(name, address, host)
      when is_binary(name) and is_binary(address) and is_binary(host) do
    with true <- String.valid?(name) and String.valid?(address),
         true <- String.length(String.trim(name)) in 1..64,
         false <- Regex.match?(~r/[\x00-\x1f\x7f]/, name <> address),
         true <- byte_size(address) <= 254,
         [local, domain] <- String.split(address, "@"),
         true <- valid_local?(local),
         true <- valid_domain?(domain),
         normalized = String.downcase(domain),
         site = String.downcase(host),
         true <- normalized == site or String.ends_with?(normalized, "." <> site) do
      {:ok, {name, local <> "@" <> normalized}}
    else
      _ -> {:error, :invalid_mail_sender}
    end
  end

  def validate(_, _, _), do: {:error, :invalid_mail_sender}

  def envelope(%Swoosh.Email{from: {_, sender}} = email) do
    case Application.get_env(:anime, :mail_return_path) do
      nil ->
        if Application.get_env(:anime, :app_env) in ["dev", "test"],
          do: email,
          else: raise(ArgumentError, "MAIL_RETURN_PATH: required")

      address ->
        [_, domain] = String.split(sender, "@")

        case validate("Return path", address, domain) do
          {:ok, {_, normalized}} ->
            if List.last(String.split(normalized, "@")) != String.downcase(domain),
              do: raise(ArgumentError, "MAIL_RETURN_PATH: must match sender domain")

            # Swoosh's SMTP adapter uses Sender as the SMTP envelope MAIL FROM;
            # the receiving server, not this application, writes Return-Path.
            Swoosh.Email.header(email, "Sender", normalized)

          _ ->
            raise ArgumentError, "MAIL_RETURN_PATH: invalid sender domain"
        end
    end
  end

  defp valid_local?(local) do
    byte_size(local) in 1..64 and
      Regex.match?(~r/\A[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+\z/, local) and
      not String.starts_with?(local, ".") and not String.ends_with?(local, ".") and
      not String.contains?(local, "..")
  end

  defp valid_domain?(domain) do
    domain
    |> String.split(".")
    |> Enum.all?(fn label ->
      byte_size(label) in 1..63 and
        Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/, label)
    end)
  end
end
