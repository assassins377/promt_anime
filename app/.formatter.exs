[
  import_deps: [:ecto, :ecto_sql, :phoenix, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{ex,exs}",
    "{config,lib,test,priv}/**/*.{ex,exs,heex}",
    "dev/coverage*.exs",
    "dev/release_package_smoke.exs"
  ]
]
