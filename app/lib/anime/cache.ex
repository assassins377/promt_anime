defmodule Anime.Cache do
  @moduledoc """
  Supervised owner of application ETS caches. Queue 1 implements only the
  role-permission presentation cache and storage readiness; authorization never reads them.
  """
  use GenServer

  @permissions :anime_role_permissions
  @topic "cache:invalidate"
  @timeout 1_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def permissions_table, do: @permissions

  @doc "Implemented application caches only; no enumeration of framework/private ETS."
  def inventory, do: [@permissions, Anime.Storage.Readiness.table()]

  @doc "Local numeric table statistics, shared with the future Cache screen. No entries are read."
  def statistics do
    Map.new(inventory(), fn name -> {name, table_statistics(name)} end)
  end

  defp table_statistics(name) do
    # Keep the exact table identity across reads, never combine two incarnations
    # of a named table during an owner restart. Counts themselves are not atomic.
    with owner when is_pid(owner) <- Process.whereis(__MODULE__),
         table when is_reference(table) <- :ets.whereis(name),
         ^owner <- :ets.info(table, :owner),
         entries when is_integer(entries) <- :ets.info(table, :size),
         words when is_integer(words) <- :ets.info(table, :memory),
         ^owner <- :ets.info(table, :owner),
         ^owner <- Process.whereis(__MODULE__),
         ^table <- :ets.whereis(name) do
      %{entries: entries, memory_bytes: words * :erlang.system_info(:wordsize)}
    else
      _ -> :unavailable
    end
  rescue
    ArgumentError -> :unavailable
  end

  @doc "UI-only role permissions. Database work runs in the caller, never in the ETS owner."
  def role_permissions(role_id, loader) when is_integer(role_id) and is_function(loader, 0) do
    # Uncommitted grants must neither read a shared snapshot nor enter the cache.
    if Anime.Repo.in_transaction?(),
      do: loader.() |> MapSet.new(),
      else: fetch(role_id, loader, 1)
  end

  @doc "Invalidate after commit on every node, including synchronous invalidation locally."
  def invalidate_permissions(key \\ :all)
      when key == :all or (is_integer(key) and key > 0) do
    id = Anime.LogContext.current()

    Anime.Repo.after_commit(fn ->
      message = {:cache_invalidate, @permissions, key, id}

      # Exclude only the owner that acknowledged the local invalidation. A new
      # owner starting in between will still receive the PubSub notification.
      case call({:invalidate, key, id}) do
        {:ok, owner} -> Phoenix.PubSub.broadcast_from(Anime.PubSub, owner, @topic, message)
        :unavailable -> Phoenix.PubSub.broadcast(Anime.PubSub, @topic, message)
      end
    end)
  end

  defp fetch(role_id, loader, retries) do
    case call({:lookup, role_id}) do
      {:hit, codes} ->
        codes

      {:miss, generation} ->
        codes = loader.() |> MapSet.new()

        case call({:store, role_id, generation, codes}) do
          :ok -> codes
          _ when retries > 0 -> fetch(role_id, loader, retries - 1)
          _ -> loader.() |> MapSet.new()
        end

      :unavailable ->
        loader.() |> MapSet.new()
    end
  end

  defp call(message) do
    GenServer.call(__MODULE__, message, @timeout)
  catch
    :exit, _ -> :unavailable
  end

  @impl true
  def init(:ok) do
    :ets.new(Anime.Storage.Readiness.table(), [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    :ets.new(@permissions, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ok = Phoenix.PubSub.subscribe(Anime.PubSub, @topic)
    {:ok, make_ref()}
  end

  @impl true
  def handle_call({:lookup, role_id}, _from, generation) do
    result =
      case :ets.lookup(@permissions, role_id) do
        [{^role_id, %MapSet{} = codes}] -> {:hit, codes}
        _ -> {:miss, generation}
      end

    {:reply, result, generation}
  end

  def handle_call({:store, role_id, expected, codes}, _from, generation) do
    if expected == generation do
      :ets.insert(@permissions, {role_id, codes})
      {:reply, :ok, generation}
    else
      {:reply, :stale, generation}
    end
  end

  def handle_call({:invalidate, key}, _from, _generation) do
    {:reply, {:ok, self()}, invalidate_with_context(key, nil)}
  end

  def handle_call({:invalidate, key, id}, _from, _generation) do
    {:reply, {:ok, self()}, invalidate_with_context(key, id)}
  end

  @impl true
  def handle_info({:cache_invalidate, @permissions, key}, _generation)
      when key == :all or (is_integer(key) and key > 0) do
    {:noreply, invalidate_with_context(key, nil)}
  end

  def handle_info({:cache_invalidate, @permissions, key, id}, _generation)
      when key == :all or (is_integer(key) and key > 0) do
    {:noreply, invalidate_with_context(key, id)}
  end

  def handle_info(_message, generation), do: {:noreply, generation}

  defp invalidate_with_context(key, id) do
    Anime.LogContext.with_id(id, fn ->
      generation = invalidate(key)
      Anime.Log.emit(:permissions_cache_reset)
      generation
    end)
  end

  defp invalidate(:all) do
    :ets.delete_all_objects(@permissions)
    make_ref()
  end

  defp invalidate(role_id) do
    :ets.delete(@permissions, role_id)
    # A generation reference covers in-flight loads as well as existing entries;
    # it also changes when the owner restarts, without another ETS metadata table.
    make_ref()
  end
end
