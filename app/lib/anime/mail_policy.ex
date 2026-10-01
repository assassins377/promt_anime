defmodule Anime.MailPolicy do
  @moduledoc "Exact staging recipient allowlist; no network access or delivery."

  def parse!(value) when is_binary(value) do
    if not String.valid?(value) or Regex.match?(~r/[\x00-\x1f\x7f]/, value),
      do: raise(ArgumentError, "STAGING_MAIL_ALLOWLIST: invalid address list")

    addresses = value |> String.split(",") |> Enum.map(&String.trim/1)

    unless addresses != [] and Enum.all?(addresses, &address?/1) do
      raise ArgumentError, "STAGING_MAIL_ALLOWLIST: expected comma-separated email addresses"
    end

    addresses |> Enum.map(&String.downcase/1) |> MapSet.new()
  end

  def parse!(_),
    do: raise(ArgumentError, "STAGING_MAIL_ALLOWLIST: required for staging")

  def allowed?(address) do
    case Application.get_env(:anime, :app_env) do
      "staging" ->
        allowlist = Application.get_env(:anime, :staging_mail_allowlist)

        is_binary(address) and match?(%MapSet{}, allowlist) and
          MapSet.member?(allowlist, String.downcase(address))

      env when env in ["dev", "prod", "test"] ->
        true

      _ ->
        false
    end
  end

  defp address?(value) do
    String.valid?(value) and byte_size(value) <= 254 and
      Regex.match?(
        ~r/\A[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}\z/,
        value
      ) and
      not String.contains?(value, ["*", "..", " ", "\r", "\n", "\t"])
  end
end
