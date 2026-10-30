defmodule ApiaryWeb.WorkspaceLive.OverviewSetupTest do
  # A workspace whose set-up is not finished, with the `factory` feature: its Overview
  # lists the set-up's steps with Continue, its sidebar has the group Set up, and every
  # landing leads to the Overview until the test run passed
  # (`ApiaryWeb.SetUpComponents.workspace_set_up/1`). Without the feature, and once the test
  # run passed, the Overview shows what it shows a workspace in use. Every workspace page
  # has the link up to its organisation.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelChoices, Repo, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Runs.Run
  alias ApiaryWeb.Layouts

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.WorkspaceLive.Overview,
      coalesce: 0,
      announce: 0,
      quiet_tick: 3_600_000,
      refresh: 3_600_000
    )

    :ok
  end

  defp overview(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}"

  defp step_path(scope, step),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/set-up/#{step}"

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp href(lv, selector) do
    [href] =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("href")

    href
  end

  # The Overview's list of the set-up: each step's name with its state, `:done`, `:next`
  # for the one Continue opens, or `:to_come`, and where its link leads.
  defp overview_steps(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#overview-set-up-steps a")
    |> Enum.map(fn step ->
      name = step |> LazyHTML.query(".q-su-nm") |> LazyHTML.text() |> String.trim()
      [class] = LazyHTML.attribute(step, "class")
      [path] = LazyHTML.attribute(step, "href")

      state =
        cond do
          class =~ "is-done" -> :done
          LazyHTML.attribute(step, "aria-current") == ["step"] -> :next
          true -> :to_come
        end

      {name, state, path}
    end)
  end

  # The step Continue opens on the Overview: its name, as the button says it, and its page.
  defp continue(conn, scope) do
    {:ok, lv, _html} = live(conn, overview(scope))
    {words(lv, "#overview-set-up-continue"), href(lv, "#overview-set-up-continue")}
  end

  # The flow's steps the reader sees: Model with the `secrets` feature.
  defp flow do
    [
      {"Name", :name},
      {"Work sources", :sources},
      {"Destinations", :destinations},
      {"Model", :model},
      {"Harness", :harness},
      {"Machines", :machines},
      {"Test run", :test}
    ]
    |> Enum.filter(fn {_label, id} -> id != :model or Apiary.Features.on?(:secrets) end)
  end

  # The instance's pool and gateway, each with a key: the Machines step is done.
  defp ready_instance! do
    pool = instance_pool_fixture()
    _pool_key = installed_key_fixture(pool)
    gateway = instance_gateway_fixture()
    _gateway_key = installed_key_fixture(gateway, allow_secrets: true)
    pool
  end

  # A test run of the workspace that passed: its one run ended by its exit, `run_ended`,
  # with its registered run completed.
  defp test_passed!(scope, pool) do
    {:ok, item} = WorkItems.take_in_test(scope, "Hi! Where are you running?")
    [queued] = Repo.all(from d in DispatchRun, where: d.work_item_id == ^item.id)

    {1, _} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^queued.id),
        set: [state: :ended, end_cause: :run_ended]
      )

    Repo.insert!(%Run{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      node_run_id: queued.run_id,
      dispatch_run_id: queued.id,
      node_id: pool.id,
      state: "completed",
      started_at: DateTime.utc_now()
    })
  end

  # The organisation's model provider with a key, and the workspace's choice of it: the
  # Model step is done.
  defp model_done!(scope) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-overview-1"}]
      })

    {:ok, _choice} = ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id})
  end

  describe "a workspace in set-up" do
    test "the Overview lists the steps with their state, and Continue opens the next", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, html} = live(conn, overview(scope))

      assert html =~ ~r{<title[^>]*>\s*Main · }
      assert words(lv, "#overview-set-up h1") == "Finish setting up Main"

      expected =
        for {label, id} <- flow() do
          state =
            case id do
              :name -> :done
              :sources -> :next
              _other -> :to_come
            end

          {label, state, step_path(scope, id)}
        end

      assert overview_steps(lv) == expected

      assert words(lv, "#overview-set-up-continue") == "Continue: Work sources"
      refute has_element?(lv, "#overview-activity")
      refute has_element?(lv, "#onboarding")

      collection = collection_fixture(scope)
      assert continue(conn, scope) == {"Continue: Destinations", step_path(scope, :destinations)}

      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^collection.adapter_id),
          set: [targets: true]
        )

      if Apiary.Features.on?(:secrets) do
        assert continue(conn, scope) == {"Continue: Model", step_path(scope, :model)}
        model_done!(scope)
      end

      assert continue(conn, scope) == {"Continue: Harness", step_path(scope, :harness)}

      {:ok, _stack} = Apiary.Stacks.Sources.choose(scope, :qory)
      assert continue(conn, scope) == {"Continue: Machines", step_path(scope, :machines)}

      _pool = ready_instance!()
      assert continue(conn, scope) == {"Continue: Test run", step_path(scope, :test)}
    end

    test "a step done after a skipped one keeps its tick, and Continue opens the first not done",
         %{conn: conn, scope: scope} do
      {:ok, _stack} = Apiary.Stacks.Sources.choose(scope, :qory)
      {:ok, lv, _html} = live(conn, overview(scope))

      assert {"Harness", :done, step_path(scope, :harness)} in overview_steps(lv)
      assert words(lv, "#overview-set-up-continue") == "Continue: Work sources"
    end

    test "the sidebar's group Set up has each step, a tick on each one done, and the page's step current",
         %{conn: conn, scope: scope} do
      total = length(flow())
      {:ok, _stack} = Apiary.Stacks.Sources.choose(scope, :qory)

      {:ok, lv, _html} = live(conn, step_path(scope, :machines))

      assert words(lv, "#nav-set-up-heading") == "Set up · 2 of #{total}"
      assert words(lv, "#nav-set-up-name") == "Name, done"

      expected =
        for {label, id} <- flow() do
          cond do
            id == :machines -> {label, :current}
            id in [:name, :harness] -> {label, :done}
            true -> {label, :to_come}
          end
        end

      assert ApiaryWeb.SetUpSteps.set_up_group(lv) == expected

      for {_label, id} <- flow() do
        assert href(lv, "#nav-set-up-#{id}") == step_path(scope, id)
      end

      # The rest of the sidebar stays.
      assert has_element?(lv, "#nav-group-home")
      assert has_element?(lv, "#nav-group-record")

      # A step opens in any order, from the group: no step is locked.
      {:ok, lv, _html} = live(conn, step_path(scope, :test))
      assert {"Test run", :current} in ApiaryWeb.SetUpSteps.set_up_group(lv)

      # On the Overview, and on Runs, the group shows with no step current.
      for path <- [overview(scope), ~p"/#{scope.organisation}/#{scope.workspace}/runs"] do
        {:ok, lv, _html} = live(conn, path)
        assert has_element?(lv, "#nav-group-set-up")
        refute has_element?(lv, "#nav-group-set-up [aria-current]")
      end

      # Once the test run passed, the group leaves the sidebar.
      test_passed!(scope, ready_instance!())

      for path <- [overview(scope), step_path(scope, :test)] do
        {:ok, lv, _html} = live(conn, path)
        refute has_element?(lv, "#nav-group-set-up")
      end
    end

    test "the group Set up shows in the phone's navigation, the drawer that holds the sidebar",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, overview(scope))

      assert has_element?(lv, ".drawer-side #sidebar #nav-group-set-up")
      assert has_element?(lv, ".drawer-side #sidebar #nav-up")
    end

    test "the landings lead to the Overview: after log-in, from the organisation, after an invitation",
         %{conn: conn, scope: scope, user: user} do
      assert Layouts.workspace_landing(scope) == overview(scope)

      conn =
        conn
        |> Map.replace!(:secret_key_base, ApiaryWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{})
        |> ApiaryWeb.UserAuth.log_in_user(%{user | authenticated_at: DateTime.utc_now(:second)})

      assert redirected_to(conn) == overview(scope)

      {:ok, lv, _html} = live(log_in_user(build_conn(), user), ~p"/#{scope.organisation}")
      assert href(lv, "#workspace-#{scope.workspace.id}-name") == overview(scope)

      # An invitation to the workspace brings the person to its page, the Overview.
      %{user: invited} = member_fixture(scope, :member)

      invited_scope =
        Apiary.Organisations.load_scope(
          Apiary.Accounts.Scope.for_user(invited),
          scope.organisation.id
        )

      assert Layouts.workspace_landing(invited_scope) == overview(scope)

      test_passed!(scope, ready_instance!())
      assert Layouts.workspace_landing(scope) == overview(scope)
    end

    test "the organisation's overview marks its line with the set-up's count until the test run passed",
         %{conn: conn, scope: scope} do
      total = length(flow())
      row = "#workspace-#{scope.workspace.id}"

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}")
      assert words(lv, row <> "-set-up") == "Set-up: 1 of #{total} steps"
      assert href(lv, row <> "-name") == overview(scope)

      {:ok, _stack} = Apiary.Stacks.Sources.choose(scope, :qory)
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}")
      assert words(lv, row <> "-set-up") == "Set-up: 2 of #{total} steps"

      test_passed!(scope, ready_instance!())
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}")
      refute has_element?(lv, row <> "-set-up")
      assert href(lv, row <> "-name") == overview(scope)
    end

    test "a member who may act on no step reads the step, and who does it", %{scope: scope} do
      free = collection_fixture(scope, workspace_id: nil)
      connection = Repo.get!(Apiary.Adapters.Connection, free.connection_id)
      grant = Repo.get_by!(Apiary.Adapters.Grant, grant_ref: listing_grant(connection))
      %{user: member} = member_fixture(scope, :member)
      conn = log_in_user(build_conn(), member)

      {:ok, lv, _html} = live(conn, overview(scope))
      assert words(lv, "#overview-set-up-continue") == "Continue: Work sources"

      {:ok, lv, _html} = live(conn, step_path(scope, :sources))
      assert has_element?(lv, "#set-up-grant-#{grant.public_id}-choose")
      assert has_element?(lv, "#set-up-who-may")
      assert {"Work sources", :current} in ApiaryWeb.SetUpSteps.set_up_group(lv)

      # The grant's chooser shows the choice disabled, and no Save.
      {:ok, chooser, _html} =
        live(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/set-up/sources/choose?#{[grant: grant.public_id]}"
        )

      assert has_element?(chooser, "#choose-only[disabled]")
      refute has_element?(chooser, "#choose-save")
      assert {"Work sources", :current} in ApiaryWeb.SetUpSteps.set_up_group(chooser)
    end

    test "Backlog and Runs open as before", %{conn: conn, scope: scope} do
      assert {:ok, _lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")
      assert {:ok, _lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/backlog")
    end
  end

  describe "the link up to the organisation" do
    test "is the sidebar's first line on every workspace page, and not on the organisation's",
         %{conn: conn, scope: scope} do
      org = scope.organisation
      ws = scope.workspace

      for path <- [
            overview(scope),
            step_path(scope, :name),
            ~p"/#{org}/#{ws}/runs",
            ~p"/#{org}/#{ws}/settings"
          ] do
        {:ok, lv, _html} = live(conn, path)

        assert words(lv, "#nav-up") == org.name
        assert href(lv, "#nav-up") == ~p"/#{org}"

        [first | _rest] =
          lv
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.query(".q-sidebar-body > *")
          |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))

        assert first == "nav-up"

        # The breadcrumb keeps its link to the organisation.
        assert has_element?(lv, ~s{#top-bar a.q-trail-link[href="/#{org.slug}"]})
      end

      {:ok, lv, _html} = live(conn, ~p"/#{org}")
      refute has_element?(lv, "#nav-up")
    end
  end

  test "once the test run passed, the Overview opens, with no set-up on it", %{
    conn: conn,
    scope: scope
  } do
    test_passed!(scope, ready_instance!())

    {:ok, view, _html} = live(conn, overview(scope))
    render_async(view, 5_000)

    refute has_element?(view, "#setup")
    refute has_element?(view, "#onboarding")
    assert has_element?(view, "#overview-activity")
  end

  test "without the feature, the Overview opens with the empty workspace's box", %{
    conn: conn,
    scope: scope
  } do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
    Apiary.EditionStubs.HidesNamed.put([:factory])

    {:ok, view, _html} = live(conn, overview(scope))

    assert has_element?(view, "#onboarding")
    # A scope keeps what the edition hid as it was loaded.
    assert Layouts.workspace_landing(%{scope | hidden: [:factory]}) == overview(scope)
  end
end
