defmodule AnimeWeb.Router do
  use Phoenix.Router
  @after_compile AnimeWeb.AdminRouteCheck
  import Phoenix.Controller, except: [put_secure_browser_headers: 2]
  import AnimeWeb.SecurityHeaders, only: [put_secure_browser_headers: 2]
  import Phoenix.LiveView.Router
  import AnimeWeb.Auth, only: [locale: 2, require_user: 2, force_password: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AnimeWeb.Layouts, :root}
    plug :protect_from_forgery
    # Declare CSP explicitly while reusing Endpoint's exact per-response policy.
    plug :put_secure_browser_headers, %{
      "content-security-policy" => &AnimeWeb.SecurityHeaders.content_security_policy!/1
    }

    plug AnimeWeb.Auth
    plug :locale
    plug :force_password
  end

  pipeline :authenticated do
    plug :require_user
  end

  scope "/", AnimeWeb, log: false do
    get "/healthz", HealthController, :live
    get "/readyz", HealthController, :ready
    get "/robots.txt", HealthController, :robots
  end

  scope "/", AnimeWeb, log: false do
    pipe_through :browser
    post "/locale", SessionController, :locale
    post "/logout", SessionController, :logout
  end

  for prefix <- ["/", "/en"] do
    scope prefix, AnimeWeb, log: false do
      pipe_through :browser
      post "/login", SessionController, :login
      post "/register", SessionController, :register
      get "/confirm/:token", SessionController, :confirm
      get "/account/restore/:token", SessionController, :restore
      get "/403", PageController, :forbidden
      get "/u/:nick", PublicProfileController, :show

      live_session if(prefix == "/", do: :public_ru, else: :public_en),
        session:
          {AnimeWeb.LogContext, :session,
           [%{"locale" => if(prefix == "/", do: "ru", else: "en")}]},
        on_mount: [AnimeWeb.ShutdownGate, AnimeWeb.LogContext, {AnimeWeb.Auth, :optional}] do
        live "/login", AuthLive, :login
        live "/register", AuthLive, :register
        live "/password/reset", AuthLive, :request_reset
        live "/password/reset/:token", AuthLive, :reset
        live "/", PlaceholderLive, :home
        live "/catalog", PlaceholderLive, :catalog
        live "/catalog/:type", PlaceholderLive, :catalog
        live "/genres", PlaceholderLive, :genres
        live "/blog", PlaceholderLive, :blog
        live "/donate", PlaceholderLive, :donate
        live "/feedback", PlaceholderLive, :feedback
        live "/terms", PlaceholderLive, :terms
        live "/privacy", PlaceholderLive, :privacy
      end

      scope "/" do
        pipe_through :authenticated
        post "/password/change", SessionController, :password

        live_session if(prefix == "/", do: :profile_ru, else: :profile_en),
          session:
            {AnimeWeb.LogContext, :session,
             [%{"locale" => if(prefix == "/", do: "ru", else: "en")}]},
          on_mount: [AnimeWeb.ShutdownGate, AnimeWeb.LogContext, {AnimeWeb.Auth, :required}] do
          live "/profile", ProfileLive, :overview
          live "/profile/settings", ProfileLive, :settings
          live "/profile/bookmarks", PlaceholderLive, :bookmarks
          live "/password/change", AuthLive, :change
        end
      end
    end
  end

  scope "/admin", AnimeWeb, log: false do
    pipe_through [:browser, :authenticated]

    live_session :admin,
      session: {AnimeWeb.LogContext, :session, []},
      on_mount: [
        AnimeWeb.ShutdownGate,
        AnimeWeb.LogContext,
        {AnimeWeb.Auth, :required},
        {AnimeWeb.AdminGuard, :admin}
      ] do
      live "/", AdminIndexLive, :index
      live "/dashboard", AdminLive, :index
      live "/content/anime/new", ContentPlaceholderLive, :new
      live "/users", UsersLive, :index
      live "/users/blocked", UsersLive, :blocked
      live "/users/activity", UserActivityLive, :index
      live "/users/:id", UserAdminLive, :show
      live "/roles", RolesLive, :index
      live "/roles/permissions", PermissionsLive, :index
      live "/roles/matrix", MatrixLive, :index
    end
  end

  if Mix.env() == :dev do
    scope "/dev" do
      pipe_through :browser
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Last: missing pages are controller/HEEx responses, never LiveViews.
  scope "/", AnimeWeb, log: false do
    pipe_through :browser
    get "/*path", PageController, :not_found
  end
end
