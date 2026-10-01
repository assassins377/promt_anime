defmodule AnimeWeb.DrainingAdapter do
  @moduledoc "Bandit child specs that cannot reopen listeners once node drain begins."

  def child_specs(endpoint, config) do
    Enum.map(Bandit.PhoenixAdapter.child_specs(endpoint, config), fn spec ->
      spec
      |> Map.put_new(:modules, [elem(spec.start, 0)])
      |> Map.put(:start, {Anime.WebSupervisor, :start_endpoint, [spec.start]})
    end)
  end

  defdelegate server_info(endpoint, scheme), to: Bandit.PhoenixAdapter
end
