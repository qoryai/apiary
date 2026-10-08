defmodule ApiaryWeb.WorkspaceLive.OverviewTest do
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Repo
  alias Apiary.Policy
  alias Apiary.Retention
  alias Apiary.Runs
  alias Apiary.Runs.{Liveness, Projector, Run}

  setup :register_and_log_in_user

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
          task: "nightly-mirror",
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

  describe "the empty workspace" do
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
      refute text(view, "#onboarding") =~ "qec_"
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
      assert code =~ ~r/\Aqec_[0-9A-Z]{26}\./

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
      {:ok, _} = AccessKeys.touch(key, %{last_runner_version: "v0.4.2", last_contract_version: 1})
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
               "#onboarding-landed a[href='#{workspace_path(scope, "/runs/#{run.run_id}")}']",
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
      assert text(view, "#activity-foot") =~ "Days in UTC."

      costed = run_fixture(scope)
      event_fixture(costed, 2, "run.started", started_data(), time: DateTime.utc_now())
      event_fixture(costed, 3, "session.result", %{"outcome" => "success", "cost_usd" => 0.8412})
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
      # running one, which makes it the target's last run.
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
               "#active-#{target.id} a[href='#{workspace_path(scope, "/targets/acme/shop")}']"
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
      today = Date.to_iso8601(Date.utc_today())

      assert has_element?(
               view,
               "#days a[data-day='#{today}'][href='#{workspace_path(scope, "/runs?from=#{today}&to=#{today}")}']"
             )

      assert has_element?(
               view,
               "#days a[data-day='#{today}'][aria-label*='Today: 3 runs (1 ended well, 2 alive or ended badly), 0 denied attempts']"
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

      # Each links to its page at its address: the system in it where the path is shared.
      for {system, path} <- [
            {"github.example", "/targets/github.example/acme/shop"},
            {"gitlab.example", "/targets/gitlab.example/acme/shop"}
          ] do
        target = Apiary.Targets.get(scope, system, "acme/shop")
        assert has_element?(view, "#active-#{target.id} a[href='#{workspace_path(scope, path)}']")
      end

      t1 = Apiary.Targets.get(scope, "github.example", "acme/t1")

      assert has_element?(
               view,
               "#active-#{t1.id} a[href='#{workspace_path(scope, "/targets/acme/t1")}']"
             )

      assert has_element?(view, "#overview-targets-all", "All 10 repositories")
    end

    test "with no run in the fortnight the chart has fourteen stubs and no target is active",
         %{conn: conn, scope: scope} do
      run_fixture(scope, %{
        state: "succeeded",
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
               "Machines use their own policy until the first change here."

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
               "#overview-own a[href='#{workspace_path(scope, "/targets/acme/shop/-/policy")}']",
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
               "#overview-own a[href='#{workspace_path(scope, "/targets/github.example/acme/shop/-/policy")}']"
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
               "No prune has run yet. The job runs nightly."

      workspace = Apiary.Repo.get!(Apiary.Organisations.Workspace, scope.workspace.id)
      %{runs_pruned: 0} = Retention.prune_workspace(workspace)
      view = open(conn, scope)

      assert text(view, "#overview-retention-last") =~
               "Nothing was old enough to prune last night."
    end
  end

  describe "to review" do
    @tag needs: :security
    test "is absent when there is nothing to do", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      {:ok, _} = Policy.set_mode(scope, "enforce")
      view = open(conn, scope)
      refute has_element?(view, "#attention")
      assert has_element?(view, "#overview-strip")
    end

    @tag needs: :security
    test "the kinds, in the order of the brief, bounded at five with the overflow linked", %{
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

      assert text(view, "#att-run-#{lost.run_id}") =~ "Lost, never posted its exit"

      assert has_element?(
               view,
               "#att-run-#{lost.run_id}-act[aria-label='Close nightly-mirror']",
               "Close"
             )

      assert has_element?(
               view,
               "#att-run-#{lost.run_id} a[href='#{workspace_path(scope, "/runs/#{lost.run_id}")}']",
               "nightly-mirror"
             )

      assert text(view, "#att-run-#{quiet.run_id}") =~ "No heartbeat for"

      assert has_element?(
               view,
               "#att-run-#{quiet.run_id} .q-ar-why[title='Heartbeats are due every 30 s; after 1 m 30 s of silence it is marked lost.']"
             )

      assert has_element?(
               view,
               "#att-run-#{quiet.run_id}-act[href='#{workspace_path(scope, "/runs/#{quiet.run_id}")}']",
               "Open"
             )

      # The idle key is the sixth: on the nodes page, not on this list.
      refute has_element?(view, "#att-key-#{idle.id}")
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
        workspace_path(
          scope,
          "/targets/github.example/acme/shop/-/policy/versions/#{new.version}?compare=#{old.version}"
        )

      assert has_element?(
               view,
               ~s(#att-run-#{run.run_id}-act[href="#{compare}"]),
               "What changed"
             )
    end

    @tag needs: :security
    test "the policy items: unmanaged with runs, enforce for an owner, open policy for a member",
         %{conn: conn, scope: scope} = ctx do
      started_run(scope, shop())
      view = open(conn, scope)

      assert text(view, "#att-policy-unmanaged") =~ "Qory serves no policy yet"

      assert text(view, "#att-policy-unmanaged") =~ "1 run under the machines' policies"

      assert has_element?(
               view,
               "#att-policy-unmanaged-act[href='#{workspace_path(scope, "/policy")}']",
               "Open policy"
             )

      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example.com"})
      render_async(view, 5_000)
      assert text(view, "#att-policy-unmanaged") =~ "Qory serves the policy now."
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
      {:ok, _} = AccessKeys.touch(fresh, %{last_runner_version: "v0.4.1"})
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

    test "close a lost run in place: the row stays struck, the count drops, the page says so",
         %{conn: conn, scope: scope} do
      lost = lost_run(scope)
      started_run(scope, shop())
      view = open(conn, scope)
      # With `security` the unmanaged policy is the second item, and focus goes to it;
      # without it the lost run is the only one, and focus goes to All runs.
      security? = Apiary.Features.on?(:security)
      assert text(view, "#attention-n") == if(security?, do: "2", else: "1")

      view |> element("#att-run-#{lost.run_id}-act") |> render_click()

      # The row itself asks, in place: no modal over the page.
      assert has_element?(
               view,
               "#att-run-#{lost.run_id}.q-confirming #close-run",
               "Close nightly-mirror?"
             )

      refute has_element?(view, "dialog#close-run")
      refute has_element?(view, "#att-run-#{lost.run_id}-act")

      view |> element("#close-run-cancel") |> render_click()
      refute has_element?(view, "#close-run")
      close_act = "att-run-#{lost.run_id}-act"
      assert_push_event(view, "overview:focus", %{id: ^close_act})

      view |> element("#att-run-#{lost.run_id}-act") |> render_click()
      view |> element("#att-run-#{lost.run_id} #close-confirm", "Yes, close") |> render_click()

      assert %Run{state: "closed"} = Runs.get_run!(scope, lost.id)
      assert has_element?(view, "#att-run-#{lost.run_id}.q-resolved .q-mark-closed")
      assert text(view, "#att-run-#{lost.run_id}") =~ "Closed."
      refute has_element?(view, "#att-run-#{lost.run_id}-act")
      assert text(view, "#attention-n") == if(security?, do: "1", else: "0")
      assert text(view, "#overview-announcer") == "nightly-mirror is closed."

      next = if security?, do: "att-policy-unmanaged-act", else: "activity-all"
      assert_push_event(view, "overview:focus", %{id: ^next})
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
      # The target is named as it is addressed: its path, where no other system has it.
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
        started_data(%{"labels" => Map.put(shop(), "task", "mirror-sync")}),
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
      assert has_element?(view, "#att-run-#{quiet.run_id}[data-kind=quiet]")

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
      assert text(view, "#att-run-#{quiet.run_id}") =~ "Heartbeats resumed."
      assert has_element?(view, "#att-run-#{quiet.run_id}.q-resolved")
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
      assert has_element?(view, "#att-run-#{other.run_id}[data-kind=lost].q-arrived", "Lost")
      assert text(view, "#overview-announcer") == "1 more item to review."
    end

    test "a quiet run the check finds lost turns its row to Lost in place", %{
      conn: conn,
      scope: scope
    } do
      # Silent for four intervals: quiet on the page, and lost at the check's three.
      quiet = started_run(scope, shop(), heartbeat: {120, 100, 30})
      view = open(conn, scope)
      assert has_element?(view, "#att-run-#{quiet.run_id}[data-kind=quiet]")

      assert [_] = Liveness.check(DateTime.utc_now())
      render_async(view, 5_000)
      assert has_element?(view, "#att-run-#{quiet.run_id}[data-kind=lost]", "Lost")
      refute has_element?(view, "#att-run-#{quiet.run_id}.q-resolved")
      refute text(view, "#att-run-#{quiet.run_id}") =~ "Heartbeats resumed."
      # The same row, patched: nothing arrived.
      refute has_element?(view, "#att-run-#{quiet.run_id}.q-arrived")
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
end
