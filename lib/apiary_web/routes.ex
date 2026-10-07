defmodule ApiaryWeb.Routes do
  @moduledoc """
  The core's routes, as macros a router calls: `ApiaryWeb.Router` calls them and nothing
  else, and an edition's router (`ApiaryWeb.Edition.router/0`) calls them too, with its
  own routes in their blocks and beside them.

      use ApiaryWeb, :router
      import ApiaryWeb.Routes

      pipelines()
      public_routes()
      account_routes()
      visitor_routes()
      instance_routes()
      organisation_routes()

  - `pipelines/0`: `:browser`, `:browser_json` (JSON for a signed-in page), `:api`,
    `:contract` (a signed request of the server contract) and `:path_scope` (the reserved
    names, `ApiaryWeb.ReservedSlugs`), with the plugs of `ApiaryWeb.UserAuth` the routes
    pipe through imported. First, since the others pipe through them.
  - `public_routes/0`: the home page, `/docs`, `/health`, the server contract under
    `/.well-known` and `/v1`, and, where `:dev_routes` is set, `/dev`.
  - `storybook_routes/0`: the component storybook at `/dev/storybook` (`docs/ui.md`,
    Storybook), where `:dev_routes` is set and the storybook's dependency, a development
    one, is there. `ApiaryWeb.Router` calls it; an edition's router does not, since the
    stories are this checkout's.
  - `account_routes/1`: a signed-in person's own pages under `/users` and an invitation's
    continuation, behind sign-in, in the `live_session :require_authenticated_user`.
  - `visitor_routes/1`: registration, log-in and an invitation, for anyone, in the
    `live_session :current_user`, with the session's controller routes.
  - `instance_routes/1`: the Instance level's pages under `/instance`, behind sign-in, in
    the `live_session :instance`; each page checks its own access. Before
    `organisation_routes/1`, whose `/:org` would take `/instance`.
  - `organisation_routes/1`: the organisation's pages under `/:org/…` and a workspace's
    under `/:org/:workspace/…`, in the `live_session :workspace`, with the palette's
    answers (`/:org/jump`, `/:org/:workspace/jump`) and a run's raw log beside them,
    last: `/:org` and `/:org/:workspace` would match every path of one or two segments
    before them. The first segment is never one of `ApiaryWeb.ReservedSlugs.organisation/0`,
    the second of an organisation's never one of `ApiaryWeb.ReservedSlugs.workspace/0`;
    `test/apiary_web/reserved_slugs_test.exs` holds both lists to the router's routes.

  The four route macros that hold a `live_session` take a `do` block, the caller's routes
  in that `live_session`, with its `on_mount` hooks and pipelines: after the core's in
  `:require_authenticated_user`, `:current_user` and `:instance`, and in `:workspace` after the
  organisation's own pages and before `/:org/:workspace`, so that an organisation page of
  the caller's is not taken for a workspace. The block is wrapped in
  `scope "/", alias: false`, so it names its modules in full:

      organisation_routes do
        live "/:org/reports", MyEditionWeb.ReportLive, :index
      end

  They also take `except:`, a literal list of the core's paths, written in full, that the
  caller serves with its own routes instead (every route at such a path is left out): a
  page whose behaviour differs is the caller's page at the core's path. A path that is not
  one of the macro's raises `ArgumentError`.

      visitor_routes except: ["/users/register"] do
        live "/users/register", MyEditionWeb.RegistrationLive, :new
      end
  """

  # Where a macro's block goes among its routes.
  @block :"$apiary_web_routes_block"

  # The router's calls that define a route at their first argument's path.
  @verbs [:live, :get, :post, :put, :patch, :delete, :forward, :live_dashboard]

  @doc """
  pipelines/0 defines the pipelines the core's routes pipe through, and imports the plugs
  of `ApiaryWeb.UserAuth` they name.
  """
  defmacro pipelines do
    quote do
      import ApiaryWeb.UserAuth,
        only: [
          fetch_current_scope_for_user: 2,
          require_authenticated_user: 2,
          require_authenticated_json: 2,
          fetch_path_scope: 2
        ]

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

      # JSON for a signed-in person's page, such as the palette's answers: the browser's
      # session, cookie and words, without its HTML.
      pipeline :browser_json do
        plug :accepts, ["json"]
        plug :fetch_session
        plug :fetch_live_flash
        plug :put_secure_browser_headers
        plug :fetch_current_scope_for_user
        plug ApiaryWeb.Lingo
      end

      # A request of the server contract, signed with an access key.
      pipeline :contract do
        plug :accepts, ["json"]
        plug ApiaryWeb.Contract.SignedRequest
      end

      # First for the organisation's and the workspace's pages: a segment in the place of
      # a slug that can never be one answers as a path the router does not know.
      pipeline :path_scope do
        plug ApiaryWeb.ReservedSlugs
      end
    end
  end

  @doc """
  public_routes/0 defines the routes that answer without sign-in: the home page, the
  documentation, health, the server contract and the development routes.
  """
  defmacro public_routes do
    quote do
      scope "/", ApiaryWeb do
        pipe_through :browser

        get "/", PageController, :home

        # The documentation. The endpoint serves the built files under /docs; these answer
        # /docs itself and what was not found. Public: no authentication.
        get "/docs", DocsController, :index
        get "/docs/*path", DocsController, :missing
      end

      scope "/", ApiaryWeb do
        pipe_through :api

        get "/health", HealthController, :show
      end

      # The server contract: signed requests, discovery, events, run configuration.
      scope "/.well-known", ApiaryWeb.Contract do
        pipe_through :contract

        get "/qory-configuration", ConfigurationController, :show
      end

      scope "/v1", ApiaryWeb.Contract do
        pipe_through :contract

        post "/events", EventsController, :create
        get "/run-configuration", RunConfigurationController, :show
      end

      # LiveDashboard and the Swoosh mailbox preview, in development only.
      if Application.compile_env(:apiary, :dev_routes) do
        import Phoenix.LiveDashboard.Router

        scope "/dev" do
          pipe_through :browser

          live_dashboard "/dashboard", metrics: ApiaryWeb.Telemetry
          forward "/mailbox", Plug.Swoosh.MailboxPreview
        end
      end
    end
  end

  @doc """
  storybook_routes/0 defines the component storybook, `/dev/storybook`, and its assets,
  where `:dev_routes` is set and `phoenix_storybook` is there: a dependency of this
  checkout's in development and test only, so a release, and a project that has the core
  as its dependency, has neither the routes nor any reference to the library.
  """
  defmacro storybook_routes do
    # Decided where the macro expands: in a project without the library, the routes and
    # their import are not there to compile.
    if Code.ensure_loaded?(PhoenixStorybook.Router) do
      quote do
        if Application.compile_env(:apiary, :dev_routes) do
          import PhoenixStorybook.Router

          scope "/" do
            storybook_assets("/dev/storybook/assets")
          end

          scope "/" do
            live_storybook("/dev/storybook",
              backend_module: ApiaryWeb.Storybook,
              assets_path: "/dev/storybook/assets"
            )
          end
        end
      end
    end
  end

  @doc """
  account_routes/1 defines a signed-in person's own pages and an invitation's
  continuation, behind sign-in; the block's routes go into the
  `live_session :require_authenticated_user`, after the core's.
  """
  defmacro account_routes(opts \\ [], block \\ []) do
    routes =
      quote do
        scope "/", ApiaryWeb do
          pipe_through [:browser, :require_authenticated_user]

          get "/invitations/:token/continue", InvitationController, :continue
        end

        scope "/", ApiaryWeb do
          pipe_through [:browser, :require_authenticated_user]

          live_session :require_authenticated_user,
            on_mount: [
              {ApiaryWeb.UserAuth, :require_authenticated},
              {ApiaryWeb.UserAuth, :load_organisation}
            ] do
            # A person's settings, one section a page: Profile (email, password, deleting the
            # account) and Preferences.
            live "/users/settings", UserLive.Settings, :edit
            live "/users/settings/preferences", UserLive.Settings, :preferences
            # The confirmation of deleting one's own account, in place in Profile's danger zone.
            live "/users/settings/delete", UserLive.Settings, :delete
            live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
            # A user's organisations: each in use, and those marked for deletion that they
            # own, whose deletion they can cancel there; the page of a user who has none.
            live "/users/organisations", UserLive.Organisations, :index
            unquote(@block)
          end

          post "/users/update-password", UserSessionController, :update_password
        end
      end

    compose(routes, opts, block)
  end

  @doc """
  visitor_routes/1 defines registration, log-in and an invitation's page, for anyone,
  and the session's controller routes; the block's routes go into the
  `live_session :current_user`, after the core's.
  """
  defmacro visitor_routes(opts \\ [], block \\ []) do
    routes =
      quote do
        scope "/", ApiaryWeb do
          pipe_through [:browser]

          live_session :current_user,
            on_mount: [{ApiaryWeb.UserAuth, :mount_current_scope}] do
            live "/users/register", UserLive.Registration, :new
            live "/users/log-in", UserLive.Login, :new
            live "/users/log-in/:token", UserLive.Confirmation, :new
            live "/invitations/:token", InvitationLive.Accept, :show
            unquote(@block)
          end

          post "/users/log-in", UserSessionController, :create
          delete "/users/log-out", UserSessionController, :delete
          # After an account is deleted: ends the page's own session, signed out already.
          get "/users/account-deleted", UserSessionController, :account_deleted
        end
      end

    compose(routes, opts, block)
  end

  @doc """
  instance_routes/1 defines the Instance level's pages, under `/instance`: what the
  installation as a whole holds, for the instance's admins (`Apiary.Access.instance_admin?/1`)
  and whoever else the edition lets in. There is no organisation in the path; the scope
  carries the workspace the person opened last, as on their own pages, so the sidebar
  stays the one they came from and the Instance's sections open beside it
  (`ApiaryWeb.Layouts`, `place: :instance`). Every page checks its own access. The
  block's routes go into the `live_session :instance`, after the core's. The core's one
  page here is Instance › Configuration (`ApiaryWeb.InstanceLive.Configuration`), for the
  instance's admins; `/instance` itself sends on to the first section the person may
  open, and is not found for whoever may open none (`ApiaryWeb.InstanceController`).
  """
  defmacro instance_routes(opts \\ [], block \\ []) do
    routes =
      quote do
        scope "/", ApiaryWeb do
          pipe_through [:browser, :require_authenticated_user]

          # The level itself: sent on to the first of its sections the person may open.
          get "/instance", InstanceController, :show

          live_session :instance,
            on_mount: [
              {ApiaryWeb.UserAuth, :require_authenticated},
              {ApiaryWeb.UserAuth, :load_organisation}
            ] do
            # Instance › Configuration: what whoever runs the server set, read only.
            live "/instance/configuration", InstanceLive.Configuration, :show
            unquote(@block)
          end
        end
      end

    compose(routes, opts, block)
  end

  @doc """
  organisation_routes/1 defines the organisation's pages and its workspaces', and the
  raw log of a run; the block's routes go into the `live_session :workspace`, after the
  organisation's own pages and before the workspace's.
  """
  defmacro organisation_routes(opts \\ [], block \\ []) do
    routes =
      quote do
        # What the palette of the top bar (Search or jump to) finds: JSON, not a page.
        # Before the pages, whose `/:org/:workspace` would take `/:org/jump`.
        scope "/", ApiaryWeb do
          pipe_through [
            :path_scope,
            :browser_json,
            :require_authenticated_json,
            :fetch_path_scope
          ]

          get "/:org/jump", JumpController, :show
          get "/:org/:workspace/jump", JumpController, :show
        end

        # The switcher's link to a workspace at the section the reader is on, sent on to
        # that section there, or to the workspace's overview where it has no such page:
        # whether it has one is the destination's own answer, read when it is followed.
        scope "/", ApiaryWeb do
          pipe_through [:path_scope, :browser, :require_authenticated_user, :fetch_path_scope]

          get "/:org/:workspace/switch/:section", SwitchController, :show
        end

        # The paths of pages that moved, under the settings, out of them or to a new name,
        # sent on to where they are now, so a link someone kept still lands. Before the
        # pages, whose `/:org/:workspace` would take `/:org/members`. A target's Connections tab moved
        # too; its page's glob sends that one on (`TargetLive.Show`).
        scope "/", ApiaryWeb do
          pipe_through [:path_scope, :browser]

          get "/:org/activity", MovedController, :show
          get "/:org/settings/audit-log", MovedController, :show
          get "/:org/members", MovedController, :show
          get "/:org/members/*rest", MovedController, :show
          get "/:org/:workspace/keys", MovedController, :show
          get "/:org/:workspace/keys/*rest", MovedController, :show
          get "/:org/:workspace/settings/retention", MovedController, :show
          get "/:org/:workspace/connections", MovedController, :show
          get "/:org/:workspace/runs/:run_id/connections", MovedController, :show
        end

        scope "/", ApiaryWeb do
          pipe_through [:path_scope, :browser, :require_authenticated_user, :fetch_path_scope]

          live_session :workspace,
            on_mount: [
              {ApiaryWeb.UserAuth, :require_authenticated},
              {ApiaryWeb.UserAuth, :load_path_scope}
            ] do
            # The organisation's own pages. The workspace in the scope is the one the user
            # opened last, while they reach it, else the first they reach; none for a
            # member who reaches no workspace yet.
            scope "/:org" do
              # The organisation's overview: its workspaces and its people.
              live "/", OrganisationLive, :index
              # The organisation's audit trail, a page of its sidebar beside the overview,
              # for the readers `audit.read` allows. It was a section of the settings,
              # `/settings/audit-log`, which sends on here (`ApiaryWeb.MovedController`).
              live "/audit-log", ActivityLive, :index
              # Its settings, one section a page, the list of them beside it
              # (`ApiaryWeb.SettingsComponents`). General is the settings' own path.
              live "/settings", SettingsLive, :organisation
              live "/settings/people", MemberLive.Index, :index
              live "/settings/people/invite", MemberLive.Index, :invite
              live "/settings/people/:id/remove", MemberLive.Index, :remove
              # Removing and suspending a membership confirm on the member's row.
              live "/settings/people/:id/suspend", MemberLive.Index, :suspend
              live "/settings/workspaces", SettingsLive, :workspaces
              # The confirmation of deleting a workspace, on its row of the workspaces.
              live "/settings/workspaces/:workspace_id/delete", SettingsLive, :delete_workspace
              # The confirmation of deleting the organisation, in place in General's danger
              # zone, which opens it; the second path opens the same.
              live "/settings/danger", SettingsLive, :danger
              live "/settings/delete", SettingsLive, :delete_organisation
            end

            unquote(@block)

            scope "/:org/:workspace" do
              live "/", WorkspaceLive.Overview, :index
              # The record: the runs of the workspace, and where they reached out to (Network
              # access). Every filter is a query parameter.
              live "/runs", RunLive.Index, :index
              live "/network", ConnectionLive.Index, :index
              # The targets the workspace's runs changed, and one target's page: its path
              # is the glob, its tabs follow a `-` segment (`…/-/runs`), and a tab's own
              # paths follow the tab (`…/-/policy/history`).
              live "/targets", TargetLive.Index, :index
              live "/targets/:system/*path", TargetLive.Show, :show
              # The workspace's nodes and node pools, the places its runs run: the list,
              # with New node and New node pool as dialogs over it, and a node's page,
              # Overview and Settings, its deletion a dialog over Settings, and clearing an
              # instance a dialog over Overview. `:node_id` is the node's public id; an
              # instance is named by its instance id. The sidebar's Nodes leads here.
              live "/nodes", NodeLive.Index, :index
              live "/nodes/new", NodeLive.Index, :new
              live "/nodes/new-pool", NodeLive.Index, :new_pool
              live "/nodes/:node_id", NodeLive.Show, :overview
              live "/nodes/:node_id/instances/:instance/clear", NodeLive.Show, :clear_instance
              live "/nodes/:node_id/settings", NodeLive.Show, :settings
              live "/nodes/:node_id/settings/delete", NodeLive.Show, :delete
              # One run: four tabs of one LiveView, so a tab is a patch. `:run_id` is the
              # run's subject, the id the runner prints, not the row's id.
              live "/runs/:run_id", RunLive.Show, :timeline
              live "/runs/:run_id/terminal", RunLive.Show, :terminal
              live "/runs/:run_id/network", RunLive.Show, :connections
              live "/runs/:run_id/details", RunLive.Show, :details
              # The security policy: the workspace's baseline; a target's view of it is
              # the Policy tab of the target's page. Tabs, filters, the opened change, the
              # compared version and the export page are in the URL.
              live "/policy", PolicyLive.Show, :rules
              live "/policy/targets", PolicyLive.Show, :targets
              live "/policy/history", PolicyLive.Show, :history
              live "/policy/document", PolicyLive.Show, :document
              live "/policy/versions/:n", PolicyLive.Show, :version
              live "/policy/versions/:n/export", PolicyLive.Show, :export
              # Its settings, one section a page, as the organisation's.
              live "/settings", SettingsLive, :workspace
              # Who reaches the workspace, read only: membership is the organisation's.
              live "/settings/people", MemberLive.Workspace, :index
              live "/settings/runs", SettingsLive, :runs
              live "/settings/keys", AccessKeyLive.Index, :index
              live "/settings/keys/new", AccessKeyLive.Index, :new
              live "/settings/keys/:id/rotate", AccessKeyLive.Index, :rotate
              live "/settings/keys/:id/revoke", AccessKeyLive.Index, :revoke
              # The stored secrets and the variables, one section of two views, with the
              # `security` feature; each form a page and each confirmation on its row, at
              # a path of its own. A secret is named by its public id (`sec_…`), a value by
              # its value id; the one value without a value id is the secret's
              # `change-value`.
              live "/settings/secrets", SecretLive.Index, :secrets
              live "/settings/secrets/new", SecretLive.Index, :new_secret
              live "/settings/secrets/:id/edit", SecretLive.Index, :edit_secret
              live "/settings/secrets/:id/add-value", SecretLive.Index, :add_value
              live "/settings/secrets/:id/change-value", SecretLive.Index, :change_value

              live "/settings/secrets/:id/values/:value_id/change",
                   SecretLive.Index,
                   :change_value

              live "/settings/secrets/:id/values/:value_id/rename",
                   SecretLive.Index,
                   :rename_value

              live "/settings/secrets/:id/values/:value_id/delete",
                   SecretLive.Index,
                   :delete_value

              live "/settings/secrets/:id/delete", SecretLive.Index, :delete_secret
              live "/settings/variables", SecretLive.Index, :variables
              live "/settings/variables/new", SecretLive.Index, :new_variable
              live "/settings/variables/:id/change", SecretLive.Index, :change_variable
              live "/settings/variables/:id/lock", SecretLive.Index, :lock_variable
              live "/settings/variables/:id/unlock", SecretLive.Index, :unlock_variable
              live "/settings/variables/:id/delete", SecretLive.Index, :delete_variable
              live "/settings/variables/:id/targets", SecretLive.Index, :variable_targets
              # The runtimes, integrations and services set up in the workspace, and its
              # own service definitions, with the `security` feature: the list and its
              # forms; a release asked for, by its id, before it is added; a service
              # definition by its public id (`svc_…`); and one runtime, integration or
              # service by its public id (`con_…`), its tabs and acts after it. The fixed
              # paths go first, so that `:id` never takes them.
              live "/settings/integrations", IntegrationLive.Index, :index
              live "/settings/integrations/add", IntegrationLive.Index, :add_integration
              live "/settings/integrations/new-runtime", IntegrationLive.Index, :new_runtime
              live "/settings/integrations/new-service", IntegrationLive.Index, :new_service

              live "/settings/integrations/releases/:release_id",
                   IntegrationLive.Release,
                   :show

              live "/settings/integrations/definitions/new", IntegrationLive.Definition, :new
              live "/settings/integrations/definitions/:id", IntegrationLive.Definition, :show

              live "/settings/integrations/definitions/:id/edit",
                   IntegrationLive.Definition,
                   :edit

              live "/settings/integrations/definitions/:id/delete",
                   IntegrationLive.Definition,
                   :delete

              live "/settings/integrations/:id", IntegrationLive.Show, :overview
              live "/settings/integrations/:id/targets", IntegrationLive.Show, :targets
              live "/settings/integrations/:id/targets/add", IntegrationLive.Show, :add_target

              live "/settings/integrations/:id/targets/:target_id/remove",
                   IntegrationLive.Show,
                   :remove_target

              live "/settings/integrations/:id/settings", IntegrationLive.Show, :settings
              live "/settings/integrations/:id/version", IntegrationLive.Show, :version
              live "/settings/integrations/:id/delete", IntegrationLive.Show, :delete
              # The confirmation of deleting this workspace, in place in General's danger
              # zone, which opens it; the second path opens the same.
              live "/settings/danger", SettingsLive, :workspace_danger
              live "/settings/delete", SettingsLive, :delete_this_workspace
            end
          end

          # The raw bytes of a run's log, for the terminal of the run page. Not a page.
          get "/:org/:workspace/runs/:run_id/log", RunLogController, :show

          # A target's policy had a page of its own, by the target row's id; it is the
          # Policy tab of the target's page now, where these send on to.
          get "/:org/:workspace/policy/targets/:target_id", TargetMovedController, :show
          get "/:org/:workspace/policy/targets/:target_id/*rest", TargetMovedController, :show
        end
      end

    compose(routes, opts, block)
  end

  # The core's routes without those `except:` names, and the caller's block where the
  # core's routes mark its place. A `do` block comes apart from the options:
  # `account_routes(except: [...]) do ... end` is
  # `account_routes([except: [...]], [do: ...])`.
  defp compose(routes, opts, block) do
    opts = Keyword.validate!(opts ++ block, [:except, :do])
    except = Keyword.get(opts, :except, [])

    case except -- paths(routes, "/") do
      [] -> :ok
      unknown -> raise ArgumentError, "except: names no route of these: #{inspect(unknown)}"
    end

    routes
    |> keep("/", except)
    |> Macro.prewalk(fn
      @block -> inject(opts[:do])
      node -> node
    end)
  end

  defp inject(nil), do: nil

  defp inject(block) do
    quote do
      scope "/", alias: false do
        unquote(block)
      end
    end
  end

  # The routes as the router defines them, left out when their full path is in `except`:
  # walked through the blocks, scopes (whose paths prefix theirs), live sessions and
  # conditions they sit in.
  defp keep({:__block__, meta, exprs}, prefix, except),
    do: {:__block__, meta, for(expr <- exprs, kept = keep(expr, prefix, except), do: kept)}

  defp keep({:scope, meta, [path | args]}, prefix, except) when is_binary(path),
    do: {:scope, meta, [path | keep_in_do(args, join(prefix, path), except)]}

  defp keep({call, meta, args}, prefix, except)
       when call in [:live_session, :if] and is_list(args),
       do: {call, meta, keep_in_do(args, prefix, except)}

  defp keep({verb, _meta, [path | _]} = route, prefix, except)
       when verb in @verbs and is_binary(path),
       do: if(join(prefix, path) in except, do: nil, else: route)

  defp keep(expr, _prefix, _except), do: expr

  defp keep_in_do(args, prefix, except) do
    Enum.map(args, fn
      [do: body] -> [do: keep(body, prefix, except)]
      arg -> arg
    end)
  end

  # Every full path the routes define.
  defp paths({:__block__, _meta, exprs}, prefix), do: Enum.flat_map(exprs, &paths(&1, prefix))

  defp paths({:scope, _meta, [path | args]}, prefix) when is_binary(path),
    do: paths_in_do(args, join(prefix, path))

  defp paths({call, _meta, args}, prefix) when call in [:live_session, :if] and is_list(args),
    do: paths_in_do(args, prefix)

  defp paths({verb, _meta, [path | _]}, prefix) when verb in @verbs and is_binary(path),
    do: [join(prefix, path)]

  defp paths(_expr, _prefix), do: []

  defp paths_in_do(args, prefix),
    do: for([do: body] <- args, path <- paths(body, prefix), do: path)

  defp join(prefix, path),
    do: "/" <> (String.split(prefix <> "/" <> path, "/", trim: true) |> Enum.join("/"))
end
