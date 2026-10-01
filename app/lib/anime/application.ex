defmodule Anime.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Anime.Shutdown.reset()

    children = [
      {Anime.RuntimeClock, anchor: Anime.RuntimeClock.capture()},
      Anime.LogTelemetry,
      {Anime.Metrics.Exporter, []},
      Anime.Metrics,
      Anime.Repo,
      {Anime.Metrics.PostgresSampler, []},
      {Anime.Metrics.DatabaseSizeSampler, []},
      {Anime.Metrics.DatabaseActivitySampler, []},
      {Anime.Metrics.PoolSampler, []},
      {Anime.Metrics.VMSampler, []},
      {Anime.Metrics.SchedulerSampler, []},
      {Phoenix.PubSub, name: Anime.PubSub},
      Anime.Cache,
      {Anime.Metrics.CacheSampler, []},
      Anime.Passwords,
      {Task.Supervisor, name: Anime.Tasks},
      {Oban, Application.fetch_env!(:anime, Oban)},
      {Anime.Metrics.ObanSampler, []},
      AnimeWeb.Endpoint
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: Anime.Supervisor) do
      {:ok, _pid} = result ->
        Anime.Log.emit(:application_started)
        result

      error ->
        error
    end
  end

  @impl true
  def prep_stop(state) do
    if Application.get_env(:anime, AnimeWeb.Endpoint, [])[:server], do: Anime.Shutdown.prepare()
    state
  end

  @impl true
  def stop(_), do: Anime.Log.emit(:application_stopped)

  @impl true
  def config_change(changed, _new, removed), do: AnimeWeb.Endpoint.config_change(changed, removed)
end
