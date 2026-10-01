defmodule AnimeWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint AnimeWeb.Endpoint
      import Phoenix.ConnTest
      import Plug.Conn
      import Phoenix.LiveViewTest
      import Anime.Fixtures
      alias Anime.Repo
    end
  end

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Anime.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, _} = Anime.Seeds.defaults()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
