defmodule ApiaryWeb.FactoryShellTest do
  # The shell of the pages of the feature `factory`: their routes, each answered as a path
  # that does not exist where the feature is off and, where it is on, by its page, which
  # is not found until it is built; the link that names an integration alone; the
  # sidebar's Work group; Organisation settings' Integrations; and the Activity filter's
  # words for the work item comments.
  #
  # Not async: the tests without the feature switch the instance's features, which are the
  # whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Adapters, Audit}
  alias ApiaryWeb.Layouts

  # The adapter is made where the feature is on; the tests without it turn it off after.
  @moduletag needs: :factory

  # The modules of the feature's pages, and of the link to an integration.
  @modules [
    ApiaryWeb.AdapterLive.Index,
    ApiaryWeb.AdapterLive.Show,
    ApiaryWeb.AdapterLive.AccessKey,
    ApiaryWeb.BacklogLive.Index,
    ApiaryWeb.WorkItemLive.Index,
    ApiaryWeb.WorkItemLive.Show,
    ApiaryWeb.AdapterRedirectController
  ]

  setup :register_and_log_in_user

  setup do
    %{adapter: adapter_fixture(%{name: "Acme tracker"})}
  end

  # Every route of the core's router whose page or controller belongs to `factory`, as
  # `{verb, path, module}` with its parameters filled in: the scope's organisation and
  # workspace, the adapter, a work item's number, and a made-up id for the rest.
  defp factory_routes(scope, adapter) do
    for {verb, path, module} <- ApiaryWeb.RoutesFeaturesCase.routes(ApiaryWeb.Router),
        function_exported?(Code.ensure_loaded!(module), :__feature__, 0),
        module.__feature__() == :factory do
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

    assert Enum.sort(for {verb, path, _module} <- routes, do: {verb, path}) ==
             Enum.sort(
               [
                 {:get, "/integrations/#{adapter.public_id}"},
                 {:get, "#{org}/settings/integrations"},
                 {:get, "#{org}/settings/integrations/new"},
                 {:get, integration},
                 {:get, integration <> "/assign"},
                 {:get, integration <> "/node-pools"},
                 {:get, integration <> "/access-key"},
                 {:get, integration <> "/access-key/new-code"},
                 {:get, integration <> "/access-key/keys/x1/revoke"},
                 {:get, integration <> "/access-key/codes/x1/revoke"},
                 {:get, integration <> "/settings"},
                 {:get, integration <> "/settings/rename"},
                 {:get, integration <> "/settings/remove"}
               ] ++
                 for(
                   rest <- ~w(/backlog /backlog/x1/take-in /work /work/1 /work/1/thread),
                   do: {:get, workspace_path(scope, rest)}
                 )
             )

    assert routes |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort() == Enum.sort(@modules)
  end

  describe "with the feature" do
    test "each page answers as a path that does not exist until it is built, to anyone", %{
      conn: conn,
      scope: scope,
      adapter: adapter
    } do
      for {:get, path, module} <- factory_routes(scope, adapter),
          module != ApiaryWeb.AdapterRedirectController do
        assert {404, _body, _headers} = answer(fn -> get(conn, path) end), path
      end
    end

    test "a live navigation to a page is refused the same way", %{
      conn: conn,
      scope: scope,
      adapter: adapter
    } do
      for {:get, path, module} <- factory_routes(scope, adapter),
          module != ApiaryWeb.AdapterRedirectController do
        {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")

        assert {%{status: 404, reason: "reload"}, _call} =
                 catch_exit(live_redirect(view, to: path)),
               path
      end
    end

    # An adapter is the instance's: the link names no organisation to lead to, so it is
    # not found, to every person, whatever it names, and answers the same for each.
    test "the link to an integration is not found, the same whatever it names",
         %{conn: conn, scope: scope, adapter: adapter} do
      %{user: member} = member_fixture(scope, :member)
      member_conn = log_in_user(build_conn(), member)
      admin_conn = log_in_user(build_conn(), instance_admin_scope().user)
      deleted = adapter_fixture()
      {:ok, _deleted} = Adapters.delete_adapter(instance_admin_scope(), deleted)

      for {who, asker, id} <- [
            {"an owner", conn, adapter.public_id},
            {"a member", member_conn, adapter.public_id},
            {"an instance admin", admin_conn, adapter.public_id},
            {"a deleted one", conn, deleted.public_id},
            {"none", conn, "na_doesnotexist"},
            {"not an adapter", conn, scope.workspace.slug}
          ] do
        assert {404, _body, _headers} = answer(fn -> get(asker, "/integrations/#{id}") end),
               who
      end
    end

    test "the link to an integration sends an anonymous visitor to log in", %{adapter: adapter} do
      assert build_conn() |> get(~p"/integrations/#{adapter}") |> redirected_to() ==
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

      # Nothing waits on anyone yet: no count beside Work items.
      refute has_element?(view, "#nav-work_items .q-nav-count")
      refute Map.has_key?(ApiaryWeb.UserAuth.nav_counts(scope), :waiting_on)
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

    test "the Activity filter offers the work item comments by their words, and no other action of the feature",
         %{conn: conn, scope: scope} do
      options = action_options(conn, scope)

      assert {"work_item.comment", "Work item comment added"} in options
      assert {"work_item.comment_delete", "Work item comment deleted"} in options

      offered = for {value, _words} <- options, do: String.to_existing_atom(value)

      for action <- Audit.audited_actions(),
          Apiary.Access.feature(action) == :factory,
          action not in [:"work_item.comment", :"work_item.comment_delete"],
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

    test "a live navigation to a page is refused the same way", %{
      conn: conn,
      scope: scope,
      adapter: adapter
    } do
      for {:get, path, module} <- factory_routes(scope, adapter),
          module != ApiaryWeb.AdapterRedirectController do
        {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")

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
      workspace_path(scope, "/backlog")
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
