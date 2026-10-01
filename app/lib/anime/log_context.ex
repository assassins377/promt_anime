defmodule Anime.LogContext do
  @moduledoc "Request correlation only; never stores user, form or job arguments."
  require Logger

  def valid_id(value) when is_binary(value) and byte_size(value) in 20..200 do
    if Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, value), do: value
  end

  def valid_id(_), do: nil
  def current, do: valid_id(Logger.metadata()[:request_id])

  def generate(prefix),
    do: prefix <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  def put(id), do: Logger.metadata(request_id: valid_id(id))

  def with_id(id, fun) do
    previous = current()
    put(id)

    try do
      fun.()
    after
      put(previous)
    end
  end

  @doc "Capture the validated ID and bounded metrics origin, restoring the process afterwards."
  def wrap(fun) when is_function(fun, 0) do
    id = current()
    source = Anime.Metrics.Context.current()

    fn ->
      Anime.Metrics.Context.with_source(source, fn ->
        with_id(id, fn ->
          try do
            fun.()
          catch
            kind, reason ->
              Anime.Log.emit(:async_failed)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end
        end)
      end)
    end
  end

  def job_options(worker, opts) do
    meta = Keyword.get(opts, :meta, %{}) |> Map.new()

    id =
      if meta[:cron] == true || meta["cron"] == true do
        stamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")
        "cron-#{inspect(worker)}-#{stamp}"
      else
        current() || generate("job")
      end

    # Caller-supplied correlation is not authority; always use server context.
    meta = meta |> Map.delete(:request_id) |> Map.put("request_id", id)
    Keyword.put(opts, :meta, meta)
  end

  def job_id(%Oban.Job{} = job) do
    valid_id((job.meta || %{})["request_id"]) ||
      "job-" <>
        Base.url_encode64(:crypto.hash(:sha256, "#{job.worker}:#{job.id}"), padding: false)
  end

  def begin_job(job) do
    stack = Process.get({__MODULE__, :jobs}, [])
    Process.put({__MODULE__, :jobs}, [{job.id, current()} | stack])
    put(job_id(job))
  end

  def end_job(job) do
    case Process.get({__MODULE__, :jobs}, []) do
      [{id, previous} | rest] when id == job.id ->
        if rest == [],
          do: Process.delete({__MODULE__, :jobs}),
          else: Process.put({__MODULE__, :jobs}, rest)

        put(previous)

      _ ->
        :ok
    end
  end
end
