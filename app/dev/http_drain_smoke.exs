# Standalone loopback Bandit only, no application, database or external requests.
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:req)

defmodule DrainProbePlug do
  def init(parent), do: parent

  def call(conn, parent) do
    send(parent, {:request_started, self()})

    receive do
      :finish -> Plug.Conn.send_resp(conn, 200, "completed-before-shutdown")
    after
      60_000 -> Plug.Conn.send_resp(conn, 500, "fixture-timeout")
    end
  end
end

# First scenario deliberately holds a request beyond the configured drain budget.
{:ok, server} =
  Bandit.start_link(
    plug: {DrainProbePlug, self()},
    ip: {127, 0, 0, 1},
    port: 0,
    startup_log: false,
    thousand_island_options: [shutdown_timeout: 30_000]
  )

Process.unlink(server)

try do
  {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

  request =
    Task.async(fn ->
      Req.get("http://127.0.0.1:#{port}/", retry: false, receive_timeout: 40_000)
    end)

  handler =
    receive do
      {:request_started, pid} -> pid
    after
      2000 -> raise "No blocked request"
    end

  started = System.monotonic_time(:millisecond)
  :ok = Supervisor.stop(server, :normal, 35_000)
  elapsed = System.monotonic_time(:millisecond) - started
  true = elapsed >= 29_000 and elapsed < 35_000
  false = Process.alive?(handler)
  {:error, %Req.TransportError{reason: :closed}} = Task.await(request, 5_000)
  IO.puts("PASS: blocked HTTP request forcibly closed after #{elapsed}ms, not a client timeout")
after
  if Process.alive?(server), do: Supervisor.stop(server, :normal, 35_000)
end

{:ok, server} =
  Bandit.start_link(
    plug: {DrainProbePlug, self()},
    ip: {127, 0, 0, 1},
    port: 0,
    startup_log: false,
    thousand_island_options: [shutdown_timeout: 30_000]
  )

Process.unlink(server)

try do
  {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
  request = Task.async(fn -> Req.get!("http://127.0.0.1:#{port}/", retry: false) end)

  handler =
    receive do
      {:request_started, pid} -> pid
    after
      2000 -> raise "No request"
    end

  stop = Task.async(fn -> Supervisor.stop(server, :normal, 35_000) end)
  # Wait until the listener closes; the accepted handler must remain alive.
  closed =
    Enum.reduce_while(1..100, false, fn _, _ ->
      case :gen_tcp.connect({127, 0, 0, 1}, port, [], 100) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          Process.sleep(10)
          {:cont, false}

        {:error, :econnrefused} ->
          {:halt, true}

        _ ->
          {:cont, false}
      end
    end)

  true = closed
  true = Process.alive?(handler)
  send(handler, :finish)
  %{status: 200, body: "completed-before-shutdown"} = Task.await(request, 5_000)
  :ok = Task.await(stop, 5_000)

  IO.puts(
    "PASS: HTTP listener closes to new connections while accepted request finishes with 200"
  )
after
  if Process.alive?(server), do: Supervisor.stop(server, :normal, 35_000)
end
