defmodule AnimeWeb.PlugContractTest do
  use AnimeWeb.ConnCase

  test "Auth plug initializes and resolves a revoked session as anonymous", %{conn: conn} do
    actor = user()
    conn = login_conn(conn, actor)
    :ok = Anime.Accounts.Tokens.revoke(get_session(conn, :user_token))
    conn = AnimeWeb.Auth.call(conn, AnimeWeb.Auth.init([]))
    refute conn.assigns.current_user
  end

  test "a block committed after login validation cannot establish a session", %{conn: conn} do
    actor = user()
    before = Repo.aggregate(Anime.Accounts.UserToken, :count)
    actor |> Ecto.Changeset.change(status: :blocked) |> Repo.update!()
    conn = conn |> init_test_session(%{}) |> fetch_cookies() |> Phoenix.Controller.fetch_flash([])
    conn = AnimeWeb.Auth.establish(conn, actor, true)
    assert redirected_to(conn) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Вход недоступен"
    refute get_session(conn, :user_token)
    refute conn.resp_cookies["_anime_remember"]
    assert Repo.aggregate(Anime.Accounts.UserToken, :count) == before
  end

  test "HTTP and WebSocket share the secure encrypted cookie options" do
    options = AnimeWeb.RequestPipeline.session_options()
    assert options[:store] == :cookie
    assert options[:key] == "_anime_session"
    assert options[:secure] && options[:http_only]
    assert options[:same_site] == "Lax"
    assert is_binary(options[:signing_salt]) && is_binary(options[:encryption_salt])
  end

  test "malformed URI is refused while valid escaped query remains local" do
    assert AnimeWeb.Auth.safe_return(<<"/", 255>>) == "/"
    assert AnimeWeb.Auth.safe_return("/%FF") == "/"
    assert AnimeWeb.Auth.safe_return("/catalog?q=My%20Hero") == "/catalog?q=My%20Hero"

    assert AnimeWeb.Auth.safe_return("/catalog?genre[]=1&genre[]=2") ==
             "/catalog?genre[]=1&genre[]=2"
  end
end
