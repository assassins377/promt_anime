import Config

config :anime, AnimeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  debug_errors: false,
  code_reloader: false

config :logger, level: :debug
