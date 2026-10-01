defmodule Anime.Settings do
  alias Anime.{Repo, Settings.Setting}

  def get(key, default \\ nil) do
    case Repo.get_by(Setting, key: key) do
      nil -> default
      %{value_type: :boolean, value: v} -> v == "true"
      %{value_type: :integer, value: v} -> String.to_integer(v)
      %{value_type: :json, value: v} -> Jason.decode!(v)
      %{value: v} -> v
    end
  end
end
