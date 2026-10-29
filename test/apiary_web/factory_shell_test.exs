defmodule ApiaryWeb.FactoryShellTest do
  # The shell of the pages of the feature `factory`: their routes, each answered as a path
  # that does not exist where the feature is off and, where it is on, by its page, which
  # is not found until it is built; the link that names a connection to an integration
  # (`ApiaryWeb.AdapterRedirectControllerTest` has the rest of it); the
  # sidebar's Work group; Organisation settings' Integrations; Instance settings'
  # Adapters and Nodes; and the Activity filter's words for the work item comments, the handover,
  # the release, a build asked for, an adapter installed and a set-up
  # started.
  #
  # Not async: the tests without the feature switch the instance's features, which are the
  # whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Audit
  alias ApiaryWeb.Layouts

  # The adapter is made where the feature is on; the tests without it turn it off after.
  @moduletag needs: :factory

  # The modules of the feature's pages, and of the link to an integration.
  @modules [
    ApiaryWeb.AdapterLive.Index,
    ApiaryWeb.AdapterLive.Show,
    ApiaryWeb.AdapterLive.AccessKey,
    ApiaryWeb.InstanceLive.Adapters,
    ApiaryWeb.InstanceLive.Adapter,
    ApiaryWeb.InstanceLive.Nodes,
    ApiaryWeb.InstanceLive.Node,
    ApiaryWeb.BacklogLive.Index,
    ApiaryWeb.BacklogLive.Ticket,
    ApiaryWeb.WorkItemLive.Index,
    ApiaryWeb.WorkItemLive.Show,
    ApiaryWeb.TargetLive.FurtherRepositories,
    ApiaryWeb.ProviderLive.Index,
    ApiaryWeb.ProviderLive.Show,
    ApiaryWeb.ModelChoiceLive,
    ApiaryWeb.WorkflowLive,
    ApiaryWeb.CollectionsLive,
    ApiaryWeb.ChooseCollectionsLive,
    ApiaryWeb.AdapterRedirectController,
    ApiaryWeb.AdapterInstallController,
    ApiaryWeb.AdapterSetupController
  ]

  # The modules of the feature's pages of the Instance level not built yet, which answer
  # an instance admin as a path that does not exist.
  @unbuilt []

  # The modules of the feature's pages of an organisation or a workspace not built yet,
  # which answer anyone as a path that does not exist.
  @unbuilt_pages [
    ApiaryWeb.BacklogLive.Ticket
  ]

  # The modules of the feature's pages of the Instance level.
  @instance_modules [
    ApiaryWeb.InstanceLive.Adapters,
    ApiaryWeb.InstanceLive.Adapter,
    ApiaryWeb.AdapterLive.AccessKey,
    ApiaryWeb.InstanceLive.Nodes,
    ApiaryWeb.InstanceLive.Node
  ]

  # A workspace's set-up is finished: a link to it leads to its first page.
  setup do
    Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)
  end

  setup :register_and_log_in_user

  setup do
    %{adapter: adapter_fixture(%{name: "Acme tracker"})}
  end

  # Every route of the core's router whose page or controller belongs to `factory`, as
  # `{verb, path, module}` with its parameters filled in: the scope's organisation and
  # workspace, the adapter, a connection's id that names none, a work item's number, and
  # a made-up id for the rest. The signed requests of an adapter and of a node pool's
  # starter are no page of the shell: `ApiaryWeb.Contract.AdapterRequestTest`,
  # `ApiaryWeb.Contract.ChangesControllerTest`,
  # `ApiaryWeb.Contract.SourceCollectionsControllerTest`,
  # `ApiaryWeb.Contract.SourceItemsTest`, `ApiaryWeb.Contract.SourceItemCommentsTest`,
  # `ApiaryWeb.Contract.AppValuesControllerTest`,
  # `ApiaryWeb.Contract.GrantsControllerTest`,
  # `ApiaryWeb.Contract.GrantEndControllerTest` and their fixtures' tests, and
  # `ApiaryWeb.Contract.PoolRequestTest`, answer for them. A
  # gateway's secrets request is no page either: `ApiaryWeb.Contract.SecretsControllerTest`
  # and `ApiaryWeb.Contract.SecretsDiscoveryTest` answer for it.
  @signed_routes [
    ApiaryWeb.Contract.SecretsController,
    ApiaryWeb.Contract.AdapterController,
    ApiaryWeb.Contract.ChangesController,
    ApiaryWeb.Contract.SourceCollectionsController,
    ApiaryWeb.Contract.SourcesDisconnectController,
    ApiaryWeb.Contract.SourceItemsController,
    ApiaryWeb.Contract.SourceItemCommentsController,
    ApiaryWeb.Contract.AppValuesController,
    ApiaryWeb.Contract.GrantsController,
    ApiaryWeb.Contract.GrantEndController,
    ApiaryWeb.Contract.PoolClaimController,
    ApiaryWeb.Contract.DispatchController
  ]

  defp factory_routes(scope, adapter) do
    for {verb, path, module} <- ApiaryWeb.RoutesFeaturesCase.routes(ApiaryWeb.Router),
        function_exported?(Code.ensure_loaded!(module), :__feature__, 0),
        module.__feature__() == :factory,
        module not in @signed_routes do
      {verb, fill(path, scope, adapter), module}
    end
  end

  defp fill(path, scope, adapter) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":org" -> scope.organisation.slug
      ":workspace" -> scope.workspace.slug
      ":adapter_id" -> adapter.public_id
      ":connection_id" -> "ac_0000000000000000"
      ":number" -> "1"
      ":" <> _param -> "x1"
      segment -> segment
    end)
  end

  # What a request is answered: the status, the body and the headers, all but the request's
  # id and its nonce (`ApiaryWeb.ContentSecurityPolicy`). An error the endpoint renders
  # and raises again is taken as it was sent.
  defp answer(request) do
    conn = request.()
    {conn.status, without_nonce(conn.resp_body), headers(conn.resp_headers)}
  rescue
    _error ->
      {status, headers, body} = assert_error_sent(:not_found, request)
      {status, without_nonce(body), headers(headers)}
  end

  defp headers(headers) do
    headers
    |> Enum.reject(fn {name, _} -> name == "x-request-id" end)
    |> Enum.map(fn {name, value} -> {name, without_nonce(value)} end)
    |> Enum.sort()
  end

  defp without_nonce(text),
    do: String.replace(text, ~r/nonce(-|=")[A-Za-z0-9+\/=]+/, "nonce\\1…")

  defp without_factory(_ctx) do
    previous = Application.get_env(:apiary, :features)
    {:ok, features} = Apiary.Features.parse("observability,security")
    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
    :ok
  end

  defp hide_factory(_ctx) do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
    :ok = Apiary.EditionStubs.HidesNamed.put([:factory])
  end

  test "the routes are the shared contract's, each of the feature", %{
    scope: scope,
    adapter: adapter
  } do
    routes = factory_routes(scope, adapter)
    org = "/#{scope.organisation.slug}"
    integration = "#{org}/settings/integrations/#{adapter.public_id}"
    managed = "/instance/adapters/#{adapter.public_id}"

    assert Enum.sort(for {verb, path, _module} <- routes, do: {verb, path}) ==
             Enum.sort(
               [
                 {:get, "/integrations/ac_0000000000000000"},
                 # The organisation's: the list, Add an integration (connecting one), and
                 # an integration's page in the organisation.
                 {:get, "#{org}/settings/integrations"},
                 {:get, "#{org}/settings/integrations/new"},
                 {:get, integration},
                 # Install, which connects the organisation to it.
                 {:post, integration <> "/install"},
                 # The instance admins': the list, Add for one entry of the catalogue, and
                 # an adapter's Overview, its keys and its settings.
                 {:get, "/instance/adapters"},
                 {:get, "/instance/adapters/new/x1"},
                 {:get, managed},
                 {:get, managed <> "/keys"},
                 {:get, managed <> "/keys/new-code"},
                 {:get, managed <> "/keys/x1/revoke"},
                 {:get, managed <> "/keys/codes/x1/revoke"},
                 {:get, managed <> "/settings"},
                 {:get, managed <> "/settings/rename"},
                 {:get, managed <> "/settings/remove"},
                 # Set up, which starts an adapter's set-up at the system it reads from.
                 {:post, managed <> "/setup"},
                 # The instance's pool and gateway: the list, and a node's Overview, its
                 # keys and its settings.
                 {:get, "/instance/nodes"},
                 {:get, "/instance/nodes/x1"},
                 {:get, "/instance/nodes/x1/keys"},
                 {:get, "/instance/nodes/x1/keys/x1/revoke"},
                 {:get, "/instance/nodes/x1/settings"},
                 # The organisation's model providers: the list, New model provider and a
                 # provider's page; and a workspace's Model.
                 {:get, "#{org}/settings/model-providers"},
                 {:get, "#{org}/settings/model-providers/new"},
                 {:get, "#{org}/settings/model-providers/x1"},
                 {:get, workspace_path(scope, "/settings/model")},
                 # The chooser of set-up's Work sources and Destinations.
                 {:get, "#{org}/set-up/choose"}
               ] ++
                 for(
                   rest <-
                     ~w(/backlog /backlog/x1 /work /work/1 /work/1/explore /work/1/explore/edit
                        /work/1/thread /targets/x1/also-read /settings/work-sources
                        /settings/destinations /settings/choose /settings/workflow),
                   do: {:get, workspace_path(scope, rest)}
                 )
             )

    assert routes |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort() == Enum.sort(@modules)
  end

  test "each path of Instance settings › Adapters is served by its page and action",
       %{adapter: adapter} do
    managed = "/instance/adapters/#{adapter.public_id}"

    served =
      for path <-
            ["/instance/adapters", "/instance/adapters/new/x1", managed] ++
              for(
                rest <-
                  ~w(/keys /keys/new-code /keys/x1/revoke /keys/codes/x1/revoke /settings
                     /settings/rename /settings/remove),
                do: managed <> rest
              ) do
        %{phoenix_live_view: {module, action, _, _}} =
          Phoenix.Router.route_info(ApiaryWeb.Router, "GET", path, "localhost")

        {path, module, action}
      end

    assert served == [
             {"/instance/adapters", ApiaryWeb.InstanceLive.Adapters, :index},
             {"/instance/adapters/new/x1", ApiaryWeb.AdapterLive.AccessKey, :new},
             {managed, ApiaryWeb.InstanceLive.Adapter, :overview},
             {managed <> "/keys", ApiaryWeb.AdapterLive.AccessKey, :index},
             {managed <> "/keys/new-code", ApiaryWeb.AdapterLive.AccessKey, :new_code},
             {managed <> "/keys/x1/revoke", ApiaryWeb.AdapterLive.AccessKey, :revoke},
             {managed <> "/keys/codes/x1/revoke", ApiaryWeb.AdapterLive.AccessKey, :revoke_code},
             {managed <> "/settings", ApiaryWeb.InstanceLive.Adapter, :settings},
             {managed <> "/settings/rename", ApiaryWeb.InstanceLive.Adapter, :rename},
             {managed <> "/settings/remove", ApiaryWeb.InstanceLive.Adapter, :remove}
           ]
  end

  describe "with the feature" do
    test "each page answers as a path that does not exist until it is built, to anyone", %{
      conn: conn,
      scope: scope,
      adapter: adapter
    } do
      for {:get, path, module} <- factory_routes(scope, adapter),
          module in @unbuilt_pages or module in @instance_modules do
        assert {404, _body, _headers} = answer(fn -> get(conn, path) end), path
      end
    end

    test "a live navigation to a page is refused the same way", %{
      conn: conn,
      scope: scope,
      adapter: adapter
    } do
      for {:get, path, module} <- factory_routes(scope, adapter),
          Enum.member?(@unbuilt, module) or module in @unbuilt_pages do
        {:ok, view, _html} = navigable(conn, scope, path)

        assert {%{status: 404, reason: "reload"}, _call} =
                 catch_exit(live_redirect(view, to: path)),
               path
      end
    end

    # The link leads only a person of the connection's organisation, so it is not found
    # to anyone else, whatever it names, and answers the same for each.
    test "the link to a connection the person does not reach is not found, the same whatever it names",
         %{conn: conn, scope: scope, adapter: adapter} do
      %{adapter: connectable} = connectable_adapter_fixture()
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, connectable, :pending)
      admin_conn = log_in_user(build_conn(), instance_admin_scope().user)

      for {who, asker, id} <- [
            {"another organisation's", conn, theirs.public_id},
            {"another organisation's, to an instance admin", admin_conn, theirs.public_id},
            {"none", conn, "ac_0000000000000000"},
            {"an adapter's id", conn, adapter.public_id},
            {"not an id", conn, scope.workspace.slug}
          ] do
        assert {404, _body, _headers} = answer(fn -> get(asker, "/integrations/#{id}") end),
               who

        assert {404, _body, _headers} =
                 answer(fn -> get(asker, "/integrations/#{id}?return=x.y") end),
               who
      end
    end

    test "the link to a connection sends an anonymous visitor to log in" do
      assert build_conn() |> get("/integrations/ac_0000000000000000") |> redirected_to() ==
               ~p"/users/log-in"
    end

    test "the sidebar's Work group: Work items and Backlog, between the scope's first entries and Record",
         %{conn: conn, scope: scope} do
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      assert has_element?(view, "#nav-group-work", "Work")

      assert has_element?(
               view,
               "#nav-group-work a#nav-work_items[href='#{workspace_path(scope, "/work")}']",
               "Work items"
             )

      assert has_element?(
               view,
               "#nav-group-work a#nav-backlog[href='#{workspace_path(scope, "/backlog")}']",
               "Backlog"
             )

      assert before?(html, ~s(id="nav-group-home"), ~s(id="nav-group-work"))
      assert before?(html, ~s(id="nav-work_items"), ~s(id="nav-backlog"))
      assert before?(html, ~s(id="nav-backlog"), ~s(id="nav-group-record"))

      # No work item waits for the reader: no count beside Work items.
      refute has_element?(view, "#nav-work_items .q-nav-count")
      refute Map.has_key?(ApiaryWeb.UserAuth.nav_counts(scope), :waiting_on)
    end

    test "the count beside Work items says in its title that they wait for the reader", %{
      scope: scope
    } do
      shell = fn counts ->
        assigns = %{scope: scope, counts: counts}

        ~H"""
        <Layouts.app flash={%{}} current_scope={@scope} nav={:work_items} counts={@counts}>
          <p>page</p>
        </Layouts.app>
        """
        |> rendered_to_string()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#nav-work_items .q-nav-count")
      end

      three = shell.(%{waiting_on: 3})
      assert three |> LazyHTML.text() |> String.trim() == "3"
      assert LazyHTML.attribute(three, "title") == ["Work items: 3 wait for you"]

      one = shell.(%{waiting_on: 1})
      assert one |> LazyHTML.text() |> String.trim() == "1"
      assert LazyHTML.attribute(one, "title") == ["Work items: 1 waits for you"]

      assert shell.(%{}) |> Enum.count() == 0
    end

    test "a member has the Work group too", %{scope: scope} do
      %{user: member} = member_fixture(scope, :member)
      conn = log_in_user(build_conn(), member)
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      assert has_element?(view, "#nav-group-work #nav-work_items")
      assert has_element?(view, "#nav-group-work #nav-backlog")
    end

    test "the palette's Go to leaves Work out, and a switch of workspace still lands there", %{
      scope: scope
    } do
      keys = for {entry, _path} <- Layouts.palette_entries(scope), do: entry.key

      assert :overview in keys
      refute :work_items in keys
      refute :backlog in keys

      assert Layouts.switch_target(scope, "work_items") == workspace_path(scope, "/work")
      assert Layouts.switch_target(scope, "backlog") == workspace_path(scope, "/backlog")
    end

    test "Organisation settings list Integrations, for a member too", %{
      conn: conn,
      scope: scope
    } do
      href = "/#{scope.organisation.slug}/settings/integrations"
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      assert has_element?(view, "a#settings-tab-integrations[href='#{href}']", "Integrations")

      %{user: member} = member_fixture(scope, :member)
      member_conn = log_in_user(build_conn(), member)
      {:ok, view, _html} = live(member_conn, ~p"/#{scope.organisation}/settings")
      assert has_element?(view, "a#settings-tab-integrations[href='#{href}']")
    end

    test "the Activity filter offers each action of the feature that has its words, by them, and no other",
         %{conn: conn, scope: scope} do
      options = action_options(conn, scope)

      assert {"work_item.take_in", "Work item taken in"} in options
      assert {"work_item.undo", "Take in undone"} in options
      assert {"work_item.decline", "Work item declined"} in options
      assert {"work_item.close", "Work item closed"} in options
      assert {"work_item.answer", "Work item questions answered"} in options
      assert {"work_item.confirm", "Work item proposal confirmed"} in options
      assert {"work_item.explore_again", "Work item explored again"} in options
      assert {"work_item.comment", "Work item comment added"} in options
      assert {"work_item.comment_delete", "Work item comment deleted"} in options
      assert {"collection.assign", "Assigned collections"} in options

      assert {"collection.set_backlog", "Taking tickets into the Backlog turned on or off"} in options

      assert {"dispatch.release", "Runs given back"} in options

      assert {"target.set_further_repositories", "Also read"} in options
      assert {"target.rebuild_environment", "Builds asked for"} in options

      assert {"adapter.install", "Adapter installed"} in options
      assert {"adapter.setup", "Adapter set-up started"} in options
      assert {"adapter.app_values_set", "Adapter secrets stored"} in options
      assert {"adapter.app_values_seal", "Adapter secrets sent"} in options
      assert {"adapter.end_grant", "Ended a grant"} in options
      assert {"run_credential.issue", "Run access sent or refused"} in options
      assert {"model_choice.write", "Model choice changed"} in options
      assert {"time_limit.edit", "Time limit changed"} in options

      offered = for {value, _words} <- options, do: String.to_existing_atom(value)

      for action <- Audit.audited_actions(),
          Apiary.Access.feature(action) == :factory,
          action not in [
            :"work_item.take_in",
            :"work_item.undo",
            :"work_item.decline",
            :"work_item.close",
            :"work_item.answer",
            :"work_item.confirm",
            :"work_item.explore_again",
            :"work_item.comment",
            :"work_item.comment_delete",
            :"collection.assign",
            :"collection.set_backlog",
            :"dispatch.release",
            :"target.set_further_repositories",
            :"target.rebuild_environment",
            :"adapter.install",
            :"adapter.setup",
            :"adapter.app_values_set",
            :"adapter.app_values_seal",
            :"adapter.end_grant",
            :"run_credential.issue",
            :"model_choice.write",
            :"time_limit.edit"
          ],
          do: refute(action in offered, "#{action}")
    end

    test "⌘K's Go to and Organisation settings list Integrations for an owner, and Go to leaves Work out",
         %{conn: conn, scope: scope} do
      hrefs = go_to_hrefs(conn, scope)
      assert "/#{scope.organisation.slug}/settings/integrations" in hrefs
      refute workspace_path(scope, "/work") in hrefs
      refute workspace_path(scope, "/backlog") in hrefs

      assert :integrations in section_keys(scope)
    end
  end

  describe "the instance admins' pages" do
    # The feature's pages under `/instance`, with their parameters filled in.
    defp instance_routes(scope, adapter) do
      for {:get, "/instance/" <> _ = path, module} <- factory_routes(scope, adapter),
          do: {path, module}
    end

    test "an instance admin passes the feature's gates and meets the page, not found until it is built",
         %{scope: scope, adapter: adapter} do
      admin_conn = log_in_user(build_conn(), instance_admin_scope().user)
      routes = instance_routes(scope, adapter)
      assert length(routes) == 15

      keys = "/instance/adapters/#{adapter.public_id}/keys"

      for {path, module} <- routes do
        # The answer of the page as it mounts: not the door's, nor the gate's.
        cond do
          Enum.member?(@unbuilt, module) ->
            assert_raise ApiaryWeb.NotFound, fn -> live(admin_conn, path) end

          # Add, not found until the catalogue exists.
          String.starts_with?(path, "/instance/adapters/new/") ->
            assert_raise ApiaryWeb.NotFound, fn -> live(admin_conn, path) end

          # No such node of the instance.
          String.starts_with?(path, "/instance/nodes/") ->
            assert_raise ApiaryWeb.NotFound, fn -> live(admin_conn, path) end

          # No code just made, no such key, no such code: the page leads to the tab.
          path in [keys <> "/new-code", keys <> "/x1/revoke", keys <> "/codes/x1/revoke"] ->
            assert {:error, {:live_redirect, %{to: ^keys}}} = live(admin_conn, path), path

          true ->
            assert {:ok, _view, _html} = live(admin_conn, path), path
        end

        assert ApiaryWeb.Features.gate(module) == :factory
      end
    end

    test "they ask the instance, whatever the person is shown in the organisation the scope carries",
         %{conn: conn, scope: scope, adapter: adapter} do
      hide_factory(%{})
      admin_conn = log_in_user(build_conn(), instance_admin_scope().user)

      for {path, module} <- instance_routes(scope, adapter), Enum.member?(@unbuilt, module) do
        assert_raise ApiaryWeb.NotFound, fn -> live(admin_conn, path) end
      end

      # An organisation's page of the feature asks what the person is shown there.
      assert_raise ApiaryWeb.Features.NotFound, fn ->
        live(conn, ~p"/#{scope.organisation}/settings/integrations")
      end

      hidden = owner_scope(scope.user)
      refute Apiary.Features.visible?(hidden, :factory)
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_scope: hidden}}

      assert {:cont, _socket} =
               ApiaryWeb.Features.on_mount({:instance, :factory}, %{}, %{}, socket)

      assert_raise ApiaryWeb.Features.NotFound, fn ->
        ApiaryWeb.Features.on_mount(:factory, %{}, %{}, socket)
      end
    end

    test "an open page stays open, whatever the person is shown in the organisation the scope carries" do
      hide_factory(%{})
      admin = instance_admin_scope()
      refute Apiary.Features.visible?(admin, :factory)

      for module <- @instance_modules do
        assert ApiaryWeb.Features.instance?(module), inspect(module)
        assert ApiaryWeb.Features.page_shown?(module, admin), inspect(module)

        # As a change of the person's memberships has the page read the scope again.
        socket = ApiaryWeb.UserAuth.reload_scope(open_socket(module, admin))
        refute socket.redirected, inspect(module)
      end

      # A page of the organisation asks what the person is shown there, and leaves.
      for module <- [ApiaryWeb.AdapterLive.Index, ApiaryWeb.AdapterLive.Show] do
        refute ApiaryWeb.Features.instance?(module), inspect(module)
        refute ApiaryWeb.Features.page_shown?(module, admin), inspect(module)

        socket = ApiaryWeb.UserAuth.reload_scope(open_socket(module, admin))
        assert {:redirect, %{to: to}} = socket.redirected
        assert to == "/#{admin.organisation.slug}"
      end
    end

    test "anyone but an instance admin is answered as on the Instance's other pages", %{
      conn: conn,
      scope: scope,
      adapter: adapter
    } do
      refute Apiary.Access.instance_admin?(scope)
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, ~p"/instance/general") end

      for {path, _module} <- instance_routes(scope, adapter) do
        assert_raise ApiaryWeb.NotFound, fn -> live(conn, path) end

        assert answer(fn -> get(conn, path) end) ==
                 answer(fn -> get(conn, "/instance/general") end)
      end
    end

    test "Instance settings list Adapters and Nodes for an instance admin, before Mail, and for no one else",
         %{scope: scope} do
      admin = instance_admin_scope()
      keys = for entry <- Layouts.instance_sections(admin), do: entry.key
      assert [:adapters, :nodes, :mail, :configuration] = Enum.take(keys, -4)

      assert %{label: "Nodes", path: "/instance/nodes", place: :instance} =
               Enum.find(Layouts.instance_sections(admin), &(&1.key == :nodes))

      assert %{label: "Adapters", path: "/instance/adapters", place: :instance} =
               Enum.find(Layouts.instance_sections(admin), &(&1.key == :adapters))

      {:ok, view, _html} =
        live(log_in_user(build_conn(), admin.user), ~p"/instance/general")

      assert has_element?(
               view,
               "#instance-tabs a#instance-tab-adapters[href='/instance/adapters']",
               "Adapters"
             )

      refute Enum.any?(Layouts.instance_sections(scope), &(&1.key in [:adapters, :nodes]))
    end

    test "the entry asks the instance, whatever the person is shown in the organisation the scope carries" do
      hide_factory(%{})
      admin = instance_admin_scope()
      refute Apiary.Features.visible?(owner_scope(admin.user), :factory)
      assert Enum.any?(Layouts.instance_sections(admin), &(&1.key == :adapters))
    end

    test "the organisation has no path that makes, renames, removes an integration or holds its key",
         %{scope: scope, adapter: adapter} do
      integration = "/#{scope.organisation.slug}/settings/integrations/#{adapter.public_id}"

      for rest <-
            ~w(/keys /keys/new-code /keys/x1/revoke /keys/codes/x1/revoke /access-key
               /access-key/new-code /access-key/keys/x1/revoke /access-key/codes/x1/revoke
               /settings /settings/rename /settings/remove) do
        path = integration <> rest

        assert Phoenix.Router.route_info(ApiaryWeb.Router, "GET", path, "localhost") == :error,
               path
      end

      # Add an integration stays the organisation's: there an owner or an admin connects one.
      assert %{phoenix_live_view: {ApiaryWeb.AdapterLive.Index, :new, _, _}} =
               Phoenix.Router.route_info(
                 ApiaryWeb.Router,
                 "GET",
                 "/#{scope.organisation.slug}/settings/integrations/new",
                 "localhost"
               )
    end
  end

  describe "hidden from the person, on an instance with it" do
    setup :hide_factory

    test "each route answers as a path that does not exist", %{
      conn: conn,
      scope: scope,
      adapter: adapter
    } do
      for {:get, path, _module} <- factory_routes(scope, adapter) do
        assert {404, _body, _headers} = answer(fn -> get(conn, path) end), path
      end
    end

    test "the sidebar, the settings and the Activity filter leave it out", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
      refute has_element?(view, "#nav-group-work")
      refute has_element?(view, "#nav-work_items")
      refute has_element?(view, "#nav-backlog")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      refute has_element?(view, "#settings-tab-integrations")

      values = for {value, _words} <- action_options(conn, scope), do: value
      assert "workspace.rename" in values
      refute "work_item.comment" in values
      refute "work_item.comment_delete" in values
      refute "dispatch.handover" in values
      refute "dispatch.release" in values
      refute "dispatch.prebuilt" in values
      refute "target.rebuild_environment" in values
    end

    test "⌘K's Go to, a switch of workspace and Organisation settings name none of it, to an owner",
         %{conn: conn, user: user} do
      scope = owner_scope(user)
      hrefs = go_to_hrefs(conn, scope)

      for href <- shell_hrefs(scope), do: refute(href in hrefs, href)

      keys = for {entry, _path} <- Layouts.palette_entries(scope), do: entry.key
      assert :overview in keys
      refute :work_items in keys
      refute :backlog in keys

      overview = workspace_path(scope)
      assert Layouts.switch_target(scope, "work_items") == overview
      assert Layouts.switch_target(scope, "backlog") == overview

      assert :people in section_keys(scope)
      refute :integrations in section_keys(scope)
    end
  end

  describe "without the feature" do
    setup :without_factory

    test "each route answers as a path that does not exist, to anyone", %{
      conn: conn,
      scope: scope,
      adapter: adapter
    } do
      refute Apiary.Features.on?(:factory)

      askers = [
        {"signed in", conn},
        {"anonymous", build_conn()},
        {"anonymous, asking for JSON", put_req_header(build_conn(), "accept", "application/json")}
      ]

      unknown = workspace_path(scope, "/no-such-page")

      for {who, asker} <- askers, {:get, path, _module} <- factory_routes(scope, adapter) do
        assert answer(fn -> get(asker, path) end) == answer(fn -> get(asker, unknown) end),
               "#{path}, #{who}"
      end
    end

    test "each route answers so with a character of its path escaped, as the router decodes it",
         %{conn: conn, scope: scope, adapter: adapter} do
      unknown = workspace_path(scope, "/no-such-page")

      for {:get, path, _module} <- factory_routes(scope, adapter) do
        # The first character of the last segment, escaped: `/backlog` as `/%62acklog`.
        {last, rest} = path |> String.split("/") |> List.pop_at(-1)
        <<first, after_first::binary>> = last
        hex = Base.encode16(<<first>>, case: :lower)
        escaped = Enum.join(rest ++ ["%" <> hex <> after_first], "/")

        assert answer(fn -> get(conn, escaped) end) == answer(fn -> get(conn, unknown) end),
               escaped
      end
    end

    test "a live navigation to a page is refused the same way", %{
      conn: conn,
      scope: scope,
      adapter: adapter
    } do
      for {:get, path, module} <- factory_routes(scope, adapter),
          module != ApiaryWeb.AdapterRedirectController do
        {:ok, view, _html} = navigable(conn, scope, path)

        assert {%{status: 404, reason: "reload"}, _call} =
                 catch_exit(live_redirect(view, to: path)),
               path
      end
    end

    test "the sidebar, the settings and the Activity filter leave it out", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
      refute has_element?(view, "#nav-group-work")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      refute has_element?(view, "#settings-tab-integrations")

      values = for {value, _words} <- action_options(conn, scope), do: value
      refute "work_item.comment" in values
      refute "dispatch.handover" in values
      refute "dispatch.release" in values
      refute "dispatch.prebuilt" in values
      refute "target.rebuild_environment" in values
    end

    test "⌘K's Go to, a switch of workspace and Organisation settings name none of it, to an owner",
         %{conn: conn, user: user} do
      scope = owner_scope(user)
      hrefs = go_to_hrefs(conn, scope)

      for href <- shell_hrefs(scope), do: refute(href in hrefs, href)

      keys = for {entry, _path} <- Layouts.palette_entries(scope), do: entry.key
      assert :overview in keys
      refute :work_items in keys
      refute :backlog in keys

      overview = workspace_path(scope)
      assert Layouts.switch_target(scope, "work_items") == overview
      assert Layouts.switch_target(scope, "backlog") == overview

      assert :people in section_keys(scope)
      refute :integrations in section_keys(scope)
    end

    test "an open page of the Instance level is not there, for an instance admin too" do
      admin = instance_admin_scope()

      for module <- @instance_modules do
        refute ApiaryWeb.Features.page_shown?(module, admin), inspect(module)
      end
    end

    test "Instance settings leave Adapters out, for an instance admin too" do
      admin = instance_admin_scope()
      keys = for entry <- Layouts.instance_sections(admin), do: entry.key
      assert :configuration in keys
      refute :adapters in keys

      {:ok, view, _html} =
        live(log_in_user(build_conn(), admin.user), ~p"/instance/general")

      refute has_element?(view, "#instance-tab-adapters")
    end
  end

  # An open page of `module`, as a LiveView holds it once mounted with `scope`.
  defp open_socket(module, scope) do
    %Phoenix.LiveView.Socket{
      view: module,
      assigns: %{__changed__: %{}, current_scope: scope, flash: %{}}
    }
  end

  # A page a live navigation to `path` starts from, in the same live session: an Instance
  # page, opened by an instance admin, for a page of the Instance level, else a page of
  # the workspace. The async reads it starts (the runs page's) finish first
  # (`render_async/1`): the refused navigation ends the page, and a task still reading
  # would be killed holding the test's sandbox connection.
  defp navigable(conn, scope, path) do
    {:ok, view, html} = start_page(conn, scope, path)
    render_async(view)
    {:ok, view, html}
  end

  defp start_page(_conn, _scope, "/instance/" <> _),
    do: live(log_in_user(build_conn(), instance_admin_scope().user), ~p"/instance/general")

  defp start_page(conn, scope, _path),
    do: live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")

  # Where ⌘K's Go to leads, as `ApiaryWeb.JumpController` answers it from the
  # organisation's path and from the workspace's, with nothing typed and with the words
  # of the feature's entries.
  defp go_to_hrefs(conn, scope) do
    for path <- ["/#{scope.organisation.slug}/jump", workspace_path(scope, "/jump")],
        q <- ["", "integrations", "Integrations", "Work", "Backlog"],
        group <-
          conn
          |> put_req_header("accept", "application/json")
          |> get(path, %{"q" => q})
          |> json_response(200)
          |> Map.fetch!("groups"),
        group["label"] == "Go to",
        item <- group["items"],
        uniq: true,
        do: item["href"]
  end

  # The paths of the feature's entries: Organisation settings › Integrations, Work items
  # and Backlog.
  defp shell_hrefs(scope) do
    [
      "/#{scope.organisation.slug}/settings/integrations",
      workspace_path(scope, "/work"),
      workspace_path(scope, "/backlog"),
      workspace_path(scope, "/settings/work-sources"),
      workspace_path(scope, "/settings/destinations")
    ]
  end

  defp section_keys(scope),
    do: for(entry <- ApiaryWeb.SettingsComponents.sections(scope, :organisation), do: entry.key)

  # The owner's scope read again, with what the edition hides from them now.
  defp owner_scope(user),
    do: Apiary.Organisations.load_scope(Apiary.Accounts.Scope.for_user(user))

  # The Action filter's options of the organisation's Activity page, as `{value, words}`.
  defp action_options(conn, scope) do
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/audit-log")
    render_async(view)

    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#filter-action-form li")
    |> Enum.map(fn li ->
      [value] = li |> LazyHTML.query("input") |> LazyHTML.attribute("value")
      {value, li |> LazyHTML.text() |> String.trim()}
    end)
  end

  defp before?(html, first, second) do
    {a, _} = :binary.match(html, first)
    {b, _} = :binary.match(html, second)
    a < b
  end
end
