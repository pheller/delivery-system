defmodule Prodigy.Portal.Router do
  use Prodigy.Portal, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {Prodigy.Portal.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :auth do
    plug Prodigy.Portal.UserManager.Pipeline
  end

  pipeline :ensure_auth do
    plug Guardian.Plug.EnsureAuthenticated
  end

  scope "/", Prodigy.Portal do
    pipe_through [:browser, :auth]

    live "/", HomeLive
    live "/project", ProjectLive
    get "/news", PageController, :news
    live "/get-started", GetStartedLive

    get "/login", SessionController, :new
    post "/login", SessionController, :login
    get "/logout", SessionController, :logout
    get "/account", PageController, :account

    #get "/users", UsersController, :index
    live "/users", UsersLive
  end

  scope "/", Prodigy.Portal do
    pipe_through [:browser, :auth, :ensure_auth]

    get "/protected", PageController, :protected
  end

  # Other scopes may use custom stacks.
  # scope "/api", Prodigy.Portal do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:portal, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: Prodigy.Portal.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
