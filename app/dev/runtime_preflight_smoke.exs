# Run from app/: elixir dev/runtime_preflight_smoke.exs
# Requires an existing dev build; uses synthetic settings, never starts the app,
# never reads .env and does not create users, connect to services or run migrations.
defmodule RuntimePreflightSmoke do
  def run do
    env = [
      {"MIX_ENV", "dev"},
      {"ELIXIR_ERL_OPTIONS", "+S 2:2"},
      {"APP_ENV", "dev"},
      {"NODE_ROLE", "web"},
      {"TRUSTED_PROXIES", ""},
      {"PHX_HOST", "localhost"},
      {"PORT", "4100"},
      {"METRICS_PORT", "9568"},
      {"PHX_SERVER", "false"},
      {"SECRET_KEY_BASE", String.duplicate("Synthetic-key-", 6)},
      {"LIVE_VIEW_SIGNING_SALT", String.duplicate("Synthetic-salt-", 3)},
      {"DATABASE_URL", "ecto://reader:SYNTHETIC-PASSWORD@127.0.0.1:59432/anime_test"},
      {"DATABASE_SSL", "false"},
      {"POOL_SIZE", "12"},
      {"MINIO_ENDPOINT", "http://127.0.0.1:9000"},
      {"MINIO_PUBLIC_URL", "http://localhost:9000"},
      {"MINIO_ACCESS_KEY_ID", "SYNTHETIC-ACCESS-KEY"},
      {"MINIO_SECRET_ACCESS_KEY", "SYNTHETIC-SECRET-KEY"},
      {"MINIO_REGION", "us-east-1"},
      {"MAIL_ADAPTER", "local"},
      {"LOG_LEVEL", "warning"},
      {"TZ", "UTC"}
    ]

    code = """
    endpoint = Application.fetch_env!(:anime, AnimeWeb.Endpoint)
    repo = Application.fetch_env!(:anime, Anime.Repo)
    true = endpoint[:http] == [ip: {127, 0, 0, 1}, port: 4100, thousand_island_options: [shutdown_timeout: 30_000]]
    true = endpoint[:server] == false
    true = Application.fetch_env!(:anime, Anime.Metrics.Exporter) == [server: false, port: 9568]
    true = repo[:pool_size] == 12 and repo[:ssl] == false
    true = Application.fetch_env!(:logger, :level) == :debug
    nil = Process.whereis(Anime.Supervisor)
    nil = Process.whereis(Anime.Repo)
    IO.puts("PREFLIGHT_OK")
    """

    {output, status} = run_mix(env, code)
    check!(status == 0 and String.contains?(output, "PREFLIGHT_OK"), "valid configuration")

    for {key, value} <- [
          {"PORT", "PRIVATE-NUMBER-SENTINEL"},
          {"METRICS_PORT", "PRIVATE-METRICS-SENTINEL"},
          {"METRICS_PORT", "4100"},
          {"DATABASE_URL", "ecto://reader:PRIVATE-PASSWORD-SENTINEL@localhost:bad/db"},
          {"MINIO_PUBLIC_URL", "http://user:PRIVATE-MINIO-SENTINEL@storage.test"},
          {"APP_ENV", "prod"},
          {"TRUSTED_PROXIES", "PRIVATE-PROXY-SENTINEL/24"},
          {"NODE_ROLE", "media"},
          {"MAIL_ADAPTER", "smtp"}
        ] do
      vars = List.keyreplace(env, key, 0, {key, value})
      {output, status} = run_mix(vars, ~s[IO.puts("UNREACHABLE")])
      check!(status == 1, "#{key}: exit status")
      check!(String.contains?(output, "Invalid runtime configuration: #{key}:"), key)

      for hidden <- ["SENTINEL", "SYNTHETIC-", "Synthetic-", "UNREACHABLE"] do
        check!(not String.contains?(output, hidden), "#{key}: safe output")
      end
    end

    IO.puts("10 Mix preflight scenarios passed; no application or external services started")
  end

  defp run_mix(env, code) do
    System.cmd(System.find_executable("mix"), ["run", "--no-compile", "--no-start", "-e", code],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp check!(true, _), do: :ok
  defp check!(false, label), do: raise("Preflight smoke failed: #{label}; output withheld")
end

RuntimePreflightSmoke.run()
