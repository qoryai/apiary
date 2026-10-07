defmodule ApiaryWeb.RoutesFeaturesCase do
  @moduledoc """
  The routes held to the instance's features: every route of a router declares its
  feature with `use ApiaryWeb.Features`, or is one every instance has, whatever its
  features; a new route that does neither fails here, so nothing reaches an instance
  without a feature deciding it.

  The routes every instance has are the core's (`always/0`: signing in and out, the
  organisation's own management and its audit trail, the instance's configuration, the
  documentation, health and discovery) and those an edition names for its own pages. A test module uses it with a
  router, the core's or an edition's, and the edition's modules beside the core's:

      use ApiaryWeb.RoutesFeaturesCase, async: true, router: ApiaryWeb.Router

      use ApiaryWeb.RoutesFeaturesCase,
        async: true,
        router: MyEditionWeb.Router,
        always: [MyEditionWeb.SomeLive]

  and gets the tests: every route of the router is decided, no module listed as one every
  instance has declares a feature, and the security policy's pages and endpoint belong to
  `security`. `routes/1` is the router's routes, for a test of the edition's own features.
  """

  use ExUnit.CaseTemplate

  # The modules of the core's routes every instance has, whatever its features.
  @always [
    ApiaryWeb.PageController,
    ApiaryWeb.DocsController,
    ApiaryWeb.HealthController,
    ApiaryWeb.Contract.ConfigurationController,
    ApiaryWeb.Contract.EnrolmentController,
    ApiaryWeb.AccessKeyLive.Index,
    ApiaryWeb.NodeLive.Index,
    ApiaryWeb.NodeLive.Show,
    ApiaryWeb.NodeLive.AccessKey,
    ApiaryWeb.MemberLive.Index,
    ApiaryWeb.MemberLive.Workspace,
    ApiaryWeb.SettingsLive,
    ApiaryWeb.ActivityLive,
    ApiaryWeb.UserLive.Organisations,
    ApiaryWeb.OrganisationLive,
    ApiaryWeb.MovedController,
    ApiaryWeb.InvitationController,
    ApiaryWeb.UserSessionController,
    ApiaryWeb.UserLive.Settings,
    ApiaryWeb.UserLive.Registration,
    ApiaryWeb.UserLive.Login,
    ApiaryWeb.UserLive.Confirmation,
    ApiaryWeb.InvitationLive.Accept,
    ApiaryWeb.InstanceLive.Configuration,
    ApiaryWeb.InstanceController
  ]

  # Development only (`:dev_routes`), never in a release.
  @dev ["/dev/"]

  using opts do
    router = Keyword.fetch!(opts, :router)
    always = Keyword.get(opts, :always, [])

    quote do
      @router unquote(router)
      @always ApiaryWeb.RoutesFeaturesCase.always() ++ unquote(always)

      test "every route declares its feature, or is one every instance has" do
        undecided =
          for {verb, path, module} <- ApiaryWeb.RoutesFeaturesCase.routes(@router),
              module not in @always,
              not function_exported?(Code.ensure_loaded!(module), :__feature__, 0),
              do: "#{verb} #{path} (#{inspect(module)})"

        assert undecided == [],
               "routes with no feature; add `use ApiaryWeb.Features, <feature>` or list them " <>
                 "as ones every instance has:\n" <> Enum.join(undecided, "\n")
      end

      test "a module every instance has declares no feature, so the lists stay true" do
        for module <- @always do
          refute function_exported?(Code.ensure_loaded!(module), :__feature__, 0),
                 "#{inspect(module)} declares a feature and is listed as one every instance has"
        end
      end

      test "the security policy's pages and endpoint belong to security" do
        policy =
          for {_verb, "/:org/:workspace/policy" <> _, module} <-
                ApiaryWeb.RoutesFeaturesCase.routes(@router),
              do: module

        assert policy != []

        for module <- policy do
          assert module.__feature__() == :security, inspect(module)
        end

        assert ApiaryWeb.Contract.RunConfigurationController.__feature__() == :security
      end
    end
  end

  @doc "always/0 is the modules of the core's routes every instance has."
  @spec always() :: [module]
  def always, do: @always

  @doc """
  routes/1 is the routes of `router` but the development ones, each
  `{verb, path, module}`: the module is the LiveView or the controller that answers it.
  """
  @spec routes(module) :: [{atom, String.t(), module}]
  def routes(router) do
    for route <- router.__routes__(), not String.starts_with?(route.path, @dev) do
      module =
        case route do
          %{metadata: %{phoenix_live_view: {live_view, _action, _opts, _extra}}} -> live_view
          %{plug: plug} -> plug
        end

      {route.verb, route.path, module}
    end
  end
end
