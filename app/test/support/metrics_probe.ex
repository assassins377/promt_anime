defmodule Anime.MetricsProbe do
  @moduledoc false
  def capture(fun) do
    ref = make_ref()
    :ok = :telemetry.attach_many(ref, Anime.Metrics.events(), &__MODULE__.record/4, {self(), ref})

    try do
      result = fun.()
      {result, collect(ref, [])}
    after
      :telemetry.detach(ref)
    end
  end

  def record(event, measurements, tags, {owner, ref}),
    do: send(owner, {ref, event, measurements, tags})

  defp collect(ref, rows) do
    receive do
      {^ref, event, m, tags} -> collect(ref, [{event, m, tags} | rows])
    after
      0 -> Enum.reverse(rows)
    end
  end

  def rows(records, key), do: for({[:anime, :metrics, ^key], m, tags} <- records, do: {m, tags})
end
