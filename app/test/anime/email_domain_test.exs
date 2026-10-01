defmodule Anime.EmailDomainTest do
  use ExUnit.Case, async: true
  alias Anime.Accounts.EmailDomain
  alias Anime.LogContext
  import ExUnit.CaptureLog
  @id "dns-request-context-123456789"

  test "MX callback has caller ID but no unrelated metadata, and caller stays intact" do
    Logger.metadata(request_id: @id, private: "MAIL_PRIVATE")
    caller = self()

    assert EmailDomain.valid?("reader@example.invalid", fn domain, type, timeout ->
             assert self() != caller
             assert domain == ~c"example.invalid"
             assert type == :mx
             assert timeout == 3000
             assert LogContext.current() == @id
             refute Keyword.has_key?(Logger.metadata(), :private)
             send(caller, {:dns, self()})
             {:ok, :synthetic_answer}
           end)

    assert_received {:dns, _}
    assert LogContext.current() == @id
    assert Logger.metadata()[:private] == "MAIL_PRIVATE"
  end

  test "nxdomain rejects but resolver errors still allow confirmation workflow" do
    refute EmailDomain.valid?("u@example.invalid", fn _, _, _ -> {:error, :nxdomain} end)
    assert EmailDomain.valid?("u@example.invalid", fn _, _, _ -> {:error, :timeout} end)
    assert EmailDomain.valid?("u@example.invalid", fn _, _, _ -> {:error, :servfail} end)
  end

  @tag :capture_log
  test "resolver crash keeps fail-open behavior and records no domain or exception" do
    LogContext.put(@id)

    output =
      capture_log(fn ->
        assert EmailDomain.valid?("MAIL_PRIVATE@example.invalid", fn _, _, _ ->
                 raise "MAIL_PRIVATE"
               end)
      end)

    refute output =~ "MAIL_PRIVATE"
    refute output =~ "example.invalid"
    rows = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(
             rows,
             &(&1["message"] == "Asynchronous callback failed" && &1["request_id"] == @id)
           )

    assert LogContext.current() == @id
  end

  test "deadline kills the DNS task and leaves no late result" do
    parent = self()

    lookup = fn _, _, _ ->
      send(parent, {:dns_started, self()})

      receive do
        :never_sent -> {:ok, :late}
      end
    end

    assert EmailDomain.valid?("u@example.invalid", lookup)
    assert_received {:dns_started, pid}
    refute Process.alive?(pid)

    receive do
      {ref, _} when is_reference(ref) -> flunk("late DNS task result")
    after
      0 -> :ok
    end
  end
end
