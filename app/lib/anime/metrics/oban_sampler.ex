defmodule Anime.Metrics.ObanSampler do
  @moduledoc "Bounded, read-only aggregates of the two implemented queues, never job payloads."
  import Ecto.Query
  alias Anime.Metrics
  alias Anime.Metrics.Sampler

  def child_spec(options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}
  def start_link(options), do: Sampler.start_link(__MODULE__, options)
  def poll(server \\ __MODULE__), do: Sampler.poll(server)
  def snapshot(server \\ __MODULE__), do: Sampler.snapshot(server)

  @doc false
  def read(repo \\ Anime.Repo) do
    # One SELECT snapshot; at most queue_count * state_count aggregate rows.
    # The database supplies the clock, so no comparison with a web-node clock.
    query =
      from j in Oban.Job,
        where: j.queue in ^Metrics.oban_queues() and j.state in ^Metrics.oban_states(),
        group_by: [j.queue, j.state],
        select:
          {j.queue, j.state, count(j.id),
           fragment(
             "CASE WHEN ? = 'available' THEN GREATEST(0, FLOOR(EXTRACT(EPOCH FROM ((statement_timestamp() AT TIME ZONE 'UTC') - MIN(?)))))::bigint ELSE 0 END",
             j.state,
             j.scheduled_at
           )}

    Metrics.Context.with_source(:other, fn ->
      query |> repo.all(timeout: 750, queue: false, log: false) |> from_rows()
    end)
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  @doc false
  def from_rows(rows) when is_list(rows) do
    keys = for queue <- Metrics.oban_queues(), state <- Metrics.oban_states(), do: {queue, state}
    initial = %{counts: Map.new(keys, &{&1, 0}), ages: Map.new(Metrics.oban_queues(), &{&1, 0})}

    result =
      Enum.reduce_while(rows, {initial, MapSet.new()}, fn
        {queue, state, count, age}, {values, seen} ->
          key = {queue, state}

          if key in keys and not MapSet.member?(seen, key) and
               Metrics.valid_pool_count?(count) and count > 0 and
               Metrics.valid_pool_count?(age) and (state == "available" or age == 0) do
            values = put_in(values, [:counts, key], count)

            values =
              if state == "available", do: put_in(values, [:ages, queue], age), else: values

            {:cont, {values, MapSet.put(seen, key)}}
          else
            {:halt, :unavailable}
          end

        _, _ ->
          {:halt, :unavailable}
      end)

    case result do
      {values, _seen} -> normalize({:ok, values})
      _ -> :unavailable
    end
  end

  def from_rows(_), do: :unavailable
  @doc false
  def normalize(snapshot), do: Metrics.normalize_oban_snapshot(snapshot)
  @doc false
  def publish(snapshot), do: Metrics.publish_oban_snapshot(snapshot)
  @doc false
  def guard(body, snapshot), do: Anime.Metrics.Exporter.guard_oban_snapshot(body, snapshot)
end
