defmodule Anime.OperationalLoggingTest do
  use Anime.DataCase
  import ExUnit.CaptureLog
  alias Anime.{Access, Audit, Cache, LogContext, RateLimits}
  @id "operation-context-123456789"
  @secret "OPERATION_PRIVATE"
  @moduletag :capture_log

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    LogContext.put(@id)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  defp records(output, message) do
    refute output =~ @secret

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message"] == message))
  end

  test "protected context denial has one safe warning and its existing audit record" do
    u = user()

    output =
      capture_log(fn ->
        assert {:error, :forbidden} =
                 Access.protect(u, "users.user.edit", "User", u.id, fn _ ->
                   flunk("denied function was called")
                 end)
      end)

    [row] = records(output, "Access denied")
    assert row["request_id"] == @id
    assert row["user_id"] == u.id
    assert row["level"] == "warning"
    refute output =~ u.email
    refute output =~ u.nick

    assert Repo.exists?(
             from a in Audit, where: a.action == "users.user.edit" and a.result == :denied
           )
  end

  test "guest denial omits user ID and a mere permission probe produces no denial" do
    output =
      capture_log(fn ->
        refute Access.allowed?(nil, "users.user.edit")

        assert {:error, :forbidden} =
                 Access.protect(nil, "users.user.edit", "User", nil, fn _ -> :never end)
      end)

    [row] = records(output, "Access denied")
    refute Map.has_key?(row, "user_id")
  end

  test "audit projection excludes sensitive values, validation and non-permission decisions" do
    u = user()

    for {action, reason, expected} <- [
          {"roles.matrix.edit", "cannot_grant", 1},
          {"roles.role.edit", "forbidden", 1},
          {"roles.role.edit", "validation", 0},
          {"roles.role.edit", "not_found", 0},
          {"login", nil, 0}
        ] do
      output =
        capture_log(fn ->
          Audit.record(u, action, "Role", nil, :denied, %{
            ip: "192.0.2.198",
            old_value: %{secret: @secret},
            new_value: %{reason: reason, secret: @secret}
          })
        end)

      assert length(records(output, "Access denied")) == expected
      refute output =~ "192.0.2.198"
      refute output =~ u.nick
    end
  end

  test "rate-limit warning survives rollback without its subject or scope in output" do
    subject = "ip:" <> @secret

    {:ok, :ok} =
      Repo.transaction(fn -> RateLimits.consume("register", subject, [{3600, 1}, {86400, 5}]) end)

    output =
      capture_log(fn ->
        assert {:error, :rate_limited} =
                 Repo.transaction(fn ->
                   RateLimits.consume("register", subject, [{3600, 1}, {86400, 5}])
                 end)
      end)

    [row] = records(output, "Rate limit reached")
    assert row["level"] == "warning"
    assert row["request_id"] == @id
    refute Map.has_key?(row, "subject")

    %{rows: counts} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT count FROM rate_limit_counters WHERE subject=$1", [
        subject
      ])

    assert counts == [[1], [1]]
  end

  test "login threshold and active lock each warn once and never log login or IP" do
    u = user()
    # The fifth failed attempt installs the lock; only that attempt reaches a limit.
    for _ <- 1..4, do: Anime.Accounts.authenticate(u.email, @secret, meta())

    for _ <- 1..2 do
      output = capture_log(fn -> Anime.Accounts.authenticate(u.email, @secret, meta()) end)
      [row] = records(output, "Rate limit reached")
      assert row["request_id"] == @id
      refute output =~ u.email
      refute output =~ meta().ip
    end
  end

  test "local cache reset is logged once inside owner, preserving both process contexts" do
    output = capture_log(fn -> Cache.invalidate_permissions() end)
    [row] = records(output, "Role permissions ETS cache reset")
    assert row["request_id"] == @id
    assert row["level"] == "info"
    assert LogContext.current() == @id
    {:dictionary, dictionary} = Process.info(Process.whereis(Cache), :dictionary)
    refute inspect(dictionary) =~ @id
  end

  test "cache reset logs after commit with captured ID but never after rollback" do
    output =
      capture_log(fn ->
        assert {:error, :cancel} =
                 Repo.transaction(fn ->
                   Cache.invalidate_permissions()
                   Repo.rollback(:cancel)
                 end)
      end)

    assert records(output, "Role permissions ETS cache reset") == []

    output =
      capture_log(fn ->
        assert {:ok, _} =
                 Repo.transaction(fn ->
                   Cache.invalidate_permissions()
                   LogContext.put("later-transaction-context-12345")
                 end)
      end)

    [row] = records(output, "Role permissions ETS cache reset")
    assert row["request_id"] == @id
    assert LogContext.current() == "later-transaction-context-12345"
  end

  test "subscriber accepts correlated and legacy invalidation without stale or forged IDs" do
    table = Cache.permissions_table()

    for {message, expected} <- [
          {{:cache_invalidate, table, :all, @id}, @id},
          {{:cache_invalidate, table, :all}, nil},
          {{:cache_invalidate, table, :all, "bad\n" <> @secret}, nil}
        ] do
      output =
        capture_log(fn ->
          send(Cache, message)
          :sys.get_state(Cache)
        end)

      [row] = records(output, "Role permissions ETS cache reset")
      assert row["request_id"] == expected
    end
  end
end
