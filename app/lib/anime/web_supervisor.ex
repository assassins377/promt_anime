defmodule Anime.WebSupervisor do
  @moduledoc "Restart the endpoint after transport tracking loss, never keep untracked connections."
  use Supervisor

  def start_link(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    endpoint = Supervisor.child_spec(Keyword.get(opts, :endpoint, AnimeWeb.Endpoint), [])
    endpoint = Map.put_new(endpoint, :modules, [elem(endpoint.start, 0)])
    endpoint = %{endpoint | start: {__MODULE__, :start_endpoint, [endpoint.start]}}

    children = [
      {Anime.LiveTransports, name: Keyword.get(opts, :transports_name, Anime.LiveTransports)},
      endpoint
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def start_endpoint({module, function, args}) do
    if Anime.Shutdown.rejecting?(), do: :ignore, else: apply(module, function, args)
  end
end
