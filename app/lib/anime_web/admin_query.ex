defmodule AnimeWeb.AdminQuery do
  @moduledoc "Bounded query state shared by existing admin lists. Never grants access."
  def clean(params, keys) do
    params
    |> Map.take(keys)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      value = normalize(key, value)
      if value in [nil, "", []], do: acc, else: Map.put(acc, key, value)
    end)
  end

  def url(path, params) do
    query =
      params
      |> Enum.reject(fn {k, v} -> v in [nil, "", []] or (k == "page" and v in [1, "1"]) end)
      |> Map.new()

    if query == %{}, do: path, else: path <> "?" <> Plug.Conn.Query.encode(query)
  end

  def remove(params, key, value) do
    params = Map.delete(params, "page")

    case params[key] do
      items when is_list(items) -> Map.put(params, key, List.delete(items, value))
      _ -> Map.delete(params, key)
    end
  end

  def sort_query(params, columns) do
    case params["sort"] do
      nil ->
        params

      column when is_binary(column) ->
        if column in columns, do: params, else: Map.drop(params, ["sort", "dir"])

      _ ->
        Map.drop(params, ["sort", "dir"])
    end
  end

  def page(params) do
    case normalize("page", params["page"]) do
      nil -> 1
      value -> String.to_integer(value)
    end
  end

  defp normalize("q", value) when is_binary(value) do
    q = value |> String.trim() |> String.slice(0, 100)
    if String.length(q) >= 2, do: q
  end

  defp normalize(key, value) when key in ~w(page user_id role blocked_by) and is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 and n < 9_223_372_036_854_775_807 ->
        if key != "page" or n != 1, do: to_string(n)

      _ ->
        if key == "blocked_by" and value == "missing", do: value
    end
  end

  defp normalize(key, value) when key in ~w(from to) and is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Date.to_iso8601(date)
      _ -> nil
    end
  end

  defp normalize(key, value) when key in ~w(status result action) do
    allowed =
      case key do
        "status" -> ~w(active blocked)
        "result" -> ~w(success denied error)
        "action" -> Anime.Accounts.Activity.actions()
      end

    value |> List.wrap() |> Enum.filter(&(&1 in allowed)) |> Enum.uniq()
  end

  defp normalize("ip", v) when is_binary(v), do: String.slice(String.trim(v), 0, 64)
  defp normalize("confirmed", v) when v in ~w(yes no), do: v
  defp normalize("term", v) when v in ~w(permanent temporary), do: v
  defp normalize(k, "true") when k in ~w(deletion supporter), do: "true"
  defp normalize("dir", v) when v in ~w(asc desc), do: v

  defp normalize("sort", v)
       when v in ~w(id nick role status inserted_at blocked_at occurred_at code position), do: v

  defp normalize("group", v) when is_binary(v) do
    if Enum.any?(Anime.Access.Catalog.codes(), &(hd(String.split(&1, ".")) == v)), do: v
  end

  defp normalize(_, _), do: nil
end
