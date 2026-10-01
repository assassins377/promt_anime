defmodule AnimeWeb.Locale do
  @moduledoc "Locale preferences and URL operations shared by HTTP and LiveView."

  @service_roots ~w(admin locale logout healthz readyz robots.txt dev)

  def preferred(user, cookies, accept_language) do
    normalize(user && user.locale) || normalize(cookies["locale"]) ||
      from_accept_language(accept_language)
  end

  def normalize(locale) when locale in ["ru", :ru], do: "ru"
  def normalize(locale) when locale in ["en", :en], do: "en"
  def normalize(_), do: nil

  # Error pages can run before the browser pipeline, without a session or DB.
  # p.20 explicitly gives unknown unprefixed URLs the guest cookie locale.
  def error_locale(conn) do
    if path_locale(conn.request_path) == "en" do
      "en"
    else
      conn = Plug.Conn.fetch_cookies(conn)
      normalize(conn.cookies["locale"]) || "ru"
    end
  end

  def path_locale(path) do
    if path == "/en" || String.starts_with?(path, "/en/"), do: "en", else: "ru"
  end

  def service?(path) do
    path |> String.split("/", trim: true) |> List.first() |> then(&(&1 in @service_roots))
  end

  # q=0 excludes a range. Unsupported/malformed ranges are ignored; ties retain
  # header order. No arbitrary language tag is converted to an atom.
  def from_accept_language(headers) when is_list(headers) do
    headers
    |> Enum.join(",")
    |> String.slice(0, 8192)
    |> String.split(",")
    |> Enum.take(64)
    |> Enum.with_index()
    |> Enum.flat_map(fn {range, index} ->
      case range |> String.trim() |> String.downcase() |> parse_range() do
        {locale, q} when q > 0 -> [{locale, q, index}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_, q, index} -> {-q, index} end)
    |> case do
      [{locale, _, _} | _] -> locale
      [] -> "ru"
    end
  end

  def from_accept_language(_), do: "ru"

  defp parse_range(range) do
    case String.split(range, ";", trim: true) |> Enum.map(&String.trim/1) do
      [tag] ->
        language_range(tag, 1.0)

      [tag, "q=" <> quality] ->
        if Regex.match?(~r/\A(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\z/, quality) do
          {q, _} = Float.parse(quality)
          language_range(tag, q)
        end

      _ ->
        nil
    end
  end

  defp language_range(tag, q) do
    if Regex.match?(~r/\A(?:ru|en)(?:-[a-z0-9]{1,8})*\z/, tag),
      do: {String.slice(tag, 0, 2), q}
  end

  def current_path(%Plug.Conn{} = conn) do
    join_query(conn.request_path, conn.query_string)
  end

  def current_path(uri) when is_binary(uri) do
    parsed = URI.parse(uri)
    join_query(parsed.path || "/", parsed.query)
  end

  defp join_query(path, query) when query in [nil, ""], do: path
  defp join_query(path, query), do: path <> "?" <> query

  def localized(locale, url) do
    uri = URI.parse(url)
    path = strip_prefix(uri.path || "/")

    path =
      if locale == "en" && !service?(path),
        do: if(path == "/", do: "/en", else: "/en" <> path),
        else: path

    URI.to_string(%{uri | path: path})
  end

  # Validate both sides of stripping /en: /en//host must not become //host.
  # Auth.safe_return also excludes the admin area as required by the spec.
  def switch_path(locale, value) do
    value
    |> AnimeWeb.Auth.safe_return()
    |> then(&localized("ru", &1))
    |> AnimeWeb.Auth.safe_return()
    |> then(&localized(locale, &1))
  end

  defp strip_prefix("/en"), do: "/"
  defp strip_prefix("/en/" <> path), do: "/" <> path
  defp strip_prefix(path), do: path
end
