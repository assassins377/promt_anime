defmodule Anime.LogFormatterTest do
  use ExUnit.Case, async: true
  alias Anime.{Log, LogFormatter}
  @id "safe-request-id-1234567890"
  @time DateTime.to_unix(~U[2026-09-29 01:02:03.123456Z], :microsecond)
  @secret "PRIVATE-SENTINEL"

  defp event(fields \\ %{}, level \\ :info) do
    %{
      level: level,
      msg: {:string, @secret},
      meta: %{
        time: @time,
        request_id: @id,
        anime_event: :http_response,
        anime_fields: fields
      }
    }
  end

  defp row(event) do
    output = event |> LogFormatter.format(%{}) |> IO.iodata_to_binary()
    assert length(String.split(output, "\n")) == 2
    refute output =~ @secret
    refute output =~ "\e["
    Jason.decode!(output)
  end

  test "mandatory keys are flat JSON, with UTC microseconds and no raw message" do
    r = row(event())
    assert Enum.sort(Map.keys(r)) == ~w(app_version level message node request_id ts)
    assert r["ts"] == "2026-09-29T01:02:03.123456Z"
    assert r["level"] == "info"
    assert r["message"] == "HTTP request completed"
    assert r["request_id"] == @id
    assert r["app_version"] == "0.1.0"
    assert r["node"] == Atom.to_string(node())
  end

  test "HTTP fields are typed and dynamic path segments and query are masked" do
    r =
      row(
        event(
          %{
            method: "GET",
            path: "/confirm/#{@secret}?password=#{@secret}",
            status: 400,
            duration_ms: 2.5
          },
          :warning
        )
      )

    assert r["path"] == "/confirm/:token"
    assert r["method"] == "GET"
    assert r["status"] == 400
    assert r["duration_ms"] == 2.5
  end

  test "all supported secret paths, public nick and unknown paths are safe" do
    for {path, expected} <- [
          {"/confirm/#{@secret}", "/confirm/:token"},
          {"/en/confirm/#{@secret}", "/en/confirm/:token"},
          {"/password/reset/#{@secret}", "/password/reset/:token"},
          {"/en/password/reset/#{@secret}", "/en/password/reset/:token"},
          {"/account/restore/#{@secret}", "/account/restore/:token"},
          {"/u/#{@secret}", "/u/:nick"},
          {"/admin/users/12345", "/admin/users/:id"},
          {"/feedback/#{@secret}", "/[unmatched]"},
          {"/profile/exports/#{@secret}", "/[unmatched]"},
          {"/#{@secret}/#{@secret}", "/[unmatched]"},
          {"/assets/#{@secret}.js", "/assets/*path"},
          {"/images/#{@secret}.png", "/images/*path"}
        ] do
      assert Log.safe_path(path) == expected
      assert row(event(%{path: path}))["path"] == expected
    end
  end

  test "route sanitizer tolerates malformed UTF-8, percent escapes and excessive size" do
    for value <- [<<255>>, "/%FF", "/%xx", String.duplicate(@secret, 1000), nil, 123, %{}] do
      refute Log.safe_path(value) =~ @secret
    end
  end

  test "forbidden and nested data never becomes a key or value" do
    fields =
      Map.new(
        ~w(password password_confirmation hashed_password token cookie authorization email nick ip user_agent raw_body body bucket object_key url sql params stacktrace signature _csrf_token)a,
        &{&1, @secret}
      )

    r = row(event(Map.put(fields, :nested, %{secret: @secret})))
    assert map_size(r) == 6
    refute Enum.any?(Map.values(r), &is_map/1)
  end

  test "only integer user ID and only warning/error, never info/debug" do
    for level <- [:info, :debug],
        do: refute(Map.has_key?(row(event(%{user_id: 42}, level)), "user_id"))

    for level <- [:warning, :error],
        do: assert(row(event(%{user_id: 42}, level))["user_id"] == 42)

    for value <- ["42", 1.5, 0, -1, %{id: 42}],
        do: refute(Map.has_key?(row(event(%{user_id: value}, :error)), "user_id"))
  end

  test "allowed database IDs are positive integers only" do
    for key <- ~w(anime_id episode_id video_upload_id transaction_id comment_id)a do
      assert row(event(%{key => 42}))[Atom.to_string(key)] == 42
      refute Map.has_key?(row(event(%{key => @secret})), Atom.to_string(key))
    end
  end

  test "invalid optional field types are omitted, not inspected" do
    r = row(event(%{method: @secret, status: @secret, duration_ms: -1, user_id: @secret}))
    assert map_size(r) == 6
    assert row(event(%URI{path: @secret}))["message"] == "HTTP request completed"
  end

  test "raw dependency reports and stacktrace are suppressed without invoking report callbacks" do
    raw = %{
      level: :error,
      msg: {:report, %{password: @secret}},
      meta: %{
        time: @time,
        crash_reason: {%RuntimeError{message: @secret}, [@secret]},
        report_cb: fn _ -> raise "must not run" end,
        email: @secret,
        mfa: {Postgrex.Protocol, :connect, 1}
      }
    }

    r = row(raw)
    assert r["message"] == "Unstructured log suppressed (Elixir.Postgrex.Protocol.connect/1)"
    assert r["request_id"] == nil
  end

  test "all OTP levels map to the four spec levels" do
    for {source, expected} <- [
          debug: "debug",
          info: "info",
          notice: "info",
          warning: "warning",
          error: "error",
          critical: "error",
          alert: "error",
          emergency: "error"
        ] do
      assert row(event(%{}, source))["level"] == expected
    end
  end

  test "untrusted request ID types and control characters are dropped" do
    for value <- [
          nil,
          "short",
          @secret <> "\nnew record",
          %{token: @secret},
          String.duplicate("x", 201)
        ] do
      e = put_in(event(), [:meta, :request_id], value)
      assert row(e)["request_id"] == nil
    end
  end

  test "malformed event falls back to a safe JSON record instead of raising" do
    for value <- [@secret, {:secret, @secret}, %{meta: %URI{path: @secret}}] do
      r = row(value)
      assert r["level"] == "error"
      assert r["message"] == "Log formatting failed safely"
    end
  end

  test "legacy capture formatter also ignores raw message and metadata secrets" do
    output =
      LogFormatter.legacy_format(:error, @secret, nil,
        password: @secret,
        anime_event: :http_response,
        anime_fields: %{status: 500}
      )
      |> IO.iodata_to_binary()

    assert Jason.decode!(output)["status"] == 500
    refute output =~ @secret
  end

  test "HTTP severity matches status classes and messages reject unknown event names safely" do
    assert Log.http_level(200) == :info
    assert Log.http_level(302) == :info
    assert Log.http_level(403) == :warning
    assert Log.http_level(503) == :error
    error = assert_raise ArgumentError, fn -> Log.emit(@secret) end
    refute error.message =~ @secret
  end

  test "LiveView labels are closed sets and values are safe after repeated sanitizing" do
    fields = %{
      live_view: AnimeWeb.AuthLive,
      live_action: :login,
      live_event: "validate",
      socket_id: "phx-abcdefghijklmnop",
      params: @secret
    }

    safe = LogFormatter.fields(fields, :debug)
    assert LogFormatter.fields(safe, :debug) == safe
    assert safe.live_view == "AnimeWeb.AuthLive"
    assert safe.live_event == "validate"
    assert safe.socket_id == "phx-abcdefghijklmnop"
    refute Map.has_key?(safe, :params)

    r =
      row(
        event(%{
          live_view: @secret,
          live_action: @secret,
          live_event: @secret,
          socket_id: @secret
        })
      )

    assert r["live_view"] == "[unknown]"
    assert r["live_event"] == "[unknown]"
    refute Map.has_key?(r, "socket_id")
  end

  test "Oban fields are typed, queue/worker are allowlisted, args/errors never serialize" do
    r =
      row(
        event(%{
          oban_worker: "Anime.Workers.Mail",
          oban_queue: "mailers",
          oban_job_id: 42,
          oban_attempt: 2,
          oban_duration_ms: 1.5,
          args: @secret,
          errors: @secret
        })
      )

    assert r["oban_worker"] == "Anime.Workers.Mail"
    assert r["oban_attempt"] == 2
    assert r["oban_duration_ms"] == 1.5

    r =
      row(
        event(%{
          oban_worker: @secret,
          oban_queue: @secret,
          oban_attempt: -1,
          oban_job_id: @secret,
          oban_duration_ms: @secret
        })
      )

    assert r["oban_worker"] == "[unknown]"
    assert r["oban_queue"] == "[unknown]"
    refute Map.has_key?(r, "oban_job_id")
    refute Map.has_key?(r, "oban_attempt")
    refute Map.has_key?(r, "oban_duration_ms")
  end
end
