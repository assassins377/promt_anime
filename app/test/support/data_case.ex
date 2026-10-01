defmodule Anime.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      alias Anime.Repo
      import Anime.Fixtures
    end
  end

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Anime.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, _} = Anime.Seeds.defaults()
    :ok
  end
end
