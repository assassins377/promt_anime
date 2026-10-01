defmodule AnimeWeb.Auth do
  import Plug.Conn, except: [assign: 3]
  import Phoenix.Controller
  import Phoenix.Component, only: [assign: 3]
  alias Anime.Accounts
  alias Anime.Accounts.Tokens
  alias AnimeWeb.Locale

  def init(opts), do: opts
  def call(conn, _), do: fetch_user(conn, [])

  def fetch_user(conn, _) do
    conn = fetch_cookies(conn, signed: ["_anime_remember"])
    raw = get_session(conn, :user_token)
    user = Tokens.user(raw)

    {conn, user, raw} =
      if is_nil(user) && is_binary(conn.cookies["_anime_remember"]) do
        case Accounts.restore_session(conn.cookies["_anime_remember"], meta(conn)) do
          {:ok, new} ->
            {conn |> configure_session(renew: true) |> put_session(:user_token, new),
             Tokens.user(new), new}

          _ ->
            {delete_resp_cookie(conn, "_anime_remember"), nil, nil}
        end
      else
        {conn, user, raw}
      end

    conn |> Plug.Conn.assign(:current_user, user) |> Plug.Conn.assign(:session_token, raw)
  end

  def locale(conn, _) do
    locale =
      if conn.request_path == "/" || Locale.service?(conn.request_path),
        do:
          Locale.preferred(
            conn.assigns.current_user,
            conn.cookies,
            get_req_header(conn, "accept-language")
          ),
        else: Locale.path_locale(conn.request_path)

    Gettext.put_locale(AnimeWeb.Gettext, locale)

    conn =
      conn
      |> Plug.Conn.assign(:locale, locale)
      |> Plug.Conn.assign(:current_path, Locale.current_path(conn))
      |> put_session(:locale, locale)

    # Only the unprefixed entry point negotiates. Deep links keep their URL
    # language, so sharing a Russian page never silently renders English HTML.
    if conn.method in ["GET", "HEAD"] && conn.request_path == "/" && locale == "en" do
      conn |> redirect(to: Locale.localized("en", Locale.current_path(conn))) |> halt()
    else
      conn
    end
  end

  def force_password(conn, _) do
    allowed? =
      conn.request_path in ["/password/change", "/en/password/change"] ||
        (conn.method == "POST" && conn.request_path in ["/locale", "/logout"])

    if conn.assigns.current_user && conn.assigns.current_user.must_change_password &&
         !allowed? do
      conn |> redirect(to: path(conn, "/password/change")) |> halt()
    else
      conn
    end
  end

  def require_user(conn, _) do
    if conn.assigns.current_user do
      conn
    else
      conn
      |> put_session(:return_to, safe_return(Locale.current_path(conn)))
      |> redirect(to: path(conn, "/login"))
      |> halt()
    end
  end

  def on_mount(kind, _params, session, socket) do
    raw = session["user_token"]
    user = Tokens.user(raw)
    locale = session["locale"] || "ru"
    Gettext.put_locale(AnimeWeb.Gettext, locale)

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:session_token, raw)
      |> assign(:locale, locale)
      |> assign(:client_meta, socket_meta(socket))
      |> Phoenix.LiveView.attach_hook(:locale_location, :handle_params, fn _, uri, socket ->
        {:cont, assign(socket, :current_path, Locale.current_path(uri))}
      end)

    if kind == :required && is_nil(user) do
      {:halt, Phoenix.LiveView.redirect(socket, to: localized(locale, "/login"))}
    else
      if user && Phoenix.LiveView.connected?(socket),
        do: Phoenix.PubSub.subscribe(Anime.PubSub, "user:#{user.id}:access")

      {:cont, socket}
    end
  end

  def establish(conn, user, remember) do
    Tokens.revoke(get_session(conn, :user_token))
    Tokens.revoke(conn.cookies["_anime_remember"])

    case Accounts.create_session(user, remember, meta(conn)) do
      {:ok, {session, cookie}} ->
        return_to = get_session(conn, :return_to) |> safe_return()

        conn =
          conn
          |> configure_session(renew: true)
          |> clear_session()
          |> put_session(:user_token, session)

        conn =
          if cookie,
            do:
              put_resp_cookie(conn, "_anime_remember", cookie,
                sign: true,
                max_age: 60 * 86400,
                http_only: true,
                secure: true,
                same_site: "Lax"
              ),
            else: delete_resp_cookie(conn, "_anime_remember")

        redirect(conn,
          to: if(user.must_change_password, do: path(conn, "/password/change"), else: return_to)
        )

      _ ->
        conn |> put_flash(:error, "Вход недоступен") |> redirect(to: path(conn, "/login"))
    end
  end

  def safe_return(value) when is_binary(value) do
    decoded = URI.decode(value)
    uri = URI.parse(decoded)

    # URI.parse accepts browser query syntax such as genre[]=1. Validate UTF-8
    # explicitly; a strict URI.new check would reject those valid local links.
    if String.valid?(decoded) && byte_size(value) <= 512 &&
         String.starts_with?(decoded, "/") &&
         !String.starts_with?(decoded, "//") &&
         !String.contains?(decoded, ["\\", "\r", "\n", <<0>>]) && is_nil(uri.host) &&
         is_nil(uri.scheme) &&
         !String.starts_with?(decoded, "/admin"), do: value, else: "/"
  end

  def safe_return(_), do: "/"

  defp socket_meta(socket) do
    if Phoenix.LiveView.connected?(socket) do
      peer = Phoenix.LiveView.get_connect_info(socket, :peer_data)
      agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)
      headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
      client = Anime.ClientIP.resolve(peer && peer.address, headers)
      Anime.ClientIP.observe(client, :websocket)

      %{
        ip: Anime.ClientIP.text(client.ip),
        user_agent: String.slice(agent || "", 0, 512)
      }
    else
      %{}
    end
  end

  defdelegate localized(locale, path), to: Locale
  def path(conn, p), do: localized(conn.assigns[:locale], p)
  # Endpoint has already resolved this from the transport peer and trusted CIDRs.
  def meta(conn),
    do: %{
      ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent:
        get_req_header(conn, "user-agent")
        |> List.first()
        |> then(&String.slice(&1 || "", 0, 512))
    }
end
