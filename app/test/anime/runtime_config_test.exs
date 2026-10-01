defmodule Anime.RuntimeConfigTest do
  use ExUnit.Case, async: true
  alias Anime.RuntimeConfig

  @required ~w(APP_ENV NODE_ROLE PHX_HOST SECRET_KEY_BASE LIVE_VIEW_SIGNING_SALT DATABASE_URL MINIO_ENDPOINT MINIO_PUBLIC_URL MINIO_ACCESS_KEY_ID MINIO_SECRET_ACCESS_KEY)
  @optional ~w(PORT METRICS_PORT PHX_SERVER POOL_SIZE DATABASE_SSL LOG_LEVEL TZ MAIL_ADAPTER MINIO_REGION)
  @runtime_file Path.expand("../../config/runtime.exs", __DIR__)

  defp valid do
    %{
      "APP_ENV" => "dev",
      "NODE_ROLE" => "web",
      "PHX_HOST" => "localhost",
      "SECRET_KEY_BASE" => String.duplicate("Synthetic-key-", 6),
      "LIVE_VIEW_SIGNING_SALT" => String.duplicate("Synthetic-salt-", 3),
      "DATABASE_URL" => "ecto://reader:p%40ss%3Aword@127.0.0.1:59432/anime_test",
      "MINIO_ENDPOINT" => "http://127.0.0.1:9000",
      "MINIO_PUBLIC_URL" => "http://localhost:9000",
      "MINIO_ACCESS_KEY_ID" => "Synthetic-access-key",
      "MINIO_SECRET_ACCESS_KEY" => "Synthetic-secret-key"
    }
  end

  test "valid local configuration has typed defaults and no implicit server start" do
    runtime = RuntimeConfig.load!(valid())
    assert runtime.environment == "dev"
    assert runtime.node_role == "web"
    assert runtime.port == 4000
    assert runtime.metrics_port == 9568
    assert runtime.pool_size == 10
    refute runtime.server
    refute runtime.database_ssl
    assert runtime.trusted_proxies == []
    assert runtime.origin == "http://localhost:4000"
    assert runtime.minio_region == "us-east-1"
    assert runtime.log_level == :debug
    assert runtime.database_url == valid()["DATABASE_URL"]
  end

  test "every required field rejects missing, empty, whitespace and control values" do
    for name <- @required do
      assert_bad(Map.delete(valid(), name), name)

      for value <- ["", " \t ", "hidden\r\nvalue", <<255>>, "value\0"] do
        assert_bad(Map.put(valid(), name, value), name)
      end
    end
  end

  test "optional values default only when absent, not when blank" do
    for name <- @optional, value <- ["", " ", "\n", <<255>>] do
      assert_bad(Map.put(valid(), name, value), name)
    end
  end

  test "both short keys and reusing a key as the signing salt fail" do
    assert_bad(Map.put(valid(), "SECRET_KEY_BASE", String.duplicate("x", 63)), "SECRET_KEY_BASE")

    assert_bad(
      Map.put(valid(), "LIVE_VIEW_SIGNING_SALT", String.duplicate("x", 31)),
      "LIVE_VIEW_SIGNING_SALT"
    )

    assert_bad(
      Map.put(valid(), "LIVE_VIEW_SIGNING_SALT", valid()["SECRET_KEY_BASE"]),
      "LIVE_VIEW_SIGNING_SALT"
    )

    assert RuntimeConfig.load!(valid()).secret_key_base == valid()["SECRET_KEY_BASE"]
  end

  test "invalid numeric values stop before integer conversion can echo their input" do
    for name <- ~w(PORT METRICS_PORT POOL_SIZE),
        value <- ["oops-SENTINEL", "0", "-1", "+12", " 12", "12 ", "1.5", "10ms"] do
      assert_bad(Map.put(valid(), name, value), name)
    end

    assert_bad(Map.put(valid(), "PORT", "65536"), "PORT")
    assert_bad(Map.put(valid(), "METRICS_PORT", "65536"), "METRICS_PORT")
    assert_bad(Map.put(valid(), "METRICS_PORT", "4000"), "METRICS_PORT")

    for value <- ["1", "65535"] do
      assert RuntimeConfig.load!(Map.put(valid(), "PORT", value)).port == String.to_integer(value)
    end

    assert RuntimeConfig.load!(Map.put(valid(), "POOL_SIZE", "25")).pool_size == 25
  end

  test "site host cannot inject an origin, path, credentials or CSP directive" do
    for value <- [
          "https://site.test",
          "site.test:4000",
          "site.test/path",
          "user@site.test",
          "site.test;script-src",
          "*.site.test",
          "site..test",
          "-site.test",
          "site-.test",
          "999.1.1.1",
          "::1",
          "site.test.",
          "%61.test"
        ] do
      assert_bad(Map.put(valid(), "PHX_HOST", value), "PHX_HOST")
    end

    assert RuntimeConfig.load!(Map.put(valid(), "PHX_HOST", "ANIME.Example.test")).host ==
             "anime.example.test"

    assert RuntimeConfig.load!(Map.put(valid(), "PHX_HOST", "127.0.0.1")).host == "127.0.0.1"
  end

  test "MinIO origins reject credentials, bucket paths, query, fragments and invalid ports" do
    for name <- ~w(MINIO_ENDPOINT MINIO_PUBLIC_URL),
        value <- [
          "ftp://storage.test",
          "//storage.test",
          "http:///",
          "http://user:SECRET@storage.test",
          "http://storage.test/bucket",
          "http://storage.test/?token=SECRET",
          "http://storage.test/#SECRET",
          "http://storage.test:bad",
          "http://storage.test:0",
          "http://storage.test:65536",
          "http://storage.test;unsafe",
          "http://a\\b.test",
          "http://%61.test",
          "http://[not-ipv6]",
          "http://storage.test/%GG"
        ] do
      assert_bad(Map.put(valid(), name, value), name)
    end
  end

  test "MinIO canonical origins preserve scheme host and nondefault port, including IPv6" do
    runtime =
      RuntimeConfig.load!(
        Map.merge(valid(), %{
          "MINIO_ENDPOINT" => "https://[::1]:9443/",
          "MINIO_PUBLIC_URL" => "https://Storage.Example.test/"
        })
      )

    assert runtime.minio_endpoint == %URI{scheme: "https", host: "::1", port: 9443}
    assert runtime.minio_public_url == "https://storage.example.test"
  end

  test "database URL checks cannot reveal credentials or leave malformed options to Ecto" do
    for value <- [
          "http://reader:SECRET@localhost/db",
          "ecto:///db",
          "ecto://localhost/db",
          "ecto://:SECRET@localhost/db",
          "ecto://reader:SECRET@localhost",
          "ecto://reader:SECRET@localhost/",
          "ecto://reader:SECRET@localhost/db/extra",
          "ecto://reader:SECRET@localhost:bad/db",
          "ecto://reader:SECRET@localhost:0/db",
          "ecto://reader:SECRET@localhost/db#SECRET",
          "ecto://reader:SECRET%ZZ@localhost/db",
          "ecto://reader:SECRET%0a@localhost/db",
          "ecto://reader:SECRET@localhost/db?timeout=SECRET",
          "ecto://reader:SECRET@localhost/db?ssl=maybe",
          "ecto://reader:SECRET@localhost/db?pool_size=2",
          "ecto://reader:SECRET@localhost/db?ssl=true&ssl=false",
          "ecto://reader:SECRET@localhost/db?%73sl=true&ssl=false",
          "ecto://reader:SECRET@localhost/db?timeout=0",
          "ecto://reader:SECRET@localhost/db?socket_dir=%FF"
        ] do
      assert_bad(Map.put(valid(), "DATABASE_URL", value), "DATABASE_URL")
    end
  end

  test "database SSL uses explicit validated choice or the URL, never conflicting values" do
    for scheme <- ~w(ecto postgres postgresql) do
      env =
        Map.put(
          valid(),
          "DATABASE_URL",
          "#{scheme}://reader:p%40ss@[::1]/db?ssl=true&timeout=1000&idle_interval=2000"
        )

      assert RuntimeConfig.load!(env).database_ssl
      assert RuntimeConfig.load!(Map.put(env, "DATABASE_SSL", "true")).database_ssl
      assert_bad(Map.put(env, "DATABASE_SSL", "false"), "DATABASE_SSL")
    end

    assert RuntimeConfig.load!(Map.put(valid(), "DATABASE_SSL", "true")).database_ssl
    refute RuntimeConfig.load!(Map.put(valid(), "DATABASE_SSL", "false")).database_ssl
  end

  test "booleans, logger, timezone, region and mail selection are explicit" do
    for name <- ~w(PHX_SERVER DATABASE_SSL), value <- ["yes", "TRUE", "0", "FALSE"] do
      assert_bad(Map.put(valid(), name, value), name)
    end

    assert RuntimeConfig.load!(Map.put(valid(), "PHX_SERVER", "true")).server
    refute RuntimeConfig.load!(Map.put(valid(), "PHX_SERVER", "false")).server

    for {level, _atom} <- [
          {"debug", :debug},
          {"info", :info},
          {"warning", :warning},
          {"error", :error}
        ] do
      assert RuntimeConfig.load!(Map.put(valid(), "LOG_LEVEL", level)).log_level == :debug
    end

    for {name, value} <- [
          {"LOG_LEVEL", "warn"},
          {"TZ", "Asia/Yakutsk"},
          {"MAIL_ADAPTER", "smtp"},
          {"MAIL_ADAPTER", "test"},
          {"MINIO_REGION", "bad/region"},
          {"MINIO_REGION", "bad region"}
        ] do
      assert_bad(Map.put(valid(), name, value), name)
    end
  end

  test "staging prod and media remain disabled even with valid-looking settings" do
    for env <- ~w(staging prod) do
      assert_bad(Map.put(valid(), "APP_ENV", env), "APP_ENV")
      assert_bad(%{"APP_ENV" => env}, "APP_ENV")
    end

    assert_bad(Map.put(valid(), "APP_ENV", "preview"), "APP_ENV")
    assert_bad(Map.put(valid(), "NODE_ROLE", "media"), "NODE_ROLE")
    assert_bad(Map.put(valid(), "NODE_ROLE", "unknown"), "NODE_ROLE")
  end

  test "configuration inspection redacts keys and database credentials" do
    rendered = inspect(RuntimeConfig.load!(valid()))
    assert rendered =~ "Anime.RuntimeConfig"
    assert rendered =~ "localhost"

    for value <- [
          valid()["SECRET_KEY_BASE"],
          valid()["LIVE_VIEW_SIGNING_SALT"],
          valid()["DATABASE_URL"],
          "p%40ss",
          valid()["MINIO_ACCESS_KEY_ID"],
          valid()["MINIO_SECRET_ACCESS_KEY"]
        ] do
      refute rendered =~ value
    end
  end

  test "proxy trust is opt-in and malformed CIDRs stop startup safely" do
    for value <- ["", "   "] do
      assert RuntimeConfig.load!(Map.put(valid(), "TRUSTED_PROXIES", value)).trusted_proxies == []
    end

    assert RuntimeConfig.load!(Map.put(valid(), "TRUSTED_PROXIES", "10.0.0.0/8")).trusted_proxies ==
             Anime.ClientIP.parse_trusted!("10.0.0.0/8")

    assert_bad(Map.put(valid(), "TRUSTED_PROXIES", "SENTINEL/32"), "TRUSTED_PROXIES")
  end

  test "runtime.exs consumes typed configuration without starting the application" do
    code = """
    cfg = Config.Reader.read!(#{inspect(@runtime_file)}, env: :dev, imports: :disabled)
    app = Keyword.fetch!(cfg, :anime)
    endpoint = Keyword.fetch!(app, AnimeWeb.Endpoint)
    repo = Keyword.fetch!(app, Anime.Repo)
    true = endpoint[:http] == [ip: {127, 0, 0, 1}, port: 4100, thousand_island_options: [shutdown_timeout: 30_000]]
    true = endpoint[:check_origin] == ["http://localhost:4100"]
    true = endpoint[:server] == false
    true = app[Anime.Metrics.Exporter] == [server: false, port: 9568]
    true = repo[:ssl] == false and repo[:pool_size] == 12
    true = app[:minio_origin] == "http://localhost:9000"
    true = app[Anime.Mailer][:adapter] == Swoosh.Adapters.Local
    true = cfg[:logger][:level] == :debug
    true = app[:trusted_proxies] == Anime.ClientIP.parse_trusted!("10.0.0.0/8")
    nil = Process.whereis(Anime.Supervisor)
    nil = Process.whereis(Anime.Repo)
    IO.puts("PREFLIGHT_OK")
    """

    env =
      Map.merge(valid(), %{
        "PORT" => "4100",
        "POOL_SIZE" => "12",
        "LOG_LEVEL" => "warning",
        "TRUSTED_PROXIES" => "10.0.0.0/8"
      })

    assert {"PREFLIGHT_OK\n", 0} = reader_process(env, code)
  end

  test "runtime reader exits 1 for invalid configuration without exposing values" do
    code =
      "Config.Reader.read!(#{inspect(@runtime_file)}, env: :dev, imports: :disabled); IO.puts(\"UNREACHABLE\")"

    for {key, value} <- [
          {"PORT", "PRIVATE-NUMBER-SENTINEL"},
          {"DATABASE_URL", "ecto://reader:PRIVATE-PASSWORD-SENTINEL@localhost:bad/db"},
          {"MINIO_PUBLIC_URL", "http://user:PRIVATE-MINIO-SENTINEL@storage.test"},
          {"APP_ENV", "prod"}
        ] do
      {output, status} = reader_process(Map.put(valid(), key, value), code)
      assert status == 1
      assert output =~ "Invalid runtime configuration: #{key}:"
      refute output =~ "SENTINEL"
      refute output =~ valid()["SECRET_KEY_BASE"]
      refute output =~ "UNREACHABLE"
    end
  end

  test "test config skips operator environment and preserves hermetic test configuration" do
    code = """
    [] = Config.Reader.read!(#{inspect(@runtime_file)}, env: :test, imports: :disabled)
    IO.puts("TEST_CONFIG_OK")
    """

    assert {"TEST_CONFIG_OK\n", 0} = reader_process(%{"APP_ENV" => "invalid"}, code)
  end

  defp assert_bad(env, key) do
    error = assert_raise RuntimeError, fn -> RuntimeConfig.load!(env) end
    assert error.message =~ "Invalid runtime configuration: #{key}:"
    refute error.message =~ "SENTINEL"
    refute error.message =~ "SECRET@"
    refute error.message =~ valid()["SECRET_KEY_BASE"]
  end

  defp reader_process(env, code) do
    vars = Map.new(@required ++ @optional ++ ["TRUSTED_PROXIES"], &{&1, nil}) |> Map.merge(env)
    vars = Map.put(vars, "ELIXIR_ERL_OPTIONS", "+S 2:2")
    # :code.which/1 returns :cover_compiled under --cover, not a filename.
    # The isolated VM must load the real build without starting the application.
    ebin = Application.app_dir(:anime, "ebin")

    System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", code],
      env: Map.to_list(vars),
      stderr_to_stdout: true
    )
  end
end
