import Config
config :anime, AnimeWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"
config :anime, AnimeWeb.Endpoint, force_ssl: [rewrite_on: [:x_forwarded_proto]]
config :logger, level: :info
