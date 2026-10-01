defmodule AnimeWeb.ErrorPagesTest do
  use AnimeWeb.ConnCase

  test "unknown GET is a controller 404 with navigation, no indexing or LiveView", %{conn: conn} do
    c = get(conn, "/missing-page?private=should-not-appear")
    html = html_response(c, 404)
    doc = LazyHTML.from_document(html)
    assert LazyHTML.query(doc, "h1") |> LazyHTML.text() == "Страница не найдена"

    assert LazyHTML.query(doc, "meta[name=robots]") |> LazyHTML.attribute("content") == [
             "noindex,follow"
           ]

    assert html =~ ~s(href="/catalog")
    assert html =~ ~s(href="/")
    assert html =~ "<header"
    assert html =~ "<footer"
    refute html =~ "data-phx-main"
    assert LazyHTML.query(doc, "link[rel=canonical],link[hreflang]") |> Enum.empty?()
    assert_headers(c.resp_headers)
  end

  test "404 uses URL English, then cookie, then Russian", %{conn: conn} do
    for {path, cookie, locale, title} <- [
          {"/en/missing", "ru", "en", "Page not found"},
          {"/missing", "en", "en", "Page not found"},
          {"/missing", "ru", "ru", "Страница не найдена"},
          {"/missing", "bad", "ru", "Страница не найдена"}
        ] do
      html = conn |> put_req_cookie("locale", cookie) |> get(path) |> html_response(404)
      assert html =~ ~s(<html lang="#{locale}">)
      assert html =~ "<title>#{title} · Anime</title>"
      assert html =~ ~s(href="#{if locale == "en", do: "/en/catalog", else: "/catalog"}")
    end
  end

  test "missing public profile uses the same 404 with noindex follow", %{conn: conn} do
    html = conn |> get("/en/u/no-such-profile") |> html_response(404)
    assert html =~ "Page not found"
    assert html =~ ~s(content="noindex,follow")
  end

  test "unknown POST is safely rendered by Phoenix's fallback", %{conn: conn} do
    c = post(conn, "/en/missing", %{})
    assert html_response(c, 404) =~ "Page not found"
    assert_headers(c.resp_headers)
  end

  test "HEAD missing page has no body", %{conn: conn} do
    c = head(conn, "/missing")
    assert response(c, 404) == ""
    assert_headers(c.resp_headers)
  end

  test "parser failure before Router retains request id and security headers", %{conn: conn} do
    {400, headers, html} =
      assert_error_sent 400, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/html")
        |> put_req_header("x-request-id", "test-invalid-json-request")
        |> post("/en/login", ~s({"secret":"NEVER-REFLECT-THIS"))
      end

    assert_headers(headers)
    assert html =~ "Invalid request"
    assert html =~ Map.new(headers)["x-request-id"]
    refute html =~ "test-invalid-json-request"
    refute html =~ "NEVER-REFLECT-THIS"
    refute html =~ "ParseError"
  end

  test "CSRF failure keeps headers and never exposes the exception", %{conn: conn} do
    {403, headers, html} =
      assert_error_sent 403, fn ->
        conn |> put_private(:plug_skip_csrf_protection, false) |> post("/en/login", %{})
      end

    assert_headers(headers)
    assert html =~ "Insufficient permissions"
    refute html =~ "InvalidCSRFTokenError"
    assert html =~ ~s(content="noindex,nofollow")
  end

  defp assert_headers(headers) do
    headers = Map.new(headers)
    assert headers["content-security-policy"] =~ "frame-ancestors 'none'"
    assert headers["strict-transport-security"] =~ "max-age="
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["x-frame-options"] == "DENY"
    assert headers["cache-control"] == "no-store"
    assert byte_size(headers["x-request-id"]) >= 20
  end
end

defmodule AnimeWeb.ErrorRendererTest do
  # Deliberately no ConnCase/Sandbox owner: any accidental Repo read fails.
  use ExUnit.Case, async: true
  import Plug.Conn
  import Phoenix.ConnTest

  defmodule FailureHarness do
    use Plug.Builder

    use Phoenix.Endpoint.RenderErrors,
      formats: [html: AnimeWeb.ErrorHTML, json: AnimeWeb.ErrorJSON],
      log: false

    plug AnimeWeb.SecurityHeaders
    plug AnimeWeb.ClientIP
    plug :fail

    defp fail(conn, _) do
      conn = put_private(conn, :phoenix_endpoint, AnimeWeb.Endpoint)

      try do
        raise "DATABASE-PASSWORD-SENTINEL SELECT * FROM users /secret/source.ex"
      rescue
        error -> Plug.Conn.WrapperError.reraise(conn, :error, error, __STACKTRACE__)
      end
    end
  end

  test "500 renders through Phoenix without a database and discloses only request id" do
    {500, headers, html} =
      assert_error_sent 500, fn ->
        build_conn(:get, "/en/private?token=BEARER-SENTINEL")
        |> put_req_header("accept", "text/html")
        |> put_req_header("x-request-id", "test-failure-request-id-123")
        |> FailureHarness.call([])
      end

    assert html =~ "Unable to complete the request"
    assert html =~ Map.new(headers)["x-request-id"]
    refute html =~ "test-failure-request-id-123"
    assert html =~ ~s(content="noindex,nofollow")
    assert Map.new(headers)["content-security-policy"] =~ "object-src 'none'"
    assert Map.new(headers)["cache-control"] == "no-store"

    for secret <- [
          "DATABASE-PASSWORD-SENTINEL",
          "BEARER-SENTINEL",
          "SELECT",
          "RuntimeError",
          "/secret/source.ex",
          "FailureHarness"
        ] do
      refute html =~ secret
    end

    refute html =~ "<header"
    refute html =~ "<script"
  end

  test "500 escapes a client-provided request id and restores the caller locale" do
    Gettext.put_locale(AnimeWeb.Gettext, "ru")

    conn =
      build_conn(:get, "/en/missing")
      |> put_resp_header("x-request-id", "<script>alert('x')</script>")

    html =
      AnimeWeb.ErrorHTML.render("500.html", %{conn: conn, reason: "SECRET"})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    refute html =~ "SECRET"
    assert Gettext.get_locale(AnimeWeb.Gettext) == "ru"
  end

  test "fallback 404 and 403 can render without session or database" do
    for {code, text} <- [{404, "Page not found"}, {403, "Insufficient permissions"}] do
      conn = build_conn(:get, "/en/missing") |> AnimeWeb.SecurityHeaders.call([])

      html =
        AnimeWeb.ErrorHTML.render("#{code}.html", %{conn: conn})
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ text
      assert html =~ "<header"
      assert html =~ "<footer"
    end
  end

  test "JSON errors never echo details" do
    assert AnimeWeb.ErrorJSON.render("500.json", %{reason: "SECRET"}) == %{
             error: "Request failed"
           }
  end
end
