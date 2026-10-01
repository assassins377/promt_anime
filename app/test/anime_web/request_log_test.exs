defmodule AnimeWeb.RequestLogTest do
  use AnimeWeb.ConnCase
  import ExUnit.CaptureLog
  require Logger

  @secret "PRIVATE-LOG-SENTINEL"

  defmodule FailureHarness do
    use Plug.Builder

    use Phoenix.Endpoint.RenderErrors,
      formats: [html: AnimeWeb.ErrorHTML, json: AnimeWeb.ErrorJSON],
      log: false

    plug AnimeWeb.SecurityHeaders
    plug AnimeWeb.ClientIP
    plug AnimeWeb.RequestLog
    plug :fail

    defp fail(conn, _) do
      conn = put_private(conn, :phoenix_endpoint, AnimeWeb.Endpoint)

      try do
        raise "PRIVATE-LOG-SENTINEL password SQL query /private/source.ex"
      rescue
        error -> Plug.Conn.WrapperError.reraise(conn, :error, error, __STACKTRACE__)
      end
    end
  end

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  defp records(output) do
    refute output =~ @secret
    refute output =~ "\e["

    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      row = Jason.decode!(line)
      assert Enum.all?(Map.values(row), &(is_nil(&1) or is_binary(&1) or is_number(&1)))
      assert row["ts"] =~ ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/
      row
    end)
  end

  defp http_record(output) do
    [row] = Enum.filter(records(output), &(&1["message"] == "HTTP request completed"))
    row
  end

  test "actual endpoint logs success, redirect and 404 once with the response request ID" do
    for {path, status, level, template} <- [
          {"/login?email=#{@secret}", 200, "info", "/login"},
          {"/profile/settings", 302, "info", "/profile/settings"},
          {"/u/#{@secret}", 404, "warning", "/u/:nick"},
          {"/#{@secret}?token=#{@secret}", 404, "warning", "/[unmatched]"},
          {"/healthz", 200, "info", "/healthz"}
        ] do
      {response, output} = with_log(fn -> get(build_conn(), path) end)
      assert response.status == status
      row = http_record(output)
      assert row["status"] == status
      assert row["level"] == level
      assert row["path"] == template
      assert row["method"] == "GET"
      assert row["duration_ms"] >= 0
      assert row["request_id"] == hd(get_resp_header(response, "x-request-id"))
      refute Map.has_key?(row, "user_id")
    end
  end

  test "missing static assets do not create HTTP warning records" do
    for path <- ["/assets/#{@secret}.js", "/images/#{@secret}.png"] do
      {response, output} = with_log(fn -> get(build_conn(), path) end)
      assert response.status == 404
      refute Enum.any?(records(output), &(&1["message"] == "HTTP request completed"))
    end
  end

  test "POST form fields, cookie, authorization and query never reach output" do
    {response, output} =
      with_log(fn ->
        build_conn()
        |> put_req_header("authorization", "Bearer #{@secret}")
        |> put_req_cookie("private_cookie", @secret)
        |> post("/login?signature=#{@secret}", %{
          "email" => "#{@secret}@example.invalid",
          "password" => @secret,
          "token" => @secret,
          "nested" => %{"body" => @secret}
        })
      end)

    row = http_record(output)
    assert row["status"] == response.status
    assert row["method"] == "POST"
    assert row["path"] == "/login"
    refute output =~ "example.invalid"
    refute output =~ "Bearer"
  end

  test "parser 400 before routing is correlated and contains no raw body" do
    {{400, headers, _}, output} =
      with_log(fn ->
        assert_error_sent 400, fn ->
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/en/login?token=#{@secret}", ~s({"password":"#{@secret}"))
        end
      end)

    row = http_record(output)
    assert row["status"] == 400
    assert row["level"] == "warning"
    assert row["path"] == "/en/login"
    assert row["request_id"] == Map.new(headers)["x-request-id"]
    refute output =~ "ParseError"
  end

  test "CSRF rejection is a single safe HTTP 403" do
    {{403, headers, _}, output} =
      with_log(fn ->
        assert_error_sent 403, fn ->
          build_conn()
          |> put_private(:plug_skip_csrf_protection, false)
          |> post("/en/login", %{"password" => @secret})
        end
      end)

    row = http_record(output)
    assert row["status"] == 403
    assert row["level"] == "warning"
    assert row["request_id"] == Map.new(headers)["x-request-id"]
  end

  test "exception response has safe error record and matching request ID" do
    {{500, headers, html}, output} =
      with_log(fn ->
        assert_error_sent 500, fn ->
          build_conn(:get, "/#{@secret}?password=#{@secret}")
          |> put_req_header("accept", "text/html")
          |> FailureHarness.call([])
        end
      end)

    row = http_record(output)
    assert row["status"] == 500
    assert row["level"] == "error"
    assert row["path"] == "/[unmatched]"
    assert row["request_id"] == Map.new(headers)["x-request-id"]
    assert html =~ row["request_id"]
    refute output =~ "SQL"
    refute output =~ "RuntimeError"
  end

  test "HEAD is logged without a body" do
    {response, output} = with_log(fn -> head(build_conn(), "/missing") end)
    assert response.resp_body == ""
    assert http_record(output)["method"] == "HEAD"
  end

  test "only authenticated numeric ID is logged and only on warning/error responses" do
    for status <- [200, 400, 500] do
      output =
        capture_log(fn ->
          build_conn(:get, "/login")
          |> assign(:current_user, %{id: 42, email: @secret, nick: @secret})
          |> AnimeWeb.RequestLog.call([])
          |> send_resp(status, @secret)
        end)

      row = http_record(output)

      if status >= 400,
        do: assert(row["user_id"] == 42),
        else: refute(Map.has_key?(row, "user_id"))
    end
  end

  test "real Logger messages and OTP reports never render their raw content" do
    output =
      capture_log(fn ->
        Logger.error("password=#{@secret}\nforged log record", email: @secret)
        :logger.error(%{secret: @secret, sql: @secret}, %{crash_reason: {@secret, [@secret]}})
      end)

    rows = records(output)
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1["level"] == "error"))
    assert Enum.all?(rows, &String.starts_with?(&1["message"], "Unstructured log suppressed"))
    refute output =~ "forged log record"
  end

  test "SQL logging is disabled and Phoenix parameter protection includes spec keys" do
    assert Anime.Repo.config()[:log] == false

    for key <-
          ~w(password password_confirmation current_password token _csrf_token secret signature authorization email guest_email raw_body),
        do: assert(Phoenix.Logger.filter_values(%{key => @secret}) == %{key => "[FILTERED]"})
  end
end
