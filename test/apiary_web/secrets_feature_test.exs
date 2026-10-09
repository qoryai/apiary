defmodule ApiaryWeb.SecretsFeatureTest do
  @moduledoc """
  The `secrets` feature, opt-in (`Apiary.Features.opt_in/0`): the workspace's stored
  secrets, variables and integrations. Off, it is absent: its pages answer as paths that
  do not exist, and the settings' list, New, the palette, the instance's Configuration, a
  key's card, the integrations' fetch and the guides at `/docs` leave it out. On, each of
  them has it.
  """
  # Not async: the tests switch the instance's features, which are the whole node's.
  use ApiaryWeb.ConnCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.AccessKeysFixtures

  alias Apiary.Integrations
  alias Apiary.Integrations.{FetchJob, Release}
  alias Mix.Tasks.Docs.All, as: DocsAll

  @off [:observability, :security]
  @on [:observability, :security, :secrets]

  # The routes whose page or endpoint belongs to `secrets`, each `{verb, path}`.
  defp secrets_routes do
    for {verb, path, module} <- ApiaryWeb.RoutesFeaturesCase.routes(ApiaryWeb.Router),
        function_exported?(Code.ensure_loaded!(module), :__feature__, 0),
        module.__feature__() == :secrets,
        do: {verb, path}
  end

  # A route's path with the scope's organisation and workspace, and a value of its own for
  # every other segment it takes.
  defp concrete(path, scope) do
    path
    |> String.replace(":org", scope.organisation.slug)
    |> String.replace(":workspace", scope.workspace.slug)
    |> String.replace(~r/:[a-z_]+/, "00000000-0000-0000-0000-000000000000")
  end

  # What a request is answered: the status and the body, without the request's nonce. An
  # error the endpoint renders and raises again is taken as it was sent.
  defp answer(request) do
    conn = request.()
    {conn.status, without_nonce(conn.resp_body)}
  rescue
    _error ->
      {status, _headers, body} = assert_error_sent(:not_found, request)
      {status, without_nonce(body)}
  end

  defp without_nonce(text),
    do: String.replace(text, ~r/nonce(-|=")[A-Za-z0-9+\/=]+/, "nonce\\1…")

  defp jump(conn, scope, q \\ "") do
    conn
    |> put_req_header("accept", "application/json")
    |> get(workspace_path(scope, "/jump"), %{"q" => q})
    |> json_response(200)
  end

  defp labels(answer, group) do
    case Enum.find(answer["groups"], &(&1["label"] == group)) do
      nil -> []
      found -> Enum.map(found["items"], & &1["label"])
    end
  end

  # The Audit log's Action filter's options, as their values.
  defp audit_actions(conn, scope) do
    {:ok, view, _html} = live(conn, "/#{scope.organisation.slug}/audit-log")
    render_async(view)

    html =
      view
      |> render()
      |> LazyHTML.from_fragment()

    actions =
      html
      |> LazyHTML.query("#filter-action-form li input")
      |> LazyHTML.attribute("value")

    {actions, view}
  end

  @secrets_actions ~w(secret.write variable.edit connection.write)

  # The text of `guide` as the tree with `features` has it.
  defp guide(guide, features) do
    path = Path.join("guides", guide)
    path |> File.read!() |> DocsAll.split!(path) |> DocsAll.join(features)
  end

  @gated_passages [
    {"quickstart.md", "Secrets and variables are under"},
    {"hosting-checklist.md", "Where integrations come from"},
    {"install.md", "### Integrations"},
    {"install.md", "INTEGRATION_URL_SOURCES"},
    {"backup.md", "loses every stored secret value"},
    {"nodes.md", "Stored secrets"}
  ]

  describe "off, as QORY_FEATURES unset, all or all-… leaves it" do
    @describetag with_features: @off
    @describetag needs: :security

    setup :register_and_log_in_user

    test "is off", %{scope: scope} do
      refute Apiary.Features.on?(:secrets)
      refute Apiary.Features.on?(scope, :secrets)
      assert Apiary.Features.on?(scope, :security)
    end

    test "every route of it answers as a path that does not exist, to anyone",
         %{conn: conn, scope: scope} do
      routes = secrets_routes()
      assert {:get, "/:org/:workspace/settings/secrets"} in routes
      assert {:get, "/:org/:workspace/settings/variables"} in routes
      assert {:get, "/:org/:workspace/settings/integrations"} in routes

      unknown = workspace_path(scope, "/settings/no-such-page")

      for {who, asker} <- [{"signed in", conn}, {"anonymous", build_conn()}],
          {:get, path} <- routes do
        path = concrete(path, scope)

        assert answer(fn -> get(asker, path) end) == answer(fn -> get(asker, unknown) end),
               "#{path}, #{who}"
      end
    end

    test "the workspace's settings list neither Integrations nor Secrets and variables",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, workspace_path(scope, "/settings"))

      assert has_element?(view, "#settings-tab-general")
      refute has_element?(view, "#settings-tab-integrations")
      refute has_element?(view, "#settings-tab-secrets")
      refute render(view) =~ "Secrets and variables"
    end

    test "New offers no integration, secret or variable", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, workspace_path(scope))

      assert has_element?(view, "#new-menu-node")
      refute has_element?(view, "#new-menu-integration")
      refute has_element?(view, "#new-menu-secret")
      refute has_element?(view, "#new-menu-variable")
    end

    test "the palette finds none of it", %{conn: conn, scope: scope} do
      answer = jump(conn, scope)

      assert labels(answer, "Actions") == ["New node", "New node pool", "Invite people"]
      refute "Workspace settings › Integrations" in labels(answer, "Go to")
      refute "Workspace settings › Secrets and variables" in labels(answer, "Go to")

      for q <- ["secret", "variable", "integration", "token"] do
        assert labels(jump(conn, scope, q), "Go to") == [], q
        assert labels(jump(conn, scope, q), "Actions") == [], q
      end
    end

    test "the Audit log's Action filter offers none of its actions, and its entries still show",
         %{conn: conn, scope: scope} do
      {:ok, _secret} = Apiary.Secrets.create_secret(scope, %{name: "FORGE_TOKEN", value: "x"})

      {actions, view} = audit_actions(conn, scope)

      assert "workspace.rename" in actions
      for action <- @secrets_actions, do: refute(action in actions, action)

      # The entry made while its rows are there keeps its words.
      assert render(view) =~ "Created a stored secret"
      assert render(view) =~ "FORGE_TOKEN"

      # Asked for by its address, the filter takes it for none.
      {:ok, view, _html} =
        live(conn, "/#{scope.organisation.slug}/audit-log?action=secret.write")

      render_async(view)
      refute has_element?(view, "#filter-action-button", "Stored secret changed")
    end

    test "a key's card has no Stored secrets row", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      %{access_key: key} = node_key_fixture(scope, node)

      {:ok, view, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}/access-key")

      assert has_element?(view, "#key-#{key.key_id}-fingerprint")
      refute has_element?(view, "#key-#{key.key_id}-stored-secrets")
      refute render(view) =~ "Stored secrets"
    end

    # The cancelled job says so in the log.
    @tag :capture_log
    test "a release's fetch does nothing and is not retried", %{scope: scope} do
      {:ok, release} =
        Integrations.request_release(scope, %{
          source: "github.com/acme/tracker-integration",
          version: "0.3.0"
        })

      args = FetchJob.for_scope(scope, %{"release_id" => release.id}).changes.args
      assert {:cancel, :not_found} = perform_job(FetchJob, args)

      assert {:ok, %Release{state: "pending"}} = Integrations.get_release(scope, release.id)
    end
  end

  describe "off, the instance's Configuration" do
    @describetag with_features: @off
    @describetag needs: :security

    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "lists the feature not, and has no Integrations part", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      assert has_element?(view, "#config-feature-security")
      refute has_element?(view, "#config-feature-secrets")
      refute has_element?(view, "#config-integrations")
      refute has_element?(view, "#config-url-sources")
      refute render(view) =~ "secrets"
    end
  end

  describe "off, the guides at /docs" do
    test "an instance launched with QORY_FEATURES unset or all is served a tree without it" do
      for value <- [nil, "all"] do
        {:ok, features} = Apiary.Features.parse(value)
        refute ApiaryWeb.DocsController.tree_name(features) == "all"
        refute "secrets" in String.split(ApiaryWeb.DocsController.tree_name(features), "+")
      end
    end

    # The documentation's configuration, as `mix docs.all` reads it: the release notes
    # need no feature, the module reference every feature, and a default instance is
    # served a tree without `secrets`.
    test "a default instance's /docs has the release notes and no module reference" do
      docs = Mix.Project.config()[:docs]
      docs = if is_function(docs, 0), do: docs.(), else: docs
      owned = Keyword.fetch!(docs, :features)

      assert "CHANGELOG.md" in Enum.map(docs[:extras], &to_string/1)

      for {_feature, owns} <- owned do
        refute "CHANGELOG.md" in Enum.map(Keyword.get(owns, :extras, []), &to_string/1)
      end

      assert [_ | _] = owned |> Keyword.fetch!(:all) |> Keyword.fetch!(:modules)

      {:ok, default} = Apiary.Features.parse(nil)
      refute Apiary.Features.all() -- default == []
    end

    test "leave out each passage of it" do
      for {file, words} <- @gated_passages do
        refute guide(file, @off) =~ words, "#{file}: #{words}"
        refute guide(file, [:observability]) =~ words, "#{file}: #{words}"
      end
    end

    # The documentation an instance without the feature is served, and the README and
    # EDITIONS.md beside it, with the markers resolved as `mix docs.all` resolves them.
    test "say nothing that gives it away, in any guide, the release notes or the READMEs" do
      giveaways =
        ~r/stored.secret|stored value|allow_secrets|secret_values|workspace_data_keys|INTEGRATION_URL_SOURCES|Apiary\.Secrets|Apiary\.Connections|Secrets and variables/i

      files = Path.wildcard("guides/*.md") ++ ["CHANGELOG.md", "README.md", "EDITIONS.md"]

      caught =
        for path <- files,
            features <- [@off, [:observability]],
            text = path |> File.read!() |> DocsAll.split!(path) |> DocsAll.join(features),
            [word | _] <- Regex.scan(giveaways, text),
            uniq: true,
            do: "#{path}: #{word}"

      assert caught == []
    end

    test "read on where a passage was left out" do
      nodes = guide("nodes.md", @off)

      assert nodes =~
               "time, so that a machine can move to a new key before the old one is revoked.\nA key is never rotated"

      assert nodes =~ ~s{its **Fingerprint**;\nwith **Forager file** and **Revoke…**.}
      assert nodes =~ "There is nothing to fill\n   in.\n2."
      assert nodes =~ "half. The key\n   is active as soon as it arrives."
    end
  end

  describe "on, named in QORY_FEATURES" do
    @describetag with_features: @on
    @describetag needs: :secrets

    setup :register_and_log_in_user

    test "its pages are there", %{conn: conn, scope: scope} do
      for rest <- ["/settings/secrets", "/settings/variables", "/settings/integrations"] do
        assert {:ok, _view, _html} = live(conn, workspace_path(scope, rest)), rest
      end
    end

    test "the workspace's settings list Integrations and Secrets and variables",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, workspace_path(scope, "/settings"))

      assert has_element?(view, "#settings-tab-integrations", "Integrations")
      assert has_element?(view, "#settings-tab-secrets", "Secrets and variables")
    end

    test "New offers an integration, a secret and a variable", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, workspace_path(scope))

      assert has_element?(
               view,
               "#new-menu-integration[href='#{workspace_path(scope, "/settings/integrations")}#add-part']"
             )

      assert has_element?(
               view,
               "#new-menu-secret[href='#{workspace_path(scope, "/settings/secrets/new")}']"
             )

      assert has_element?(
               view,
               "#new-menu-variable[href='#{workspace_path(scope, "/settings/variables/new")}']"
             )
    end

    test "the palette finds it", %{conn: conn, scope: scope} do
      answer = jump(conn, scope)

      assert labels(answer, "Actions") ==
               [
                 "New node",
                 "New node pool",
                 "Add integration",
                 "New secret",
                 "New variable",
                 "Invite people"
               ]

      assert "Workspace settings › Integrations" in labels(answer, "Go to")
      assert "Workspace settings › Secrets and variables" in labels(answer, "Go to")

      assert labels(jump(conn, scope, "token"), "Go to") ==
               ["Workspace settings › Secrets and variables"]
    end

    test "the Audit log's Action filter offers its actions", %{conn: conn, scope: scope} do
      {actions, _view} = audit_actions(conn, scope)
      for action <- @secrets_actions, do: assert(action in actions, action)
    end

    test "a key's card has its Stored secrets row", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      %{access_key: key} = node_key_fixture(scope, node)

      {:ok, view, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}/access-key")

      assert has_element?(view, "#key-#{key.key_id}-stored-secrets", "Not allowed")
      assert render(view) =~ "Stored secrets"
    end
  end

  describe "on, the instance's Configuration" do
    @describetag with_features: @on
    @describetag needs: :secrets

    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "lists the feature as on, and has the Integrations part", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      assert view |> element("#config-feature-secrets-value") |> render() =~ "On"
      assert has_element?(view, "#config-integrations")
      assert has_element?(view, "#config-url-sources")
    end
  end

  describe "on, the guides at /docs" do
    test "an instance that names every feature is served the tree of every feature" do
      {:ok, features} = Apiary.Features.parse(Enum.join(Apiary.Features.all(), ","))
      assert :secrets in features
      assert ApiaryWeb.DocsController.tree_name(features) == "all"
    end

    test "have each passage of it" do
      for {file, words} <- @gated_passages do
        assert guide(file, @on) =~ words, "#{file}: #{words}"
      end

      nodes = guide("nodes.md", @on)
      assert nodes =~ "its **Fingerprint**;\nits **Stored secrets**;\nwith **Forager file**"

      assert nodes =~
               "half. The key\n   gets **Stored secrets** **Not allowed**, and\n   is active"
    end
  end
end
