defmodule AnimeWeb.SecurityHeadersTest do
  use AnimeWeb.ConnCase
  alias AnimeWeb.SecurityHeaders

  defmodule FailureHarness do
    use Plug.Builder

    use Phoenix.Endpoint.RenderErrors,
      formats: [html: AnimeWeb.ErrorHTML],
      log: false

    plug AnimeWeb.SecurityHeaders
    plug Plug.RequestId
    plug :fail

    defp fail(conn, _) do
      conn = put_private(conn, :phoenix_endpoint, AnimeWeb.Endpoint)

      try do
        raise "CSP failure-path test"
      rescue
        error -> Plug.Conn.WrapperError.reraise(conn, :error, error, __STACKTRACE__)
      end
    end
  end

  test "browser adapter preserves the endpoint policy and its nonce" do
    conn = build_conn(:get, "/login") |> SecurityHeaders.call([])
    nonce = conn.assigns.csp_nonce
    [expected] = get_resp_header(conn, "content-security-policy")

    # A router-level fallback or another plug must not replace the endpoint policy.
    adapted =
      conn
      |> put_resp_header("content-security-policy", "default-src *")
      |> SecurityHeaders.put_secure_browser_headers(%{
        "content-security-policy" => &SecurityHeaders.content_security_policy!/1
      })

    assert adapted.assigns.csp_nonce == nonce
    assert get_resp_header(adapted, "content-security-policy") == [expected]
    assert get_resp_header(adapted, "x-frame-options") == ["DENY"]
    assert_policy(adapted.resp_headers, nonce)
  end

  test "missing endpoint policy fails closed instead of trusting client or fallback headers" do
    conn =
      build_conn(:get, "/login")
      |> put_req_header("content-security-policy", "default-src *")
      |> put_resp_header("content-security-policy", "default-src *")
      |> assign(:csp_nonce, "client-controlled")

    assert_raise KeyError, fn ->
      SecurityHeaders.put_secure_browser_headers(conn, %{
        "content-security-policy" => &SecurityHeaders.content_security_policy!/1
      })
    end
  end

  test "each response gets a fresh 16-byte nonce shared by header and inline script" do
    replies = for _ <- 1..3, do: get(build_conn(), "/login")
    nonces = Enum.map(replies, & &1.assigns.csp_nonce)
    assert length(Enum.uniq(nonces)) == 3

    for reply <- replies do
      assert_policy(reply.resp_headers, reply.assigns.csp_nonce)
      assert_inline_nonce(reply)
    end
  end

  test "public, profile and admin HTML share exactly the same policy except nonce" do
    owner = role_user("owner")

    policies =
      for {path, signed_in?} <- [
            {"/login", false},
            {"/en/login", false},
            {"/catalog", false},
            {"/profile/settings", true},
            {"/admin/dashboard", true},
            {"/admin/users", true}
          ] do
        conn = if signed_in?, do: login_conn(build_conn(), owner), else: build_conn()
        reply = get(conn, path)
        assert reply.status == 200
        assert_policy(reply.resp_headers, reply.assigns.csp_nonce)
        assert_inline_nonce(reply)
        policy_without_nonce(reply)
      end

    assert length(Enum.uniq(policies)) == 1
  end

  test "redirects, controlled 403/404, health, robots and static assets retain full CSP" do
    for {method, path, status} <- [
          {:get, "/profile", 302},
          {:get, "/admin", 302},
          {:get, "/403", 403},
          {:get, "/missing-page", 404},
          {:head, "/missing-page", 404},
          {:get, "/healthz", 200},
          {:get, "/robots.txt", 200},
          {:get, "/assets/app.css", 200},
          {:get, "/assets/app.js", 200}
        ] do
      reply = dispatch(build_conn(), @endpoint, method, path)
      assert reply.status == status
      assert_policy(reply.resp_headers, reply.assigns.csp_nonce)
    end
  end

  test "CSRF and early parser errors retain the full policy and matching inline nonce" do
    for failure <- [:csrf, :parser] do
      status = if failure == :csrf, do: 403, else: 400

      {^status, headers, html} =
        assert_error_sent status, fn ->
          case failure do
            :csrf ->
              build_conn()
              |> put_private(:plug_skip_csrf_protection, false)
              |> post("/en/login", %{})

            :parser ->
              build_conn()
              |> put_req_header("content-type", "application/json")
              |> put_req_header("accept", "text/html")
              |> post("/en/login", "{invalid")
          end
        end

      policy = List.keyfind(headers, "content-security-policy", 0) |> elem(1)
      [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, policy)
      assert_policy(headers, nonce)

      if failure == :csrf do
        assert LazyHTML.from_document(html)
               |> LazyHTML.query("script:not([src])")
               |> LazyHTML.attribute("nonce") == [nonce]
      else
        # Early malformed JSON uses the minimal, script-free error layout.
        refute html =~ "<script"
      end
    end
  end

  test "secret routes keep no-referrer even after the browser header adapter" do
    for path <- [
          "/confirm/fake",
          "/en/confirm/fake",
          "/password/reset/fake",
          "/en/password/reset/fake",
          "/account/restore/fake",
          "/en/account/restore/fake",
          "/feedback/fake",
          "/en/profile/exports/fake"
        ] do
      reply = get(build_conn(), path)
      assert get_resp_header(reply, "referrer-policy") == ["no-referrer"]
      assert_policy(reply.resp_headers, reply.assigns.csp_nonce)
    end

    reply = get(build_conn(), "/login")
    assert get_resp_header(reply, "referrer-policy") == ["strict-origin-when-cross-origin"]
  end

  test "500 fallback keeps the same complete CSP without adding executable markup" do
    {500, headers, html} =
      assert_error_sent 500, fn ->
        build_conn(:get, "/en/failure")
        |> put_req_header("accept", "text/html")
        |> FailureHarness.call([])
      end

    policy = List.keyfind(headers, "content-security-policy", 0) |> elem(1)
    [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, policy)
    assert_policy(headers, nonce)
    refute html =~ "<script"
    refute html =~ "CSP failure-path test"
  end

  test "request CSP and nonce headers cannot influence the response policy" do
    reply =
      build_conn()
      |> put_req_header("content-security-policy", "default-src *; script-src 'unsafe-inline'")
      |> put_req_header("x-csp-nonce", "attacker-nonce")
      |> get("/login")

    refute reply.assigns.csp_nonce == "attacker-nonce"
    assert_policy(reply.resp_headers, reply.assigns.csp_nonce)
    assert_inline_nonce(reply)
  end

  defp assert_inline_nonce(conn) do
    doc = LazyHTML.from_document(html_response(conn, 200))

    assert LazyHTML.query(doc, "script:not([src])") |> LazyHTML.attribute("nonce") == [
             conn.assigns.csp_nonce
           ]
  end

  defp policy_without_nonce(conn) do
    [policy] = get_resp_header(conn, "content-security-policy")
    String.replace(policy, conn.assigns.csp_nonce, "RESPONSE_NONCE")
  end

  defp assert_policy(headers, nonce) do
    assert is_binary(nonce)
    assert {:ok, bytes} = Base.decode64(nonce)
    assert byte_size(bytes) == 16

    assert [{_, policy}] =
             Enum.filter(headers, fn {key, _} -> key == "content-security-policy" end)

    refute List.keymember?(headers, "content-security-policy-report-only", 0)

    directives = String.split(policy, "; ")
    assert length(directives) == 17

    assert Map.new(directives, fn directive ->
             case String.split(directive, " ", parts: 2) do
               [key, value] -> {key, value}
               [key] -> {key, ""}
             end
           end) == %{
             "default-src" => "'self'",
             "script-src" => "'self' 'unsafe-eval' 'nonce-#{nonce}'",
             "style-src" => "'self' 'unsafe-inline'",
             "style-src-attr" => "'unsafe-inline'",
             "style-src-elem" => "'self' 'nonce-#{nonce}'",
             "img-src" => "'self' data: blob: http://localhost:9000",
             "media-src" => "'self' blob: http://localhost:9000",
             "connect-src" => "'self' ws://localhost:4002 http://localhost:9000",
             "font-src" => "'self'",
             "frame-src" => "'none'",
             "worker-src" => "'self' blob:",
             "manifest-src" => "'self'",
             "object-src" => "'none'",
             "base-uri" => "'none'",
             "form-action" => "'self'",
             "frame-ancestors" => "'none'",
             "upgrade-insecure-requests" => ""
           }
  end
end
