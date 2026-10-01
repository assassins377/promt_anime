import Config

if config_env() != :test do
  runtime = Anime.RuntimeConfig.load!()
  mail = Anime.MailConfig.load!(System.get_env(), runtime.environment, runtime.host)

  config :anime, :app_env, runtime.environment

  config :anime,
         :staging_mail_allowlist,
         if(runtime.environment == "staging",
           do: Anime.MailPolicy.parse!(System.get_env("STAGING_MAIL_ALLOWLIST")),
           else: MapSet.new()
         )

  config :anime, :node_role, runtime.node_role
  config :anime, :trusted_proxies, runtime.trusted_proxies
  config :anime, Anime.Metrics.Exporter, server: runtime.server, port: runtime.metrics_port
  config :anime, :site_origin, runtime.origin
  config :anime, :minio_origin, runtime.minio_public_url
  config :anime, :mx_lookup, true
  config :anime, :mail_return_path, mail.return_path
  config :anime, Anime.Mailer, mail.options
  config :logger, level: runtime.log_level

  config :anime, Anime.Repo,
    url: runtime.database_url,
    ssl: runtime.database_ssl,
    pool_size: runtime.pool_size

  config :anime, AnimeWeb.Endpoint,
    url: [host: runtime.host, scheme: "http", port: runtime.port],
    http: [
      ip: {127, 0, 0, 1},
      port: runtime.port,
      thousand_island_options: [shutdown_timeout: 30_000]
    ],
    secret_key_base: runtime.secret_key_base,
    live_view: [signing_salt: runtime.live_view_signing_salt],
    check_origin: [runtime.origin],
    server: runtime.server

  config :ex_aws,
    access_key_id: runtime.minio_access_key_id,
    secret_access_key: runtime.minio_secret_access_key,
    region: runtime.minio_region,
    http_client: Anime.Storage.HTTP

  config :ex_aws, :s3,
    scheme: runtime.minio_endpoint.scheme <> "://",
    host: runtime.minio_endpoint.host,
    port: runtime.minio_endpoint.port
end
