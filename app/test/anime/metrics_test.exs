defmodule Anime.MetricsTest do
  use ExUnit.Case
  import Anime.MetricsProbe
  @secret "PRIVATE-METRIC-SENTINEL"
  @duration System.convert_time_unit(1500, :microsecond, :native)

  defp emit(source, meta, measurements \\ %{duration: @duration}) do
    :telemetry.execute(
      source,
      Map.put(measurements, :private, @secret),
      Map.put(meta, :private, @secret)
    )
  end

  defp conn(status \\ 200) do
    %Plug.Conn{
      status: status,
      method: "GET",
      request_path: "/u/" <> @secret,
      params: %{"password" => @secret},
      req_headers: [{"authorization", @secret}],
      private: %{phoenix_endpoint: AnimeWeb.Endpoint, phoenix_router: AnimeWeb.Router}
    }
  end

  defp safe!(records) do
    refute inspect(records) =~ @secret
    contracts = Anime.Metrics.contracts()

    for {event, m, tags} <- records do
      schema = Map.fetch!(contracts, event)
      assert Enum.sort(Map.keys(m)) == Enum.sort(schema.measurements)
      assert Enum.sort(Map.keys(tags)) == Enum.sort(schema.tags)
      assert Enum.all?(Map.values(m), &(is_number(&1) and &1 >= 0))
      assert Enum.all?(Map.values(tags), &(is_binary(&1) or is_integer(&1)))

      refute Enum.any?(
               Map.keys(tags),
               &(&1 in [:user_id, :request_id, :job_id, :socket_id, :ip, :email])
             )
    end

    records
  end

  test "endpoint projects one count and milliseconds with status, no connection data" do
    {_, records} =
      capture(fn ->
        for status <- [200, 302, 400, 403, 404, 429, 500, 503] do
          emit([:phoenix, :endpoint, :stop], %{conn: conn(status)})
        end
      end)

    assert length(safe!(records)) == 8

    assert Enum.map(rows(records, :http), &elem(&1, 1).status) == [
             200,
             302,
             400,
             403,
             404,
             429,
             500,
             503
           ]

    assert Enum.all?(rows(records, :http), &(elem(&1, 0) == %{count: 1, duration_ms: 1.5}))
  end

  test "invalid duration/status/foreign endpoint cannot invent zero duration or leak fields" do
    {_, records} =
      capture(fn ->
        for duration <- [nil, -1, 1.5, @secret, %{}, []] do
          emit([:phoenix, :endpoint, :stop], %{conn: conn()}, %{duration: duration})
        end

        for status <- [nil, 99, 600, @secret],
            do: emit([:phoenix, :endpoint, :stop], %{conn: conn(status)})

        emit([:phoenix, :endpoint, :stop], %{
          conn: %{conn() | private: %{phoenix_endpoint: OtherEndpoint}}
        })

        Anime.Metrics.handle([:phoenix, :endpoint, :stop], nil, @secret, nil)
      end)

    assert records == []
  end

  test "router takes only registered template and method pairs, not path or query" do
    {_, records} =
      capture(fn ->
        emit([:phoenix, :router_dispatch, :stop], %{
          conn: conn(),
          route: "/u/:nick",
          path_params: %{nick: @secret}
        })

        emit([:phoenix, :router_dispatch, :stop], %{
          conn: put_in(conn().private[:anime_metrics_method], "HEAD"),
          route: "/u/:nick"
        })

        emit([:phoenix, :router_dispatch, :exception], %{
          conn: conn(),
          route: "/u/:nick",
          reason: @secret,
          stacktrace: [@secret]
        })
      end)

    safe!(records)

    assert rows(records, :router) == [
             {%{count: 1, duration_ms: 1.5}, %{route: "/u/:nick", method: "GET"}},
             {%{count: 1, duration_ms: 1.5}, %{route: "/u/:nick", method: "HEAD"}}
           ]

    assert rows(records, :router_exception) == [{%{count: 1}, %{route: "/u/:nick"}}]
  end

  test "arbitrary routes, verbs and impossible pairs collapse to one label set" do
    {_, records} =
      capture(fn ->
        for i <- 1..100 do
          emit([:phoenix, :router_dispatch, :stop], %{
            conn: %{conn() | method: @secret <> to_string(i)},
            route: "/" <> @secret <> to_string(i)
          })
        end

        emit([:phoenix, :router_dispatch, :stop], %{
          conn: %{conn() | method: "DELETE"},
          route: "/u/:nick"
        })
      end)

    assert length(safe!(records)) == 101

    assert records |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == [
             %{route: "[unknown]", method: "[unknown]"}
           ]
  end

  test "LiveView durations distinguish static and connected mount without socket IDs" do
    {_, records} =
      capture(fn ->
        for pid <- [nil, self()] do
          emit([:phoenix, :live_view, :mount, :stop], %{
            socket: %Phoenix.LiveView.Socket{
              view: AnimeWeb.AuthLive,
              transport_pid: pid,
              id: @secret
            },
            session: %{token: @secret}
          })
        end

        for stage <- [:handle_params, :handle_event] do
          emit([:phoenix, :live_view, stage, :stop], %{
            socket: %Phoenix.LiveView.Socket{view: AnimeWeb.AuthLive},
            params: %{password: @secret}
          })
        end
      end)

    safe!(records)

    assert Enum.map(rows(records, :live_mount), &elem(&1, 1).connection) == [
             "static",
             "connected"
           ]

    assert rows(records, :live_event) == [
             {%{count: 1, duration_ms: 1.5}, %{view: "AnimeWeb.AuthLive"}}
           ]

    assert length(rows(records, :live_params)) == 1
  end

  test "LiveView exception events are allowed per view, not a Cartesian product" do
    {_, records} =
      capture(fn ->
        for {view, event} <- [
              {AnimeWeb.AuthLive, "submit"},
              {AnimeWeb.AuthLive, "select_page"},
              {OtherView, "submit"},
              {AnimeWeb.AuthLive, @secret}
            ] do
          emit([:phoenix, :live_view, :handle_event, :exception], %{
            socket: %Phoenix.LiveView.Socket{view: view},
            event: event,
            reason: @secret
          })
        end

        emit([:phoenix, :live_view, :mount, :exception], %{
          socket: %Phoenix.LiveView.Socket{view: AnimeWeb.ProfileLive},
          reason: @secret
        })
      end)

    safe!(records)

    assert Enum.map(rows(records, :live_event_exception), &elem(&1, 1)) == [
             %{view: "AnimeWeb.AuthLive", event: "submit"},
             %{view: "AnimeWeb.AuthLive", event: "[unknown]"},
             %{view: "[unknown]", event: "[unknown]"},
             %{view: "AnimeWeb.AuthLive", event: "[unknown]"}
           ]

    assert length(rows(records, :live_mount_exception)) == 1
  end

  test "Oban projects worker and closed outcome, never args/meta/attempts/IDs" do
    job = %Oban.Job{
      id: 424_242,
      worker: "Anime.Workers.Mail",
      args: %{"secret" => @secret},
      meta: %{"request_id" => @secret},
      attempt: 1,
      max_attempts: 2
    }

    {_, records} =
      capture(fn ->
        emit([:oban, :job, :stop], %{job: job, state: :success, result: @secret})

        for state <- [:failure, :discard, @secret],
            do: emit([:oban, :job, :exception], %{job: job, state: state, reason: @secret})

        emit([:oban, :job, :stop], %{job: %{job | worker: @secret}, state: :success})
      end)

    safe!(records)

    assert Enum.map(rows(records, :job), &elem(&1, 1).worker) == [
             "Anime.Workers.Mail",
             "[unknown]"
           ]

    assert Enum.map(rows(records, :job_exception), &elem(&1, 1).outcome) == [
             "failure",
             "discard",
             "[unknown]"
           ]
  end

  test "operational counters have finite labels and ignore supplied counts and payloads" do
    {_, records} =
      capture(fn ->
        emit(
          [:anime, :access, :denied],
          %{permission: "users.user.edit", user_id: 42, email: @secret},
          %{count: @secret}
        )

        emit([:anime, :access, :denied], %{permission: @secret})
        emit([:anime, :rate_limit, :rejected], %{scope: "login", subject: @secret})
        emit([:anime, :rate_limit, :rejected], %{scope: @secret})

        emit([:anime, :client_ip, :rejected], %{
          reason: :untrusted_peer,
          transport: :websocket,
          ip: @secret
        })

        emit([:anime, :client_ip, :rejected], %{reason: @secret, transport: @secret})
      end)

    safe!(records)

    assert rows(records, :access_denied) == [
             {%{count: 1}, %{permission: "users.user.edit"}},
             {%{count: 1}, %{permission: "[unknown]"}}
           ]

    assert rows(records, :rate_limited) == [
             {%{count: 1}, %{scope: "login"}},
             {%{count: 1}, %{scope: "[unknown]"}}
           ]

    assert rows(records, :proxy_rejected) == [
             {%{count: 1}, %{reason: "untrusted_peer", transport: "websocket"}},
             {%{count: 1}, %{reason: "[unknown]", transport: "[unknown]"}}
           ]
  end

  test "observer restart reattaches exactly once and never stores observations" do
    on_exit(fn ->
      unless Process.whereis(Anime.Metrics),
        do: Supervisor.restart_child(Anime.Supervisor, Anime.Metrics)
    end)

    {_, records} =
      capture(fn ->
        :ok = Supervisor.terminate_child(Anime.Supervisor, Anime.Metrics)
        {:ok, _} = Supervisor.restart_child(Anime.Supervisor, Anime.Metrics)
        emit([:phoenix, :endpoint, :stop], %{conn: conn()})
      end)

    assert length(safe!(records)) == 1
    assert :sys.get_state(Anime.Metrics) == nil

    assert Enum.count(
             :telemetry.list_handlers([:phoenix, :endpoint, :stop]),
             &(&1.id == Anime.Metrics)
           ) == 1
  end

  test "malformed observation does not detach the projector or leak the error" do
    {_, records} =
      capture(fn ->
        Anime.Metrics.handle(
          [:phoenix, :router_dispatch, :stop],
          %{duration: @duration},
          %{conn: conn(), route: @secret},
          nil
        )

        emit([:phoenix, :endpoint, :stop], %{conn: conn()})
      end)

    assert safe!(records) |> rows(:projection_error) == [{%{count: 1}, %{}}]
    assert length(rows(records, :http)) == 1
  end

  test "registered routes and permissions have bounded domains without a metrics route" do
    domains = Anime.Metrics.domains()
    assert MapSet.size(domains.route_pairs) + 1 <= 500
    assert MapSet.size(domains.permissions) + 1 <= 500
    refute MapSet.member?(domains.routes, "/metrics")
    assert map_size(Anime.Metrics.contracts()) == length(Anime.Metrics.events())
  end

  test "known user editor exception names are not collapsed to unknown" do
    {_, records} =
      capture(fn ->
        for event <- ["validate_edit", "activity_filter"] do
          emit([:phoenix, :live_view, :handle_event, :exception], %{
            socket: %Phoenix.LiveView.Socket{view: AnimeWeb.UserAdminLive},
            event: event,
            reason: @secret
          })
        end
      end)

    safe!(records)

    assert Enum.map(rows(records, :live_event_exception), &elem(&1, 1).event) == [
             "validate_edit",
             "activity_filter"
           ]
  end
end
