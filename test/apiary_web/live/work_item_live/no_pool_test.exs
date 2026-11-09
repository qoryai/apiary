defmodule ApiaryWeb.WorkItemLive.NoPoolTest do
  # A work item whose run waits in the queue while no pool that serves the workspace's
  # runs is ready (`ApiaryWeb.WorkItemLive.Show`): the header's status, the error box on
  # Explore's tab with the reason and Open Machines, and the step card's line; the reason
  # for each state of the pools, and for pools in different states; no link for a reader
  # who may not read the machines; today's words while a pool is ready, for a run a pool
  # claimed, and before the first run is queued; the instance's pool; the page read again
  # when a machine enrols a key on a pool or on its gateway; and the first render, before
  # the browser connects, which reads no gateway to listen to. A run after a move back to
  # Explore and a later stage's run are in `ApiaryWeb.WorkItemLive.WorkflowTest`.
  #
  # The instance has one pool in use at most, and a test here makes it, so the module is
  # not async.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures, only: [enrolled_key_fixture: 2]
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1, workspace_gateway!: 1]

  import Apiary.NodesFixtures,
    only: [gateway_fixture: 1, pool_fixture: 1, instance_pool_fixture: 0, unique_node_name: 0]

  import Apiary.OrganisationsFixtures, only: [workspace_fixture: 2]
  import Apiary.WorkItemsFixtures

  alias Apiary.{AccessKeys, Repo}
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  setup :register_and_log_in_user

  defp page(scope, number),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/explore"

  defp machines(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/machines"

  # A work item as a take in leaves it: its first run waiting in the queue.
  defp queued(scope) do
    work_item = work_item_fixture(scope)
    explore_run_fixture(work_item, state: :waiting)
    work_item
  end

  # A pool of the workspace with an active key, set to Direct.
  defp direct_pool(scope) do
    pool = pool_fixture(scope)
    _key = enrolled_key_fixture(scope, pool)
    pool |> Ecto.Changeset.change(gateway_choice: :direct) |> Repo.update!()
  end

  # A pool of the workspace with an active key, its choice the workspace's default
  # gateway. A pool made while the workspace has no gateway is made Direct.
  defp keyed_pool(scope) do
    pool = pool_fixture(scope)
    _key = enrolled_key_fixture(scope, pool)
    pool |> Ecto.Changeset.change(gateway_choice: :default) |> Repo.update!()
  end

  defp reason(conn, scope, work_item) do
    {:ok, view, _html} = live(conn, page(scope, work_item.number))
    words(view, "#work-item-explore-no-pool-reason")
  end

  defp words(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

  test "no pool can take the run: the header, the box with the reason and Open Machines, and the step card's line",
       %{conn: conn, scope: scope} do
    _pool = direct_pool(scope)
    _other = direct_pool(scope)
    work_item = queued(scope)
    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    assert words(view, "#work-item-head-stage-status") == "Waiting: no pool can take the run"
    assert has_element?(view, "#work-item-head-stage-status .q-wi-mk-err")

    assert words(view, "#work-item-explore-no-pool-h") == "No pool can take attempt 1."

    assert words(view, "#work-item-explore-no-pool-reason") ==
             "The 2 pools of #{scope.workspace.name} are set to Direct, and a run needs a gateway. Choose a gateway for a pool on the Machines page."

    assert has_element?(
             view,
             ~s(#work-item-explore-no-pool-reason a[href="#{machines(scope)}"]),
             "Machines"
           )

    assert has_element?(
             view,
             ~s(#work-item-explore-no-pool-open[href="#{machines(scope)}"]),
             "Open Machines"
           )

    refute has_element?(view, "#work-item-explore-wait")

    assert words(view, "#work-item-step-no-pool") == "No pool can take the run. Open Machines"

    assert has_element?(
             view,
             ~s(#work-item-step-no-pool-open[href="#{machines(scope)}"]),
             "Open Machines"
           )

    # The step card keeps what Explore does when the run starts, and Undo.
    assert has_element?(view, "#work-item-step", "When the run starts, Explore reads")
    assert has_element?(view, "#work-item-step-undo")
  end

  test "a later attempt: the step card's line in place of the attempt that is queued",
       %{conn: conn, scope: scope} do
    _pool = direct_pool(scope)
    work_item = work_item_fixture(scope)
    explore_run_fixture(work_item)
    explore_run_fixture(work_item, state: :waiting)
    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    assert words(view, "#work-item-explore-no-pool-h") == "No pool can take attempt 2."

    assert words(view, "#work-item-explore-no-pool-reason") ==
             "The pool of #{scope.workspace.name} is set to Direct, and a run needs a gateway. Choose a gateway for the pool on the Machines page."

    assert words(view, "#work-item-step-no-pool") == "No pool can take the run. Open Machines"
    refute has_element?(view, "#work-item-step-run")
  end

  test "a ready pool: today's words", %{conn: conn, scope: scope} do
    _place = handover_place_fixture(scope)
    work_item = queued(scope)
    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    assert words(view, ".q-wi-st") == "Explore is queued"
    refute has_element?(view, "#work-item-head-stage-status")
    assert words(view, "#work-item-explore-wait-h") == "Explore is queued."

    assert has_element?(
             view,
             "#work-item-explore-wait",
             "Attempt 1 starts when the workspace's pool takes it."
           )

    refute has_element?(view, "#work-item-explore-no-pool")
    refute has_element?(view, "#work-item-step-no-pool")
  end

  test "a ready pool that cannot start the run's machine type: the header has the type", %{
    conn: conn,
    scope: scope
  } do
    %{pool: pool} = handover_place_fixture(scope)
    work_item = queued(scope)

    Repo.update_all(
      from(r in Apiary.Dispatches.DispatchRun, where: r.work_item_id == ^work_item.id),
      set: [machine_type: "large", machine_spec: Apiary.MachineTypesFixtures.spec()]
    )

    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    assert words(view, "#work-item-head-stage-status") ==
             "Waiting: no pool can start machine type large"

    assert has_element?(view, "#work-item-head-stage-status .q-wi-mk-err")
    refute has_element?(view, "#work-item-explore-no-pool")

    # A pool whose offers fit the type: today's words.
    Apiary.MachineTypesFixtures.with_offers(pool, [Apiary.MachineTypesFixtures.spec()])
    {:ok, view, _html} = live(conn, page(scope, work_item.number))
    refute has_element?(view, "#work-item-head-stage-status")
    assert words(view, "#work-item-explore-wait-h") == "Explore is queued."
  end

  test "the instance's pool: no pool at all, then the Qory Pool not ready", %{
    conn: conn,
    scope: scope
  } do
    work_item = queued(scope)
    name = scope.workspace.name
    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    assert words(view, "#work-item-head-stage-status") == "Waiting: no pool can take the run"

    assert words(view, "#work-item-explore-no-pool-reason") ==
             "No pool takes the runs of #{name}. Add a pool on the Machines page."

    _pool = instance_pool_fixture()
    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    assert words(view, "#work-item-explore-no-pool-reason") ==
             "The Qory Pool takes the runs of #{name}, and it is not ready. Add a pool for #{name} on the Machines page."
  end

  test "a machine enrols a key on the pool: the page reads it again, and the run waits for it",
       %{conn: conn, scope: scope} do
    # The workspace's default gateway, with an active key, and a pool with no key yet.
    _gateway = workspace_gateway!(scope)
    pool = pool_fixture(scope)
    work_item = queued(scope)
    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    assert words(view, "#work-item-explore-no-pool-reason") ==
             "The pool of #{scope.workspace.name} has no active access key. Enrol a machine on the pool on the Machines page."

    %{access_key: key} = enrolled_key_fixture(scope, pool)

    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      AccessKeys.topic(scope.workspace.id, pool.id),
      {:key_enrolled, %{key_id: key.key_id, node_id: pool.id}}
    )

    refute has_element?(view, "#work-item-explore-no-pool")
    assert words(view, "#work-item-explore-wait-h") == "Explore is queued."
    assert words(view, ".q-wi-st") == "Explore is queued"
  end

  test "each state of the pools has its reason", %{conn: conn, scope: scope} do
    work_item = queued(scope)
    name = scope.workspace.name

    # No gateway: the pool's choice is the workspace's default, and it has none.
    pool = keyed_pool(scope)

    assert reason(conn, scope, work_item) ==
             "No gateway exists for the gateway choice of the pool of #{name}. Choose a gateway for the pool on the Machines page."

    # The default gateway with no active key.
    _gateway = gateway_fixture(scope)

    assert reason(conn, scope, work_item) ==
             "The gateway of the pool of #{name} has no active access key. Enrol a machine on the gateway on the Machines page."

    # A gateway of another workspace, which does not serve this one, written straight into
    # the table: the form refuses that choice.
    second = workspace_fixture(scope.organisation, "Second")

    elsewhere =
      Repo.insert!(%Node{
        kind: :gateway,
        public_id: Apiary.PublicId.generate("ng"),
        name: unique_node_name(),
        organisation_id: scope.organisation.id,
        workspace_id: second.id,
        url: "https://gateway.example",
        gateway_choice: :direct
      })

    pool
    |> Ecto.Changeset.change(gateway_choice: :named, gateway_id: elsewhere.id)
    |> Repo.update!()

    assert reason(conn, scope, work_item) ==
             "The gateway chosen for the pool of #{name} does not serve #{name}. Choose another gateway for the pool on the Machines page."
  end

  test "pools in different states: the sentence for any reason", %{conn: conn, scope: scope} do
    _direct = direct_pool(scope)
    _without_key = pool_fixture(scope)
    work_item = queued(scope)

    assert reason(conn, scope, work_item) ==
             "No pool of #{scope.workspace.name} is ready to take runs. Set up a pool on the Machines page."
  end

  test "a reader who may not read the machines: no Open Machines, and Machines as plain words",
       %{conn: conn, scope: scope} do
    _pool = direct_pool(scope)
    work_item = queued(scope)
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ReadsNoMachines)
    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    assert words(view, "#work-item-explore-no-pool-reason") =~ "on the Machines page."
    refute has_element?(view, "#work-item-explore-no-pool-reason a")
    refute has_element?(view, "#work-item-explore-no-pool-open")
    assert words(view, "#work-item-step-no-pool") == "No pool can take the run."
    refute has_element?(view, "#work-item-step-no-pool-open")
  end

  test "a run a pool claimed: today's words", %{conn: conn, scope: scope} do
    _pool = direct_pool(scope)
    work_item = work_item_fixture(scope)

    explore_run_fixture(work_item,
      state: :claimed,
      registered: true,
      run: %{state: "pending", started_at: nil}
    )

    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    assert words(view, ".q-wi-st") == "Explore is queued"
    assert words(view, "#work-item-explore-wait-h") =~ "Explore is queued"
    refute has_element?(view, "#work-item-explore-no-pool")
    refute has_element?(view, "#work-item-step-no-pool")
  end

  test "before the take in's first run is queued: today's words", %{conn: conn, scope: scope} do
    _pool = direct_pool(scope)
    work_item = work_item_fixture(scope)
    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    assert words(view, ".q-wi-st") == "Explore is queued"
    refute has_element?(view, "#work-item-head-stage-status")
    refute has_element?(view, "#work-item-explore-no-pool")
    refute has_element?(view, "#work-item-step-no-pool")
  end

  test "a machine enrols a key on the pool's gateway: the page reads it again",
       %{conn: conn, scope: scope} do
    gateway = gateway_fixture(scope)
    _pool = keyed_pool(scope)
    work_item = queued(scope)
    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    assert has_element?(view, "#work-item-explore-no-pool")

    %{access_key: key} = enrolled_key_fixture(scope, gateway)

    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      AccessKeys.topic(scope.workspace.id, gateway.id),
      {:key_enrolled, %{key_id: key.key_id, node_id: gateway.id}}
    )

    refute has_element?(view, "#work-item-explore-no-pool")
    assert words(view, ".q-wi-st") == "Explore is queued"
  end

  test "the first render, before the browser connects, reads no gateway to listen to",
       %{conn: conn, scope: scope} do
    gateway = gateway_fixture(scope)

    # A named choice: the read of the gateway is made inside `chosen/1`, not in a tail call
    # that leaves no frame of it on the stack.
    _pool =
      scope
      |> keyed_pool()
      |> Ecto.Changeset.change(gateway_choice: :named, gateway_id: gateway.id)
      |> Repo.update!()

    work_item = queued(scope)

    assert chosen_reads(fn -> get(conn, page(scope, work_item.number)) end) == 0
    assert chosen_reads(fn -> live(conn, page(scope, work_item.number)) end) > 0
  end

  # How many queries, in any process, `Apiary.Gateways.chosen/1` makes while `fun` runs:
  # the reads of the gateways the page listens to (`listen_to_pools/1`). The module is
  # not async, so no other test makes them meanwhile.
  defp chosen_reads(fun) do
    handler = "chosen-reads-#{System.unique_integer()}"
    parent = self()

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

        if Enum.any?(stack, &match?({Apiary.Gateways, :chosen, 1, _}, &1)),
          do: send(parent, :chosen_read)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    count_reads(0)
  end

  defp count_reads(count) do
    receive do
      :chosen_read -> count_reads(count + 1)
    after
      0 -> count
    end
  end
end
