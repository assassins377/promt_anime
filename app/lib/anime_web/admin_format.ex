defmodule AnimeWeb.AdminFormat do
  @moduledoc "Presentation-only RU/EN formatting. Language never changes the UTC timezone."

  def datetime(value, locale, seconds \\ false) do
    case utc(value) do
      nil ->
        nil

      dt ->
        date = if locale == "en", do: "%b %d, %Y", else: "%d.%m.%Y"
        time = if seconds, do: "%H:%M:%S", else: "%H:%M"
        separator = if locale == "en", do: ", ", else: " "

        %{
          text: Calendar.strftime(dt, date <> separator <> time <> " UTC"),
          iso: DateTime.to_iso8601(dt),
          title: DateTime.to_iso8601(dt) <> " (UTC)"
        }
    end
  end

  def number(value, locale) when is_integer(value) do
    separator = if locale == "en", do: ",", else: "\u00a0"

    digits =
      value
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(separator, &Enum.join/1)
      |> String.reverse()

    if value < 0, do: "-" <> digits, else: digits
  end

  defp utc(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")

  defp utc(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp utc(_), do: nil
end
