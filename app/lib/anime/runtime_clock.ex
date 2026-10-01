defmodule Anime.RuntimeClock do
  @moduledoc """
  One application-lifetime anchor, shared by metrics and future Uptime displays.
  Capture it in Application.start, not in a child init: a child restart reuses
  the supervisor's original anchor. Elapsed time uses only the monotonic clock.
  """
  use GenServer

  def capture do
    %{started_at: System.system_time(:second), monotonic_ms: now()}
  end

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  def measure(server \\ __MODULE__), do: GenServer.call(server, :measure, 500)

  @impl true
  def init(options) do
    {:ok,
     %{anchor: Keyword.fetch!(options, :anchor), clock: Keyword.get(options, :clock, &now/0)}}
  end

  @impl true
  def handle_call(:measure, _, state) do
    elapsed = state.clock.() - state.anchor.monotonic_ms

    result =
      if elapsed >= 0,
        do: {:ok, %{started_at: state.anchor.started_at, uptime_ms: elapsed}},
        else: :unavailable

    {:reply, result, state}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
