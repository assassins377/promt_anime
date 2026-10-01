defmodule Anime.OperationalMetricsTest do
  use Anime.DataCase
  import Anime.MetricsProbe
  alias Anime.{Access, Audit, RateLimits}
  @secret "PRIVATE-METRIC-SENTINEL"

  test "real permission denial emits once, allowed probe and validation do not" do
    u = user()

    {_, records} =
      capture(fn ->
        refute Access.allowed?(u, "users.user.edit")

        assert {:error, :forbidden} =
                 Access.protect(u, "users.user.edit", "User", u.id, fn _ -> :never end)

        Audit.record(u, "users.user.edit", "User", u.id, :denied, %{
          new_value: %{reason: "validation", private: @secret}
        })
      end)

    assert rows(records, :access_denied) == [{%{count: 1}, %{permission: "users.user.edit"}}]
    for hidden <- [u.email, u.nick, @secret], do: refute(inspect(records) =~ hidden)
  end

  test "rate rejection survives rollback and multiple windows don't double count it" do
    {:ok, :ok} =
      Repo.transaction(fn -> RateLimits.consume("register", @secret, [{3600, 1}, {86400, 1}]) end)

    {_, records} =
      capture(fn ->
        assert {:error, :rate_limited} =
                 Repo.transaction(fn ->
                   RateLimits.consume("register", @secret, [{3600, 1}, {86400, 1}])
                 end)
      end)

    assert rows(records, :rate_limited) == [{%{count: 1}, %{scope: "register"}}]
    refute inspect(records) =~ @secret
  end

  test "login threshold and active lock each count once without login or IP" do
    u = user()
    for _ <- 1..4, do: Anime.Accounts.authenticate(u.email, @secret, meta())

    for _ <- 1..2 do
      {_, records} = capture(fn -> Anime.Accounts.authenticate(u.email, @secret, meta()) end)
      assert rows(records, :rate_limited) == [{%{count: 1}, %{scope: "login"}}]
      for hidden <- [u.email, @secret, meta().ip], do: refute(inspect(records) =~ hidden)
    end
  end

  test "real mail job success and retry expose only worker and closed outcome" do
    u = user()
    {_, records} = capture(fn -> assert %{success: 1} = Oban.drain_queue(queue: :mailers) end)

    assert [{%{count: 1, duration_ms: duration}, %{worker: "Anime.Workers.Mail"}}] =
             rows(records, :job)

    assert duration >= 0
    refute inspect(records) =~ u.email

    # A real worker call with malformed internal arguments retries via the Oban
    # executor; the deliberately private argument must never become a label.
    Anime.Workers.Mail.new(%{"private" => @secret}, max_attempts: 2) |> Oban.insert!()

    for outcome <- ["failure", "discard"] do
      {_, records} =
        capture(fn ->
          Oban.drain_queue(queue: :mailers, with_scheduled: true, with_safety: true)
        end)

      assert rows(records, :job_exception) == [
               {%{count: 1}, %{worker: "Anime.Workers.Mail", outcome: outcome}}
             ]

      refute inspect(records) =~ @secret
    end
  end

  test "IP-only threshold and its active block keep login_ip scope" do
    u = user()

    {:ok, _} =
      Repo.transaction(fn ->
        for _ <- 1..49, do: RateLimits.consume("login_ip", "ip:" <> meta().ip, [{900, 50}])
      end)

    for expected_result <- [{:error, :invalid_credentials}, {:error, :rate_limited}] do
      {result, records} = capture(fn -> Anime.Accounts.authenticate(u.email, @secret, meta()) end)
      assert result == expected_result
      assert rows(records, :rate_limited) == [{%{count: 1}, %{scope: "login_ip"}}]
      refute inspect(records) =~ meta().ip
    end
  end

  test "simultaneous login and IP thresholds count once per distinct scope, not once per request" do
    u = user()

    {:ok, _} =
      Repo.transaction(fn ->
        for _ <- 1..49, do: RateLimits.consume("login_ip", "ip:" <> meta().ip, [{900, 50}])

        for _ <- 1..4,
            do: RateLimits.consume("login", Jason.encode!([u.email, meta().ip]), [{900, 5}])
      end)

    for _ <- 1..2 do
      {_, records} = capture(fn -> Anime.Accounts.authenticate(u.email, @secret, meta()) end)

      assert records |> rows(:rate_limited) |> Enum.map(&elem(&1, 1).scope) |> Enum.sort() == [
               "login",
               "login_ip"
             ]
    end
  end
end
