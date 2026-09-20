defmodule ApiaryWeb.Router do
  use ApiaryWeb, :router

  import ApiaryWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ApiaryWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ApiaryWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  ## Operations (region owned by the operations work: health)

  scope "/", ApiaryWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  ## The server contract (region owned by the domain work: signed requests, discovery, events)

  pipeline :contract do
    plug :accepts, ["json"]
    plug ApiaryWeb.Contract.SignedRequest
  end

  scope "/.well-known", ApiaryWeb.Contract do
    pipe_through :contract

    get "/qory-configuration", ConfigurationController, :show
  end

  scope "/v1", ApiaryWeb.Contract do
    pipe_through :contract

    post "/events", EventsController, :create
  end

  ## The application (region owned by the web work: everything behind sign-in)

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:apiary, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ApiaryWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## The hive: everything behind sign-in with an organisation loaded

  scope "/", ApiaryWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :hive,
      on_mount: [
        {ApiaryWeb.UserAuth, :require_authenticated},
        {ApiaryWeb.UserAuth, :load_organisation},
        {ApiaryWeb.UserAuth, :require_organisation}
      ] do
      live "/hive", HiveLive.Overview, :index
      live "/hive/keys", AccessKeyLive.Index, :index
      live "/hive/keys/new", AccessKeyLive.Index, :new
      live "/hive/keys/:id/rotate", AccessKeyLive.Index, :rotate
      live "/hive/keys/:id/revoke", AccessKeyLive.Index, :revoke
      live "/hive/members", MemberLive.Index, :index
      live "/hive/members/invite", MemberLive.Index, :invite
      live "/hive/members/:id/remove", MemberLive.Index, :remove
      live "/hive/settings", SettingsLive, :edit
    end

    live_session :no_organisation,
      on_mount: [
        {ApiaryWeb.UserAuth, :require_authenticated},
        {ApiaryWeb.UserAuth, :load_organisation}
      ] do
      live "/no-hive", HiveLive.NoHive, :index
    end

    post "/organisations/switch", OrganisationSessionController, :switch
    get "/invitations/:token/continue", OrganisationSessionController, :continue_invitation
  end

  ## Authentication routes

  scope "/", ApiaryWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [
        {ApiaryWeb.UserAuth, :require_authenticated},
        {ApiaryWeb.UserAuth, :load_organisation}
      ] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", ApiaryWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{ApiaryWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
      live "/invitations/:token", InvitationLive.Accept, :show
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
