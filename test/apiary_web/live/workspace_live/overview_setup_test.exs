defmodule ApiaryWeb.WorkspaceLive.OverviewSetupTest do
  # A workspace whose set-up is not finished, with the `factory` feature: its Overview and
  # its landing (`ApiaryWeb.Layouts.workspace_landing/1`) lead to the set-up's next step
  # until the test run passed (`ApiaryWeb.SetUpComponents.set_up_path/1`). Without the
  # feature, and once the test run passed, the Overview opens.
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
    do: ~p"/#{scope.organisation}/set-up?step=#{step}&workspace=#{scope.workspace}"

  # Where opening the Overview sends the reader.
  defp sent_to(conn, scope) do
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, overview(scope))
    to
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
    test "opens at its next step, from Work sources to Test run, with no step skipped", %{
      conn: conn,
      scope: scope
    } do
      assert sent_to(conn, scope) == step_path(scope, :sources)

      collection = collection_fixture(scope)
      assert sent_to(conn, scope) == step_path(scope, :destinations)

      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^collection.adapter_id),
          set: [targets: true]
        )

      # Model is a step of the flow with the `secrets` feature.
      if Apiary.Features.on?(:secrets) do
        assert sent_to(conn, scope) == step_path(scope, :model)
        model_done!(scope)
      end

      assert sent_to(conn, scope) == step_path(scope, :harness)

      {:ok, _stack} = Apiary.Stacks.Sources.choose(scope, :qory)
      assert sent_to(conn, scope) == step_path(scope, :machines)

      _pool = ready_instance!()
      assert sent_to(conn, scope) == step_path(scope, :test)
    end

    test "opens the step, which shows it", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = conn |> live(overview(scope)) |> follow_redirect(conn)

      assert has_element?(lv, "h1", "Where does work for #{scope.workspace.name} come from?")
    end

    test "the landing leads to the next step until the test run passed, then to the Overview",
         %{scope: scope} do
      assert Layouts.workspace_landing(scope) == step_path(scope, :sources)

      test_passed!(scope, ready_instance!())
      assert Layouts.workspace_landing(scope) == overview(scope)
    end

    test "a member who may act on no step opens the step and reads who may, with no loop", %{
      scope: scope
    } do
      free = collection_fixture(scope, workspace_id: nil)
      connection = Repo.get!(Apiary.Adapters.Connection, free.connection_id)
      grant = Repo.get_by!(Apiary.Adapters.Grant, grant_ref: listing_grant(connection))
      %{user: member} = member_fixture(scope, :member)
      conn = log_in_user(build_conn(), member)

      assert sent_to(conn, scope) == step_path(scope, :sources)

      {:ok, lv, _html} = live(conn, step_path(scope, :sources))
      assert has_element?(lv, "#set-up-grant-#{grant.public_id}-choose")
      assert has_element?(lv, "#set-up-who-may")

      # The grant's chooser shows the choice disabled, and no Save.
      params = [step: :sources, grant: grant.public_id, workspace: scope.workspace.slug]
      {:ok, chooser, _html} = live(conn, ~p"/#{scope.organisation}/set-up/choose?#{params}")
      assert has_element?(chooser, "#choose-only[disabled]")
      refute has_element?(chooser, "#choose-save")

      # The set-up without a step opens the first step not done, and sends nowhere.
      assert {:ok, _lv, _html} = live(conn, ~p"/#{scope.organisation}/set-up")
    end

    test "Backlog and Runs open as before", %{conn: conn, scope: scope} do
      assert {:ok, _lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")
      assert {:ok, _lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/backlog")
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
