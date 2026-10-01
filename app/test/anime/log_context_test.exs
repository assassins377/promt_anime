defmodule Anime.LogContextTest do
  use ExUnit.Case, async: true
  alias Anime.LogContext
  import ExUnit.CaptureLog
  @id "http-correlation-1234567890"

  setup do
    Logger.reset_metadata()
    on_exit(fn -> Logger.reset_metadata() end)
    :ok
  end

  test "current context validates IDs and nested scopes restore even after an exception" do
    LogContext.put(@id)

    assert_raise RuntimeError, fn ->
      LogContext.with_id("inner-correlation-123456", fn ->
        assert LogContext.current() == "inner-correlation-123456"
        raise "synthetic"
      end)
    end

    assert LogContext.current() == @id
    LogContext.put("bad\nrequest")
    assert LogContext.current() == nil
  end

  test "wrapped work snapshots only request ID at creation, not caller metadata" do
    Logger.metadata(request_id: @id, private: "NEVER_TRANSFER")
    work = LogContext.wrap(fn -> Logger.metadata() end)
    LogContext.put("changed-parent-123456789")
    result = Task.async(work) |> Task.await()
    assert result[:request_id] == @id
    refute Keyword.has_key?(result, :private)
    assert LogContext.current() == "changed-parent-123456789"
  end

  test "wrapped work restores executor context and nested jobs inherit its captured ID" do
    LogContext.put(@id)
    work = LogContext.wrap(fn -> Ecto.Changeset.get_field(Anime.Workers.Mail.new(%{}), :meta) end)
    LogContext.put("executor-context-123456789")
    assert work.()["request_id"] == @id
    assert LogContext.current() == "executor-context-123456789"
  end

  test "missing or invalid captured ID clears stale executor ID only for the callback" do
    Logger.metadata(request_id: "bad\nID")
    work = LogContext.wrap(fn -> LogContext.current() end)
    LogContext.put(@id)
    assert work.() == nil
    assert LogContext.current() == @id
  end

  test "raise throw and exit log no reason, preserve semantics and restore context" do
    for {kind, fun} <- [
          {:error, fn -> raise "WRAPPED_PRIVATE" end},
          {:throw, fn -> throw("WRAPPED_PRIVATE") end},
          {:exit, fn -> exit("WRAPPED_PRIVATE") end}
        ] do
      LogContext.put(@id)
      work = LogContext.wrap(fun)
      LogContext.put("executor-context-123456789")

      output =
        capture_log(fn ->
          # CaptureLog also receives other async tests' Logger events. Keep a
          # foreign request here so this isolation regression is deterministic.
          LogContext.with_id("foreign-context-123456789", fn -> Anime.Log.emit(:async_failed) end)

          try do
            work.()
            flunk("callback did not propagate failure")
          catch
            ^kind, reason ->
              if kind == :error,
                do: assert(reason.message == "WRAPPED_PRIVATE"),
                else: assert(reason == "WRAPPED_PRIVATE")
          end
        end)

      rows = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      assert Enum.any?(rows, &(&1["request_id"] == "foreign-context-123456789"))
      [row] = Enum.filter(rows, &(&1["request_id"] == @id))
      assert row["request_id"] == @id
      assert row["message"] == "Asynchronous callback failed"
      assert row["level"] == "error"
      refute output =~ "WRAPPED_PRIVATE"
      assert LogContext.current() == "executor-context-123456789"
    end
  end

  test "all current workers persist correlation through both new arities" do
    LogContext.put(@id)

    for worker <- [
          Anime.Workers.Mail,
          Anime.Workers.ExpireAccounts,
          Anime.Workers.UnblockUsers,
          Anime.Workers.DeleteAccounts
        ] do
      for opts <- [[], [meta: %{request_id: "forged-request-id-123456", custom: "kept"}]] do
        changeset = if opts == [], do: worker.new(%{}), else: worker.new(%{}, opts)
        meta = Ecto.Changeset.get_field(changeset, :meta)
        assert meta["request_id"] == @id
        refute Map.has_key?(meta, :request_id)
      end
    end
  end

  test "cron overrides stale process context and retains cron metadata" do
    LogContext.put(@id)

    for meta <- [%{cron: true, cron_expr: "* * * * *"}, %{"cron" => true}] do
      job = Anime.Workers.ExpireAccounts.new(%{}, meta: meta) |> Ecto.Changeset.apply_changes()

      assert job.meta["request_id"] =~
               ~r/^cron-Anime\.Workers\.ExpireAccounts-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d{6}Z$/

      assert LogContext.valid_id(job.meta["request_id"])
      assert job.meta[:cron] || job.meta["cron"]
    end
  end

  test "jobs outside HTTP receive unique IDs without taking request_id from args" do
    a = Anime.Workers.Mail.new(%{request_id: @id}) |> Ecto.Changeset.apply_changes()
    b = Anime.Workers.Mail.new(%{}) |> Ecto.Changeset.apply_changes()
    assert String.starts_with?(a.meta["request_id"], "job-")
    assert a.meta["request_id"] != @id
    assert a.meta["request_id"] != b.meta["request_id"]
  end

  test "legacy rows without meta ID get a deterministic safe fallback" do
    job = %Oban.Job{id: 15, worker: "Anime.Workers.Mail", meta: %{}}
    assert LogContext.job_id(job) == LogContext.job_id(job)
    assert LogContext.valid_id(LogContext.job_id(job))
    assert LogContext.job_id(job) != LogContext.job_id(%{job | id: 16})

    assert LogContext.job_id(job) ==
             LogContext.job_id(%{job | meta: %{"request_id" => "bad\nid"}})
  end

  test "nested job contexts restore and parent work ID reaches child changesets" do
    LogContext.put(@id)
    a = %Oban.Job{id: 1, meta: %{"request_id" => "parent-correlation-123456"}}
    b = %Oban.Job{id: 2, meta: %{"request_id" => "nested-correlation-123456"}}
    LogContext.begin_job(a)

    assert Ecto.Changeset.get_field(Anime.Workers.Mail.new(%{}), :meta)["request_id"] ==
             a.meta["request_id"]

    LogContext.begin_job(b)
    LogContext.end_job(b)
    assert LogContext.current() == a.meta["request_id"]
    LogContext.end_job(a)
    assert LogContext.current() == @id
    LogContext.end_job(a)
    assert LogContext.current() == @id
  end
end
