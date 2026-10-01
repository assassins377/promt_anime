defmodule Anime.Background do
  @moduledoc "Separate supervisor boundary for draining Oban concurrently with the endpoint."
  use Supervisor

  def start_link(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    config = Keyword.get_lazy(opts, :oban, fn -> Application.fetch_env!(:anime, Oban) end)
    child = Supervisor.child_spec({Oban, config}, id: Oban)
    Supervisor.init([child], strategy: :one_for_one)
  end

  def drain(supervisor \\ __MODULE__, tasks \\ Anime.Tasks) do
    # terminate_child intentionally removes the running child without restarting
    # it; stopping a permanent Oban process directly would restart it instead.
    Task.Supervisor.start_child(tasks, fn ->
      :ok = Supervisor.terminate_child(supervisor, Oban)
    end)
  end
end
