Code.require_file("dev/coverage.exs", __DIR__)

defmodule Anime.MixProject do
  use Mix.Project

  def project do
    [
      app: :anime,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: Anime.Coverage],
      releases: [
        anime: [
          include_erts: true,
          include_executables_for: [:unix],
          strip_beams: true,
          # Public placeholder, never a usable cluster credential. env.sh
          # requires an externally supplied cookie before any release command.
          cookie: "runtime-cookie-must-be-supplied"
        ]
      ],
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application,
    do: [mod: {Anime.Application, []}, extra_applications: [:logger, :runtime_tools, :crypto]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.15"},
      {:phoenix_ecto, "~> 4.7"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2.12"},
      {:bandit, "~> 1.12"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:jason, "~> 1.4"},
      {:gettext, "~> 1.0"},
      {:bcrypt_elixir, "~> 3.3"},
      {:oban, "~> 2.24"},
      {:swoosh, "~> 1.28"},
      {:gen_smtp, "~> 1.3"},
      {:req, "~> 0.7"},
      # Security floor for the HTTP parser shared by Req/Finch. Keep this patch
      # line until the next minor has an explicit compatibility review.
      {:mint, "~> 1.10.2"},
      {:ex_aws, "~> 2.6"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:lazy_html, "~> 0.1", only: :test},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.15", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.create", "ecto.migrate", "assets.build"],
      "assets.build": ["esbuild default"],
      "assets.deploy": ["esbuild default --minify", "phx.digest"],
      "security.check": [
        "hex.audit",
        "deps.audit",
        "sobelow --router lib/anime_web/router.ex --exit Low"
      ],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
