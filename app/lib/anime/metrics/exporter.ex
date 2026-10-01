defmodule Anime.Metrics.Exporter do
  @moduledoc "Local-only reporter and optional dedicated listener, outside Phoenix."
  use Supervisor

  @reporter Anime.Metrics.Reporter

  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    config = Keyword.merge(Application.get_env(:anime, __MODULE__, []), options)
    metrics = Anime.Metrics.definitions()

    reporter = %{id: @reporter, start: {__MODULE__, :start_reporter, [metrics]}}

    listener =
      if Keyword.get(config, :server, false),
        do: [listener_spec(Keyword.get(config, :port, 9568))],
        else: []

    Supervisor.init([reporter | listener], strategy: :rest_for_one)
  end

  @doc false
  def start_reporter(metrics) do
    # An untrappable kill skips Core's terminate callback. Detach its dead
    # owner's handlers before reusing the named tables, otherwise counts double.
    for event <- Enum.uniq(Enum.map(metrics, & &1.event_name)),
        handler <- :telemetry.list_handlers(event) do
      case handler do
        %{
          id: {TelemetryMetricsPrometheus.Core.EventHandler, owner, _},
          config: %{table: @reporter}
        }
        when is_pid(owner) ->
          unless Process.alive?(owner), do: :telemetry.detach(handler.id)

        _ ->
          :ok
      end
    end

    result =
      TelemetryMetricsPrometheus.Core.start_link(
        name: @reporter,
        metrics: metrics,
        start_async: false
      )

    if match?({:ok, _}, result), do: Anime.Metrics.publish_runtime_versions()
    result
  end

  def scrape,
    do:
      scrape(
        Anime.Metrics.PoolSampler,
        Anime.Metrics.VMSampler,
        Anime.Metrics.SchedulerSampler,
        Anime.Metrics.CacheSampler,
        Anime.Metrics.ObanSampler,
        Anime.Metrics.PostgresSampler,
        Anime.Metrics.DatabaseSizeSampler,
        Anime.Metrics.DatabaseActivitySampler,
        @reporter
      )

  @doc false
  def scrape(pool, vm, scheduler, cache, oban, postgres, size, activity, reporter) do
    render = fn -> scrape(pool, vm, scheduler, cache, oban, postgres, size, reporter) end
    render_postgres(activity, :activity, render, 11_500)
  end

  @doc false
  def scrape(pool, vm, scheduler, cache, oban, postgres, size, reporter) do
    render = fn -> scrape(pool, vm, scheduler, cache, oban, reporter) end
    metadata = fn -> render_postgres(postgres, :metadata, render, 8_500) end
    render_postgres(size, :size, metadata, 10_000)
  end

  defp render_postgres(server, kind, render, timeout) do
    result =
      try do
        Anime.Metrics.Sampler.render(server, render, timeout)
      catch
        :exit, _ -> :sampler_unavailable
      end

    case result do
      {:ok, body} -> body
      :reporter_unavailable -> raise "Metrics unavailable"
      :sampler_unavailable -> guard_postgres_snapshot(render.(), kind, :unavailable)
    end
  end

  @doc false
  def guard_postgres_snapshot(body, kind, snapshot) do
    case Anime.Metrics.normalize_postgres_snapshot(kind, snapshot) do
      {:ok, %{version_number: version}} ->
        omit_families(body, ["anime_postgres_info"], Anime.Metrics.postgres_info_text(version))

      {:ok, _} ->
        body

      :unavailable ->
        omit_families(
          body,
          Anime.Metrics.postgres_metric_names(kind),
          Anime.Metrics.postgres_unavailable_text(kind)
        )
    end
  end

  @doc false
  def scrape(pool, vm, scheduler, cache, oban, reporter) do
    render = fn -> scrape(pool, vm, scheduler, cache, reporter) end

    result =
      try do
        Anime.Metrics.Sampler.render(oban, render, 7_000)
      catch
        :exit, _ -> :sampler_unavailable
      end

    case result do
      {:ok, body} -> body
      :reporter_unavailable -> raise "Metrics unavailable"
      :sampler_unavailable -> guard_oban_snapshot(render.(), :unavailable)
    end
  end

  @doc false
  def scrape(pool, vm, scheduler, cache, reporter) do
    render = fn -> scrape(pool, vm, scheduler, reporter) end

    result =
      try do
        Anime.Metrics.Sampler.render(cache, render, 5_500)
      catch
        :exit, _ -> :sampler_unavailable
      end

    case result do
      {:ok, body} -> body
      :reporter_unavailable -> raise "Metrics unavailable"
      :sampler_unavailable -> guard_cache_snapshot(render.(), :unavailable)
    end
  end

  @doc false
  def scrape(pool, vm, scheduler, reporter) do
    render = fn -> scrape(pool, vm, reporter) end

    result =
      try do
        Anime.Metrics.Sampler.render(scheduler, render, 4_000)
      catch
        :exit, _ -> :sampler_unavailable
      end

    case result do
      {:ok, body} -> body
      :reporter_unavailable -> raise "Metrics unavailable"
      :sampler_unavailable -> guard_scheduler_snapshot(render.(), :unavailable)
    end
  end

  @doc false
  def scrape(pool, vm, reporter) do
    # Fixed nesting order avoids cycles. Each sampler serializes its own snapshot
    # publication with this render; neither performs resource reads on scrape.
    render = fn -> scrape(pool, reporter) end

    result =
      try do
        # Allow the inner pool's 1s deadline to resolve independently of VM data.
        Anime.Metrics.Sampler.render(vm, render, 2_500)
      catch
        :exit, _ -> :sampler_unavailable
      end

    case result do
      {:ok, body} -> body
      :reporter_unavailable -> raise "Metrics unavailable"
      :sampler_unavailable -> guard_vm_snapshot(render.(), :unavailable)
    end
  end

  @doc false
  def scrape(sampler, reporter) do
    result =
      try do
        Anime.Metrics.PoolSampler.scrape(sampler, reporter)
      catch
        :exit, _ -> :sampler_unavailable
      end

    case result do
      {:ok, body} ->
        body

      :reporter_unavailable ->
        raise "Metrics unavailable"

      :sampler_unavailable ->
        reporter
        |> TelemetryMetricsPrometheus.Core.scrape()
        |> guard_pool_snapshot(:unavailable)
    end
  end

  @doc false
  def guard_pool_snapshot(body, {:ok, _}), do: body

  def guard_pool_snapshot(body, :unavailable) do
    omit_families(body, Anime.Metrics.pool_metric_names(), Anime.Metrics.pool_unavailable_text())
  end

  @doc false
  def guard_vm_snapshot(body, {:ok, _}), do: body

  def guard_vm_snapshot(body, :unavailable) do
    omit_families(body, Anime.Metrics.vm_metric_names(), Anime.Metrics.vm_unavailable_text())
  end

  @doc false
  def guard_oban_snapshot(body, {:ok, _}), do: body

  def guard_oban_snapshot(body, :unavailable),
    do:
      omit_families(
        body,
        Anime.Metrics.oban_metric_names(),
        Anime.Metrics.oban_unavailable_text()
      )

  @doc false
  def guard_cache_snapshot(body, snapshot) do
    values =
      case Anime.Metrics.normalize_cache_snapshot(snapshot) do
        {:ok, values} -> values
        :unavailable -> %{}
      end

    missing =
      Enum.filter(Anime.Cache.inventory(), fn table ->
        Map.get(values, table, :unavailable) == :unavailable
      end)

    cond do
      missing == [] ->
        body

      missing == Anime.Cache.inventory() ->
        omit_families(
          body,
          Anime.Metrics.cache_metric_names(),
          Anime.Metrics.cache_unavailable_text(missing)
        )

      true ->
        # Retain fresh tables and replace only missing tables' fixed label rows.
        names = Anime.Metrics.cache_metric_names()

        body
        |> String.split("\n", trim: true)
        |> Enum.reject(fn line ->
          Enum.any?(names, &String.starts_with?(line, &1 <> "{")) and
            Enum.any?(missing, &String.contains?(line, ~s(table="#{&1}")))
        end)
        |> Enum.map_join("", &(&1 <> "\n"))
        |> Kernel.<>(
          Enum.map_join(missing, "", fn table ->
            "anime_cache_snapshot_available{table=\"#{table}\"} 0\n"
          end)
        )
    end
  end

  @doc false
  def guard_scheduler_snapshot(body, :unavailable) do
    names =
      Enum.map(
        [
          :scheduler_run_queue_length,
          :scheduler_utilization_ratio,
          :scheduler_snapshot_available
        ],
        &Anime.Metrics.scheduler_metric_name/1
      )

    omit_families(body, names, Anime.Metrics.scheduler_availability_text(0, 0))
  end

  def guard_scheduler_snapshot(body, {:ok, %{utilization: nil}}) do
    names =
      Enum.map(
        [:scheduler_utilization_ratio, :scheduler_snapshot_available],
        &Anime.Metrics.scheduler_metric_name/1
      )

    omit_families(body, names, Anime.Metrics.scheduler_availability_text(1, 0))
  end

  def guard_scheduler_snapshot(body, {:ok, %{utilization: values}}) do
    # Core retains old label sets: remove schedulers taken offline since its
    # last sample. Labels are our fixed numeric IDs/kinds, never user input.
    name = Anime.Metrics.scheduler_metric_name(:scheduler_utilization_ratio)
    valid = MapSet.new(Enum.map(values, fn {tags, _} -> {tags.id, tags.kind} end))

    body
    |> String.split("\n", trim: true)
    |> Enum.reject(fn line ->
      if String.starts_with?(line, name <> "{") do
        with [_, id] <- Regex.run(~r/\bid="([0-9]+)"/, line),
             [_, kind] <- Regex.run(~r/\bkind="(normal|dirty_cpu|dirty_io)"/, line) do
          not MapSet.member?(valid, {id, kind})
        else
          _ -> true
        end
      else
        false
      end
    end)
    |> Enum.map_join("", &(&1 <> "\n"))
  end

  defp omit_families(body, names, unavailable_text) do
    # Core 1.2.1 has no public gauge expiry/removal API. Omit only this group's
    # exact families, including labelled rows. Never invent zero resource usage.

    body
    |> String.split("\n", trim: true)
    |> Enum.reject(fn line ->
      Enum.any?(names, fn name ->
        String.starts_with?(line, [
          name <> " ",
          name <> "{",
          "# HELP " <> name <> " ",
          "# TYPE " <> name <> " "
        ])
      end)
    end)
    |> Enum.map_join("", &(&1 <> "\n"))
    |> Kernel.<>(unavailable_text)
  end

  @doc false
  def listener_spec(port) when is_integer(port) and port in 0..65_535 do
    # This slice only permits dev/web. No configurable wildcard/public bind.
    # Port 0 is used solely by isolated listener tests; runtime requires 1..65535.
    Supervisor.child_spec(
      {Bandit,
       plug: AnimeWeb.MetricsPlug,
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false,
       http_options: [log_exceptions_with_status_codes: [], log_protocol_errors: false],
       http_2_options: [enabled: false],
       thousand_island_options: [num_acceptors: 2, read_timeout: 5_000]},
      id: Anime.Metrics.Listener
    )
  end
end
