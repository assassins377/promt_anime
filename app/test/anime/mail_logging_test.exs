defmodule Anime.MailLoggingTest do
  use Anime.DataCase
  import ExUnit.CaptureLog
  alias Anime.{LogContext, Mailer}
  @id "mail-original-request-12345"
  @secret "PRIVATE-MAIL-SENTINEL"

  defmodule Adapter do
    use Swoosh.Adapter

    def deliver(_, config) do
      case config[:mode] do
        :error ->
          {:error, "PRIVATE-MAIL-SENTINEL"}

        :smtp_permanent_connect ->
          {:error,
           {:no_more_hosts, {:permanent_failure, "private-relay", "550 PRIVATE-MAIL-SENTINEL"}}}

        :smtp_permanent_send ->
          {:error, {:send, {:permanent_failure, "private-relay", "550 PRIVATE-MAIL-SENTINEL"}}}

        :smtp_temporary ->
          {:error,
           {:retries_exceeded, {:temporary_failure, "private-relay", "450 PRIVATE-MAIL-SENTINEL"}}}

        :nil_error ->
          {:error, nil}

        :raise ->
          raise "PRIVATE-MAIL-SENTINEL"

        :throw ->
          throw("PRIVATE-MAIL-SENTINEL")

        :exit ->
          exit("PRIVATE-MAIL-SENTINEL")

        _ ->
          {:ok, %{receipt: "PRIVATE-MAIL-SENTINEL"}}
      end
    end

    def deliver_many(_, config), do: deliver(nil, config)
  end

  setup do
    previous = Application.fetch_env!(:anime, Mailer)
    LogContext.put(@id)
    on_exit(fn -> Application.put_env(:anime, Mailer, previous) end)
    :ok
  end

  defp email do
    Swoosh.Email.new()
    |> Swoosh.Email.to("private-recipient@example.test")
    |> Swoosh.Email.from("private-sender@example.test")
    |> Swoosh.Email.subject(@secret)
    |> Swoosh.Email.text_body("https://example.test/confirm/" <> @secret)
  end

  defp records(output) do
    for secret <- [@secret, "private-recipient", "private-sender", "example.test", "token_id"] do
      refute output =~ secret
    end

    output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp mail_record(output, message, level) do
    [row] = records(output) |> Enum.filter(&String.starts_with?(&1["message"], "Mail transport"))
    assert row["message"] == message
    assert row["level"] == level
    assert row["request_id"] == @id
    assert Enum.sort(Map.keys(row)) == ~w(app_version level message node request_id ts)
    row
  end

  test "test adapter acceptance is debug, not a claim of inbox delivery" do
    output = capture_log(fn -> assert {:ok, _} = Mailer.deliver(email()) end)
    assert_received {:email, %Swoosh.Email{}}
    mail_record(output, "Mail transport accepted message", "debug")
    assert LogContext.current() == @id
  end

  test "receipt and adapter config are never logged" do
    output =
      capture_log(fn ->
        assert {:ok, %{receipt: @secret}} =
                 Mailer.deliver(email(), adapter: Adapter, password: @secret)
      end)

    mail_record(output, "Mail transport accepted message", "debug")
  end

  test "returned transport errors including nil are error, once, and unchanged for caller" do
    for {mode, reason} <- [error: @secret, nil_error: nil] do
      output =
        capture_log(fn ->
          assert {:error, ^reason} = Mailer.deliver(email(), adapter: Adapter, mode: mode)
        end)

      mail_record(output, "Mail transport failed", "error")
      assert LogContext.current() == @id
    end
  end

  test "adapter raise, throw and exit retain behavior without leaking exception or stacktrace" do
    for mode <- [:raise, :throw, :exit] do
      output =
        capture_log(fn ->
          call = fn -> Mailer.deliver(email(), adapter: Adapter, mode: mode) end

          case mode do
            :raise -> assert_raise RuntimeError, @secret, call
            :throw -> assert catch_throw(call.()) == @secret
            :exit -> assert catch_exit(call.()) == @secret
          end
        end)

      mail_record(output, "Mail transport failed", "error")
      assert LogContext.current() == @id
    end
  end

  test "batch acceptance and error are one transport record per batch" do
    for {mode, expected, level} <- [
          {:ok, "Mail transport accepted message", "debug"},
          {:error, "Mail transport failed", "error"},
          {:raise, "Mail transport failed", "error"}
        ] do
      output =
        capture_log(fn ->
          call = fn -> Mailer.deliver_many([email(), email()], adapter: Adapter, mode: mode) end

          case mode do
            :ok -> assert {:ok, _} = call.()
            :error -> assert {:error, @secret} = call.()
            :raise -> assert_raise RuntimeError, @secret, call
          end
        end)

      mail_record(output, expected, level)
    end
  end

  test "foreign mailers and malformed stop metadata don't become delivery reports" do
    output =
      capture_log(fn ->
        :telemetry.execute([:swoosh, :deliver, :exception], %{}, %{
          mailer: OtherMailer,
          reason: @secret,
          email: email()
        })

        :telemetry.execute([:swoosh, :deliver, :stop], %{}, %{mailer: Mailer})
        :telemetry.execute([:swoosh, :deliver, :start], %{}, %{mailer: Mailer, email: email()})
      end)

    assert records(output) == []
  end

  test "real mail job logs transport failure and Oban retry, then acceptance with original ID" do
    u = user()
    job = Repo.one!(from j in Oban.Job, order_by: [desc: j.id], limit: 1)
    Application.put_env(:anime, Mailer, adapter: Adapter, mode: :error, password: @secret)
    LogContext.put("unrelated-caller-request-67890")

    failed = capture_log(fn -> assert %{failure: 1} = Oban.drain_queue(queue: :mailers) end)
    refute failed =~ u.email
    mail_record(failed, "Mail transport failed", "error")
    [retry] = Enum.filter(records(failed), &(&1["message"] == "Oban job will retry"))
    assert retry["request_id"] == @id
    assert retry["oban_job_id"] == job.id
    assert retry["oban_attempt"] == 1
    assert LogContext.current() == "unrelated-caller-request-67890"
    saved = Repo.get!(Oban.Job, job.id)
    assert saved.state == "retryable"
    refute inspect(saved.errors) =~ @secret
    assert inspect(saved.errors) =~ "delivery_failed"

    Application.put_env(:anime, Mailer, adapter: Swoosh.Adapters.Test)

    accepted =
      capture_log(fn ->
        assert %{success: 1} = Oban.drain_queue(queue: :mailers, with_scheduled: true)
      end)

    mail_record(accepted, "Mail transport accepted message", "debug")
    [completed] = Enum.filter(records(accepted), &(&1["message"] == "Oban job completed"))
    assert completed["request_id"] == @id
    assert completed["oban_attempt"] == 2
    assert LogContext.current() == "unrelated-caller-request-67890"
  end

  for mode <- [:smtp_permanent_connect, :smtp_permanent_send, :smtp_temporary] do
    test "SMTP outcome #{mode} controls retry without saving transport details" do
      mode = unquote(mode)
      u = user()
      job = Repo.one!(from j in Oban.Job, order_by: [desc: j.id], limit: 1)
      Application.put_env(:anime, Mailer, adapter: Adapter, mode: mode)

      output = capture_log(fn -> Oban.drain_queue(queue: :mailers) end)
      saved = Repo.get!(Oban.Job, job.id)
      assert saved.attempt == 1
      expected = smtp_expected_state(mode)
      assert saved.state == expected

      for private <- [@secret, u.email, "private-relay"] do
        refute output =~ private
        refute inspect(saved.errors) =~ private
      end

      if expected == "discarded" do
        assert %{success: 0, failure: 0} =
                 Oban.drain_queue(queue: :mailers, with_scheduled: true)

        assert Repo.get!(Oban.Job, job.id).attempt == 1
      end
    end
  end

  defp smtp_expected_state(:smtp_temporary), do: "retryable"
  defp smtp_expected_state(_), do: "discarded"

  test "skipped expired token finishes job without inventing a mail acceptance" do
    user()
    Repo.update_all(Anime.Accounts.UserToken, set: [expires_at: ~U[2000-01-01 00:00:00.000000Z]])
    output = capture_log(fn -> assert %{success: 1} = Oban.drain_queue(queue: :mailers) end)
    refute Enum.any?(records(output), &String.starts_with?(&1["message"], "Mail transport"))
    refute_received {:email, _}
  end

  test "raised transport exception in a real job keeps correlation and retry without exposing it" do
    u = user()
    Application.put_env(:anime, Mailer, adapter: Adapter, mode: :raise)
    LogContext.put("caller-after-enqueue-123456")

    output =
      capture_log(fn ->
        assert %{failure: 1} = Oban.drain_queue(queue: :mailers, with_safety: true)
      end)

    refute output =~ u.email
    mail_record(output, "Mail transport failed", "error")
    [retry] = Enum.filter(records(output), &(&1["message"] == "Oban job will retry"))
    assert retry["request_id"] == @id
    assert retry["level"] == "warning"
    assert LogContext.current() == "caller-after-enqueue-123456"
  end
end
