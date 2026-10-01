defmodule Anime.WebSupervisorTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  setup do
    Anime.Shutdown.reset()
    on_exit(&Anime.Shutdown.reset/0)
    :ok
  end

  defmodule EndpointProbe do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    def init(parent) do
      send(parent, {:endpoint_started, self()})
      {:ok, parent}
    end
  end

  test "loss of tracker restarts endpoint instead of retaining untracked sockets" do
    scope = __MODULE__.Transports

    server =
      start_supervised!(
        {Anime.WebSupervisor,
         name: __MODULE__.Supervisor, transports_name: scope, endpoint: {EndpointProbe, self()}}
      )

    assert_receive {:endpoint_started, old}, 1000
    ref = Process.monitor(old)
    tracker = Process.whereis(scope)
    Process.exit(tracker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :shutdown}, 1000
    assert_receive {:endpoint_started, new}, 1000
    refute new == old
    refute Process.whereis(scope) == tracker
    assert Process.alive?(server)
    assert Anime.LiveTransports.snapshot(scope) == []
  end

  test "endpoint is not restarted after rejection begins" do
    server =
      start_supervised!(
        {Anime.WebSupervisor,
         name: __MODULE__.Supervisor,
         transports_name: __MODULE__.Transports,
         endpoint: {EndpointProbe, self()}}
      )

    assert_receive {:endpoint_started, old}, 1000
    ref = Process.monitor(old)
    Anime.Shutdown.begin_rejection()
    Process.exit(Process.whereis(__MODULE__.Transports), :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :shutdown}, 1000
    # Calling the supervisor is a barrier after its restart sequence.
    assert {EndpointProbe, :undefined, :worker, [EndpointProbe]} in Supervisor.which_children(
             server
           )

    refute_receive {:endpoint_started, _}, 100
  end
end
