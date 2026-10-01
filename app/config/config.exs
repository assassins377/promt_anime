import Config

config :anime, ecto_repos: [Anime.Repo], generators: [timestamp_type: :utc_datetime_usec]
config :anime, :trusted_proxies, []

config :anime, Anime.Repo,
  log: false,
  migration_primary_key: [type: :bigserial],
  migration_timestamps: [type: :utc_datetime_usec]

config :anime, AnimeWeb.Endpoint,
  adapter: AnimeWeb.DrainingAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: AnimeWeb.ErrorHTML, json: AnimeWeb.ErrorJSON],
    layout: false,
    log: false
  ],
  pubsub_server: Anime.PubSub,
  live_view: [signing_salt: "test-only-overridden-by-runtime!!"]

config :anime, Oban,
  repo: Anime.Repo,
  shutdown_grace_period: 60_000,
  lifeline: [rescue_after: :timer.hours(8), interval: :timer.minutes(1)],
  queues: [mailers: 10, maintenance: 2],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"20 3 * * *", Anime.Workers.ExpireAccounts},
       {"*/15 * * * *", Anime.Workers.UnblockUsers},
       {"10 1 * * *", Anime.Workers.DeleteAccounts}
     ]}
  ]

config :anime, Anime.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, false
config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "password",
  "password_confirmation",
  "current_password",
  "token",
  "_csrf_token",
  "signature",
  "email",
  "guest_email",
  "raw_body",
  "issue_nonce",
  "authorization",
  "secret",
  "cookie",
  "session_token"
]

config :anime, AnimeWeb.Gettext, default_locale: "ru", locales: ~w(ru en)

config :esbuild,
  version: "0.25.5",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --loader:.woff2=file --asset-names=fonts/[name]-[hash] --external:/assets/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :logger, :default_handler,
  formatter: {Anime.LogFormatter, %{}},
  config: [type: :standard_io]

config :logger, :default_formatter,
  format: {Anime.LogFormatter, :legacy_format},
  metadata: :all,
  colors: [enabled: false]

import_config "#{config_env()}.exs"
