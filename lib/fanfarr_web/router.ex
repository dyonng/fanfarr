defmodule FanfarrWeb.Router do
  use FanfarrWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FanfarrWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # Must come before load_from_session: it only writes the session, so
    # load_from_session is what turns that into conn.assigns.current_user for
    # this request rather than the next one.
    plug :sign_in_with_remember_me
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  scope "/", FanfarrWeb do
    pipe_through [:browser]
    auth_routes AuthController, Fanfarr.Accounts.User, path: "/auth"

    sign_out_route AuthController, "/sign-out",
      overrides: [FanfarrWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]

    # Remove these if you'd like to use your own authentication views
    # No register_path or reset_path: there is no sign-up. The operator account
    # is declared with AUTH_USERNAME/AUTH_PASSWORD in the compose file and
    # reconciled at boot by Fanfarr.Accounts.Seed.
    sign_in_route auth_routes_prefix: "/auth",
                  on_mount: [{FanfarrWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    FanfarrWeb.AuthOverrides,
                    AshAuthentication.Phoenix.Overrides.Default
                  ]

    # No reset, confirmation or magic-link routes: those strategies need a
    # mailer this appliance deliberately does not have. A lost password is
    # recovered from the machine itself -- see "Resetting a lost password" in
    # the README.
  end

  scope "/", FanfarrWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes,
      on_mount: [FanfarrWeb.QueueStatus],
      session: {FanfarrWeb.LiveUserAuth, :extra_session, []} do
      live "/", LibraryLive.Index, :index
      live "/library/:id", ItemLive.Show, :show
      live "/activity", ActivityLive.Index, :index
      live "/settings", SettingsLive.Index, :index
      live "/system", SystemLive.Index, :index
    end
  end

  scope "/api/json" do
    pipe_through [:api]

    forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/json/open_api",
      default_model_expand_depth: 4

    forward "/", FanfarrWeb.AshJsonApiRouter
  end

  scope "/", FanfarrWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  # Media for the dashboard: posters, and the theme audio Fanfarr wrote.
  # Session-aware so an operator login gates them the same as the pages that
  # show them, but no CSRF: these are GETs for files.
  pipeline :media do
    plug :accepts, ["html", "*/*"]
    plug :fetch_session
    plug :sign_in_with_remember_me
    plug :load_from_session
    plug FanfarrWeb.RequireUserPlug
  end

  scope "/", FanfarrWeb do
    pipe_through :media

    get "/posters/:id", PosterController, :show
    get "/library/:id/theme", ThemeController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", FanfarrWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:fanfarr, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FanfarrWeb.Telemetry
    end
  end
end
