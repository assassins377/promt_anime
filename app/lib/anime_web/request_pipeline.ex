defmodule AnimeWeb.RequestPipeline do
  @moduledoc false
  use Plug.Builder

  @session_options [
    store: :cookie,
    key: "_anime_session",
    signing_salt: "session-v1",
    encryption_salt: "encrypted-v1",
    same_site: "Lax",
    http_only: true,
    secure: true
  ]

  def session_options, do: @session_options

  plug Plug.Static, at: "/", from: :anime, gzip: true, only: ~w(assets images favicon.ico)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    length: 8_388_608

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug AnimeWeb.Router
end
