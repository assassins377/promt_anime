defmodule AnimeWeb.SecurityHeaders do
  @moduledoc """
  Builds security headers once, in Endpoint, including a fresh response nonce.

  The browser pipeline explicitly declares CSP through the resolver-aware
  `put_secure_browser_headers/2` adapter below. It delegates to Phoenix with the
  already-built policy, never a second nonce or a weaker static fallback.
  """
  import Plug.Conn
  def init(opts), do: opts

  @doc "Reads only the policy prepared by the endpoint, not a request header."
  def content_security_policy!(conn), do: Map.fetch!(conn.private, :anime_content_security_policy)

  @doc "Resolves the browser pipeline's CSP option before passing it to Phoenix."
  def put_secure_browser_headers(conn, %{"content-security-policy" => resolve})
      when is_function(resolve, 1) do
    Phoenix.Controller.put_secure_browser_headers(conn, %{
      "content-security-policy" => resolve.(conn)
    })
  end

  def call(conn, _) do
    nonce = Base.encode64(:crypto.strong_rand_bytes(16))
    origin = Application.get_env(:anime, :site_origin, "http://localhost:4000")
    minio = Application.get_env(:anime, :minio_origin, "http://localhost:9000") |> URI.parse()
    minio_origin = URI.to_string(%URI{scheme: minio.scheme, host: minio.host, port: minio.port})
    ws = String.replace_prefix(origin, "http", "ws")

    csp =
      [
        "default-src 'self'",
        "script-src 'self' 'unsafe-eval' 'nonce-#{nonce}'",
        "style-src 'self' 'unsafe-inline'",
        "style-src-attr 'unsafe-inline'",
        "style-src-elem 'self' 'nonce-#{nonce}'",
        "img-src 'self' data: blob: #{minio_origin}",
        "media-src 'self' blob: #{minio_origin}",
        "connect-src 'self' #{ws} #{minio_origin}",
        "font-src 'self'",
        "frame-src 'none'",
        "worker-src 'self' blob:",
        "manifest-src 'self'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'self'",
        "frame-ancestors 'none'",
        "upgrade-insecure-requests"
      ]
      |> Enum.join("; ")

    path = String.replace_prefix(conn.request_path, "/en/", "/")

    secret =
      Enum.any?(
        ["/confirm/", "/password/reset/", "/account/restore/", "/feedback/", "/profile/exports/"],
        &String.starts_with?(path, &1)
      )

    conn
    |> assign(:csp_nonce, nonce)
    |> put_private(:anime_content_security_policy, csp)
    |> put_resp_header("content-security-policy", csp)
    |> put_resp_header(
      "strict-transport-security",
      "max-age=63072000; includeSubDomains; preload"
    )
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header(
      "referrer-policy",
      if(secret, do: "no-referrer", else: "strict-origin-when-cross-origin")
    )
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> put_resp_header("x-permitted-cross-domain-policies", "none")
    |> put_resp_header(
      "permissions-policy",
      "accelerometer=(), ambient-light-sensor=(), autoplay=(self), camera=(), display-capture=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), midi=(), payment=(), usb=(), xr-spatial-tracking=(), fullscreen=*, picture-in-picture=(self)"
    )
    |> put_resp_header("cache-control", "no-store")
  end
end
