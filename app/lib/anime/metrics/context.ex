defmodule Anime.Metrics.Context do
  @moduledoc "Process-local query origin. Never derives labels from request or SQL metadata."
  @key {__MODULE__, :source}
  @stack {__MODULE__, :scopes}
  @sources [:web, :live_view, :oban, :other]

  def current, do: normalize(Process.get(@key))
  def put(source), do: Process.put(@key, normalize(source))

  def with_source(source, fun) when is_function(fun, 0) do
    previous = current()
    put(source)

    try do
      fun.()
    after
      put(previous)
    end
  end

  # LiveView/Oban telemetry spans execute synchronously in the caller. A stack
  # preserves static LiveView inside HTTP and nested inline jobs inside a view.
  def enter(scope, source) do
    Process.put(@stack, [{scope, current()} | Process.get(@stack, [])])
    put(source)
    :ok
  end

  def leave(scope) do
    case Process.get(@stack, []) do
      [{^scope, previous} | rest] ->
        if rest == [], do: Process.delete(@stack), else: Process.put(@stack, rest)
        put(previous)

      _ ->
        :ok
    end

    :ok
  end

  defp normalize(source) when source in @sources, do: source
  defp normalize(_), do: :other
end
