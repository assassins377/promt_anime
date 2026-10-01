defmodule Anime.Repo do
  use Ecto.Repo, otp_app: :anime, adapter: Ecto.Adapters.Postgres

  @after_commit_key {__MODULE__, :after_commit}
  defoverridable transact: 2, checkout: 2

  # DBConnection.run (used by checkout) raises acquisition errors without an
  # Ecto query event. Only observe failures before the caller's callback starts:
  # a query or nested checkout inside it owns its own timeout measurement.
  def checkout(fun, opts) when is_function(fun) do
    acquired = {__MODULE__, :checkout_acquired, make_ref()}

    try do
      super(
        fn ->
          Process.put(acquired, true)
          fun.()
        end,
        opts
      )
    rescue
      error in DBConnection.ConnectionError ->
        if error.reason == :queue_timeout and Process.get(acquired) != true do
          :telemetry.execute([:anime, :repo, :checkout_timeout], %{count: 1}, %{repo: __MODULE__})
        end

        reraise error, __STACKTRACE__
    after
      Process.delete(acquired)
    end
  end

  # Nested transactions share the outer queue. No notification may escape a
  # transaction that subsequently rolls back, including Ecto.Multi failures.
  def transact(fun_or_multi, opts) do
    if in_transaction?() do
      super(fun_or_multi, opts)
    else
      Process.put(@after_commit_key, [])

      try do
        result = super(fun_or_multi, opts)
        callbacks = Process.delete(@after_commit_key)

        if match?({:ok, _}, result) do
          callbacks |> Enum.reverse() |> Enum.each(& &1.())
        end

        result
      after
        Process.delete(@after_commit_key)
      end
    end
  end

  @doc "Run after the outer Repo transaction commits, or immediately outside a transaction."
  def after_commit(callback) when is_function(callback, 0) do
    if in_transaction?() do
      case Process.get(@after_commit_key) do
        callbacks when is_list(callbacks) ->
          Process.put(@after_commit_key, [callback | callbacks])

        _ ->
          raise ArgumentError, "after_commit requires a transaction started through Anime.Repo"
      end
    else
      callback.()
    end

    :ok
  end
end
