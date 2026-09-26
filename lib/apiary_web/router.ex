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
    plug ApiaryWeb.Lingo
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ApiaryWeb do
    pipe_through :browser

    get "/", PageController, :home

    # The documentation (decision 0043). The endpoint serves the built files under /docs;
    # these answer /docs itself and what was not found. Public: no authentication.
    get "/docs", DocsController, :index
    get "/docs/*path", DocsController, :missing
  end

  ## Operations (region owned by the operations work: health)

  scope "/", ApiaryWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  ## The server contract (region owned by the domain work: signed requests, discovery, events, run configuration)

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
    get "/run-configuration", RunConfigurationController, :show
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

  ## The workspace: everything behind sign-in with an organisation loaded

  scope "/", ApiaryWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :workspace,
      on_mount: [
        {ApiaryWeb.UserAuth, :require_authenticated},
        {ApiaryWeb.UserAuth, :load_organisation},
        {ApiaryWeb.UserAuth, :require_organisation}
      ] do
      live "/workspace", WorkspaceLive.Overview, :index
      # The record: the runs of the workspace, and where they reached out to. With the
      # rest of the workspace's pages, behind sign-in with an organisation loaded, so the
      # scope they query through is there; every filter is a query parameter.
      live "/workspace/runs", RunLive.Index, :index
      live "/workspace/connections", ConnectionLive.Index, :index
      # One run: four tabs of one LiveView, so a tab is a patch. `:run_id` is the run's
      # subject, the id the runner prints, not the row's id.
      live "/workspace/runs/:run_id", RunLive.Show, :timeline
      live "/workspace/runs/:run_id/terminal", RunLive.Show, :terminal
      live "/workspace/runs/:run_id/connections", RunLive.Show, :connections
      live "/workspace/runs/:run_id/details", RunLive.Show, :details
      # The security policy: the workspace's baseline and a target's view of it, one
      # object with two scopes. Tabs, filters, the opened change, the compared version and
      # the export modal are in the URL. `:target_id` is the target row's id, because
      # a system and a path hold slashes.
      live "/workspace/policy", PolicyLive.Show, :rules
      live "/workspace/policy/targets", PolicyLive.Show, :targets
      live "/workspace/policy/history", PolicyLive.Show, :history
      live "/workspace/policy/document", PolicyLive.Show, :document
      live "/workspace/policy/versions/:n", PolicyLive.Show, :version
      live "/workspace/policy/versions/:n/export", PolicyLive.Show, :export
      live "/workspace/policy/targets/:target_id", PolicyLive.Target, :rules
      live "/workspace/policy/targets/:target_id/history", PolicyLive.Target, :history
      live "/workspace/policy/targets/:target_id/document", PolicyLive.Target, :document
      live "/workspace/policy/targets/:target_id/versions/:n", PolicyLive.Target, :version

      live "/workspace/policy/targets/:target_id/versions/:n/export",
           PolicyLive.Target,
           :export

      live "/workspace/keys", AccessKeyLive.Index, :index
      live "/workspace/keys/new", AccessKeyLive.Index, :new
      live "/workspace/keys/:id/rotate", AccessKeyLive.Index, :rotate
      live "/workspace/keys/:id/revoke", AccessKeyLive.Index, :revoke
      live "/workspace/members", MemberLive.Index, :index
      live "/workspace/members/invite", MemberLive.Index, :invite
      live "/workspace/members/:id/remove", MemberLive.Index, :remove
      live "/workspace/settings", SettingsLive, :edit
    end

    live_session :no_organisation,
      on_mount: [
        {ApiaryWeb.UserAuth, :require_authenticated},
        {ApiaryWeb.UserAuth, :load_organisation}
      ] do
      live "/no-workspace", WorkspaceLive.NoWorkspace, :index
    end

    # The raw bytes of a run's log, for the terminal of the run page. Not a page.
    get "/workspace/runs/:run_id/log", RunLogController, :show

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
