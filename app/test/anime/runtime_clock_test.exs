defmodule Anime.RuntimeClockTest do
  use ExUnit.Case, async: false
  alias Anime.RuntimeClock

  test "capture pairs a wall-clock timestamp with a monotonic anchor" do
    before = System.system_time(:second)
    anchor = RuntimeClock.capture()
    assert anchor.started_at >= before
    assert anchor.started_at <= System.system_time(:second)
    assert anchor.monotonic_ms <= System.monotonic_time(:millisecond)
  end

  test "elapsed time is monotonic and does not recompute the wall-clock start" do
    source = start_supervised!({Agent, fn -> -20_000 end})
    clock = clock(source)
    assert RuntimeClock.measure(clock) == {:ok, %{started_at: 1_000, uptime_ms: 0}}
    Agent.update(source, fn _ -> -18_765 end)
    assert RuntimeClock.measure(clock) == {:ok, %{started_at: 1_000, uptime_ms: 1_235}}
  end

  test "supervised clock restart retains the original application anchor" do
    source = start_supervised!({Agent, fn -> -20_000 end})
    name = Anime.TestRuntimeClock
    pid = clock(source, name: name)
    Agent.update(source, fn _ -> -10_000 end)
    Process.exit(pid, :kill)
    eventually(fn -> Process.whereis(name) != nil and Process.whereis(name) != pid end)
    assert RuntimeClock.measure(name) == {:ok, %{started_at: 1_000, uptime_ms: 10_000}}
  end

  test "a new application anchor starts a new lifetime" do
    source = start_supervised!({Agent, fn -> -19_000 end})
    old = clock(source)
    assert RuntimeClock.measure(old) == {:ok, %{started_at: 1_000, uptime_ms: 1_000}}
    stop_supervised!(RuntimeClock)
    new = clock(source, anchor: %{started_at: 1_001, monotonic_ms: -19_000})
    assert RuntimeClock.measure(new) == {:ok, %{started_at: 1_001, uptime_ms: 0}}
  end

  test "a backwards clock is unavailable rather than negative or fabricated uptime" do
    source = start_supervised!({Agent, fn -> -20_001 end})
    assert RuntimeClock.measure(clock(source)) == :unavailable
  end

  test "the supervised application has a live shared clock even with samplers disabled" do
    assert {:ok, %{started_at: start, uptime_ms: elapsed}} = RuntimeClock.measure()
    assert start <= System.system_time(:second)
    assert elapsed >= 0
  end

  defp clock(source, options \\ []) do
    options =
      Keyword.merge(
        [
          name: nil,
          anchor: %{started_at: 1_000, monotonic_ms: -20_000},
          clock: fn -> Agent.get(source, & &1) end
        ],
        options
      )

    start_supervised!({RuntimeClock, options})
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end
end
