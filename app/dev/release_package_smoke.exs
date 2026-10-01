# Inspect and execute the packaged VM only; never Application.ensure_all_started(:anime).
defmodule ReleasePackageSmoke do
  def run(package) do
    package = Path.expand(package)
    runtime_dir = Path.join(Path.dirname(package), "runtime")
    File.mkdir_p!(runtime_dir)
    File.chmod!(runtime_dir, 0o700)
    check!(String.starts_with?(package, "/tmp/anime-release-check."), "temporary package path")
    executable = Path.join(package, "bin/anime")
    check_launcher(package)
    check!(File.regular?(executable), "release executable")

    check!(
      File.stat!(Path.join(package, "bin/server")).mode |> Bitwise.band(0o111) != 0,
      "server executable mode"
    )

    check!(length(Path.wildcard(Path.join(package, "erts-*/bin/beam.smp"))) == 1, "bundled ERTS")
    [app] = Path.wildcard(Path.join(package, "lib/anime-*"))

    check!(
      File.regular?(Path.join(app, "ebin/Elixir.Anime.RuntimeConfig.beam")),
      "application BEAM"
    )

    check!(File.regular?(Path.join(app, "priv/static/cache_manifest.json")), "asset manifest")
    check!(File.regular?(Path.join(app, "priv/static/assets/app.js")), "JavaScript")
    check!(File.regular?(Path.join(app, "priv/static/assets/app.css")), "CSS")

    check!(
      length(Path.wildcard(Path.join(app, "priv/static/assets/fonts/*.woff2"))) >= 4,
      "local fonts"
    )

    check!(
      length(Path.wildcard(Path.join(app, "priv/repo/migrations/*.exs"))) == 47,
      "migration files retained for future release commands"
    )

    for dependency <- ~w(mix esbuild mix_audit sobelow lazy_html) do
      check!(
        Path.wildcard(Path.join(package, "lib/#{dependency}-*")) == [],
        "no #{dependency} development dependency"
      )
    end

    for name <- ~w(.env .env.local deps _build assets test dev) do
      check!(!File.exists?(Path.join(package, name)), "no root #{name}")
    end

    check!(Path.wildcard(Path.join(app, "ebin/*Fixtures*")) == [], "no test fixtures")
    check!(Path.wildcard(Path.join(app, "ebin/*Case*")) == [], "no test case modules")
    check!(!File.dir?(Path.join(app, "lib")), "no application source tree")

    check!(
      File.read!(Path.join(package, "releases/COOKIE")) == "runtime-cookie-must-be-supplied",
      "public cookie placeholder only"
    )

    before = fingerprint(package)

    env = [
      {"RELEASE_TMP", runtime_dir},
      {"PATH", "/usr/bin:/bin"},
      {"ERL_FLAGS", "+S 2:2"},
      {"ERL_AFLAGS", nil},
      {"RELEASE_COOKIE", String.duplicate("Synthetic-cookie-", 3)},
      {"RELEASE_DISTRIBUTION", "none"},
      {"RELEASE_NODE", nil},
      {"RELEASE_SYS_CONFIG", nil},
      {"RELEASE_VM_ARGS", nil},
      {"APP_ENV", "dev"},
      {"NODE_ROLE", "web"},
      {"PHX_SERVER", "false"},
      {"PHX_HOST", "localhost"},
      {"PORT", "4100"},
      {"METRICS_PORT", "9568"},
      {"SECRET_KEY_BASE", String.duplicate("Synthetic-key-", 6)},
      {"LIVE_VIEW_SIGNING_SALT", String.duplicate("Synthetic-salt-", 3)},
      {"DATABASE_URL", "ecto://reader:SYNTHETIC-PASSWORD@127.0.0.1:59499/anime_release_test"},
      {"DATABASE_SSL", "false"},
      {"POOL_SIZE", "2"},
      {"TRUSTED_PROXIES", ""},
      {"MINIO_ENDPOINT", "http://127.0.0.1:9000"},
      {"MINIO_PUBLIC_URL", "http://localhost:9000"},
      {"MINIO_ACCESS_KEY_ID", "SYNTHETIC-ACCESS"},
      {"MINIO_SECRET_ACCESS_KEY", "SYNTHETIC-SECRET"},
      {"MINIO_REGION", "us-east-1"},
      {"MAIL_ADAPTER", "local"},
      {"LOG_LEVEL", "info"},
      {"TZ", "UTC"},
      {"ADMIN_EMAIL", nil},
      {"ADMIN_NICK", nil},
      {"ADMIN_PASSWORD", nil}
    ]

    code = """
    nil = Process.whereis(Anime.Supervisor)
    nil = Process.whereis(Anime.Repo)
    nil = Process.whereis(AnimeWeb.Endpoint)
    false = Code.ensure_loaded?(Mix)
    false = Application.fetch_env!(:anime, AnimeWeb.Endpoint)[:server]
    2 = Application.fetch_env!(:anime, Anime.Repo)[:pool_size]
    {:ok, _} = Application.ensure_all_started(:bcrypt_elixir)
    hash = Bcrypt.hash_pwd_salt("package-probe", log_rounds: 4)
    true = Bcrypt.verify_pass("package-probe", hash)
    nil = Process.whereis(Anime.Supervisor)
    5 = length(Anime.Storage.Setup.plan(%{}))
    true = Code.ensure_loaded?(Anime.Release)
    true = function_exported?(Anime.Release, :storage_setup, 0)
    IO.puts("PACKAGE_PREFLIGHT_OK")
    """

    {output, status} = run_eval(executable, env, code)

    check!(
      status == 0 && String.contains?(output, "PACKAGE_PREFLIGHT_OK"),
      "standalone eval, runtime config and bcrypt NIF"
    )

    for {key, value, message} <- [
          {"APP_ENV", "prod", "APP_ENV"},
          {"APP_ENV", "staging", "APP_ENV"},
          {"NODE_ROLE", "media", "NODE_ROLE"},
          {"MAIL_ADAPTER", "smtp", "MAIL_ADAPTER"},
          {"SECRET_KEY_BASE", nil, "SECRET_KEY_BASE"},
          {"DATABASE_URL", "ecto://reader:PRIVATE-SENTINEL@localhost:bad/db", "DATABASE_URL"},
          {"RELEASE_COOKIE", nil, "RELEASE_COOKIE"},
          {"RELEASE_COOKIE", "short", "RELEASE_COOKIE"},
          {"RELEASE_TMP", nil, "RELEASE_TMP"},
          {"RELEASE_TMP", package, "RELEASE_TMP"},
          {"RELEASE_DISTRIBUTION", "name", "Distributed release"}
        ] do
      {output, status} =
        run_eval(
          executable,
          List.keyreplace(env, key, 0, {key, value}),
          ~s[IO.puts("UNREACHABLE")]
        )

      check!(status != 0 && String.contains?(output, message), "#{key} rejects invalid runtime")

      for hidden <- ["PRIVATE-SENTINEL", "Synthetic-", "SYNTHETIC-", "UNREACHABLE"],
          do: check!(!String.contains?(output, hidden), "#{key} does not reveal credentials")
    end

    check!(
      fingerprint(package) == before,
      "runtime preflight never writes credentials into package"
    )

    IO.puts(
      "Package inventory, 2 launcher checks and 12 release runtime scenarios passed; no Anime/Repo/Endpoint startup"
    )
  end

  defp run_eval(executable, env, code),
    do: System.cmd(executable, ["eval", code], cd: "/tmp", env: env, stderr_to_stdout: true)

  defp fingerprint(package) do
    for file <- Path.wildcard(Path.join(package, "**/*"), match_dot: true),
        File.regular?(file),
        into: %{},
        do: {Path.relative_to(file, package), :crypto.hash(:sha256, File.read!(file))}
  end

  defp check_launcher(package) do
    # A fake sibling executable verifies the wrapper without starting a VM.
    dir = Path.join(Path.dirname(package), "launcher probe/bin")
    File.mkdir_p!(dir)
    launcher = Path.join(dir, "server")
    File.cp!(Path.join(package, "bin/server"), launcher)
    File.chmod!(launcher, 0o700)
    fake = Path.join(dir, "anime")

    File.write!(fake, """
    #!/bin/sh
    test "$#" = 1 && test "$1" = start && test "$PHX_SERVER" = true || exit 7
    echo LAUNCHER_OK
    """)

    File.chmod!(fake, 0o700)

    {output, status} =
      System.cmd(launcher, [], cd: "/tmp", env: [{"PHX_SERVER", "false"}], stderr_to_stdout: true)

    check!(
      status == 0 && String.trim(output) == "LAUNCHER_OK",
      "launcher uses sibling release and PHX_SERVER=true"
    )

    {output, status} = System.cmd(launcher, ["eval"], cd: "/tmp", stderr_to_stdout: true)

    check!(
      status == 2 && !String.contains?(output, "LAUNCHER_OK"),
      "launcher refuses extra commands"
    )
  end

  defp check!(true, _), do: :ok
  defp check!(false, label), do: raise("Release package check failed: #{label}; output withheld")
end

[package] = System.argv()
ReleasePackageSmoke.run(package)
