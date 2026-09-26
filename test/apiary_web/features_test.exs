defmodule ApiaryWeb.FeaturesRoutesTest do
  use ExUnit.Case, async: true

  # The routes every instance has, whatever its features: signing in and out, the
  # organisation's own management, the documentation, health and discovery. Every other
  # route declares its feature with `use ApiaryWeb.Features`; a new route that does
  # neither fails here, so nothing reaches an instance without a feature deciding it.
  @core [
    ApiaryWeb.PageController,
    ApiaryWeb.DocsController,
    ApiaryWeb.HealthController,
    ApiaryWeb.Contract.ConfigurationController,
    ApiaryWeb.AccessKeyLive.Index,
    ApiaryWeb.MemberLive.Index,
    ApiaryWeb.SettingsLive,
    ApiaryWeb.HiveLive.NoHive,
    ApiaryWeb.OrganisationSessionController,
    ApiaryWeb.UserSessionController,
    ApiaryWeb.UserLive.Settings,
    ApiaryWeb.UserLive.Registration,
    ApiaryWeb.UserLive.Login,
    ApiaryWeb.UserLive.Confirmation,
    ApiaryWeb.InvitationLive.Accept
  ]

  # Development only (`:dev_routes`), never in a release.
  @dev ["/dev/"]

  defp routes do
    for route <- ApiaryWeb.Router.__routes__(),
        not String.starts_with?(route.path, @dev) do
      module =
        case route do
          %{metadata: %{phoenix_live_view: {live_view, _action, _opts, _extra}}} -> live_view
          %{plug: plug} -> plug
        end

      {route.verb, route.path, module}
    end
  end

  test "every route declares its feature, or is one every instance has" do
    undecided =
      for {verb, path, module} <- routes(),
          module not in @core,
          not function_exported?(Code.ensure_loaded!(module), :__feature__, 0),
          do: "#{verb} #{path} (#{inspect(module)})"

    assert undecided == [],
           "routes with no feature; add `use ApiaryWeb.Features, <feature>` or list them as core:\n" <>
             Enum.join(undecided, "\n")
  end

  test "a core module declares no feature, so the list above stays true" do
    for module <- @core do
      refute function_exported?(Code.ensure_loaded!(module), :__feature__, 0),
             "#{inspect(module)} declares a feature and is listed as core"
    end
  end

  test "the security policy's pages and endpoint belong to security" do
    for {_verb, "/hive/policy" <> _, module} <- routes() do
      assert module.__feature__() == :security
    end

    assert ApiaryWeb.Contract.RunConfigurationController.__feature__() == :security
  end
end

defmodule ApiaryWeb.FeaturesTest do
  # Not async: the tests switch the instance's features, which are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Phoenix.LiveViewTest

  alias Apiary.Policy
  alias ApiaryWeb.Contract.Configuration

  @policy_paths [
    "/hive/policy",
    "/hive/policy/targets",
    "/hive/policy/history",
    "/hive/policy/document",
    "/hive/policy/versions/1",
    "/hive/policy/versions/1/export",
    "/hive/policy/targets/00000000-0000-0000-0000-000000000000",
    "/hive/policy/targets/00000000-0000-0000-0000-000000000000/history"
  ]

  setup :register_and_log_in_user

  # What a request is answered: the status, the body and the headers, all but the request's
  # own id. An error the endpoint renders and raises again is taken as it was sent.
  defp answer(request) do
    conn = request.()
    {conn.status, conn.resp_body, headers(conn.resp_headers)}
  rescue
    _error ->
      {status, headers, body} = assert_error_sent(:not_found, request)
      {status, body, headers(headers)}
  end

  defp headers(headers),
    do: headers |> Enum.reject(fn {name, _} -> name == "x-request-id" end) |> Enum.sort()

  # The hive's policy made while the instance still had `security`, as on an instance
  # launched with it and restarted without: its rows stay, and nothing of it may show.
  defp managed_before_security_went(scope) do
    features = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, Apiary.Features.all())
    {:ok, _rule} = Policy.deny(scope, nil, %{host: "ads.example"})
    Application.put_env(:apiary, :features, features)
    assert Policy.managed?(scope)
  end

  describe "without security" do
    @describetag with_features: [:observability]

    test "the policy's pages answer as a path that does not exist, to anyone", %{conn: conn} do
      askers = [
        {"signed in", conn},
        {"anonymous", build_conn()},
        {"anonymous, asking for JSON", put_req_header(build_conn(), "accept", "application/json")}
      ]

      for {who, asker} <- askers, path <- @policy_paths do
        assert answer(fn -> get(asker, path) end) ==
                 answer(fn -> get(asker, "/hive/no-such-page") end),
               "#{path}, #{who}"
      end
    end

    test "the run configuration endpoint answers as one that does not exist", ctx do
      %{access_key: key, secret: secret} = access_key_fixture(ctx.scope)

      askers = [
        {"signed", &signed_get(build_conn(), key.key_id, secret, &1)},
        {"signed, asking for JSON",
         &signed_get(build_conn(), key.key_id, secret, &1,
           headers: [{"accept", "application/json"}]
         )},
        {"unsigned", &get(build_conn(), &1)}
      ]

      for {who, ask} <- askers do
        assert answer(fn -> ask.("/v1/run-configuration") end) ==
                 answer(fn -> ask.("/v1/no-such-endpoint") end),
               who
      end
    end

    test "a live navigation to the policy is refused the same way", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hive/runs")

      # The page is not mounted: the browser is told to load it, and gets the 404 above.

      assert {%{status: 404, reason: "reload"}, _call} =
               catch_exit(live_redirect(view, to: ~p"/hive/policy"))
    end

    test "the contract names no run section and serves no run configuration", ctx do
      managed_before_security_went(ctx.scope)
      %{access_key: key, secret: secret} = access_key_fixture(ctx.scope)

      conn = signed_get(build_conn(), key.key_id, secret, "/.well-known/qory-configuration")
      assert conn.status == 200
      refute Map.has_key?(Jason.decode!(conn.resp_body), "run")
      assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(false)]

      {_subject, events} = first_events()
      conn = signed_post(build_conn(), key.key_id, secret, events)
      assert conn.status in 200..299
      assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(false)]
    end

    test "the context writes no policy, whichever surface asks", %{scope: scope} do
      for write <- [
            fn -> Policy.allow(scope, nil, %{host: "api.example"}) end,
            fn -> Policy.deny(scope, nil, %{host: "ads.example"}) end,
            fn -> Policy.set_mode(scope, "enforce") end
          ] do
        assert {:error, %Policy.Error{reason: :not_found}} = write.()
      end

      refute Policy.managed?(scope)
    end
  end

  describe "with every feature" do
    @describetag with_features: Apiary.Features.all()

    test "the policy's pages are there", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, ~p"/hive/policy")
    end

    test "the contract names the run section of a managed hive", ctx do
      {:ok, _rule} = Policy.deny(ctx.scope, nil, %{host: "ads.example"})
      %{access_key: key, secret: secret} = access_key_fixture(ctx.scope)

      conn = signed_get(build_conn(), key.key_id, secret, "/.well-known/qory-configuration")
      assert Map.has_key?(Jason.decode!(conn.resp_body), "run")
      assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(true)]
    end
  end
end
