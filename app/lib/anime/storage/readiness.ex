defmodule Anime.Storage.Readiness do
  @moduledoc "Short-lived storage availability only; never an authorization cache."
  @table :anime_storage_readiness
  def table, do: @table

  def ready?(opts \\ []) do
    table = Keyword.get(opts, :table, @table)
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    probe = Keyword.get(opts, :probe, &probe/0)
    timeout = Keyword.get(opts, :timeout, 2000)
    # Pin this incarnation: an in-flight result must not populate a restarted owner.
    id = if is_atom(table), do: :ets.whereis(table), else: table

    case :ets.lookup(id, :result) do
      [{:result, value, expires}] when is_boolean(value) ->
        if clock.() < expires, do: value, else: refresh(id, probe, clock, timeout)

      [] ->
        refresh(id, probe, clock, timeout)
    end
  rescue
    ArgumentError -> false
  end

  defp refresh(table, probe, clock, timeout) do
    task =
      Task.Supervisor.async_nolink(Anime.Tasks, fn ->
        try do
          probe.() == true
        rescue
          _ -> false
        catch
          _, _ -> false
        end
      end)

    value =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> false
      end

    :ets.insert(table, {:result, value, clock.() + 10_000})
    value
  catch
    :exit, _ -> false
  end

  defp probe do
    match?({:ok, _}, ExAws.S3.list_buckets() |> ExAws.request(retries: [max_attempts: 1]))
  end
end
