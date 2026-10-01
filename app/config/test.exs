import Config

config :anime, :app_env, "test"

config :anime, Anime.Repo,
  url: System.get_env("TEST_DATABASE_URL", "ecto://postgres@127.0.0.1:59432/anime_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :anime, AnimeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false,
  secret_key_base: String.duplicate("test-only-key-not-for-deployment!", 3),
  check_origin: ["http://localhost:4002"]

config :anime, Oban, testing: :manual, queues: false, plugins: false
# Polling the ownership sandbox has different semantics and pollutes unrelated
# telemetry tests. Dedicated tests enable a sampler against an ordinary pool.
config :anime, Anime.Metrics.PoolSampler, enabled: false
# Resource sampling is enabled explicitly by its tests, not unrelated telemetry tests.
config :anime, Anime.Metrics.VMSampler, enabled: false
config :anime, Anime.Metrics.SchedulerSampler, enabled: false
config :anime, Anime.Metrics.CacheSampler, enabled: false
config :anime, Anime.Metrics.ObanSampler, enabled: false
config :anime, Anime.Metrics.PostgresSampler, enabled: false
config :anime, Anime.Metrics.DatabaseSizeSampler, enabled: false
config :anime, Anime.Metrics.DatabaseActivitySampler, enabled: false
config :anime, Anime.Mailer, adapter: Swoosh.Adapters.Test
config :anime, :mx_lookup, false
config :anime, :site_origin, "http://localhost:4002"
config :anime, :minio_origin, "http://localhost:9000"
config :bcrypt_elixir, log_rounds: 4
config :logger, level: :debug
