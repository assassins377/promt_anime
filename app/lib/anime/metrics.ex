defmodule Anime.Metrics do
  @moduledoc """
  Privacy boundary for metrics. Subscribe to events/0, never raw framework events.

  This process owns subscriptions only. Prometheus definitions below consume
  that safe projection, never raw framework metadata. No database reads.
  Projection measurements use milliseconds; sums use integer microseconds.
  All output is reconstructed from finite label domains; IDs are never labels.
  """
  use GenServer
  alias Anime.Metrics.Context

  @prefix [:anime, :metrics]
  @source_events [
                   [:phoenix, :endpoint, :stop],
                   [:phoenix, :router_dispatch, :stop],
                   [:phoenix, :router_dispatch, :exception],
                   [:oban, :job, :stop],
                   [:oban, :job, :exception],
                   [:oban, :job, :start],
                   [:anime, :repo, :query],
                   [:anime, :repo, :checkout_timeout],
                   [:anime, :client_ip, :rejected],
                   [:anime, :access, :denied],
                   [:anime, :rate_limit, :rejected]
                 ] ++
                   for(
                     stage <- [:mount, :handle_params, :handle_event],
                     phase <- [:start, :stop, :exception],
                     do: [:phoenix, :live_view, stage, phase]
                   )

  @view_events %{
    AnimeWeb.AuthLive => ~w(validate submit),
    AnimeWeb.ProfileLive =>
      ~w(confirm revoke revoke_others preferences validate_nick validate_email validate_deletion change_nick change_email resend_email cancel_email delete_account),
    AnimeWeb.PlaceholderLive => [],
    AnimeWeb.AdminIndexLive => ~w(admin_locale),
    AnimeWeb.AdminLive => ~w(admin_locale),
    AnimeWeb.ContentPlaceholderLive => ~w(admin_locale),
    AnimeWeb.UsersLive =>
      ~w(filter select select_page prepare_bulk cancel_bulk confirm_bulk admin_locale retry_list),
    AnimeWeb.UserActivityLive => ~w(activity_filter admin_locale retry_list),
    AnimeWeb.UserAdminLive =>
      ~w(prepare cancel confirm validate_edit activity_filter admin_locale),
    AnimeWeb.RolesLive =>
      ~w(filter page new edit cancel_edit validate save prepare cancel confirm admin_locale retry_list),
    AnimeWeb.PermissionsLive => ~w(filter admin_locale retry_list),
    AnimeWeb.MatrixLive => ~w(filter change review cancel reset save admin_locale)
  }
  @workers ~w(Anime.Workers.Mail Anime.Workers.ExpireAccounts Anime.Workers.UnblockUsers Anime.Workers.DeleteAccounts)
  @scopes ~w(login login_ip register confirm_resend password_reset comment_post rating_change video_report donation_create feedback_create feedback_reply data_export admin_test_email admin_cron_run)
  @states [:success, :cancelled, :snoozed, :discard, :failure, :exhausted]
  @unknown "[unknown]"
  @db_sources ~w(web live_view oban other)
  @db_phases [:total_time, :query_time, :queue_time, :decode_time, :idle_time]
  @pool_gauges %{
    db_pool_ready: "Ready connections in the latest fresh pool snapshot.",
    db_pool_waiting: "Requests waiting for checkout in the latest fresh pool snapshot.",
    db_pool_snapshot_available: "Fresh pool snapshot available (not database health)."
  }

  @memory_types ~w(total processes processes_used system atom atom_used binary code ets)a
  @vm_gauges %{
    vm_memory_bytes: "BEAM allocated bytes by overlapping category, not OS RSS.",
    vm_process_count: "BEAM process count at the latest fresh sample.",
    vm_port_count: "BEAM port count at the latest fresh sample.",
    vm_atom_count: "BEAM atom count at the latest fresh sample.",
    vm_gc_collections:
      "OTP garbage collections since VM start at the latest fresh sample, not GC time.",
    application_start_time_seconds:
      "Application start time as Unix seconds, preserved on child restart.",
    application_uptime_seconds:
      "Completed monotonic seconds since application start at the latest sample.",
    vm_snapshot_available: "Fresh complete VM resource snapshot available."
  }
  @vm_counts Map.keys(Map.drop(@vm_gauges, [:vm_memory_bytes, :vm_snapshot_available]))

  @scheduler_gauges %{
    scheduler_run_queue_length:
      "Ready tasks per normal queue or shared dirty queue, sampled non-atomically.",
    scheduler_utilization_ratio:
      "Online scheduler busy fraction between consecutive samples, not OS CPU usage.",
    scheduler_snapshot_available: "Fresh scheduler queues or utilization interval available."
  }

  @cache_gauges %{
    cache_entries:
      "Objects in an implemented local application ETS table, sampled non-atomically.",
    cache_memory_bytes:
      "ETS allocated words converted to bytes, not total referenced binary memory.",
    cache_snapshot_available: "Fresh numeric snapshot for an implemented application cache."
  }
  @runtime_description "Loaded application and language versions; Erlang/OTP release is the major release."

  # Queue 1 only; adding a queue requires an explicit domain/budget update.
  @oban_queues ~w(mailers maintenance)
  @oban_states ~w(available scheduled executing retryable completed cancelled discarded)
  @oban_gauges %{
    oban_jobs:
      "Current stored jobs by implemented queue and specified state, not lifetime totals.",
    oban_oldest_available_age_seconds:
      "Age since scheduled_at of the oldest available job at sample time; zero if empty.",
    oban_snapshot_available: "Fresh complete aggregate job snapshot available, not worker health."
  }
  @postgres_gauges %{
    postgres_version_number: "Numeric PostgreSQL server release at the latest metadata sample.",
    db_pending_migrations: "Release migration files not present in the migration ledger.",
    db_metadata_available: "Fresh server version and migration count available, not readiness.",
    db_size_bytes: "Disk space used by the current database, sampled every five minutes.",
    db_size_available: "Fresh database size measurement available, not free disk space.",
    db_active_connections:
      "Active client backends in this database, excluding the sampling connection.",
    db_idle_in_transaction_connections:
      "Client backends idle in a transaction, including aborted, excluding the sampler.",
    db_oldest_transaction_age_seconds:
      "Age of the oldest client xact_start in this database, excluding the sampler; zero if none.",
    db_activity_available:
      "Fresh complete client activity snapshot available, not database readiness."
  }

  @doc "One derived info row per scrape, never accumulated in the reporter by version label."
  def postgres_info_definition do
    %{
      name: "anime_postgres_info",
      type: :gauge,
      tags: [:version],
      max_series: 1,
      description: "PostgreSQL release derived from the fresh numeric Telemetry measurement."
    }
  end

  @doc false
  def postgres_metric_names(:metadata),
    do:
      ~w(anime_postgres_version_number anime_db_pending_migrations anime_db_metadata_available anime_postgres_info)

  def postgres_metric_names(:size), do: ~w(anime_db_size_bytes anime_db_size_available)

  def postgres_metric_names(:activity),
    do:
      ~w(anime_db_active_connections anime_db_idle_in_transaction_connections anime_db_oldest_transaction_age_seconds anime_db_activity_available)

  @doc false
  def normalize_postgres_snapshot(:metadata, {:ok, %{version_number: version, pending: pending}})
      when is_integer(version) and version in 100_000..999_999 and
             is_integer(pending) and pending in 0..4096,
      do: {:ok, %{version_number: version, pending: pending}}

  def normalize_postgres_snapshot(:size, {:ok, %{bytes: bytes}}) do
    if valid_pool_count?(bytes), do: {:ok, %{bytes: bytes}}, else: :unavailable
  end

  def normalize_postgres_snapshot(
        :activity,
        {:ok, %{active: active, idle: idle, oldest_seconds: age}}
      ) do
    if Enum.all?([active, idle, age], &valid_pool_count?/1),
      do: {:ok, %{active: active, idle: idle, oldest_seconds: age}},
      else: :unavailable
  end

  def normalize_postgres_snapshot(_, _), do: :unavailable

  @doc false
  def publish_postgres_snapshot(kind, snapshot) when kind in [:metadata, :size, :activity] do
    values =
      case {kind, normalize_postgres_snapshot(kind, snapshot)} do
        {:metadata, {:ok, value}} ->
          [
            postgres_version_number: value.version_number,
            db_pending_migrations: value.pending,
            db_metadata_available: 1
          ]

        {:size, {:ok, value}} ->
          [db_size_bytes: value.bytes, db_size_available: 1]

        {:activity, {:ok, value}} ->
          [
            db_active_connections: value.active,
            db_idle_in_transaction_connections: value.idle,
            db_oldest_transaction_age_seconds: value.oldest_seconds,
            db_activity_available: 1
          ]

        {:metadata, :unavailable} ->
          [db_metadata_available: 0]

        {:size, :unavailable} ->
          [db_size_available: 0]

        {:activity, :unavailable} ->
          [db_activity_available: 0]
      end

    for {key, value} <- values, do: :telemetry.execute(event(key), %{value: value}, %{})
    :ok
  end

  @doc false
  def postgres_unavailable_text(kind) do
    key =
      case kind do
        :metadata -> :db_metadata_available
        :size -> :db_size_available
        :activity -> :db_activity_available
      end

    "# HELP anime_#{key} #{@postgres_gauges[key]}\n# TYPE anime_#{key} gauge\nanime_#{key} 0\n"
  end

  @doc false
  def postgres_info_text(version) when is_integer(version) and version in 100_000..999_999 do
    info = postgres_info_definition()
    # Only decimal digits and a dot can reach this label; no server banner,
    # database name, hostname, paths or historical versions are retained.
    release = "#{div(version, 10_000)}.#{rem(version, 10_000)}"

    "# HELP #{info.name} #{info.description}\n# TYPE #{info.name} gauge\n#{info.name}{version=\"#{release}\"} 1\n"
  end

  # Closed event contracts. Exporters must aggregate only these measurements and
  # tags and separately enforce their final Prometheus series budget (including
  # histogram buckets / quantiles). These are observations, not stored metrics.
  @contracts %{
    http: %{measurements: [:count, :duration_ms], tags: [:status]},
    router: %{measurements: [:count, :duration_ms], tags: [:route, :method]},
    router_exception: %{measurements: [:count], tags: [:route]},
    live_mount: %{measurements: [:count, :duration_ms], tags: [:view, :connection]},
    live_mount_exception: %{measurements: [:count], tags: [:view, :connection]},
    live_mount_redirect: %{measurements: [:count], tags: [:view, :connection]},
    live_params: %{measurements: [:count, :duration_ms], tags: [:view]},
    live_event: %{measurements: [:count, :duration_ms], tags: [:view]},
    live_event_exception: %{measurements: [:count], tags: [:view, :event]},
    job: %{measurements: [:count, :duration_ms], tags: [:worker]},
    job_exception: %{measurements: [:count], tags: [:worker, :outcome]},
    access_denied: %{measurements: [:count], tags: [:permission]},
    rate_limited: %{measurements: [:count], tags: [:scope]},
    proxy_rejected: %{measurements: [:count], tags: [:reason, :transport]},
    db_query: %{measurements: [:count], tags: [:source, :outcome]},
    db_timing: %{measurements: [:count, :duration_ms], tags: [:source, :phase]},
    db_slow: %{measurements: [:count], tags: [:source]},
    db_checkout_timeout: %{measurements: [:count], tags: [:source]},
    projection_error: %{measurements: [:count], tags: []}
  }

  def events, do: Map.keys(contracts())

  def contracts do
    counters = Map.new(@contracts, fn {key, schema} -> {event(key), schema} end)

    Map.merge(
      counters,
      Map.new(@pool_gauges, fn {key, _} ->
        {event(key), %{measurements: [:value], tags: []}}
      end)
    )
    |> Map.merge(
      Map.new(@vm_gauges, fn {key, _} ->
        {event(key),
         %{measurements: [:value], tags: if(key == :vm_memory_bytes, do: [:kind], else: [])}}
      end)
    )
    |> Map.merge(
      Map.new(@scheduler_gauges, fn {key, _} ->
        {event(key), %{measurements: [:value], tags: scheduler_tags(key)}}
      end)
    )
    |> Map.merge(
      Map.new(@cache_gauges, fn {key, _} ->
        {event(key), %{measurements: [:value], tags: [:table]}}
      end)
    )
    |> Map.put(event(:runtime_info), %{measurements: [:value], tags: [:component, :version]})
    |> Map.merge(
      Map.new(@oban_gauges, fn {key, _} ->
        {event(key), %{measurements: [:value], tags: oban_tags(key)}}
      end)
    )
    |> Map.merge(
      Map.new(@postgres_gauges, fn {key, _} ->
        {event(key), %{measurements: [:value], tags: []}}
      end)
    )
  end

  defp event(key), do: @prefix ++ [key]

  @doc false
  def valid_pool_count?(value),
    do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991

  def oban_queues, do: @oban_queues
  def oban_states, do: @oban_states
  defp oban_tags(:oban_jobs), do: [:queue, :state]
  defp oban_tags(:oban_oldest_available_age_seconds), do: [:queue]
  defp oban_tags(:oban_snapshot_available), do: []

  @doc false
  def oban_domains do
    %{
      oban_jobs:
        for(queue <- @oban_queues, state <- @oban_states, do: %{queue: queue, state: state}),
      oban_oldest_available_age_seconds: Enum.map(@oban_queues, &%{queue: &1}),
      oban_snapshot_available: [%{}]
    }
  end

  @doc false
  def normalize_oban_snapshot({:ok, %{counts: counts, ages: ages}})
      when is_map(counts) and is_map(ages) do
    keys = for queue <- @oban_queues, state <- @oban_states, do: {queue, state}

    if Enum.all?(keys, &valid_pool_count?(Map.get(counts, &1))) and
         Enum.all?(@oban_queues, fn queue ->
           age = Map.get(ages, queue)
           valid_pool_count?(age) and (counts[{queue, "available"}] > 0 or age == 0)
         end) do
      {:ok, %{counts: Map.take(counts, keys), ages: Map.take(ages, @oban_queues)}}
    else
      :unavailable
    end
  end

  def normalize_oban_snapshot(_), do: :unavailable

  @doc false
  def publish_oban_snapshot(snapshot) do
    case normalize_oban_snapshot(snapshot) do
      {:ok, %{counts: counts, ages: ages}} ->
        for {{queue, state}, count} <- counts,
            do:
              :telemetry.execute(event(:oban_jobs), %{value: count}, %{queue: queue, state: state})

        for {queue, age} <- ages,
            do:
              :telemetry.execute(event(:oban_oldest_available_age_seconds), %{value: age}, %{
                queue: queue
              })

        :telemetry.execute(event(:oban_snapshot_available), %{value: 1}, %{})

      :unavailable ->
        :telemetry.execute(event(:oban_snapshot_available), %{value: 0}, %{})
    end
  end

  @doc false
  def oban_metric_names, do: Enum.map(@oban_gauges, fn {key, _} -> "anime_#{key}" end)
  @doc false
  def oban_unavailable_text do
    name = "anime_oban_snapshot_available"
    "# HELP #{name} #{@oban_gauges.oban_snapshot_available}\n# TYPE #{name} gauge\n#{name} 0\n"
  end

  @doc "Constants from the running VM, not environment variables, lockfiles or request metadata."
  def runtime_version_tags do
    [
      {"application", Application.spec(:anime, :vsn)},
      {"elixir", System.version()},
      {"erlang_otp", :erlang.system_info(:otp_release)}
    ]
    |> Enum.flat_map(fn {component, value} ->
      version = if is_list(value), do: List.to_string(value), else: value

      if is_binary(version) and byte_size(version) in 1..64 and
           Regex.match?(~r/\A[0-9]+(?:\.[0-9]+)*(?:[-+][a-zA-Z0-9.-]+)?\z/, version),
         do: [%{component: component, version: version}],
         else: []
    end)
  end

  @doc false
  def publish_runtime_versions do
    for tags <- runtime_version_tags(),
        do: :telemetry.execute(event(:runtime_info), %{value: 1}, tags)

    :ok
  end

  @doc false
  def normalize_cache_snapshot({:ok, values}) when is_map(values) do
    {:ok,
     Map.new(Anime.Cache.inventory(), fn table ->
       value =
         case Map.get(values, table) do
           %{entries: count, memory_bytes: bytes} ->
             if valid_pool_count?(count) and valid_pool_count?(bytes),
               do: %{entries: count, memory_bytes: bytes},
               else: :unavailable

           _ ->
             :unavailable
         end

       {table, value}
     end)}
  end

  def normalize_cache_snapshot(_), do: :unavailable

  @doc false
  def publish_cache_snapshot(snapshot) do
    values =
      case normalize_cache_snapshot(snapshot) do
        {:ok, values} -> values
        :unavailable -> %{}
      end

    for table <- Anime.Cache.inventory() do
      tags = %{table: Atom.to_string(table)}

      case Map.get(values, table) do
        %{entries: count, memory_bytes: bytes} ->
          :telemetry.execute(event(:cache_entries), %{value: count}, tags)
          :telemetry.execute(event(:cache_memory_bytes), %{value: bytes}, tags)
          :telemetry.execute(event(:cache_snapshot_available), %{value: 1}, tags)

        _ ->
          :telemetry.execute(event(:cache_snapshot_available), %{value: 0}, tags)
      end
    end

    :ok
  end

  @doc false
  def cache_metric_names, do: Enum.map(@cache_gauges, fn {key, _} -> "anime_#{key}" end)

  @doc false
  def cache_unavailable_text(tables) do
    name = "anime_cache_snapshot_available"

    "# HELP #{name} #{@cache_gauges.cache_snapshot_available}\n# TYPE #{name} gauge\n" <>
      Enum.map_join(tables, "", fn table -> "#{name}{table=\"#{table}\"} 0\n" end)
  end

  @doc false
  def publish_pool_snapshot({:ok, %{ready: ready, waiting: waiting}}) do
    if valid_pool_count?(ready) and valid_pool_count?(waiting) do
      :telemetry.execute(event(:db_pool_ready), %{value: ready}, %{})
      :telemetry.execute(event(:db_pool_waiting), %{value: waiting}, %{})
      :telemetry.execute(event(:db_pool_snapshot_available), %{value: 1}, %{})
    else
      publish_pool_snapshot(:unavailable)
    end
  end

  def publish_pool_snapshot(:unavailable),
    do: :telemetry.execute(event(:db_pool_snapshot_available), %{value: 0}, %{})

  @doc false
  def pool_metric_names, do: Enum.map(@pool_gauges, fn {key, _} -> "anime_#{key}" end)

  @doc false
  def pool_unavailable_text do
    name = "anime_db_pool_snapshot_available"
    "# HELP #{name} #{@pool_gauges.db_pool_snapshot_available}\n# TYPE #{name} gauge\n#{name} 0\n"
  end

  @doc false
  def memory_types, do: @memory_types

  @doc false
  def normalize_vm_snapshot({:ok, %{memory: memory} = values}) when is_map(memory) do
    if Enum.all?(@memory_types, &valid_pool_count?(Map.get(memory, &1))) and
         Enum.all?(@vm_counts, &valid_pool_count?(Map.get(values, &1))) do
      {:ok, values |> Map.take(@vm_counts) |> Map.put(:memory, Map.take(memory, @memory_types))}
    else
      :unavailable
    end
  end

  def normalize_vm_snapshot(_), do: :unavailable

  @doc false
  def publish_vm_snapshot(snapshot) do
    case normalize_vm_snapshot(snapshot) do
      {:ok, values} ->
        for kind <- @memory_types do
          :telemetry.execute(event(:vm_memory_bytes), %{value: values.memory[kind]}, %{
            kind: Atom.to_string(kind)
          })
        end

        for key <- @vm_counts, do: :telemetry.execute(event(key), %{value: values[key]}, %{})
        :telemetry.execute(event(:vm_snapshot_available), %{value: 1}, %{})

      :unavailable ->
        :telemetry.execute(event(:vm_snapshot_available), %{value: 0}, %{})
    end
  end

  @doc false
  def vm_metric_names, do: Enum.map(@vm_gauges, fn {key, _} -> "anime_#{key}" end)

  @doc false
  def vm_unavailable_text do
    name = "anime_vm_snapshot_available"
    "# HELP #{name} #{@vm_gauges.vm_snapshot_available}\n# TYPE #{name} gauge\n#{name} 0\n"
  end

  @doc false
  def scheduler_topology do
    %{
      normal: :erlang.system_info(:schedulers),
      dirty_cpu: :erlang.system_info(:dirty_cpu_schedulers),
      dirty_io: :erlang.system_info(:dirty_io_schedulers)
    }
  end

  @doc false
  def scheduler_domains(topology \\ scheduler_topology()) do
    normal = scheduler_labels(:normal, topology.normal)

    %{
      scheduler_run_queue_length:
        normal ++ [%{kind: "dirty_cpu", id: "shared"}, %{kind: "dirty_io", id: "shared"}],
      scheduler_utilization_ratio:
        normal ++
          scheduler_labels(:dirty_cpu, topology.dirty_cpu) ++
          scheduler_labels(:dirty_io, topology.dirty_io),
      scheduler_snapshot_available: [%{measurement: "queues"}, %{measurement: "utilization"}]
    }
  end

  defp scheduler_labels(kind, count),
    do: for(id <- 1..count//1, do: %{kind: Atom.to_string(kind), id: Integer.to_string(id)})

  defp scheduler_tags(:scheduler_snapshot_available), do: [:measurement]
  defp scheduler_tags(_), do: [:kind, :id]

  @doc false
  def publish_scheduler_snapshot({:ok, %{queues: queues, utilization: utilization}}) do
    with {:ok, queues} <- scheduler_rows(:scheduler_run_queue_length, queues),
         {:ok, utilization} <- scheduler_rows(:scheduler_utilization_ratio, utilization) do
      for {tags, value} <- queues,
          do: :telemetry.execute(event(:scheduler_run_queue_length), %{value: value}, tags)

      scheduler_available("queues", 1)

      if is_list(utilization) do
        for {tags, value} <- utilization,
            do: :telemetry.execute(event(:scheduler_utilization_ratio), %{value: value}, tags)

        scheduler_available("utilization", 1)
      else
        scheduler_available("utilization", 0)
      end
    else
      _ -> publish_scheduler_snapshot(:unavailable)
    end
  end

  def publish_scheduler_snapshot(_) do
    scheduler_available("queues", 0)
    scheduler_available("utilization", 0)
  end

  defp scheduler_rows(:scheduler_utilization_ratio, nil), do: {:ok, nil}

  defp scheduler_rows(key, rows) when is_list(rows) and rows != [] do
    allowed = MapSet.new(scheduler_domains()[key])

    clean =
      Enum.map(rows, fn
        {tags, value} when is_map(tags) ->
          tags = Map.take(tags, scheduler_tags(key))

          if MapSet.member?(allowed, tags) and valid_scheduler_value?(key, value),
            do: {tags, value}

        _ ->
          nil
      end)

    if Enum.all?(clean, &(not is_nil(&1))) and
         length(Enum.uniq_by(clean, &elem(&1, 0))) == length(clean),
       do: {:ok, clean},
       else: :unavailable
  end

  defp scheduler_rows(_, _), do: :unavailable

  defp valid_scheduler_value?(:scheduler_utilization_ratio, value),
    do: is_number(value) and value >= 0 and value <= 1

  defp valid_scheduler_value?(:scheduler_snapshot_available, value), do: value in [0, 1]
  defp valid_scheduler_value?(_, value), do: valid_pool_count?(value)

  defp scheduler_available(measurement, value),
    do:
      :telemetry.execute(event(:scheduler_snapshot_available), %{value: value}, %{
        measurement: measurement
      })

  @doc false
  def scheduler_metric_name(key), do: "anime_#{key}"
  @doc false
  def scheduler_availability_text(queues, utilization) do
    name = scheduler_metric_name(:scheduler_snapshot_available)

    "# HELP #{name} #{@scheduler_gauges.scheduler_snapshot_available}\n# TYPE #{name} gauge\n" <>
      "#{name}{measurement=\"queues\"} #{queues}\n#{name}{measurement=\"utilization\"} #{utilization}\n"
  end

  @doc "Exact finite sets of exportable label combinations, including unknowns."
  def allowed_tags do
    domains = domains()
    views = Enum.map(Map.keys(@view_events), &inspect/1) ++ [@unknown]

    mounts =
      for view <- views,
          connection <- ~w(static connected),
          do: %{view: view, connection: connection}

    Map.new(
      %{
        http: Enum.map(100..599, &%{status: &1}),
        router:
          Enum.map(domains.route_pairs, fn {route, method} -> %{route: route, method: method} end) ++
            [%{route: @unknown, method: @unknown}],
        router_exception: Enum.map([@unknown | MapSet.to_list(domains.routes)], &%{route: &1}),
        live_mount: mounts,
        live_mount_exception: mounts,
        live_mount_redirect: mounts,
        live_params: Enum.map(views, &%{view: &1}),
        live_event: Enum.map(views, &%{view: &1}),
        live_event_exception:
          Enum.flat_map(@view_events, fn {view, events} ->
            Enum.map([@unknown | events], &%{view: inspect(view), event: &1})
          end) ++ [%{view: @unknown, event: @unknown}],
        job: Enum.map([@unknown | @workers], &%{worker: &1}),
        job_exception:
          for(
            worker <- [@unknown | @workers],
            outcome <- [@unknown | Enum.map(@states, &to_string/1)],
            do: %{worker: worker, outcome: outcome}
          ),
        access_denied:
          Enum.map([@unknown | MapSet.to_list(domains.permissions)], &%{permission: &1}),
        rate_limited: Enum.map([@unknown | @scopes], &%{scope: &1}),
        proxy_rejected:
          for(
            reason <- ~w(untrusted_peer invalid too_many all_trusted) ++ [@unknown],
            transport <- ~w(http websocket) ++ [@unknown],
            do: %{reason: reason, transport: transport}
          ),
        projection_error: [%{}],
        db_pool_ready: [%{}],
        db_pool_waiting: [%{}],
        db_pool_snapshot_available: [%{}],
        db_query:
          for(
            source <- @db_sources,
            outcome <- ~w(ok error unknown),
            do: %{source: source, outcome: outcome}
          ),
        db_timing:
          for(
            source <- @db_sources,
            phase <- @db_phases,
            do: %{source: source, phase: Atom.to_string(phase)}
          ),
        db_slow: Enum.map(@db_sources, &%{source: &1}),
        db_checkout_timeout: Enum.map(@db_sources, &%{source: &1})
      },
      fn {key, tags} -> {event(key), MapSet.new(tags)} end
    )
    |> Map.merge(
      Map.new(@vm_gauges, fn {key, _} ->
        tags =
          if key == :vm_memory_bytes,
            do: Enum.map(@memory_types, &%{kind: Atom.to_string(&1)}),
            else: [%{}]

        {event(key), MapSet.new(tags)}
      end)
    )
    |> Map.merge(
      Map.new(scheduler_domains(), fn {key, tags} -> {event(key), MapSet.new(tags)} end)
    )
    |> Map.merge(
      Map.new(@cache_gauges, fn {key, _} ->
        {event(key), MapSet.new(Anime.Cache.inventory(), &%{table: Atom.to_string(&1)})}
      end)
    )
    |> Map.put(event(:runtime_info), MapSet.new(runtime_version_tags()))
    |> Map.merge(Map.new(oban_domains(), fn {key, tags} -> {event(key), MapSet.new(tags)} end))
    |> Map.merge(Map.new(@postgres_gauges, fn {key, _} -> {event(key), MapSet.new([%{}])} end))
  end

  @doc "Bounded counters, duration sums and resource gauges. No invented quantiles."
  def definitions do
    counter_definitions() ++
      pool_definitions() ++
      vm_definitions() ++
      scheduler_definitions() ++
      inventory_definitions() ++ oban_definitions() ++ postgres_definitions()
  end

  defp postgres_definitions do
    for {key, description} <- Enum.sort(@postgres_gauges) do
      Telemetry.Metrics.last_value([:anime, key],
        event_name: event(key),
        tags: [],
        keep: &is_map/1,
        measurement: fn measurements ->
          value = if is_map(measurements), do: Map.get(measurements, :value)

          valid =
            case key do
              :postgres_version_number ->
                is_integer(value) and value in 100_000..999_999

              :db_pending_migrations ->
                is_integer(value) and value in 0..4096

              key
              when key in [:db_metadata_available, :db_size_available, :db_activity_available] ->
                value in [0, 1]

              _ ->
                valid_pool_count?(value)
            end

          if valid, do: value
        end,
        description: description
      )
      |> validate_budget!([%{}])
    end
  end

  defp oban_definitions do
    domains = oban_domains()

    for {key, description} <- Enum.sort(@oban_gauges) do
      tags = oban_tags(key)
      tag_sets = MapSet.new(domains[key])

      Telemetry.Metrics.last_value([:anime, key],
        event_name: event(key),
        tags: tags,
        keep: fn meta -> is_map(meta) and MapSet.member?(tag_sets, Map.take(meta, tags)) end,
        measurement: fn measurements ->
          value = if is_map(measurements), do: Map.get(measurements, :value)

          if valid_pool_count?(value) and (key != :oban_snapshot_available or value in [0, 1]),
            do: value
        end,
        description: description
      )
      |> validate_budget!(tag_sets)
    end
  end

  defp inventory_definitions do
    allowed = allowed_tags()

    for {key, description} <-
          Enum.sort(Map.put(@cache_gauges, :runtime_info, @runtime_description)) do
      tags = if key == :runtime_info, do: [:component, :version], else: [:table]
      tag_sets = allowed[event(key)]

      Telemetry.Metrics.last_value([:anime, key],
        event_name: event(key),
        tags: tags,
        keep: fn meta -> is_map(meta) and MapSet.member?(tag_sets, Map.take(meta, tags)) end,
        measurement: fn measurements ->
          value = if is_map(measurements), do: Map.get(measurements, :value)

          valid? =
            case key do
              :runtime_info -> value === 1
              :cache_snapshot_available -> value in [0, 1]
              _ -> valid_pool_count?(value)
            end

          if valid?, do: value
        end,
        description: description
      )
      |> validate_budget!(tag_sets)
    end
  end

  defp scheduler_definitions do
    domains = scheduler_domains()

    for {key, description} <- Enum.sort(@scheduler_gauges) do
      tags = scheduler_tags(key)
      tag_sets = MapSet.new(domains[key])

      Telemetry.Metrics.last_value([:anime, key],
        event_name: event(key),
        tags: tags,
        keep: fn meta -> is_map(meta) and MapSet.member?(tag_sets, Map.take(meta, tags)) end,
        measurement: fn measurements ->
          value = if is_map(measurements), do: Map.get(measurements, :value)

          if valid_scheduler_value?(key, value), do: value
        end,
        description: description
      )
      |> validate_budget!(tag_sets)
    end
  end

  defp vm_definitions do
    allowed = allowed_tags()

    for {key, description} <- Enum.sort(@vm_gauges) do
      tags = if key == :vm_memory_bytes, do: [:kind], else: []
      tag_sets = allowed[event(key)]

      Telemetry.Metrics.last_value([:anime, key],
        event_name: event(key),
        tags: tags,
        keep: fn meta -> is_map(meta) and MapSet.member?(tag_sets, Map.take(meta, tags)) end,
        measurement: fn measurements ->
          value = if is_map(measurements), do: Map.get(measurements, :value)

          if valid_pool_count?(value) and (key != :vm_snapshot_available or value in [0, 1]),
            do: value
        end,
        description: description
      )
      |> validate_budget!(tag_sets)
    end
  end

  defp pool_definitions do
    for {key, description} <- Enum.sort(@pool_gauges) do
      Telemetry.Metrics.last_value([:anime, key],
        event_name: event(key),
        tags: [],
        keep: &is_map/1,
        measurement: fn measurements ->
          value = if is_map(measurements), do: Map.get(measurements, :value)

          if valid_pool_count?(value) and
               (key != :db_pool_snapshot_available or value in [0, 1]),
             do: value
        end,
        description: description
      )
      |> validate_budget!([%{}])
    end
  end

  defp counter_definitions do
    allowed = allowed_tags()

    @contracts
    |> Enum.sort()
    |> Enum.flat_map(fn {key, contract} ->
      tags = allowed[event(key)]
      timed? = :duration_ms in contract.measurements

      common = [
        event_name: event(key),
        tags: contract.tags,
        # Validate combinations, not Cartesian products. Additional metadata is
        # neither stored nor exported; unknown values must come from projection.
        keep: fn meta -> is_map(meta) and MapSet.member?(tags, Map.take(meta, contract.tags)) end
      ]

      count =
        Telemetry.Metrics.sum(
          [:anime, key, :total],
          common ++
            [
              measurement: fn measurements ->
                if valid_observation?(measurements, timed?), do: 1
              end,
              description: "Observed #{key} events since reporter start."
            ]
        )

      duration =
        if timed? do
          [
            Telemetry.Metrics.sum(
              [:anime, key, :duration, :microseconds, :total],
              common ++
                [
                  # Core 1.2.1 uses ets.update_counter for sums: integers only. Never
                  # convert to floating seconds here (that detaches the event handler).
                  measurement: fn measurements ->
                    if valid_observation?(measurements, true),
                      do: round(measurements.duration_ms * 1000)
                  end,
                  unit: :microsecond,
                  description: "Cumulative #{key} duration in microseconds since reporter start."
                ]
            )
          ]
        else
          []
        end

      Enum.map([count | duration], &validate_budget!(&1, tags))
    end)
  end

  defp valid_observation?(%{count: 1, duration_ms: duration}, true),
    do: is_number(duration) and duration >= 0 and duration <= 9_007_199_254_740

  defp valid_observation?(%{count: 1}, false), do: true
  defp valid_observation?(_, _), do: false

  @doc "Fail startup if a metric's entire possible exposition exceeds 500 rows."
  def validate_budget!(metric, tag_sets) do
    multiplier =
      case metric do
        %Telemetry.Metrics.Distribution{reporter_options: options} ->
          length(Keyword.fetch!(options, :buckets)) + 3

        %Telemetry.Metrics.Sum{} ->
          1

        %Telemetry.Metrics.Counter{} ->
          1

        %Telemetry.Metrics.LastValue{} ->
          1

        _ ->
          raise ArgumentError, "Unsupported metrics exposition; budget cannot be proven"
      end

    if MapSet.size(MapSet.new(tag_sets)) * multiplier > 500,
      do:
        raise(ArgumentError, "Metric #{Enum.join(metric.name, "_")} exceeds 500 exposition rows")

    metric
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :telemetry.detach(__MODULE__)
    :ok = :telemetry.attach_many(__MODULE__, @source_events, &__MODULE__.handle/4, domains())
    {:ok, nil}
  end

  @impl true
  def terminate(_, _), do: :telemetry.detach(__MODULE__)

  @doc false
  def domains do
    routes = AnimeWeb.Router.__routes__()

    pairs =
      for r <- routes, r.verb != :*, do: {r.path, r.verb |> Atom.to_string() |> String.upcase()}

    heads = for {path, "GET"} <- pairs, do: {path, "HEAD"}

    %{
      route_pairs: MapSet.new(pairs ++ heads),
      routes: MapSet.new(Enum.map(routes, & &1.path)),
      permissions: MapSet.new(Anime.Access.Catalog.codes())
    }
  end

  @doc false
  def handle(source, measurements, metadata, domains)
      when is_map(measurements) and is_map(metadata) do
    try do
      project(source, measurements, metadata, domains)
    after
      finish_scope(source, metadata)
    end
  rescue
    _ -> count(:projection_error, %{})
  catch
    _, _ -> count(:projection_error, %{})
  end

  def handle(_, _, _, _), do: :ok

  defp finish_scope([:phoenix, :live_view, stage, phase], %{socket: %{view: view}})
       when phase in [:stop, :exception] and is_map_key(@view_events, view),
       do: Context.leave({:live_view, stage})

  defp finish_scope([:oban, :job, phase], %{job: %Oban.Job{}})
       when phase in [:stop, :exception],
       do: Context.leave(:oban)

  defp finish_scope(_, _), do: :ok

  defp project([:phoenix, :live_view, stage, :start], _, %{socket: %{view: view}}, _)
       when is_map_key(@view_events, view),
       do: Context.enter({:live_view, stage}, :live_view)

  defp project([:oban, :job, :start], _, %{job: %Oban.Job{}}, _),
    do: Context.enter(:oban, :oban)

  defp project([:anime, :repo, :checkout_timeout], %{count: 1}, %{repo: Anime.Repo}, _) do
    # Repo emits this only for a typed queue_timeout before its checkout callback
    # runs. There is no query event in this path; never subscribe to the global
    # DBConnection error event (it cannot identify our repo and would double count).
    count(:db_checkout_timeout, %{source: Atom.to_string(Context.current())})
  end

  defp project(
         [:anime, :repo, :query],
         measurements,
         %{repo: Anime.Repo, type: :ecto_sql_query} = metadata,
         _
       ) do
    # source in Ecto metadata is a table name, not the caller. Never export it,
    # nor query, params, result contents, options or exception messages.
    tags = %{source: Atom.to_string(Context.current())}

    outcome =
      case metadata[:result] do
        {:ok, _} -> "ok"
        {:error, _} -> "error"
        _ -> "unknown"
      end

    count(:db_query, Map.put(tags, :outcome, outcome))

    for phase <- @db_phases do
      value = measurements[phase]

      if valid_db_time?(value) do
        duration(:db_timing, %{duration: value}, Map.put(tags, :phase, Atom.to_string(phase)))
      end
    end

    total = measurements[:total_time]

    if valid_db_time?(total) and total > System.convert_time_unit(500, :millisecond, :native),
      do: count(:db_slow, tags)

    if match?({:error, %DBConnection.ConnectionError{reason: :queue_timeout}}, metadata[:result]),
      do: count(:db_checkout_timeout, tags)
  end

  defp project(
         [:phoenix, :endpoint, :stop],
         measurements,
         %{conn: %Plug.Conn{status: status, private: %{phoenix_endpoint: AnimeWeb.Endpoint}}},
         _
       )
       when is_integer(status) and status in 100..599 do
    duration(:http, measurements, %{status: status})
  end

  defp project(
         [:phoenix, :router_dispatch, phase],
         measurements,
         %{conn: %Plug.Conn{private: %{phoenix_router: AnimeWeb.Router}} = conn} = meta,
         domains
       ) do
    route = if MapSet.member?(domains.routes, meta[:route]), do: meta.route, else: @unknown
    # Plug.Head normalizes the method before Router; only recover a recognized
    # original method recorded by our own endpoint plug, never from headers/forms.
    method = conn.private[:anime_metrics_method] || conn.method

    {route, method} =
      if MapSet.member?(domains.route_pairs, {route, method}),
        do: {route, method},
        else: {@unknown, @unknown}

    case phase do
      :stop -> duration(:router, measurements, %{route: route, method: method})
      :exception -> count(:router_exception, %{route: route})
    end
  end

  defp project(
         [:phoenix, :live_view, stage, phase],
         measurements,
         %{socket: %Phoenix.LiveView.Socket{} = socket} = meta,
         _
       ) do
    view = socket.view
    label = if Map.has_key?(@view_events, view), do: inspect(view), else: @unknown
    tags = %{view: label}

    case {stage, phase} do
      {:mount, :stop} ->
        duration(:live_mount, measurements, Map.put(tags, :connection, connection(socket)))
        # A halted on_mount with redirect is a normal stop span, not an exception.
        # This is a subset of mounts, not another completed mount/duration sample.
        if socket.redirected,
          do: count(:live_mount_redirect, Map.put(tags, :connection, connection(socket)))

      {:mount, :exception} ->
        count(:live_mount_exception, Map.put(tags, :connection, connection(socket)))

      {:handle_params, :stop} ->
        duration(:live_params, measurements, tags)

      {:handle_event, :stop} ->
        duration(:live_event, measurements, tags)

      {:handle_event, :exception} ->
        name = if meta[:event] in Map.get(@view_events, view, []), do: meta.event, else: @unknown
        count(:live_event_exception, Map.put(tags, :event, name))

      _ ->
        :ok
    end
  end

  defp project([:oban, :job, phase], measurements, %{job: %Oban.Job{} = job} = meta, _) do
    worker = label(job.worker, @workers)

    case phase do
      :stop ->
        duration(:job, measurements, %{worker: worker})

      :exception ->
        count(:job_exception, %{worker: worker, outcome: label(meta[:state], @states)})
    end
  end

  defp project([:anime, :access, :denied], _, meta, domains) do
    permission =
      if MapSet.member?(domains.permissions, meta[:permission]),
        do: meta.permission,
        else: @unknown

    count(:access_denied, %{permission: permission})
  end

  defp project([:anime, :rate_limit, :rejected], _, meta, _) do
    count(:rate_limited, %{scope: label(meta[:scope], @scopes)})
  end

  defp project([:anime, :client_ip, :rejected], _, meta, _) do
    count(:proxy_rejected, %{
      reason: label(meta[:reason], [:untrusted_peer, :invalid, :too_many, :all_trusted]),
      transport: label(meta[:transport], [:http, :websocket])
    })
  end

  defp project(_, _, _, _), do: :ok

  defp valid_db_time?(value) do
    is_integer(value) and value >= 0 and
      value <= System.convert_time_unit(9_007_199_254_740, :millisecond, :native)
  end

  defp duration(key, %{duration: n}, tags) when is_integer(n) and n >= 0 do
    # Ignore all other measurements as well as all raw framework metadata.
    :telemetry.execute(
      event(key),
      %{count: 1, duration_ms: System.convert_time_unit(n, :native, :microsecond) / 1000},
      tags
    )
  end

  defp duration(_, _, _), do: :ok
  defp count(key, tags), do: :telemetry.execute(event(key), %{count: 1}, tags)

  defp connection(socket),
    do: if(Phoenix.LiveView.connected?(socket), do: "connected", else: "static")

  defp label(value, allowed), do: if(value in allowed, do: to_string(value), else: @unknown)
end
