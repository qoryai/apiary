defmodule Apiary.Dispatches.InstancePoolTest do
  # The claims of the instance's node pool (`Apiary.Dispatches.claim/2`): it takes the
  # oldest waiting run of any workspace with no pool in use, across organisations, writes
  # the dispatch and the registered run in the run's workspace, counts its limit across
  # them, and leaves a run held for its build waiting. Then the claim's query on 200
  # workspaces. Not async: the instance has one pool and one gateway in use.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Nodes}
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Nodes.Node
  alias Apiary.Runs.Run

  @moduletag needs: :factory

  setup do
    gateway = instance_gateway_fixture()
    installed_key_fixture(gateway, allow_secrets: true)
    pool = instance_pool_fixture()
    %{access_key: key} = installed_key_fixture(pool)

    %{scope: a} = sign_up_fixture()
    %{scope: b} = sign_up_fixture()
    %{scope: c} = sign_up_fixture()

    %{pool: pool, key: key, gateway: gateway, a: a, b: b, c: c}
  end

  defp queued!(scope) do
    work_item = work_item_fixture(scope)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    run
  end

  defp claim(key), do: Dispatches.claim(key, Dispatches.now())

  defp place(row), do: {row.organisation_id, row.workspace_id}
  defp place_of(scope), do: {scope.organisation.id, scope.workspace.id}

  describe "claim/2 by the instance's pool" do
    test "takes the oldest waiting run of the workspaces with no pool in use, across organisations",
         ctx do
      # C has a pool that never enrolled: it is in use, and C's runs wait for it.
      _theirs = pool_fixture(ctx.c)
      a1 = queued!(ctx.a)
      c1 = queued!(ctx.c)
      b1 = queued!(ctx.b)
      a2 = queued!(ctx.a)

      taken =
        for _claim <- 1..3 do
          assert {:ok, %{run: run, dispatch: dispatch, registered: %Run{} = registered}} =
                   claim(ctx.key)

          assert place(Repo.get!(Dispatch, dispatch.id)) == place(run)
          assert place(Repo.get!(Run, registered.id)) == place(run)
          assert registered.node_id == ctx.pool.id
          {run.id, place(run)}
        end

      assert taken == [
               {a1.id, place_of(ctx.a)},
               {b1.id, place_of(ctx.b)},
               {a2.id, place_of(ctx.a)}
             ]

      assert claim(ctx.key) == {:ok, :none}
      assert Repo.get!(DispatchRun, c1.id).state == :waiting
    end

    test "takes a workspace's runs once its pool is deleted", ctx do
      theirs = pool_fixture(ctx.c)
      c1 = queued!(ctx.c)
      assert claim(ctx.key) == {:ok, :none}

      {:ok, _deleted} = Nodes.delete_node(ctx.c, theirs)
      assert {:ok, %{run: %{id: id}}} = claim(ctx.key)
      assert id == c1.id
    end

    test "a workspace's pool still takes only its workspace's runs", ctx do
      theirs = pool_fixture(ctx.c)
      %{access_key: their_key} = enrolled_key_fixture(ctx.c, theirs)
      Apiary.DispatchedRunsFixtures.gateway_for!(ctx.c, theirs)
      _a1 = queued!(ctx.a)
      c1 = queued!(ctx.c)

      assert {:ok, %{run: %{id: id}}} = claim(their_key)
      assert id == c1.id
      assert claim(their_key) == {:ok, :none}
    end

    test "counts its limit across workspaces", ctx do
      Repo.update_all(from(n in Node, where: n.id == ^ctx.pool.id), set: [instance_limit: 1])
      _a1 = queued!(ctx.a)
      b1 = queued!(ctx.b)

      assert {:ok, %{run: %{}}} = claim(ctx.key)
      assert claim(ctx.key) == {:ok, :none}
      assert Nodes.instances_in_use(Repo.reload!(ctx.pool), Dispatches.now()) == 1
      assert Repo.get!(DispatchRun, b1.id).state == :waiting
    end

    test "leaves a run held for its build waiting, and takes the next", ctx do
      held = work_item_fixture(ctx.a)

      _collection =
        collection_fixture(ctx.a,
          target_system: held.target_system,
          target_path: held.target_path
        )

      {:ok, held_run} = Repo.transact(fn -> Dispatches.queue(held, 1) end)
      b1 = queued!(ctx.b)

      assert {:ok, %{run: %{id: id}}} = claim(ctx.key)
      assert id == b1.id
      assert Repo.get!(DispatchRun, held_run.id).state == :waiting

      # In a workspace whose domain has no prebuilds, the same run is taken.
      with_domain(ctx.a, "general")
      assert {:ok, %{run: %{id: id}}} = claim(ctx.key)
      assert id == held_run.id
    end

    test "claims nothing while the instance's gateway has no active key", ctx do
      Repo.delete_all(from k in Apiary.AccessKeys.AccessKey, where: k.node_id == ^ctx.gateway.id)
      queued!(ctx.a)
      assert claim(ctx.key) == {:error, :no_gateway}
    end
  end

  describe "a request of the instance's pool" do
    test "records its instance with no organisation, and tells the instance's topic", ctx do
      :ok = Phoenix.PubSub.subscribe(Apiary.PubSub, Nodes.topic("instance"))
      instance_id = unique_instance_id()
      assert Nodes.seen(ctx.pool, %{instance_id: instance_id}) == :ok

      assert %Apiary.Nodes.Instance{organisation_id: nil, workspace_id: nil} =
               Repo.get_by!(Apiary.Nodes.Instance,
                 node_id: ctx.pool.id,
                 node_instance_id: instance_id
               )

      assert_received {:nodes_touched, "instance"}
    end
  end

  describe "the claim's query" do
    test "reads the waiting runs of 200 workspaces once", ctx do
      organisation = ctx.a.organisation

      for n <- 1..199 do
        workspace = workspace_fixture(organisation)
        scope = %{ctx.a | workspace: workspace}
        if rem(n, 2) == 0, do: pool_fixture(scope)
        queued!(scope)
      end

      plan = Repo.explain(:all, Dispatches.waiting_query(ctx.key), analyze: true, format: :map)
      scans = scans(plan, "dispatch_runs")

      assert scans != []
      assert Enum.all?(scans, &(&1["Actual Loops"] == 1)), inspect(scans)
      assert {:ok, %{run: %{}}} = claim(ctx.key)
    end
  end

  # The plan's nodes that read `table`.
  defp scans([%{"Plan" => plan} | _rest], table), do: scans(plan, table)

  defp scans(%{} = node, table) do
    found = if node["Relation Name"] == table, do: [node], else: []
    found ++ Enum.flat_map(Map.get(node, "Plans", []), &scans(&1, table))
  end
end
