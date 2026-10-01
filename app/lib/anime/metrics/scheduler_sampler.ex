defmodule Anime.Metrics.SchedulerSampler do
  @moduledoc """
  Bounded scheduler observations. Retains one baseline for interval ratios, not
  a history. The sampler process owns its wall-time reference; worker exits do
  not disable it, and stopping the sampler releases it automatically in OTP.
  """
  alias Anime.Metrics
  alias Anime.Metrics.Sampler

  def child_spec(options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}
  def start_link(options), do: Sampler.start_link(__MODULE__, options)
  def poll(server \\ __MODULE__), do: Sampler.poll(server)
  def snapshot(server \\ __MODULE__), do: Sampler.snapshot(server)

  @doc false
  def init_sampling do
    :erlang.system_flag(:scheduler_wall_time, true)
    nil
  end

  @doc false
  def read do
    topology = Metrics.scheduler_topology()
    online = online()
    queues = :erlang.statistics(:run_queue_lengths_all)
    wall = :erlang.statistics(:scheduler_wall_time_all)

    if online == online(),
      do: {:ok, %{topology: topology, online: online, queues: queues, wall: wall}},
      else: :unavailable
  end

  defp online do
    %{
      normal: :erlang.system_info(:schedulers_online),
      dirty_cpu: :erlang.system_info(:dirty_cpu_schedulers_online)
    }
  end

  @doc false
  def normalize(result), do: normalize(result, Metrics.scheduler_topology())

  @doc false
  def normalize(
        {:ok, %{topology: topology, online: online, queues: queues, wall: wall}},
        expected
      )
      when topology == expected and is_map(online) and is_list(queues) do
    tags = Metrics.scheduler_domains(expected).scheduler_run_queue_length

    if valid_online?(online, expected) and length(queues) == length(tags) and
         Enum.all?(queues, &Metrics.valid_pool_count?/1) do
      {:ok,
       %{
         topology: expected,
         online: Map.take(online, [:normal, :dirty_cpu]),
         queues: Enum.zip(tags, queues),
         wall: normalize_wall(wall, expected)
       }}
    else
      :unavailable
    end
  end

  def normalize(_, _), do: :unavailable

  defp valid_online?(online, topology) do
    is_integer(online[:normal]) and online.normal >= 1 and online.normal <= topology.normal and
      is_integer(online[:dirty_cpu]) and online.dirty_cpu >= 1 and
      online.dirty_cpu <= topology.dirty_cpu
  end

  defp normalize_wall(wall, topology) when is_list(wall) do
    count = topology.normal + topology.dirty_cpu + topology.dirty_io

    if length(wall) == count and Enum.all?(wall, &valid_wall_row?(&1, count)) do
      indexed = Map.new(wall, fn {id, active, total} -> {id, {active, total}} end)
      if map_size(indexed) == count, do: indexed
    end
  end

  defp normalize_wall(_, _), do: nil

  defp valid_wall_row?({id, active, total}, count) do
    is_integer(id) and id >= 1 and id <= count and
      is_integer(active) and is_integer(total) and active >= 0 and total >= active and
      total <= 18_446_744_073_709_551_615
  end

  defp valid_wall_row?(_, _), do: false

  @doc false
  def project({:ok, current}, previous, measured_at, max_age) do
    utilization = utilization(current, previous, measured_at, max_age)
    baseline = if current.wall, do: {current, measured_at}
    {{:ok, %{queues: current.queues, utilization: utilization}}, baseline}
  end

  def project(:unavailable, _, _, _), do: {:unavailable, nil}

  defp utilization(current, {old, measured_at}, now, max_age)
       when now > measured_at and now - measured_at < max_age and
              current.topology == old.topology and current.online == old.online and
              is_map(current.wall) and is_map(old.wall) do
    rows =
      for {id, {active, total}} <- Enum.sort(current.wall), online?(id, current) do
        {old_active, old_total} = Map.fetch!(old.wall, id)
        da = active - old_active
        dt = total - old_total

        if dt > 0 and da >= 0 and da <= dt,
          do: {scheduler_tag(id, current.topology), da / dt}
      end

    if rows != [] and Enum.all?(rows, &(not is_nil(&1))), do: rows
  end

  defp utilization(_, _, _, _), do: nil

  defp online?(id, %{topology: t, online: o}) do
    id <= o.normal or (id > t.normal and id <= t.normal + o.dirty_cpu) or
      id > t.normal + t.dirty_cpu
  end

  defp scheduler_tag(id, t) do
    cond do
      id <= t.normal -> %{kind: "normal", id: Integer.to_string(id)}
      id <= t.normal + t.dirty_cpu -> %{kind: "dirty_cpu", id: Integer.to_string(id - t.normal)}
      true -> %{kind: "dirty_io", id: Integer.to_string(id - t.normal - t.dirty_cpu)}
    end
  end

  @doc false
  def publish(snapshot), do: Metrics.publish_scheduler_snapshot(snapshot)
  @doc false
  def guard(body, snapshot), do: Anime.Metrics.Exporter.guard_scheduler_snapshot(body, snapshot)
end
