defmodule ApiaryWeb.WorkspaceLive.OverviewTest do
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures
  import Apiary.Midnight

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Repo
  alias Apiary.Policy
  alias Apiary.Retention
  alias Apiary.Runs.{Liveness, Projector, Run}
  alias ApiaryWeb.Format

  # The hints of a lock where no rule can change what became of a request.
  @wall_own_address "The wall refused this, not a rule. A rule naming this exact host opens the machine's addresses to it; link-local addresses never open."
  @wall_host_form "The wall refused this, not a rule: no rule can name a host written this way."
  @wall_ambiguous_path "The wall refused this, not a rule: the request's path reads two ways. A request with a plain path gets through."
  @unnameable "No rule can name this host."

  setup :register_and_log_in_user

  # A workspace's set-up is finished: a link to it leads to its first page.
  setup do
    Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)
  end

  # The edition's words for who may lock, as `Apiary.EditionStubs.LockWorded` has them, on
  # a workspace whose set-up is finished.
  defmodule LockWordedFinished do
    @moduledoc false
    defdelegate who_may_sentence(about, scope), to: Apiary.EditionStubs.LockWorded
    defdelegate test_run_passed?(workspace), to: Apiary.EditionStubs.SetUpFinished
  end

  # No coalescing and no throttling here, so a broadcast is followed by its read as the
  # next message and no test waits on a clock.
  setup do
    Application.put_env(:apiary, ApiaryWeb.WorkspaceLive.Overview,
      coalesce: 0,
      announce: 0,
      quiet_tick: 3_600_000,
      refresh: 3_600_000
    )

    :ok
  end

  defp open(conn, scope) do
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
    render_async(view, 5_000)
    view
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&#39;", "'")
    |> String.replace("&quot;", "\"")
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\s+([,.;:])/, "\\1")
    |> String.trim()
  end

  defp as_member(%{scope: scope}) do
    %{user: member} = member_fixture(scope, :member)
    log_in_user(build_conn(), member)
  end

  # A node's key, made in a browser and active at once, on a node of its own unless `node` is given.
  defp node_key(scope, label, node \\ nil) do
    node = node || Apiary.NodesFixtures.node_fixture(scope)
    %{access_key: key} = node_key_fixture(scope, node, label: label)
    key
  end

  defp long_ago(%AccessKey{id: id}, days) do
    at = DateTime.add(DateTime.utc_now(), -days, :day)

    Repo.update_all(from(k in AccessKey, where: k.id == ^id),
      set: [inserted_at: at, received_at: at]
    )
  end

  defp lost_run(scope, attrs \\ %{}) do
    now = DateTime.utc_now()

    run_fixture(
      scope,
      Map.merge(
        %{
          state: "lost",
          about_title: "nightly-mirror",
          started_at: DateTime.add(now, -7200, :second),
          last_heartbeat_at: DateTime.add(now, -3600, :second),
          lost_at: DateTime.add(now, -3000, :second),
          elapsed_seconds: 510,
          heartbeat_interval_seconds: 30
        },
        attrs
      )
    )
  end

  test "has the page header, and links the lists whole: nothing carries a target here",
       %{conn: conn, scope: scope} do
    view = open(conn, scope)

    assert has_element?(view, "h1#page-header-title", scope.workspace.name)
    assert has_element?(view, "#nav-overview[aria-current='page']")
    assert has_element?(view, "#nav-runs[href='#{workspace_path(scope, "/runs")}']")
    assert has_element?(view, "#nav-network[href='#{workspace_path(scope, "/network")}']")
  end

  test "the breadcrumb ends with Overview, the page itself", %{conn: conn, scope: scope} do
    view = open(conn, scope)

    assert crumbs(view) == [{"Overview", nil}]
    assert has_element?(view, "#breadcrumb [aria-current=page]", "Overview")
  end

  describe "the empty workspace" do
    # Without the `factory` feature, whose set-up takes the box's place
    # (`ApiaryWeb.WorkspaceLive.OverviewSetupTest`).
    setup do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      Apiary.EditionStubs.HidesNamed.put([:factory])
    end

    @step_2_text "Run one command on the machine, or generate a key for a CI or another system."

    @two_ways "Two ways to connect a machine Connect with a command. For a laptop or a server you can open a terminal on: you run one command there, and the key's secret never leaves the machine. Generate a key in the browser. For a CI job, a pool, or a machine you can't type on: this page shows the key's secret once, and you copy it into that system. You choose one for each node, once you have added it."

    # The ids of step 2's buttons, in their order, and those shown as primary.
    defp ways(view) do
      doc = view |> element("#onboarding-ways") |> render() |> LazyHTML.from_fragment()

      {doc |> LazyHTML.query(".btn") |> LazyHTML.attribute("id"),
       doc |> LazyHTML.query(".btn-primary") |> LazyHTML.attribute("id")}
    end

    test "no node: the box is the page, step 1 current, leading to a new node, nothing else renders",
         %{conn: conn, scope: scope} do
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      assert html =~ scope.workspace.name

      assert html =~
               ~r{<title[^>]*>\s*#{Regex.escape(scope.workspace.name)} · #{Regex.escape(scope.organisation.name)} · Qory Apiary\s*</title>}

      # No filler under the title: the name says which workspace it is.
      refute html =~ "The workspace of the #{scope.organisation.name} organisation."
      refute html =~ ~r/<abbr[^>]*>(hive|apiary)<\/abbr>/

      assert has_element?(view, "#onboarding[data-step='1'] h2", "Send your first run")
      assert has_element?(view, "#onboarding .q-step-current", "Add a node")

      assert text(view, "#onboarding") =~
               "Nothing has posted to this workspace yet. A machine posts once it is connected to a node."

      assert has_element?(view, "#onboarding .q-steps li:nth-child(2)", "Connect it")
      assert text(view, "#onboarding") =~ @step_2_text
      refute text(view, "#onboarding") =~ "qory access-key create"
      refute text(view, "#onboarding") =~ ~r/approv/i

      assert has_element?(
               view,
               "#onboarding-new-node[href='#{workspace_path(scope, "/nodes/new")}']",
               "New node"
             )

      assert has_element?(
               view,
               "#onboarding-new-pool[href='#{workspace_path(scope, "/nodes/new-pool")}']",
               "New node pool"
             )

      refute has_element?(view, "#onboarding-nodes")
      refute has_element?(view, "#onboarding-members")
      refute has_element?(view, "#onboarding-pending")
      refute has_element?(view, "#onboarding-target")
      refute has_element?(view, "#onboarding-enrol")
      refute has_element?(view, "#onboarding-generate")
      refute has_element?(view, "#onboarding-members-key")

      # Beside the steps, the two ways explained, and no command: none is got yet.
      assert text(view, "#onboarding-panel") =~ @two_ways
      refute has_element?(view, "#onboarding-command")
      refute text(view, "#onboarding") =~ ~r/qec[a-z]?_/
      refute text(view, "#onboarding") =~ "enrolment code"

      assert has_element?(view, "#onboarding", "Listening for the first post from a machine.")
      # Nothing in it asks for a workspace key.
      refute text(view, "#onboarding") =~ "Create an access key"
      refute has_element?(view, "#onboarding-create")
      refute has_element?(view, "#onboarding a[href*='settings/keys']")
      refute has_element?(view, "#overview-strip")
      refute has_element?(view, "#days")
      refute has_element?(view, "#overview-policy")
      refute has_element?(view, "#overview-retention")
      refute has_element?(view, "#overview-keys")

      {:ok, _lv, html} =
        view
        |> element("#onboarding-new-node")
        |> render_click()
        |> follow_redirect(conn, workspace_path(scope, "/nodes/new"))

      assert html =~ "New node"
    end

    test "no node, a member: no buttons, who adds one instead", %{scope: scope} = ctx do
      view = open(as_member(ctx), scope)

      assert has_element?(view, "#onboarding[data-step='1']")

      assert has_element?(
               view,
               "#onboarding-members",
               "An owner or admin adds nodes and connects them."
             )

      assert text(view, "#onboarding") =~ @step_2_text
      refute has_element?(view, "#onboarding-new-node")
      refute has_element?(view, "#onboarding-new-pool")
      refute has_element?(view, "#onboarding-members-key")

      # The two ways are explained, but "you" choose nothing: an owner or admin does.
      assert text(view, "#onboarding-panel") =~ "Two ways to connect a machine"
      refute has_element?(view, "#onboarding-choose")
      refute text(view, "#onboarding") =~ "You choose one for each node"
    end

    test "a node, no key: step 2 current, both ways for the newest node, the command first", %{
      conn: conn,
      scope: scope
    } do
      pool_fixture(scope, %{name: "spot-runners"})
      node = node_fixture(scope, %{name: "build-01"})
      view = open(conn, scope)
      tab = workspace_path(scope, "/nodes/#{node.public_id}/access-key")

      assert has_element?(view, "#onboarding[data-step='2'] h2", "Send your first run")
      assert has_element?(view, "#onboarding .q-step-done", "Add a node")
      assert has_element?(view, "#onboarding .q-step-current", "Connect it")

      assert text(view, "#onboarding") =~
               "A node or pool is connected once it has a key. Qory Apiary keeps only the key's public half."

      assert text(view, "#onboarding") =~ @step_2_text

      # The newest node or pool with no key, its name linking to its Access key tab.
      assert text(view, "#onboarding-target") == "build-01 has no key yet."
      assert has_element?(view, "#onboarding-target a[href='#{tab}']", "build-01")

      # The panel asks how, the ways as rows, the command first and primary.
      assert text(view, "#onboarding-ask") == "How do you want to connect build-01?"
      assert ways(view) == {["onboarding-enrol", "onboarding-generate"], ["onboarding-enrol"]}

      assert text(view, "#onboarding-way-enrol") ==
               "Connect with a command For a laptop or a server you can open a terminal on. Get the command"

      assert text(view, "#onboarding-way-generate") ==
               "Generate a key in the browser For a CI job, a pool of short-lived machines, or a machine you can't type on. Generate a key"

      assert has_element?(
               view,
               "#onboarding-enrol[phx-click='get_command'][aria-label='Get the command for build-01']",
               "Get the command"
             )

      assert has_element?(
               view,
               "#onboarding-generate[href='#{tab}/generate'][aria-label='Generate a key for build-01']",
               "Generate a key"
             )

      refute has_element?(view, "#onboarding-nodes")
      refute has_element?(view, "#onboarding-members-key")
      refute has_element?(view, "#onboarding-new-node")
      refute has_element?(view, "#onboarding-pending")
      refute has_element?(view, "#onboarding-command")
      refute has_element?(view, "#overview-strip")
      refute has_element?(view, "#overview-targets")
      assert AccessKeys.list_enrolment_codes(scope, node) == []
    end

    test "Get the command shows the command in the box, once, in no address, flash, title or log",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, %{name: "build-01"})
      view = open(conn, scope)
      path = ~p"/#{scope.organisation}/#{scope.workspace}"
      server = ApiaryWeb.Endpoint.url()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          view |> element("#onboarding-enrol") |> render_click()
        end)

      [row] = AccessKeys.list_enrolment_codes(scope, node)
      command = text(view, "#onboarding-command")
      ["qory", "access-key", "enrol", ^server, code] = String.split(command, " ")

      assert code =~
               ~r/\A#{Regex.escape(Apiary.AccessKeys.EnrolmentCode.prefix(:node))}[0-9A-Z]{26}\./

      # The defaults, no question asked.
      refute row.allow_secrets
      assert is_nil(row.label_hint)

      assert has_element?(view, "#onboarding-command-copy", "Copy command")
      assert has_element?(view, "#onboarding-panel", "What you run on build-01")

      assert text(view, "#onboarding-works") ==
               "It works once, until #{ApiaryWeb.Format.time(row.expires_at)}. This is the only time it is shown."

      assert text(view, "#onboarding-waiting") =~ "Waiting for build-01 to run it."
      refute has_element?(view, "#onboarding-ways")

      # The test server is localhost: machines can't reach it, and the box says so.
      assert text(view, "#onboarding-unreachable") =~ "Machines can't reach this address."

      # Nowhere else: the address, the flash, the title, the log, the state as inspected.
      refute path =~ code
      refute view |> element("#flash-group") |> render() =~ code
      refute page_title(view) =~ code
      refute log =~ code
      deep = &inspect(&1, limit: :infinity, printable_limit: :infinity)
      refute deep.(:sys.get_state(view.pid)) =~ code
      refute deep.(:sys.get_status(view.pid)) =~ code

      # A second click makes no second command.
      render_hook(view, "get_command", %{"allow_secrets" => "true"})
      assert [_one] = AccessKeys.list_enrolment_codes(scope, node)
      assert text(view, "#onboarding-command") == command

      # Opened again, the box asks again: the command is not shown.
      {:ok, again, html} = live(conn, path)
      refute html =~ code
      refute has_element?(again, "#onboarding-command")
      assert has_element?(again, "#onboarding-enrol")
    end

    test "for a node behind the default gateway, the command goes through it, under its notice",
         %{conn: conn, scope: scope} do
      gateway_fixture(scope, name: "edge-01", url: "https://edge.example.com")
      node_fixture(scope, %{name: "build-01"})
      view = open(conn, scope)
      server = ApiaryWeb.Endpoint.url()

      view |> element("#onboarding-enrol") |> render_click()

      assert [
               "qory",
               "access-key",
               "enrol",
               "--via",
               "https://edge.example.com",
               ^server,
               _code
             ] = view |> text("#onboarding-command") |> String.split(" ")

      assert text(view, "#onboarding-gateway") ==
               "Runs of build-01 go through the gateway edge-01, at https://edge.example.com. edge-01 has no active access key, so it isn't connected."

      assert text(view, "#onboarding-via-ca") ==
               "If edge-01's certificate is signed by a private certificate authority, add --via-ca-file and that authority's PEM file."

      # The notice above the command, the line under it.
      html = view |> element("#onboarding-panel") |> render()
      [before, after_command] = String.split(html, ~s(id="onboarding-command"), parts: 2)
      assert before =~ ~s(id="onboarding-gateway")
      assert after_command =~ ~s(id="onboarding-via-ca")
    end

    test "a gateway URL a shell would act on is quoted in the box's command", %{
      conn: conn,
      scope: scope
    } do
      # The brackets of an IPv6 host are a pattern to some shells.
      url = "https://[2001:db8::1]:8443"
      gateway_fixture(scope, name: "edge-01", url: url)
      node_fixture(scope, %{name: "build-01"})
      view = open(conn, scope)
      view |> element("#onboarding-enrol") |> render_click()

      assert text(view, "#onboarding-command") =~
               ~r/\Aqory access-key enrol --via 'https:\/\/\[2001:db8::1\]:8443' #{Regex.escape(ApiaryWeb.Endpoint.url())} #{Regex.escape(Apiary.AccessKeys.EnrolmentCode.prefix(:node))}/
    end

    test "for a node that goes direct, the command carries no --via and no gateway line", %{
      conn: conn,
      scope: scope
    } do
      gateway_fixture(scope, name: "edge-01", url: "https://edge.example.com")
      node_fixture(scope, %{name: "build-01", gateway_choice: "direct"})
      view = open(conn, scope)
      server = ApiaryWeb.Endpoint.url()

      view |> element("#onboarding-enrol") |> render_click()

      assert ["qory", "access-key", "enrol", ^server, _code] =
               view |> text("#onboarding-command") |> String.split(" ")

      refute has_element?(view, "#onboarding-gateway")
      refute has_element?(view, "#onboarding-via-ca")
    end

    test "for a node on Default gateway while none is the default, the command is as for a direct one",
         %{conn: conn, scope: scope} do
      gateway = gateway_fixture(scope, name: "edge-01", url: "https://edge.example.com")
      node = node_fixture(scope, %{name: "build-01"})
      assert node.gateway_choice == :default

      Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^gateway.id),
        set: [default_gateway: false]
      )

      view = open(conn, scope)
      server = ApiaryWeb.Endpoint.url()
      view |> element("#onboarding-enrol") |> render_click()

      assert ["qory", "access-key", "enrol", ^server, _code] =
               view |> text("#onboarding-command") |> String.split(" ")

      refute has_element?(view, "#onboarding-gateway")
      refute has_element?(view, "#onboarding-via-ca")
    end

    test "the machine running the command moves the box on, and the command is gone", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, %{name: "build-01"})
      view = open(conn, scope)
      view |> element("#onboarding-enrol") |> render_click()
      code = text(view, "#onboarding-command") |> String.split(" ") |> List.last()

      %{access_key: key} = enrolled_key_fixture(scope, node)
      send(view.pid, {:key_enrolled, %{key_id: key.key_id, node_id: node.id}})

      assert has_element?(view, "#onboarding[data-step='3']")
      assert has_element?(view, "#onboarding .q-step-done", "Connect it")
      refute has_element?(view, "#onboarding-command")
      refute render(view) =~ code
      assert is_nil(:sys.get_state(view.pid).socket.assigns.command)
    end

    test "a command cancelled on the node's tab is let go, and the box asks again", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, %{name: "build-01"})
      view = open(conn, scope)
      view |> element("#onboarding-enrol") |> render_click()
      code = text(view, "#onboarding-command") |> String.split(" ") |> List.last()
      [row] = AccessKeys.list_enrolment_codes(scope, node)

      {:ok, _} = AccessKeys.cancel_code(scope, row)

      refute has_element?(view, "#onboarding-command")
      refute has_element?(view, "#onboarding-waiting")
      refute render(view) =~ code
      assert is_nil(:sys.get_state(view.pid).socket.assigns.command)
      assert has_element?(view, "#onboarding-enrol", "Get the command")
    end

    test "a command that expires is let go, and the box asks again", %{
      conn: conn,
      scope: scope
    } do
      node_fixture(scope, %{name: "build-01"})
      view = open(conn, scope)
      view |> element("#onboarding-enrol") |> render_click()
      code = text(view, "#onboarding-command") |> String.split(" ") |> List.last()
      %{code_id: code_id} = :sys.get_state(view.pid).socket.assigns.command

      send(view.pid, {:command_expired, code_id})

      refute has_element?(view, "#onboarding-command")
      refute render(view) =~ code
      assert has_element?(view, "#onboarding-enrol", "Get the command")
    end

    test "a member is refused Get the command, and nothing is made", %{scope: scope} = ctx do
      node = node_fixture(scope, %{name: "build-01"})
      view = open(as_member(ctx), scope)

      refute has_element?(view, "#onboarding-enrol")
      render_hook(view, "get_command", %{})

      assert view |> element("#flash-group") |> render() =~
               "Only owners and admins connect a node."

      refute has_element?(view, "#onboarding-command")
      assert AccessKeys.list_enrolment_codes(scope, node) == []
    end

    test "a pool, no key: generating its key comes first and primary", %{
      conn: conn,
      scope: scope
    } do
      node_fixture(scope, %{name: "build-01"})
      pool = pool_fixture(scope, %{name: "spot-runners"})
      view = open(conn, scope)
      tab = workspace_path(scope, "/nodes/#{pool.public_id}/access-key")

      assert text(view, "#onboarding-target") == "spot-runners has no key yet."
      assert has_element?(view, "#onboarding-target a[href='#{tab}']", "spot-runners")

      assert ways(view) ==
               {["onboarding-generate", "onboarding-enrol"], ["onboarding-generate"]}

      assert has_element?(
               view,
               "#onboarding-generate[href='#{tab}/generate'][aria-label='Generate a key for spot-runners']"
             )

      assert has_element?(
               view,
               "#onboarding-enrol[phx-click='get_command'][aria-label='Get the command for spot-runners']"
             )

      {:ok, _lv, html} =
        view
        |> element("#onboarding-generate")
        |> render_click()
        |> follow_redirect(conn, "#{tab}/generate")

      assert html =~ "Generate a key for spot-runners"
    end

    test "a node, no key, a member: who connects it, no way to do it, and Go to nodes",
         %{scope: scope} = ctx do
      node_fixture(scope, %{name: "build-01"})
      view = open(as_member(ctx), scope)

      assert has_element?(view, "#onboarding[data-step='2']")

      assert has_element?(
               view,
               "#onboarding-members-key",
               "An owner or admin connects build-01."
             )

      assert has_element?(
               view,
               "#onboarding-nodes[href='#{workspace_path(scope, "/nodes")}']",
               "Go to nodes"
             )

      refute has_element?(view, "#onboarding-target")
      refute has_element?(view, "#onboarding-enrol")
      refute has_element?(view, "#onboarding-generate")
      refute has_element?(view, "#onboarding a[href*='/access-key']")
      refute text(view, "#onboarding") =~ "You choose one for each node"
    end

    test "a node whose only key is revoked has no key: step 2, named", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, %{name: "build-01"})
      %{access_key: key} = node_key_fixture(scope, node, %{label: "build-01"})
      {:ok, _} = AccessKeys.revoke_access_key(scope, key)
      view = open(conn, scope)

      assert has_element?(view, "#onboarding[data-step='2']")
      assert has_element?(view, "#onboarding .q-step-current", "Connect it")
      assert text(view, "#onboarding-target") == "build-01 has no key yet."
      assert ways(view) == {["onboarding-enrol", "onboarding-generate"], ["onboarding-enrol"]}
    end

    test "a gateway with a used key is not a node: the box reads as before, step 1 current",
         %{conn: conn, scope: scope} do
      gateway = gateway_fixture(scope, %{name: "edge-01"})
      %{access_key: key} = node_key_fixture(scope, gateway, %{label: "edge-01"})

      {:ok, _} =
        AccessKeys.touch(key, %{last_forager_version: "v0.4.2", last_contract_version: 1})

      view = open(conn, scope)

      assert has_element?(view, "#onboarding[data-step='1']")
      assert has_element?(view, "#onboarding .q-step-current", "Add a node")
      refute has_element?(view, "#onboarding .q-step-done")
      refute text(view, "#onboarding") =~ "The machine has verified with its key."
      refute text(view, "#onboarding") =~ "edge-01"
      refute has_element?(view, "#onboarding-target")
      assert has_element?(view, "#onboarding-new-node")
    end

    test "a gateway with no key is never the node to connect", %{conn: conn, scope: scope} do
      node = node_fixture(scope, %{name: "build-01"})
      gateway_fixture(scope, %{name: "edge-01"})
      view = open(conn, scope)

      assert has_element?(view, "#onboarding[data-step='2']")
      assert text(view, "#onboarding-target") == "build-01 has no key yet."
      refute text(view, "#onboarding") =~ "edge-01"

      # Once the node holds a key, a key-less gateway brings no step 2 back.
      node_key_fixture(scope, node, %{label: "build-01"})
      view = open(conn, scope)

      assert has_element?(view, "#onboarding[data-step='3']")
      refute has_element?(view, "#onboarding-target")
    end

    test "a key a command brought ticks step 2: it is active as it arrives", %{
      conn: conn,
      scope: scope
    } do
      pool = pool_fixture(scope, %{name: "spot-runners"})
      enrolled_key_fixture(scope, pool, %{label: "spot-a"})
      view = open(conn, scope)

      assert has_element?(view, "#onboarding[data-step='3']")
      assert has_element?(view, "#onboarding .q-step-done", "Connect it")
      refute has_element?(view, "#onboarding-pending")
      refute text(view, "#onboarding") =~ ~r/approv/i
    end

    test "a key, unused: step 2 done, step 3 current, listening for the first post",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, %{name: "build-01"})
      node_key_fixture(scope, node, %{label: "build-01"})

      # Another node with no key does not bring step 2's ways back.
      node_fixture(scope, %{name: "build-02"})
      view = open(conn, scope)

      assert has_element?(view, "#onboarding[data-step='3']")
      assert has_element?(view, "#onboarding .q-step-done", "Connect it")
      assert has_element?(view, "#onboarding .q-step-current", "See runs here")

      assert text(view, "#onboarding") =~
               "From the first post on, every run of that machine lands in this workspace."

      # The command is spent: the panel is the listening line alone.
      refute text(view, "#onboarding") =~ "What you ran on the machine"
      refute has_element?(view, "#onboarding-command")
      assert has_element?(view, "#onboarding-nodes", "Go to nodes")
      refute has_element?(view, "#onboarding-target")
      refute has_element?(view, "#onboarding-ways")
      refute has_element?(view, "#onboarding-members-key")
      assert has_element?(view, "#onboarding", "Listening for the first post from a machine.")
    end

    test "a key was used, no run yet: step 3 current, listening for the run", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, %{name: "build-01"})
      %{access_key: key} = node_key_fixture(scope, node, %{label: "build-01"})

      {:ok, _} =
        AccessKeys.touch(key, %{last_forager_version: "v0.4.2", last_contract_version: 1})

      view = open(conn, scope)

      assert has_element?(view, "#onboarding[data-step='3']")
      assert has_element?(view, "#onboarding .q-step-current", "See runs here")
      assert text(view, "#onboarding") =~ "The machine has verified with its key."
      assert text(view, "#onboarding") =~ "Listening for the first run. build-01 verified"
    end

    test "the box reads its steps again on the refresh", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      assert has_element?(view, "#onboarding[data-step='1']")

      node = node_fixture(scope, %{name: "build-01"})
      send(view.pid, :refresh)
      assert has_element?(view, "#onboarding[data-step='2']")

      node_key_fixture(scope, node)
      send(view.pid, :refresh)
      assert has_element?(view, "#onboarding[data-step='3']")
    end

    test "the first run lands: step 3 ticks, the box stays with a link, and leaves on the next mount",
         %{conn: conn, scope: scope} do
      node_fixture(scope, %{name: "build-01"})
      view = open(conn, scope)
      assert has_element?(view, "#onboarding[data-step='2']")

      run = run_fixture(scope)
      event_fixture(run, 2, "run.started", started_data(), time: DateTime.utc_now())
      {:ok, _} = Projector.project(run)
      render_async(view, 5_000)

      assert has_element?(view, "#onboarding[data-step='4']")
      assert has_element?(view, "#onboarding .q-step-done", "See runs here")

      assert has_element?(
               view,
               "#onboarding-landed a[href='#{workspace_path(scope, "/runs/#{run.public_id}")}']",
               "Open it"
             )

      refute has_element?(view, "#onboarding", "Listening")
      assert has_element?(view, "#overview-strip")
      assert has_element?(view, "#overview-guard")

      view = open(conn, scope)
      refute has_element?(view, "#onboarding")
      assert has_element?(view, "#overview-strip")
    end
  end

  describe "the nodes hidden from the reader" do
    # Without the `factory` feature, whose set-up takes the box's place
    # (`ApiaryWeb.WorkspaceLive.OverviewSetupTest`).
    setup do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      Apiary.EditionStubs.HidesNamed.put([:factory])
    end

    test "the empty workspace has no box, only the line under it", %{conn: conn, scope: scope} do
      node_fixture(scope, name: "build-01")
      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes, :factory])
      view = open(conn, scope)

      refute has_element?(view, "#onboarding")
      refute has_element?(view, "#onboarding-new-node")
      refute has_element?(view, "#onboarding-nodes")
      refute render(view) =~ "/nodes"
      refute render(view) =~ "Send your first run"

      assert text(view, ".q-onb-after") =~ "fill in once the first run lands"
    end

    test "Get the command asked anyway reads the scope again, and says nothing", %{
      conn: conn,
      scope: scope
    } do
      node_fixture(scope, name: "build-01")
      :ok = Apiary.EditionStubs.HidesNamed.put([:factory])
      view = open(conn, scope)
      assert has_element?(view, "#onboarding-enrol")

      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes, :factory])
      render_click(view, "get_command", %{})

      refute has_element?(view, "#onboarding")
      refute render(view) =~ "Only owners and admins connect a node."
      refute render(view) =~ "Nothing was changed."
      assert Apiary.Repo.aggregate(Apiary.AccessKeys.EnrolmentCode, :count) == 0

      # Asked again, with the box gone, nothing is said either.
      render_click(view, "get_command", %{})
      refute render(view) =~ "Only owners and admins connect a node."
    end

    test "hidden while the page is open, an idle key's row leaves, not struck", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop())
      # A lost run keeps the list, and its count, once the idle key leaves.
      lost_run(scope)
      idle = node_key(scope, "old-runner")
      long_ago(idle, 34)
      :ok = Apiary.EditionStubs.HidesNamed.put([:factory])
      view = open(conn, scope)
      assert has_element?(view, "#att-key-#{idle.id}")
      shown = String.to_integer(text(view, "#attention-n"))

      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes, :factory])
      send(view.pid, {:membership_changed, :level})

      refute has_element?(view, "#att-key-#{idle.id}")
      assert String.to_integer(text(view, "#attention-n")) == shown - 1
      refute render(view) =~ "Revoked."
      refute render(view) =~ "/nodes"
    end

    test "shown again, the box is back", %{conn: conn, scope: scope} do
      :ok = Apiary.EditionStubs.HidesNamed.put([:factory])
      view = open(conn, scope)

      assert has_element?(view, "#onboarding[data-step='1']")
      assert has_element?(view, "#onboarding-new-node")
    end

    @tag needs: :security
    test "To review leads nowhere on the nodes page, and to the Policy page for a policy item",
         %{conn: conn, scope: scope} do
      idle = node_key(scope, "old-runner")
      long_ago(idle, 34)

      started_run(scope, shop(),
        egress: [
          %{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""},
          %{"host" => "bin.paste.example", "decision" => "denied", "rule" => ""}
        ]
      )

      # An allow rule under observe, with a run this week: the enforce nudge, the sixth.
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example.com"})
      lost_run(scope)
      started_run(scope, shop(), heartbeat: {45, 100, 30})
      started_run(scope, shop(), heartbeat: {45, 100, 30})

      # Shown the nodes, the list overflows from the enforce nudge, then the idle key.
      :ok = Apiary.EditionStubs.HidesNamed.put([:factory])

      assert has_element?(
               open(conn, scope),
               "#attention-more[href='#{workspace_path(scope, "/policy")}'][title='2 more items, on the Policy page']",
               "and 2 more"
             )

      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes, :factory])
      view = open(conn, scope)

      assert text(view, "#attention-n") == "5"

      assert has_element?(
               view,
               "#attention-more[href='#{workspace_path(scope, "/policy")}'][title='1 more item, on the Policy page']",
               "and 1 more"
             )

      refute has_element?(view, "#att-key-#{idle.id}")
      refute render(view) =~ "/nodes"
    end

    @tag needs: :security
    test "a policy item first in the overflow has no link once the policy is hidden", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop(),
        egress: [
          %{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""},
          %{"host" => "bin.paste.example", "decision" => "denied", "rule" => ""}
        ]
      )

      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example.com"})
      lost_run(scope)
      started_run(scope, shop(), heartbeat: {45, 100, 30})
      started_run(scope, shop(), heartbeat: {45, 100, 30})

      :ok = Apiary.EditionStubs.HidesNamed.put([:factory])
      view = open(conn, scope)
      assert has_element?(view, "#attention-more[href='#{workspace_path(scope, "/policy")}']")

      # The policy is hidden from the reader while the page is open: once the scope is read
      # again and the list weighed again, the link goes.
      :ok = Apiary.EditionStubs.HidesNamed.put([:security, :factory])
      send(view.pid, {:membership_changed, :level})
      send(view.pid, :quiet_tick)

      assert text(view, "#attention-n") == "5"
      refute has_element?(view, "#attention-more")
    end

    @tag needs: :security
    test "an idle key first in the overflow leads to the nodes page, and nowhere once they are hidden",
         %{conn: conn, scope: scope} do
      idle = node_key(scope, "old-runner")
      long_ago(idle, 34)

      started_run(scope, shop(),
        egress: [
          %{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""},
          %{"host" => "bin.paste.example", "decision" => "denied", "rule" => ""}
        ]
      )

      # Enforce, the default: no policy item, so the idle key is the sixth.
      {:ok, _} = Policy.set_mode(scope, "enforce")
      lost_run(scope)
      started_run(scope, shop(), heartbeat: {45, 100, 30})
      started_run(scope, shop(), heartbeat: {45, 100, 30})

      :ok = Apiary.EditionStubs.HidesNamed.put([:factory])

      assert has_element?(
               open(conn, scope),
               "#attention-more[href='#{workspace_path(scope, "/nodes?sort=seen")}'][title='1 more item, on the nodes page']",
               "and 1 more"
             )

      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes, :factory])
      view = open(conn, scope)

      assert text(view, "#attention-n") == "5"
      refute has_element?(view, "#attention-more")
      refute render(view) =~ "/nodes"
    end
  end

  describe "the activity" do
    test "the summary counts the runs, the ended badly and the denials; the cost is a caption",
         %{conn: conn, scope: scope} do
      started_run(scope, shop(),
        exit: %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 10}
      )

      started_run(scope, shop(),
        exit: %{"state" => "failed", "exit_code" => 1, "duration_ms" => 10}
      )

      started_run(scope, shop(),
        egress: [%{"host" => "ads.example", "decision" => "denied", "rule" => ""}]
      )

      # Another workspace counts for nothing here.
      started_run(scope_fixture(), shop())

      view = open(conn, scope)

      assert text(view, "#overview-strip-alive .q-sum-v") == "1"
      assert text(view, "#overview-strip-runs .q-sum-v") == "3"
      assert text(view, "#overview-strip-runs") =~ "1 ended well"
      assert text(view, "#overview-strip-bad .q-sum-v") == "1"
      assert text(view, "#overview-strip-bad") =~ "33% of the runs"
      assert text(view, "#overview-strip-denied .q-sum-v") == "1"
      assert text(view, "#overview-strip-denied") =~ "to 1 destination"
      refute has_element?(view, "#activity-cost")
      refute text(view, "#activity-foot") =~ "UTC"

      costed = run_fixture(scope)
      event_fixture(costed, 2, "run.started", started_data(), time: DateTime.utc_now())
      event_fixture(costed, 3, "runtime.result", %{"outcome" => "success", "cost_usd" => 0.8412})
      {:ok, _} = Projector.project(costed)
      render_async(view, 5_000)

      assert text(view, "#activity-cost") =~ "Cost reported: $0.84, by 1 of the 4 runs."
    end

    test "the chart and the active targets read the same record", %{
      conn: conn,
      scope: scope
    } do
      # The page's today is the clock's, on which a run a minute back is yesterday's for the
      # first minute after midnight UTC: the three start now, the quiet one after the
      # running one, which makes it the target's last run. They start and the page is read
      # clear of midnight, so the day does not turn between them.
      day = clear_of_midnight()
      running = started_run(scope, shop(), host: "build-01", ago: 0)
      quiet = started_run(scope, shop(), heartbeat: {45, 100, 30}, ago: 0)

      started_run(scope, %{},
        ago: 0,
        exit: %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 48_000}
      )

      view = open(conn, scope)

      assert text(view, "#overview-strip-alive .q-sum-v") == "2"
      assert text(view, "#overview-strip-alive") =~ "1 gone quiet"

      target = Repo.get!(Apiary.Runs.Target, running.target_id)
      # One target: the run without one is on the runs list only.
      assert text(view, "#overview-targets-list") =~ "acme/shop"
      refute text(view, "#overview-targets-list") =~ "github.example"
      assert text(view, "#active-#{target.id}") =~ "2 runs"
      # The last run is the quiet one: its word, in the colour of a quiet run.
      assert has_element?(view, "#active-#{target.id} .q-rs-quiet", "Running")
      assert quiet.target_id == target.id

      assert has_element?(
               view,
               "#active-#{target.id} a[href='#{workspace_path(scope, "/targets/#{target.public_id}")}']"
             )

      assert has_element?(view, "#overview-targets-all", "All 1 repository")

      assert has_element?(
               view,
               "#activity-all[href='#{workspace_path(scope, "/runs")}']",
               "All runs"
             )

      html = render(view)

      slots =
        html |> LazyHTML.from_document() |> LazyHTML.query("#days a[data-day]") |> Enum.to_list()

      assert length(slots) == 14
      today = Date.to_iso8601(day)

      assert has_element?(
               view,
               "#days a[data-day='#{today}'][href='#{workspace_path(scope, "/runs?from=#{today}&to=#{today}")}']"
             )

      assert has_element?(
               view,
               "#days a[data-day='#{today}'][aria-label*='Today: 3 runs (1 ended well, 0 cancelled, 2 alive or ended badly), 0 denied attempts']"
             )

      assert has_element?(view, "#days .q-col-runs.q-col-today")

      assert has_element?(
               view,
               "#days svg[aria-label*='3 runs and 0 denied attempts in 14 days; most runs on today, 3.']"
             )

      # The chart is drawn for the width the browser measured.
      render_hook(view, "chart_size", %{"width" => 503})
      assert has_element?(view, "#days svg[viewBox^='0 0 500 ']")

      # The table twin, then the chart again.
      view |> element("#days-toggle") |> render_click()
      assert has_element?(view, "#days-toggle[aria-pressed=true]", "As a chart")
      assert has_element?(view, "#days table th", "Ended well")
      assert has_element?(view, "#days-row-#{today} td", "Today")
      refute has_element?(view, "#days svg")
      render_hook(view, "chart_table", %{"on" => false})
      assert has_element?(view, "#days svg")
    end

    test "the tiles, the table and the spoken days count every state in its family, Cancelled apart",
         %{conn: conn, scope: scope} do
      # Today's runs start now, and the page is read clear of midnight, as above.
      clear_of_midnight()
      now = DateTime.utc_now()
      today = DateTime.to_date(now)
      yesterday = Date.add(today, -1)
      noon = DateTime.new!(yesterday, ~T[12:00:00.000000], "Etc/UTC")

      # Yesterday, every state that ends: two runs completed and three were cancelled.
      for state <- ~w(completed completed cancelled cancelled cancelled failed lost),
          do: run_fixture(scope, %{state: state, started_at: noon})

      for state <- ~w(pending running completed cancelled failed),
          do: run_fixture(scope, %{state: state, started_at: now})

      view = open(conn, scope)

      assert text(view, "#overview-strip-alive .q-sum-v") == "2"
      assert text(view, "#overview-strip-runs .q-sum-v") == "12"
      assert text(view, "#overview-strip-runs") =~ "3 ended well"
      # Failed and Lost: a cancelled run does not raise Ended badly.
      assert text(view, "#overview-strip-bad .q-sum-v") == "3"
      assert text(view, "#overview-strip-bad") =~ "25% of the runs"

      assert has_element?(view, "#overview-strip-bad[href*='state=failed%2Clost']")

      day = Date.to_iso8601(yesterday)

      assert has_element?(
               view,
               "#days a[data-day='#{day}'][aria-label^='#{Format.short_date(yesterday)}: 7 runs (2 ended well, 3 cancelled, 2 ended badly), 0 denied attempts, open that day']"
             )

      assert has_element?(
               view,
               "#days a[data-day='#{Date.to_iso8601(today)}'][aria-label^='Today: 5 runs (1 ended well, 1 cancelled, 3 alive or ended badly), 0 denied attempts']"
             )

      view |> element("#days-toggle") |> render_click()

      headings =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#days table th")
        |> Enum.map(&LazyHTML.text/1)

      assert headings == ["Day", "Runs", "Ended well", "Cancelled", "Denied attempts"]

      assert text(view, "#days-row-#{day}") == "#{Format.short_date(yesterday)} 7 2 3 0"

      assert text(view, "#days-row-#{Date.to_iso8601(today)}") == "Today 5 1 1 0"
    end

    test "the active targets are the eight with the most runs; a path on two systems names them",
         %{conn: conn, scope: scope} do
      for _ <- 1..3, do: started_run(scope, shop(), ago: 600)
      for _ <- 1..2, do: started_run(scope, shop("gitlab.example"), ago: 600)

      for n <- 1..8,
          do: started_run(scope, %{"forge" => "github.example", "repository" => "acme/t#{n}"})

      view = open(conn, scope)

      rows =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#overview-targets-list li")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&String.replace(&1, ~r/\s+/, " "))

      assert length(rows) == 8
      assert Enum.at(rows, 0) =~ "github.example/acme/shop"
      assert Enum.at(rows, 1) =~ "gitlab.example/acme/shop"
      assert Enum.at(rows, 2) =~ "acme/t1"
      refute Enum.at(rows, 2) =~ "github.example"

      # Each links to its page by its public id.
      for system <- ["github.example", "gitlab.example"] do
        target = Apiary.Targets.get(scope, system, "acme/shop")
        path = "/targets/#{target.public_id}"
        assert has_element?(view, "#active-#{target.id} a[href='#{workspace_path(scope, path)}']")
      end

      t1 = Apiary.Targets.get(scope, "github.example", "acme/t1")

      assert has_element?(
               view,
               "#active-#{t1.id} a[href='#{workspace_path(scope, "/targets/#{t1.public_id}")}']"
             )

      assert has_element?(view, "#overview-targets-all", "All 10 repositories")
    end

    test "with no run in the fortnight the chart has fourteen stubs and no target is active",
         %{conn: conn, scope: scope} do
      run_fixture(scope, %{
        state: "completed",
        started_at: DateTime.add(DateTime.utc_now(), -20, :day)
      })

      view = open(conn, scope)

      assert text(view, "#overview-strip-alive") =~ "none"
      html = render(view)

      assert html |> LazyHTML.from_document() |> LazyHTML.query("#days .q-stub") |> Enum.count() ==
               28

      assert has_element?(view, "#days.q-chart-empty")
      assert has_element?(view, "#overview-targets-none", "in the last 14 days")
    end

    test "the chart's days are the reader's: today is their day, not UTC's", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      # A zone whose day is not UTC's now, its midnight at least an hour away: fourteen hours
      # ahead from 11:00 UTC, twelve behind before it.
      now = DateTime.utc_now()
      zone = if now.hour >= 11, do: "Etc/GMT-14", else: "Etc/GMT+12"
      {:ok, _} = Apiary.Accounts.update_user_preferences(user, %{time_zone: zone})
      today = Apiary.Days.today(zone, now)
      refute today == DateTime.to_date(now)

      started_run(scope, shop(), ago: 0)
      view = open(conn, scope)

      days =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#days a[data-day]")
        |> LazyHTML.attribute("data-day")

      assert length(days) == 14
      assert List.last(days) == Date.to_iso8601(today)
      assert hd(days) == today |> Date.add(-13) |> Date.to_iso8601()

      assert has_element?(
               view,
               "#days a[data-day='#{today}'][aria-label^='Today: 1 run']"
             )
    end

    # The caption for denied destinations not counted is in `OverviewBudgetTest`, not
    # async: the cap it lowers is the node's, and here it would lower it for every test
    # running beside this one.
  end

  describe "guard" do
    @tag needs: :security
    test "policy: a new workspace, then a managed one with a version, own rules and hosts to review",
         %{conn: conn, scope: scope} do
      run = started_run(scope, shop())
      view = open(conn, scope)

      assert text(view, "#overview-policy-version") == "observe"

      assert text(view, "#overview-policy-mode") ==
               "Machines use their local policy until the first change here."

      assert has_element?(
               view,
               "#overview-policy-open[href='#{workspace_path(scope, "/policy")}']"
             )

      event_fixture(run, 20, "run.policy_applied", %{
        "harness_hosts" => ["registry.example", "cdn.example"]
      })

      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _} = Policy.set_mode(scope, "enforce")
      render_async(view, 5_000)

      assert text(view, "#overview-policy-version") == "enforce · v2"
      assert text(view, "#overview-policy-mode") =~ "In force since"
      assert text(view, "#overview-policy-mode") =~ "1 of 1 repository follow it."
      assert text(view, "#overview-policy-mode") =~ "2 declared hosts to review in 1 repository."
      assert text(view, "#overview-own") =~ "Every repository follows the workspace's mode."

      target = Repo.get!(Apiary.Runs.Target, run.target_id)
      {:ok, _} = Policy.set_mode(scope, target, "observe")
      render_async(view, 5_000)

      assert text(view, "#overview-own") =~ "acme/shop observes; the rest follow the workspace."
      refute text(view, "#overview-own") =~ "github.example"

      assert has_element?(
               view,
               "#overview-own a[href='#{workspace_path(scope, "/targets/#{target.public_id}/policy")}']",
               "acme/shop"
             )

      assert has_element?(
               view,
               "#overview-own-review[href='#{workspace_path(scope, "/policy/targets")}']"
             )
    end

    @tag needs: :security
    test "policy: a target with a mode of its own whose path another system has is named with its system",
         %{conn: conn, scope: scope} do
      run = started_run(scope, shop())
      started_run(scope, shop("gitlab.example"))
      target = Repo.get!(Apiary.Runs.Target, run.target_id)
      {:ok, _} = Policy.set_mode(scope, target, "enforce")

      view = open(conn, scope)

      assert text(view, "#overview-own") =~
               "github.example/acme/shop enforces; the rest follow the workspace."

      assert has_element?(
               view,
               "#overview-own a[href='#{workspace_path(scope, "/targets/#{target.public_id}/policy")}']"
             )
    end

    test "retention: the setting in a few words and the last prune", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      view = open(conn, scope)
      assert text(view, "#overview-retention-setting") == "Everything is kept"
      assert text(view, "#overview-retention-last") =~ "Nothing is pruned"

      # The row's action says what it does, like the row above it ("Review").
      assert has_element?(
               view,
               "#overview-retention-settings[href='#{workspace_path(scope, "/settings/runs")}']",
               "Change"
             )

      {:ok, _} =
        Retention.update_retention(scope, %{
          "events_retention_days" => "90",
          "log_retention_days" => "30"
        })

      view = open(conn, scope)

      assert text(view, "#overview-retention-setting") == "30 days of log output"

      assert text(view, "#overview-retention-last") ==
               "No prune has run yet. The job runs every day."

      workspace = Apiary.Repo.get!(Apiary.Organisations.Workspace, scope.workspace.id)
      %{runs_pruned: 0} = Retention.prune_workspace(workspace)
      # The day the prune finished, in the reader's zone (UTC here), whatever the clock says
      # by the time the page renders.
      [prune] = Retention.list_retention_runs(scope, 1)
      view = open(conn, scope)

      assert text(view, "#overview-retention-last") ==
               "Nothing was old enough to prune on #{Format.short_date(prune.finished_at)}."
    end

    test "retention: the last prune says its date, a prune of yesterday too", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop())
      {:ok, _} = Retention.update_retention(scope, %{"log_retention_days" => "30"})
      yesterday = DateTime.add(DateTime.utc_now(), -1, :day)

      prune = fn complete ->
        Repo.insert!(%Apiary.Retention.RetentionRun{
          organisation_id: scope.organisation.id,
          workspace_id: scope.workspace.id,
          trigger: "schedule",
          started_at: DateTime.add(yesterday, -60, :second),
          finished_at: yesterday,
          runs_pruned: 3,
          complete: complete
        })
      end

      date = Format.short_date(yesterday)
      run = prune.(true)
      assert text(open(conn, scope), "#overview-retention-last") == "#{date} pruned 3 runs."

      Repo.delete!(run)
      prune.(false)

      assert text(open(conn, scope), "#overview-retention-last") ==
               "#{date} pruned 3 runs; not finished, the next daily job goes on."
    end
  end

  describe "to review" do
    @tag needs: :security
    test "a locked rule's hover says who may change it: the core's words, or an edition's sentence after the rule",
         %{conn: conn, scope: scope} do
      started_run(scope, shop(),
        egress: [
          %{"host" => "bin.paste.example", "decision" => "denied", "rule" => "*.paste.example"}
        ]
      )

      {:ok, deny} = Policy.deny(scope, nil, %{host: "*.paste.example"})
      {:ok, _} = Policy.lock(scope, deny)

      title = fn ->
        conn
        |> open(scope)
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li[data-kind=denied] .q-ar-why")
        |> LazyHTML.attribute("title")
      end

      assert title.() == [
               "A locked workspace rule denies *.paste.example. Only an owner can change it."
             ]

      :ok = Apiary.Edition.put_test_stub(LockWordedFinished)
      sentence = Apiary.EditionStubs.LockWorded.sentence()
      assert title.() == ["A locked workspace rule denies *.paste.example. #{sentence}"]
    end

    @tag needs: :security
    test "is absent when there is nothing to do", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      {:ok, _} = Policy.set_mode(scope, "enforce")
      view = open(conn, scope)
      refute has_element?(view, "#attention")
      assert has_element?(view, "#overview-strip")
    end

    @tag needs: :security
    test "the kinds, in their order, bounded at five with the overflow linked", %{
      conn: conn,
      scope: scope
    } do
      idle = node_key(scope, "old-runner")
      long_ago(idle, 34)

      # Two denied destinations, one of them under a locked deny.
      started_run(scope, shop(),
        egress: [
          %{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""},
          %{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""},
          %{"host" => "bin.paste.example", "decision" => "denied", "rule" => "*.paste.example"}
        ]
      )

      {:ok, deny} = Policy.deny(scope, nil, %{host: "*.paste.example"})
      {:ok, _} = Policy.lock(scope, deny)
      # An allow rule under observe, with a run this week: the enforce nudge.
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example.com"})

      lost = lost_run(scope)
      quiet = started_run(scope, shop(), heartbeat: {45, 100, 30})

      view = open(conn, scope)

      assert text(view, "#attention-h") == "To review"
      assert text(view, "#attention-n") == "5"
      assert has_element?(view, "#attention-list[aria-label='5 items to review']")
      assert has_element?(view, "#attention-more", "and 1 more")

      assert has_element?(
               view,
               "#attention-more[href='#{workspace_path(scope, "/nodes?sort=seen")}'][title='1 more item, on the nodes page']"
             )

      kinds =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li")
        |> LazyHTML.attribute("data-kind")

      assert kinds == ~w(denied denied lost quiet enforce)

      denied = text(view, "#attention-list li[data-kind=denied]:first-child")
      assert denied =~ "files.cdn.example:443"
      assert denied =~ "acme/shop"
      assert denied =~ "Denied 2 times in 1 run"

      assert has_element?(
               view,
               "#attention-list li[data-kind=denied]:first-child button[aria-label='Allow files.cdn.example for acme/shop']",
               "Allow here"
             )

      locked = text(view, "#attention-list li[data-kind=denied]:nth-child(2)")
      assert locked =~ "bin.paste.example:443"
      assert locked =~ "Denied by a locked rule"

      assert has_element?(
               view,
               "#attention-list li[data-kind=denied]:nth-child(2) .q-ar-why[title='A locked workspace rule denies *.paste.example. Only an owner can change it.']"
             )

      assert has_element?(
               view,
               "#attention-list li[data-kind=denied]:nth-child(2) a",
               "Open the rule"
             )

      assert text(view, "#att-run-#{lost.public_id}") =~ "Lost, never posted its exit"

      assert has_element?(
               view,
               "#att-run-#{lost.public_id}-act[aria-label='Open nightly-mirror']",
               "Open"
             )

      assert has_element?(
               view,
               "#att-run-#{lost.public_id} a[href='#{workspace_path(scope, "/runs/#{lost.public_id}")}']",
               "nightly-mirror"
             )

      assert text(view, "#att-run-#{quiet.public_id}") =~ "No heartbeat for"

      assert has_element?(
               view,
               "#att-run-#{quiet.public_id} .q-ar-why[title='Heartbeats are due every 30 s; after 1 m 30 s of silence it is marked lost.']"
             )

      assert has_element?(
               view,
               "#att-run-#{quiet.public_id}-act[href='#{workspace_path(scope, "/runs/#{quiet.public_id}")}']",
               "Open"
             )

      # The idle key is the sixth: on the nodes page, not on this list.
      refute has_element?(view, "#att-key-#{idle.id}")
    end

    @tag needs: :security
    test "a policy item first in the overflow links to the Policy page", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop(),
        egress: [
          %{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""},
          %{"host" => "bin.paste.example", "decision" => "denied", "rule" => ""}
        ]
      )

      # No rule yet, with runs: the policy is unmanaged, the sixth item.
      lost_run(scope)
      started_run(scope, shop(), heartbeat: {45, 100, 30})
      started_run(scope, shop(), heartbeat: {45, 100, 30})

      view = open(conn, scope)

      assert has_element?(
               view,
               "#attention-more[href='#{workspace_path(scope, "/policy")}'][title='1 more item, on the Policy page']",
               "and 1 more"
             )
    end

    @tag needs: :security
    test "a run behind a shared target's policy compares at the target's own address", %{
      conn: conn,
      scope: scope
    } do
      run = started_run(scope, shop(), ago: 0)
      # Another system has the path: the target's address keeps its system.
      started_run(scope, shop("gitlab.example"), ago: 0)
      {:ok, target} = Policy.get_target(scope, Repo.get!(Run, run.id).target_id)
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      {:ok, _} = Policy.set_mode(scope, "enforce")
      {:ok, _} = Policy.allow(scope, target, %{host: "one.example"})
      {:ok, old} = Policy.current_configuration(scope, target)
      {:ok, _} = Policy.allow(scope, target, %{host: "two.example"})
      {:ok, new} = Policy.current_configuration(scope, target)

      # In force long enough for a run still on the one before to be behind.
      Repo.update_all(
        from(c in Apiary.Policy.RunConfiguration, where: c.id == ^new.id),
        set: [rendered_at: DateTime.add(DateTime.utc_now(), -600, :second)]
      )

      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [reported_run_configuration_digest: old.digest]
      )

      view = open(conn, scope)

      compare =
        target_page_path(
          scope,
          "github.example",
          "acme/shop",
          "/policy/versions/#{new.version}?compare=#{old.version}"
        )

      assert has_element?(
               view,
               ~s(#att-run-#{run.public_id}-act[href="#{compare}"]),
               "What changed"
             )
    end

    @tag needs: :security
    test "a run given an image compares by the policy it was composed from", %{
      conn: conn,
      scope: scope
    } do
      image = "registry.example.com/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)
      current = started_run(scope, shop(), ago: 0)
      behind = started_run(scope, shop(), ago: 0)
      {:ok, target} = Policy.get_target(scope, Repo.get!(Run, current.id).target_id)
      {:ok, _} = Policy.allow(scope, target, %{host: "one.example"})
      {:ok, old} = Policy.current_configuration(scope, target)
      {:ok, _} = Policy.allow(scope, target, %{host: "two.example"})
      {:ok, new} = Policy.current_configuration(scope, target)

      Repo.update_all(
        from(c in Apiary.Policy.RunConfiguration, where: c.id == ^new.id),
        set: [rendered_at: DateTime.add(DateTime.utc_now(), -600, :second)]
      )

      composed = fn configuration ->
        {:ok, row} =
          Apiary.Policy.ComposedConfiguration.serve(
            scope.organisation.id,
            scope.workspace.id,
            configuration,
            image,
            false
          )

        row.digest
      end

      for {run, configuration} <- [{current, new}, {behind, old}] do
        Repo.update_all(from(r in Run, where: r.id == ^run.id),
          set: [
            configured_image: image,
            reported_run_configuration_digest: composed.(configuration)
          ]
        )
      end

      view = open(conn, scope)

      # The run on the policy in force, with its image, is behind nothing.
      refute has_element?(view, "#att-run-#{current.public_id}-act")

      compare =
        target_page_path(
          scope,
          "github.example",
          "acme/shop",
          "/policy/versions/#{new.version}?compare=#{old.version}"
        )

      assert has_element?(
               view,
               ~s(#att-run-#{behind.public_id}-act[href="#{compare}"]),
               "What changed"
             )
    end

    @tag needs: :security
    test "a run whose start was kept compares by the policy its reload was composed from", %{
      conn: conn,
      scope: scope
    } do
      run = started_run(scope, shop(), ago: 0)
      {:ok, target} = Policy.get_target(scope, Repo.get!(Run, run.id).target_id)
      {:ok, _} = Policy.allow(scope, target, %{host: "one.example"})
      {:ok, current} = Policy.current_configuration(scope, target)

      # A version whose policy names an image, written as it is: the run, which started in
      # no image, is given it without the image.
      naming =
        String.replace(
          current.document,
          ~s(]}}),
          ~s(]},"image":"with-docker"}),
          global: false
        )

      assert Apiary.Policy.ComposedConfiguration.policy_image(naming) == "with-docker"

      newer =
        Repo.insert!(%Apiary.Policy.RunConfiguration{
          organisation_id: scope.organisation.id,
          workspace_id: scope.workspace.id,
          target_id: target.id,
          version: current.version + 1,
          document: naming,
          digest: Apiary.Policy.Render.digest(naming),
          rendered_at: DateTime.add(DateTime.utc_now(), -600, :second)
        })

      {:ok, row} =
        Apiary.Policy.ComposedConfiguration.serve(
          scope.organisation.id,
          scope.workspace.id,
          newer,
          :none,
          false,
          true
        )

      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [started_image_from: "none", reported_run_configuration_digest: row.digest]
      )

      view = open(conn, scope)
      refute has_element?(view, "#att-run-#{run.public_id}-act")
    end

    @tag needs: :security
    test "the policy items: unmanaged with runs, enforce for an owner, open policy for a member",
         %{conn: conn, scope: scope} = ctx do
      started_run(scope, shop())
      view = open(conn, scope)

      assert text(view, "#att-policy-unmanaged") =~ "Qory Apiary serves no policy yet"

      assert text(view, "#att-policy-unmanaged") =~ "1 run under the machines' policies"

      assert has_element?(
               view,
               "#att-policy-unmanaged-act[href='#{workspace_path(scope, "/policy")}']",
               "Open policy"
             )

      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example.com"})
      render_async(view, 5_000)
      assert text(view, "#att-policy-unmanaged") =~ "Qory Apiary serves the policy now."
      assert has_element?(view, "#att-policy-unmanaged.q-resolved")

      assert text(view, "#att-policy-enforce") =~ "Observe is the workspace's default"

      assert text(view, "#att-policy-enforce") =~ "Enforce would deny nothing today"

      assert has_element?(
               view,
               "#att-policy-enforce-act[href='#{workspace_path(scope, "/policy?confirm=enforce")}']",
               "Set to enforce"
             )

      member = as_member(ctx)
      view = open(member, scope)

      assert has_element?(
               view,
               "#att-policy-enforce .q-ar-why[title='Only an owner or an admin sets a mode.']"
             )

      assert has_element?(
               view,
               "#att-policy-enforce-act[href='#{workspace_path(scope, "/policy")}']",
               "Open policy"
             )

      refute has_element?(view, "#att-policy-enforce", "Set the default")

      # Something uncovered: review, not a one-click switch.
      started_run(scope, shop(),
        egress: [%{"host" => "new.example", "decision" => "allowed", "rule" => ""}]
      )

      view = open(conn, scope)

      assert text(view, "#att-policy-enforce") =~ "Enforce would deny 1 destination"

      assert has_element?(
               view,
               "#att-policy-enforce-act[href='#{workspace_path(scope, "/policy")}']",
               "Review"
             )
    end

    test "an idle node key names its label and node, and links to the node's revoke confirm",
         %{conn: conn, scope: scope} do
      started_run(scope, shop())
      node = Apiary.NodesFixtures.node_fixture(scope, %{name: "build-01"})
      idle = node_key(scope, "old-runner", node)
      long_ago(idle, 34)
      fresh = node_key(scope, "build-02", node)
      {:ok, _} = AccessKeys.touch(fresh, %{last_forager_version: "v0.4.1"})
      # A key a code brought is weighed too, from when it arrived.
      %{access_key: enrolled} =
        enrolled_key_fixture(scope, Apiary.NodesFixtures.node_fixture(scope))

      long_ago(enrolled, 40)

      view = open(conn, scope)
      assert text(view, "#att-key-#{idle.id}") =~ "old-runner #{idle.key_id}"
      assert text(view, "#att-key-#{idle.id}") =~ "build-01"
      assert text(view, "#att-key-#{idle.id}") =~ "Never used in 34 days"

      revoke =
        workspace_path(scope, "/nodes/#{node.public_id}/access-key/keys/#{idle.key_id}/revoke")

      assert has_element?(
               view,
               "#att-key-#{idle.id}-act[href='#{revoke}'][aria-label='Revoke old-runner']",
               "Revoke"
             )

      refute has_element?(view, "#att-key-#{fresh.id}")
      assert text(view, "#att-key-#{enrolled.id}") =~ "Never used in 40 days"

      # A member may not revoke a node's key: the list, which holds acts, has no item for it.
      %{user: member} = member_fixture(scope, :member)
      view = open(log_in_user(build_conn(), member), scope)
      refute has_element?(view, "#att-key-#{idle.id}")
    end

    test "a lost run offers Open, never Close",
         %{conn: conn, scope: scope} do
      runs =
        for n <- 0..1 do
          lost_run(scope, %{about_title: "nightly-mirror-#{n}"})
        end

      view = open(conn, scope)

      for run <- runs do
        assert text(view, "#att-run-#{run.public_id}") =~ "Lost, never posted its exit"

        assert has_element?(
                 view,
                 "a#att-run-#{run.public_id}-act[aria-label='Open #{run.about_title}']" <>
                   "[href='#{workspace_path(scope, "/runs/#{run.public_id}")}']",
                 "Open"
               )

        refute has_element?(view, "button#att-run-#{run.public_id}-act")
      end

      refute render(view) =~ ~r/>\s*Close\s*</
      refute has_element?(view, "#close-run")
    end

    test "a lost run's tip says how it was lost: silent, never picked up, past its backstop, or ended silent",
         %{conn: conn, scope: scope} do
      now = DateTime.utc_now()
      ago = &DateTime.add(now, -&1, :second)
      # Far enough back for a backstop of 87,300 s to have passed.
      issued = ago.(100_000)
      attach_by = DateTime.add(issued, 600, :second)
      attached = ago.(99_000)

      silent =
        "Nothing was heard for three heartbeat intervals. The run may still be going; the record is not."

      never =
        "It never started: its gateway did not pick it up in the time it was given, and now it can't."

      backstop = fn word ->
        "Qory Apiary received no exit within #{word} after the gateway took the run, so it marked the run lost. The run may still be running; only its exit changes this record now."
      end

      ended_silent =
        "Qory Apiary received nothing from the run for 10 minutes, so it marked the run lost and freed its slot. The run may still be running; only its exit changes this record now."

      gateway =
        now
        |> Apiary.DispatchedRunsFixtures.gateway_run_attrs()
        |> Map.merge(%{registered_at: issued, run_key_issued_at: issued, attach_by: attach_by})

      unattached =
        gateway
        |> Map.merge(Apiary.DispatchedRunsFixtures.unattached())
        |> Map.merge(%{
          state: "lost",
          started_at: nil,
          elapsed_seconds: nil,
          heartbeat_interval_seconds: nil
        })

      attached_with = fn seconds, lost_at ->
        Map.merge(gateway, %{
          state: "lost",
          attached_at: attached,
          backstop_at: DateTime.add(attached, seconds, :second),
          lost_at: lost_at
        })
      end

      for {attrs, tip} <- [
            # Lost to silence, with no run key.
            {%{}, silent},
            # Its run key issued, never attached, lost past its attach_by.
            {Map.put(unattached, :lost_at, DateTime.add(attach_by, 1, :second)), never},
            # Never attached, and lost at its attach_by or before it: not by that rule.
            {Map.put(unattached, :lost_at, attach_by), silent},
            {Map.put(unattached, :lost_at, DateTime.add(attach_by, -1, :second)), silent},
            # Past its backstop, in the minutes its attach gave it.
            {attached_with.(1200, DateTime.add(attached, 1201, :second)),
             backstop.("20 minutes")},
            {attached_with.(2700, DateTime.add(attached, 2701, :second)),
             backstop.("45 minutes")},
            {attached_with.(60, DateTime.add(attached, 61, :second)), backstop.("1 minute")},
            # In hours and minutes from 60 minutes on.
            {attached_with.(87_300, DateTime.add(attached, 87_301, :second)),
             backstop.("24 hours and 15 minutes")},
            {attached_with.(3600, DateTime.add(attached, 3601, :second)), backstop.("1 hour")},
            {attached_with.(7200, DateTime.add(attached, 7201, :second)), backstop.("2 hours")},
            {attached_with.(3660, DateTime.add(attached, 3661, :second)),
             backstop.("1 hour and 1 minute")},
            # Lost to silence before its backstop.
            {attached_with.(1200, DateTime.add(attached, 600, :second)), silent},
            {attached_with.(1200, DateTime.add(attached, 1200, :second)), silent},
            # Ended for 600 s of silence, which moved its backstop: lost at that end, as a
            # run of a long interval is, or lost by three intervals of 30 s before it, as
            # a run of the default interval is.
            {Map.put(
               attached_with.(4200, DateTime.add(attached, 4201, :second)),
               :silenced_at,
               DateTime.add(attached, 4201, :second)
             ), ended_silent},
            {Map.merge(attached_with.(4200, DateTime.add(attached, 3695, :second)), %{
               heartbeat_interval_seconds: 30,
               last_heartbeat_at: DateTime.add(attached, 3600, :second),
               silenced_at: DateTime.add(attached, 4201, :second)
             }), ended_silent}
          ] do
        run = lost_run(scope, attrs)
        view = open(conn, scope)
        case_ = inspect(Map.take(attrs, [:attached_at, :backstop_at, :lost_at, :silenced_at]))

        assert text(view, "#att-run-#{run.public_id}") =~ "Lost, never posted its exit", case_

        assert view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#att-run-#{run.public_id} .q-ar-why")
               |> LazyHTML.attribute("title") == [tip],
               case_

        Repo.delete!(run)
      end
    end

    test "a run that ended Lost lists with its own words; Apiary's own Lost keeps its line",
         %{conn: conn, scope: scope} do
      own = lost_run(scope)

      silent =
        started_run(scope, shop(),
          about: %{"title" => "nightly-build"},
          exit: %{"state" => "failed", "reason" => "session_lost", "exit_code" => -1}
        )

      unrecorded =
        started_run(scope, shop(),
          about: %{"title" => "nightly-sync"},
          exit: %{"state" => "failed", "reason" => "gateway_lost", "exit_code" => -1}
        )

      assert %Run{state: "lost", lost_at: %DateTime{}} = Repo.reload!(silent)
      view = open(conn, scope)

      assert text(view, "#att-run-#{own.public_id}") =~ "Lost, never posted its exit"

      assert has_element?(
               view,
               "#att-run-#{own.public_id} .q-ar-why[title='Nothing was heard for three heartbeat intervals. The run may still be going; the record is not.']"
             )

      for {run, words} <- [
            {silent, "Lost, stopped responding"},
            {unrecorded, "Lost, end not recorded"}
          ] do
        assert has_element?(view, "#att-run-#{run.public_id}[data-kind=lost]", "Lost")
        assert text(view, "#att-run-#{run.public_id}") =~ words
        refute text(view, "#att-run-#{run.public_id}") =~ "never posted its exit"

        assert has_element?(
                 view,
                 ~s(#att-run-#{run.public_id} .q-ar-why[title="The run's end was not recorded; how it went is not known."])
               )
      end
    end

    test "a lost run whose title has nothing left to show is called as a run with no title is",
         %{conn: conn, scope: scope} do
      lost = lost_run(scope, %{about_title: "\u202E\u200B"})
      shown = ApiaryWeb.OverviewComponents.row_title(%{lost | about_title: nil})
      view = open(conn, scope)

      refute has_element?(view, "#att-run-#{lost.public_id} .q-ar-t > bdi")
      assert has_element?(view, "#att-run-#{lost.public_id} .q-ar-t", shown)
      assert has_element?(view, ~s(#att-run-#{lost.public_id}-act[aria-label="Open #{shown}"]))
    end

    test "a lost run's title is isolated, its bidi override dropped",
         %{conn: conn, scope: scope} do
      lost = lost_run(scope, %{about_title: "nightly\u202Erorrim"})
      view = open(conn, scope)

      assert has_element?(view, "#att-run-#{lost.public_id} .q-ar-t > bdi", "nightlyrorrim")
      # The label for a screen reader stays plain text.
      assert has_element?(
               view,
               ~s(#att-run-#{lost.public_id}-act[aria-label="Open nightlyrorrim"])
             )
    end

    test "a lost run whose heartbeats are sent late keeps its row until its exit arrives",
         %{conn: conn, scope: scope} do
      now = DateTime.utc_now()
      # Its heartbeats had set its clock offset, a second behind, before it was lost.
      lost = lost_run(scope, %{clock_offset_ms: 1000})
      view = open(conn, scope)
      assert has_element?(view, "#att-run-#{lost.public_id}[data-kind=lost]", "Lost")

      # The heartbeats of the hour it was lost for, sent now.
      for k <- 1..20 do
        event_fixture(
          lost,
          10 + k,
          "run.heartbeat",
          %{"elapsed_seconds" => 510 + 30 * k, "interval_seconds" => 30},
          time: DateTime.add(now, -3600 + 30 * k, :second),
          received_at: now
        )
      end

      assert {:ok, %Run{state: "lost"}} = Projector.project(lost)
      render_async(view, 5_000)
      assert has_element?(view, "#att-run-#{lost.public_id}[data-kind=lost]", "Lost")
      refute has_element?(view, "#att-run-#{lost.public_id}.q-resolved")

      event_fixture(
        lost,
        31,
        "run.exited",
        %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1},
        time: DateTime.add(now, -2900, :second),
        received_at: now
      )

      assert {:ok, %Run{state: "failed"}} = Projector.project(lost)
      refute has_element?(open(conn, scope), "#att-run-#{lost.public_id}")
    end

    @tag needs: :security
    test "a denied host is isolated, a tool's too, so a bidi override reorders nothing", %{
      conn: conn,
      scope: scope
    } do
      host = "evil\u202Elpmaxe.<script>"

      started_run(scope, shop(),
        egress: [
          %{"host" => host, "decision" => "denied", "rule" => ""},
          tool_invocation_data(%{
            "host" => host,
            "path_rule" => "",
            "decision" => "denied",
            "outcome" => "refused"
          })
        ]
      )

      view = open(conn, scope)
      selector = "#attention-list li[data-kind=denied]"

      # The page drops the override (`Apiary.ExternalText.line/1`) and isolates the rest.
      shown = "evillpmaxe.<script>"
      assert has_element?(view, "#{selector} .q-host:not(.q-dest-tool) > bdi", shown)
      assert has_element?(view, "#{selector} .q-dest-tool .q-port > bdi", shown)
      html = render(view)

      assert html =~
               "<bdi>evillpmaxe.&lt;script&gt;</bdi><span class=\"q-port\">:443</span>"

      assert html =~
               "<span class=\"q-port\"><bdi>evillpmaxe.&lt;script&gt;</bdi>:443</span>"

      refute html =~ "elpmaxe.<script>"
    end

    @tag needs: :security
    test "allow a denied destination here: the panel in place, the rule, the struck row", %{
      conn: conn,
      scope: scope
    } do
      run =
        started_run(scope, shop(),
          egress: [%{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""}]
        )

      view = open(conn, scope)

      [item] =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li[data-kind=denied]")
        |> LazyHTML.attribute("id")

      refute has_element?(view, "##{item}-act[aria-haspopup]")

      assert has_element?(
               view,
               "##{item}-act[aria-expanded=false][aria-controls='#{item}-panel']"
             )

      view |> element("##{item}-act") |> render_click()

      # In place, inside the item, not an overlay.
      assert has_element?(
               view,
               "li##{item} > ##{item}-panel > #rule-panel[role=group][data-anchor='#{item}-act']"
             )

      refute has_element?(view, "#rule-panel[popover], #rule-panel[role=dialog]")
      assert has_element?(view, "##{item}-act[aria-expanded=true]")
      assert has_element?(view, "#rule-panel", "files.cdn.example")
      assert has_element?(view, "#rule-panel-submit", "Allow for the repository")
      # The target is named by its path, with its system where another system shares the
      # path: here no other system has it.
      assert text(view, "#rule-panel-target") =~ "acme/shop · 1 run"
      refute text(view, "#rule-panel-target") =~ "github.example"
      # The one target is chosen, so its option takes the focus.
      assert has_element?(view, "#rule-panel input[value=target][checked][data-autofocus]")

      # Cancel closes it; the act opens it again.
      view |> element("#rule-panel-cancel") |> render_click()
      refute has_element?(view, "##{item}-panel")
      assert has_element?(view, "##{item}-act[aria-expanded=false]")
      view |> element("##{item}-act") |> render_click()

      view |> element("#rule-panel form") |> render_submit()

      target = Repo.get!(Apiary.Runs.Target, run.target_id)

      assert [%{host: "files.cdn.example", action: "allow"}] =
               Policy.list_rules(scope, target)

      refute has_element?(view, "#rule-panel")
      assert has_element?(view, "##{item}.q-resolved .q-mark-ok")
      assert has_element?(view, "##{item}-done", "Allowed here")

      assert text(view, "#overview-announcer") =~ "files.cdn.example is allowed for acme/shop."

      # The policy topic re-reads the list: the struck row stays where it is, and the
      # workspace is managed now, so the unmanaged item resolves in words too. A target's
      # rule is no allow rule of the workspace: no enforce nudge.
      render_async(view, 5_000)
      assert has_element?(view, "##{item}.q-resolved")
      assert has_element?(view, "#att-policy-unmanaged.q-resolved")
      refute has_element?(view, "#att-policy-enforce")
      assert text(view, "#attention-n") == "0"
    end

    @tag needs: :security
    test "a request a path rule refused is a denied request to its tool", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop(),
        egress: [
          tool_invocation_data(%{
            "path" => "/media/acme/other/checkout.png",
            "path_rule" => "",
            "decision" => "denied",
            "outcome" => "refused"
          })
        ]
      )

      view = open(conn, scope)
      selector = "#attention-list li[data-kind=denied]"

      assert has_element?(view, "#{selector} .q-dest-tool .q-tool-name", "files")

      assert text(view, "#{selector} .q-dest-tool") ==
               "Tool files /media/acme/other/checkout.png files.tools.internal:443"

      assert has_element?(
               view,
               ~s(#{selector} .q-host[title="files.tools.internal:443/media/acme/other/checkout.png, a host the tool files serves"])
             )
    end

    @tag needs: :security
    test "a denial no rule can change offers a lock, its hover why: the wall's refusals and a host no rule can name",
         %{conn: conn, scope: scope} do
      started_run(scope, shop(),
        egress: [
          %{"host" => "Files.CDN.example.", "decision" => "denied", "rule" => "wall:host-form"},
          %{"host" => "metadata.internal", "decision" => "denied", "rule" => "wall:own-address"},
          %{
            "host" => "files.cdn.example",
            "path" => "/a/%2e%2e/b",
            "decision" => "denied",
            "rule" => "",
            "path_rule" => "wall:ambiguous-path"
          },
          %{"host" => "10.0.0.012", "decision" => "denied", "rule" => ""},
          %{"host" => "flags.example", "decision" => "denied", "rule" => ""}
        ]
      )

      view = open(conn, scope)

      items =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li[data-kind=denied]")
        |> Enum.map(&{&1 |> LazyHTML.attribute("id") |> hd(), LazyHTML.text(&1)})

      item = fn needle ->
        {id, _text} = Enum.find(items, fn {_id, text} -> text =~ needle end)
        id
      end

      # Each still shows, with no act: no Allow, and no rule to open; a faint lock where
      # Allow would be, its hover why.
      for {needle, tip} <- [
            {"Files.CDN.example.", @wall_host_form},
            {"metadata.internal", @wall_own_address},
            {"files.cdn.example", @wall_ambiguous_path},
            {"10.0.0.012", @unnameable}
          ] do
        id = item.(needle)
        assert text(view, "##{id}") =~ "Denied once in 1 run", needle
        refute has_element?(view, "##{id} .q-ar-act a, ##{id} .q-ar-act button"), needle

        assert view
               |> render()
               |> LazyHTML.from_document()
               |> LazyHTML.query("##{id} .q-ar-act span##{id}-act.q-act-lock")
               |> LazyHTML.attribute("title") == [tip],
               needle

        assert text(view, "##{id}-act .sr-only") == tip, needle

        # Asked anyway, the panel does not open.
        render_hook(view, "rule_open", %{"id" => id, "level" => "target"})
        refute has_element?(view, "#rule-panel"), needle
      end

      # A denial a rule can change keeps its Allow.
      assert has_element?(view, "##{item.("flags.example")}-act", "Allow here")
    end

    @tag needs: :security
    test "a wall's refusal for a reason the page has no words for offers nothing", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop(),
        egress: [
          %{"host" => "other.example", "decision" => "denied", "rule" => "wall:another-reason"}
        ]
      )

      view = open(conn, scope)

      [item] =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li[data-kind=denied]")
        |> LazyHTML.attribute("id")

      assert text(view, "##{item}") =~ "other.example"
      refute has_element?(view, "##{item} .q-ar-act *")
    end

    @tag needs: :security
    test "allow for the workspace, where several targets reached the host", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop(),
        egress: [%{"host" => "flags.example", "decision" => "denied", "rule" => ""}]
      )

      started_run(scope, %{"forge" => "github.example", "repository" => "acme/docs"},
        egress: [%{"host" => "flags.example", "decision" => "denied", "rule" => ""}]
      )

      view = open(conn, scope)

      [item] =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li[data-kind=denied]")
        |> LazyHTML.attribute("id")

      assert text(view, "##{item}") =~ "2 repositories"
      assert text(view, "##{item}") =~ "Denied 2 times in 2 runs"
      # Several targets: the page does not guess a scope.
      assert has_element?(
               view,
               "##{item}-act[aria-label='Allow flags.example, choose a scope']",
               "Allow"
             )

      view |> element("##{item}-act") |> render_click()
      assert has_element?(view, "#rule-panel-submit[disabled]")
      render_hook(view, "rule_change", %{"for" => "workspace"})
      view |> element("#rule-panel form") |> render_submit()

      assert Enum.any?(Policy.list_rules(scope, nil), &(&1.host == "flags.example"))
      assert has_element?(view, "##{item}-done", "Allowed for the workspace")
    end

    @tag needs: :security
    test "a denied host longer than 255 bytes is listed with the host cut and marked, and offers no act",
         %{conn: conn, scope: scope} do
      long = String.duplicate("a", 292) <> ".example"
      assert byte_size(long) == 300
      cut = String.duplicate("a", 252) <> "…"

      run =
        started_run(scope, shop(),
          egress: [%{"host" => long, "decision" => "denied", "rule" => ""}]
        )

      target = Repo.get!(Apiary.Runs.Target, run.target_id)
      view = open(conn, scope)

      [item] =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li[data-kind=denied]")
        |> LazyHTML.attribute("id")

      # The host as its connection keeps it, still counted, with no Allow and no rule.
      assert text(view, "##{item}") =~ cut
      refute text(view, "##{item}") =~ String.duplicate("a", 253)
      assert text(view, "##{item}") =~ "Denied once in 1 run"
      assert has_element?(view, ~s(span##{item}-act.q-act-lock[title="#{@unnameable}"]))
      refute has_element?(view, "##{item} .q-ar-act a, ##{item} .q-ar-act button")

      # Asked anyway, the panel does not open, and no rule is written.
      render_hook(view, "rule_open", %{"id" => item, "level" => "target"})
      refute has_element?(view, "#rule-panel")
      assert Policy.list_rules(scope, target) == []
      assert Policy.list_rules(scope, nil) == []
    end
  end

  describe "live" do
    test "a run that starts is counted; the active target's last run follows in place",
         %{conn: conn, scope: scope} do
      first = started_run(scope, shop(), ago: 600)
      view = open(conn, scope)
      target = Repo.get!(Apiary.Runs.Target, first.target_id)
      assert text(view, "#overview-strip-alive .q-sum-v") == "1"

      second = run_fixture(scope)

      event_fixture(
        second,
        2,
        "run.started",
        started_data(%{"labels" => shop(), "about" => %{"title" => "mirror-sync"}}),
        time: DateTime.utc_now()
      )

      {:ok, _} = Projector.project(second)
      render_async(view, 5_000)

      assert text(view, "#overview-strip-alive .q-sum-v") == "2"
      assert text(view, "#overview-strip-runs .q-sum-v") == "2"
      assert has_element?(view, "#active-#{target.id} .q-rs-running", "Running")

      event_fixture(second, 50, "run.exited", %{
        "state" => "failed",
        "exit_code" => 1,
        "duration_ms" => 10
      })

      {:ok, _} = Projector.project(second)
      render_async(view, 5_000)
      assert text(view, "#overview-strip-alive .q-sum-v") == "1"
      assert has_element?(view, "#active-#{target.id} .q-rs-failed", "Failed")
      assert text(view, "#overview-strip-bad .q-sum-v") == "1"
    end

    test "a quiet run that beats again resolves its row in words; a lost run gets a row", %{
      conn: conn,
      scope: scope
    } do
      quiet = started_run(scope, shop(), heartbeat: {45, 100, 30})
      view = open(conn, scope)
      assert has_element?(view, "#att-run-#{quiet.public_id}[data-kind=quiet]")

      event_fixture(
        quiet,
        41,
        "run.heartbeat",
        %{"elapsed_seconds" => 150, "interval_seconds" => 30},
        time: DateTime.utc_now(),
        received_at: DateTime.utc_now()
      )

      {:ok, _} = Projector.project(quiet)
      render_async(view, 5_000)
      assert text(view, "#att-run-#{quiet.public_id}") =~ "Heartbeats resumed."
      assert has_element?(view, "#att-run-#{quiet.public_id}.q-resolved")
      assert text(view, "#attention-n") =~ ~r/^\d$/

      other = started_run(scope, shop())
      # The read its start set off lands first, so the page knows it as just started and
      # the row arrives Lost; a read after the backdating would find it quiet first, the
      # next test's case.
      render_async(view, 5_000)

      Repo.update_all(from(r in Run, where: r.id == ^other.id),
        set: [last_heartbeat_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      assert [_] = Liveness.check(DateTime.utc_now())
      render_async(view, 5_000)
      assert has_element?(view, "#att-run-#{other.public_id}[data-kind=lost].q-arrived", "Lost")
      assert text(view, "#overview-announcer") == "1 more item to review."
    end

    test "a quiet run that ends resolves its row with its state: Completed, Failed, Cancelled",
         %{conn: conn, scope: scope} do
      runs =
        for exit <- [
              %{"state" => "succeeded", "exit_code" => 0},
              %{"state" => "failed", "exit_code" => 1},
              %{"state" => "cancelled", "reason" => "no_longer_needed"}
            ] do
          {started_run(scope, shop(), heartbeat: {45, 100, 30}), exit}
        end

      view = open(conn, scope)

      for {run, _exit} <- runs,
          do: assert(has_element?(view, "#att-run-#{run.public_id}[data-kind=quiet]"))

      for {run, exit} <- runs do
        event_fixture(run, 41, "run.exited", Map.put(exit, "duration_ms", 1000),
          time: DateTime.utc_now(),
          received_at: DateTime.utc_now()
        )

        {:ok, _} = Projector.project(run)
      end

      render_async(view, 5_000)

      for {{run, _exit}, words} <- Enum.zip(runs, ["Completed.", "Failed.", "Cancelled."]) do
        assert has_element?(view, "#att-run-#{run.public_id}.q-resolved")
        assert text(view, "#att-run-#{run.public_id}") =~ words
      end

      # Nothing arrived, so the announcer says nothing.
      assert text(view, "#overview-announcer") == ""
    end

    test "a quiet run the check finds lost turns its row to Lost in place", %{
      conn: conn,
      scope: scope
    } do
      # Silent for four intervals: quiet on the page, and lost at the check's three.
      quiet = started_run(scope, shop(), heartbeat: {120, 100, 30})
      view = open(conn, scope)
      assert has_element?(view, "#att-run-#{quiet.public_id}[data-kind=quiet]")

      assert [_] = Liveness.check(DateTime.utc_now())
      render_async(view, 5_000)
      assert has_element?(view, "#att-run-#{quiet.public_id}[data-kind=lost]", "Lost")
      refute has_element?(view, "#att-run-#{quiet.public_id}.q-resolved")
      refute text(view, "#att-run-#{quiet.public_id}") =~ "Heartbeats resumed."
      # The same row, patched: nothing arrived.
      refute has_element?(view, "#att-run-#{quiet.public_id}.q-arrived")
      assert text(view, "#overview-announcer") == ""
    end

    test "another workspace's runs change nothing here", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      view = open(conn, scope)
      other = scope_fixture()
      started_run(other, shop())
      render_async(view, 5_000)
      assert text(view, "#overview-strip-alive .q-sum-v") == "1"
      assert text(view, "#overview-strip-runs .q-sum-v") == "1"
    end
  end

  test "redirects to log in when signed out", %{scope: scope} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/#{scope.organisation}/#{scope.workspace}")
  end

  test "answers not found to a user who is not a member", %{scope: scope} do
    conn = log_in_user(build_conn(), Apiary.AccountsFixtures.user_fixture())
    assert conn |> get(~p"/#{scope.organisation}/#{scope.workspace}") |> html_response(404)
  end

  test "a lost run's target path: cleaned; one sent with nothing left to show is marked", %{
    conn: conn,
    scope: scope
  } do
    at = &%{target_system: "git.example", target_path: &1}
    named = lost_run(scope, at.("acme/\u202Eshop\a"))
    blank = lost_run(scope, at.("\u202E\u200B"))
    view = open(conn, scope)

    assert text(view, "#att-run-#{named.public_id} .q-ar-where") == "acme/shop\uFFFD"
    assert text(view, "#att-run-#{blank.public_id} .q-ar-where") == "\uFFFD\uFFFD"

    # A run that sent no path keeps no repository.
    none = lost_run(scope, at.(nil))
    view = open(conn, scope)
    assert text(view, "#att-run-#{none.public_id} .q-ar-where") == "no repository"
  end

  test "a lost run's target is named with its system where the path as sent is shared", %{
    conn: conn,
    scope: scope
  } do
    path = "acme/\u202Eshop"

    for system <- ~w(github.example gitlab.example),
        do: started_run(scope, %{"forge" => system, "repository" => path})

    run = lost_run(scope, %{target_system: "github.example", target_path: path})
    view = open(conn, scope)

    assert text(view, "#att-run-#{run.public_id} .q-ar-where") == "github.example / acme/shop"
  end

  # The page's markup with what `<bdi>` isolates taken out, as text: what of a host is
  # left outside an isolate.
  defp outside_bdi(html) do
    html
    |> String.replace(~r{<bdi[^>]*>.*?</bdi>}s, "")
    |> String.replace(~r{<[^>]*>}, " ")
  end

  @tag needs: :security
  test "a denied request's tool, path and host as a page shows what Forager sent", %{
    conn: conn,
    scope: scope
  } do
    started_run(scope, shop(),
      egress: [
        tool_invocation_data(%{
          "tool" => "fi\u202Eles\a",
          "host" => "files.tools\u200B.internal",
          "rule" => "",
          "path" => "/media/\u202Ea.png",
          "path_rule" => "",
          "decision" => "denied",
          "outcome" => "refused"
        })
      ]
    )

    view = open(conn, scope)
    selector = "#attention-list li[data-kind=denied]"

    assert text(view, "#{selector} .q-dest-tool") ==
             "Tool files\uFFFD /media/a.png files.tools.internal:443"

    title = "files.tools.internal:443/media/a.png, a host the tool files\uFFFD serves"
    assert has_element?(view, ~s(#{selector} .q-host[title="#{title}"]))
    assert has_element?(view, "#{selector} .q-host .q-port > bdi", "files.tools.internal")
    refute render(element(view, "#{selector} .q-ar-subj")) =~ "\u202E"
  end

  @tag needs: :security
  test "a host the wall refused for its form: marked, inside a <bdi>", %{
    conn: conn,
    scope: scope
  } do
    host = "Files\u202E.CDN\u200B.example."

    started_run(scope, shop(),
      egress: [%{"host" => host, "decision" => "denied", "rule" => "wall:host-form"}]
    )

    view = open(conn, scope)
    subject = "#attention-list li[data-kind=denied] .q-ar-subj"

    marked = "Files\uFFFD.CDN\uFFFD.example."
    assert has_element?(view, "#{subject} .q-host > bdi", marked)
    refute view |> element(subject) |> render() |> outside_bdi() =~ "\u202E"
    refute render(view) =~ "\u202E"
  end

  @tag needs: :security
  test "a denied request's tool and path with nothing left to show: marked, not none",
       %{conn: conn, scope: scope} do
    started_run(scope, shop(),
      egress: [
        tool_invocation_data(%{
          "tool" => "\u200B",
          "path" => "\u202E",
          "path_rule" => "",
          "decision" => "denied",
          "outcome" => "refused"
        })
      ]
    )

    view = open(conn, scope)
    selector = "#attention-list li[data-kind=denied]"

    assert has_element?(view, "#{selector} .q-dest-tool .q-tool-name", "\uFFFD")
    assert has_element?(view, "#{selector} .q-dest-tool .q-path", "\uFFFD")
    refute render(element(view, selector)) =~ "\u202E"
  end

  @tag needs: :security
  test "a target's name in an Allow's label and among the targets with a mode: cleaned", %{
    conn: conn,
    scope: scope
  } do
    # A target's path may carry a bidirectional override and a zero-width space.
    path = "acme/\u202Eshop\u200B"

    run =
      started_run(scope, %{"forge" => "github.example", "repository" => path},
        egress: [%{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""}]
      )

    target = Repo.get!(Apiary.Runs.Target, run.target_id)
    {:ok, _} = Policy.set_mode(scope, target, "observe")
    view = open(conn, scope)
    render_async(view, 5_000)

    assert has_element?(
             view,
             "#attention-list li[data-kind=denied] button[aria-label='Allow files.cdn.example for acme/shop']"
           )

    assert text(view, "#overview-own") =~ "acme/shop observes; the rest follow the workspace."
    refute render(view) =~ "\u202E"
  end
end
