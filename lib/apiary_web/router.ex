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

    # The documentation. The endpoint serves the built files under /docs; these answer
    # /docs itself and what was not found. Public: no authentication.
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

  scope "/", ApiaryWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/invitations/:token/continue", InvitationController, :continue
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
      # A user's organisations: for now the page of a user who has none.
      live "/users/organisations", WorkspaceLive.NoWorkspace, :index
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

  ## The organisations and their workspaces, last: `/:org` and `/:org/:workspace` would
  ## match every path of one or two segments above. The first segment is never one of
  ## `ApiaryWeb.ReservedSlugs.organisation/0`, the second of an organisation's never one
  ## of `ApiaryWeb.ReservedSlugs.workspace/0`; the router's test holds both lists to these
  ## routes.

  pipeline :path_scope do
    plug ApiaryWeb.ReservedSlugs
  end

  scope "/", ApiaryWeb do
    pipe_through [:path_scope, :browser, :require_authenticated_user, :fetch_path_scope]

    live_session :workspace,
      on_mount: [
        {ApiaryWeb.UserAuth, :require_authenticated},
        {ApiaryWeb.UserAuth, :load_path_scope}
      ] do
      # The organisation's own pages. The workspace in the scope is the one of the user's
      # membership in it.
      scope "/:org" do
        live "/members", MemberLive.Index, :index
        live "/members/invite", MemberLive.Index, :invite
        live "/members/:id/remove", MemberLive.Index, :remove
        live "/settings", SettingsLive, :organisation
      end

      scope "/:org/:workspace" do
        live "/", WorkspaceLive.Overview, :index
        # The record: the runs of the workspace, and where they reached out to. Every
        # filter is a query parameter.
        live "/runs", RunLive.Index, :index
        live "/connections", ConnectionLive.Index, :index
        # One run: four tabs of one LiveView, so a tab is a patch. `:run_id` is the run's
        # subject, the id the runner prints, not the row's id.
        live "/runs/:run_id", RunLive.Show, :timeline
        live "/runs/:run_id/terminal", RunLive.Show, :terminal
        live "/runs/:run_id/connections", RunLive.Show, :connections
        live "/runs/:run_id/details", RunLive.Show, :details
        # The security policy: the workspace's baseline and a target's view of it, one
        # object with two scopes. Tabs, filters, the opened change, the compared version
        # and the export modal are in the URL. `:target_id` is the target row's id,
        # because a system and a path hold slashes.
        live "/policy", PolicyLive.Show, :rules
        live "/policy/targets", PolicyLive.Show, :targets
        live "/policy/history", PolicyLive.Show, :history
        live "/policy/document", PolicyLive.Show, :document
        live "/policy/versions/:n", PolicyLive.Show, :version
        live "/policy/versions/:n/export", PolicyLive.Show, :export
        live "/policy/targets/:target_id", PolicyLive.Target, :rules
        live "/policy/targets/:target_id/history", PolicyLive.Target, :history
        live "/policy/targets/:target_id/document", PolicyLive.Target, :document
        live "/policy/targets/:target_id/versions/:n", PolicyLive.Target, :version
        live "/policy/targets/:target_id/versions/:n/export", PolicyLive.Target, :export
        live "/keys", AccessKeyLive.Index, :index
        live "/keys/new", AccessKeyLive.Index, :new
        live "/keys/:id/rotate", AccessKeyLive.Index, :rotate
        live "/keys/:id/revoke", AccessKeyLive.Index, :revoke
        live "/settings", SettingsLive, :workspace
      end
    end

    # The organisation alone names no page: it sends on to the user's workspace in it.
    get "/:org", PageController, :organisation
    # The raw bytes of a run's log, for the terminal of the run page. Not a page.
    get "/:org/:workspace/runs/:run_id/log", RunLogController, :show
  end
end
