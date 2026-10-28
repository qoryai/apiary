defmodule Apiary.Dispatches.InstancePoolTest do
  # The claims of the instance's node pool (`Apiary.Dispatches.claim/2`): it takes the
  # oldest waiting run of any workspace with no pool in use, across organisations, writes
  # the dispatch and the registered run in the run's workspace, counts its limit across
  # them, and leaves a run held for its build waiting until its prebuild, which it queues
  # in the run's workspace, made the image. Its release is in the trail of the run's
  # organisation. Then the gateway a claim with no workspace goes through, and the claim's
  # query on 200 workspaces. Not async: the instance has one pool and one gateway in use.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Nodes}
  alias Apiary.Audit.Entry
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

    test "takes no run of a workspace or an organisation marked for deletion", ctx do
      a1 = queued!(ctx.a)
      b1 = queued!(ctx.b)
      c1 = queued!(ctx.c)
      now = DateTime.utc_now(:second)

      Repo.update_all(
        from(o in Apiary.Organisations.Organisation, where: o.id == ^ctx.a.organisation.id),
        set: [deletion_marked_at: now, purge_after: now, purge_trigger: "grace_period"]
      )

      Repo.update_all(
        from(w in Apiary.Organisations.Workspace, where: w.id == ^ctx.b.workspace.id),
        set: [deletion_marked_at: now, purge_after: now, purge_trigger: "grace_period"]
      )

      assert {:ok, %{run: %{id: id}}} = claim(ctx.key)
      assert id == c1.id
      assert claim(ctx.key) == {:ok, :none}
      assert Repo.get!(DispatchRun, a1.id).state == :waiting
      assert Repo.get!(DispatchRun, b1.id).state == :waiting
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
      with_domain(ctx.a, "example")
      assert {:ok, %{run: %{id: id}}} = claim(ctx.key)
      assert id == held_run.id
    end

    test "claims nothing while the instance's gateway has no active key", ctx do
      Repo.delete_all(from k in Apiary.AccessKeys.AccessKey, where: k.node_id == ^ctx.gateway.id)
      queued!(ctx.a)
      assert claim(ctx.key) == {:error, :no_gateway}
    end
  end

  describe "a release by the instance's pool" do
    test "is in the trail of the dispatch's organisation, about the pool", ctx do
      instance = instance_scope()
      queued!(ctx.a)
      {:ok, %{dispatch: dispatch}} = claim(ctx.key)

      assert Dispatches.release(ctx.key, dispatch.public_id, %{reason: "No machine started."}) ==
               :ok

      assert [entry] =
               Repo.all(from e in Entry, where: e.action == "dispatch.release")

      assert entry.organisation_id == ctx.a.organisation.id
      assert entry.organisation_id != instance.organisation.id
      assert {entry.actor_kind, entry.actor_id} == {:access_key, ctx.key.id}
      assert {entry.subject_kind, entry.subject_id} == {"node", ctx.pool.id}
      assert entry.details["dispatch_id"] == dispatch.public_id
    end
  end

  describe "a prebuild for the instance's pool" do
    @image "registry.example.com/acme/shop-env@sha256:" <> String.duplicate("4c", 32)

    # A waiting run of a work item of `scope` with a target, and a collection of that
    # target with an `environment_ref`: the run is held for the pool's build.
    defp held!(scope) do
      work_item = work_item_fixture(scope)

      collection =
        collection_fixture(scope,
          target_system: work_item.target_system,
          target_path: work_item.target_path
        )

      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      {run, collection, %{system: work_item.target_system, path: work_item.target_path}}
    end

    test "is queued in a served workspace, and its image is the held run's", ctx do
      {held, collection, target} = held!(ctx.a)

      assert {:ok, %{run: %DispatchRun{step: "prebuild"} = prebuild, collection: %{id: id}}} =
               claim(ctx.key)

      assert id == collection.id
      assert prebuild.pool_id == ctx.pool.id
      assert place(prebuild) == place_of(ctx.a)

      assert [%Apiary.Environments.Record{} = record] =
               Repo.all(
                 from r in Apiary.Environments.Record,
                   where: r.pool_id == ^ctx.pool.id and r.source_collection_id == ^collection.id
               )

      assert place(record) == place_of(ctx.a)

      {:ok, :ok} =
        Repo.transact(fn ->
          {:ok,
           Apiary.Environments.record_build(
             Repo.get!(DispatchRun, prebuild.id),
             %{image: @image, size: 1_048_576, commit: "4b7d0a3f", environment_ref: "env-1"},
             target,
             DateTime.utc_now()
           )}
        end)

      assert Apiary.Environments.image_for(ctx.pool, ctx.a.workspace.id, target) == @image

      assert {:ok, %{run: %{id: id}, registered: %Run{configured_image: @image}}} =
               claim(ctx.key)

      assert id == held.id
    end

    test "is not queued for a workspace with a pool in use", ctx do
      _theirs = pool_fixture(ctx.c)
      {held, collection, _target} = held!(ctx.c)

      assert claim(ctx.key) == {:ok, :none}
      assert Repo.get!(DispatchRun, held.id).state == :waiting

      refute Repo.exists?(
               from r in DispatchRun,
                 where: r.source_collection_id == ^collection.id and r.pool_id == ^ctx.pool.id
             )
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

  describe "the gateway of a claim with no workspace (`Apiary.Dispatches.Handover.serves?/2`)" do
    alias Apiary.Dispatches.Handover

    test "is the instance's gateway in use, and no other", ctx do
      assert Handover.serves?(ctx.gateway, nil)
      refute Handover.serves?(%{ctx.gateway | deleted_at: DateTime.utc_now()}, nil)

      theirs = gateway_fixture(ctx.a)
      refute Handover.serves?(theirs, nil)
      refute Handover.serves?(organisation_gateway_fixture(ctx.b), nil)
      assert Handover.serves?(theirs, ctx.a.workspace)
    end
  end

  describe "the claim's query" do
    # Postgres plans the waiting query from its statistics. Without them, as on tables
    # filled inside a test's transaction, it may read an organisation's workspaces once
    # for each waiting run. With them, as autovacuum keeps them in production, it reads
    # each table once, or probes `dispatch_runs_waiting_index` once per workspace; both
    # are plans it may choose, and each reads every run of the queue at most once. The
    # test gives Postgres the statistics, then holds what the claim costs: each run of the
    # queue read at most once, at most 5 rows read over the whole plan for each run, each
    # run's harness walk and each workspace, and one query for the queue, whatever the
    # number of workspaces. The walks count because the query skips a run whose walk has
    # not resolved, which reads each walk once. The plans seen read 1,404 to 1,920 rows
    # locally and 2,119 on CI, under the bound of 3,015. With index scans, hash joins,
    # materialize and memoize turned off, the plan scans tables once per run and reads
    # 112,304.
    test "reads each run of the queue of 200 workspaces at most once, in one query", ctx do
      queued!(ctx.b)
      few = claim_queries(ctx.key)
      organisation = ctx.a.organisation

      for n <- 1..199 do
        workspace = workspace_fixture(organisation)
        scope = %{ctx.a | workspace: workspace}
        if rem(n, 2) == 0, do: pool_fixture(scope)
        queued!(scope)
      end

      runs = Repo.aggregate(DispatchRun, :count)
      workspaces = Repo.aggregate(Apiary.Organisations.Workspace, :count)
      walks = Repo.aggregate(Apiary.Harnesses.RunHarness, :count)

      Repo.query!(
        "ANALYZE dispatch_runs, workspaces, organisations, nodes, source_collections, " <>
          "work_items, environments, run_harnesses"
      )

      [%{"Plan" => plan}] =
        Repo.explain(:all, Dispatches.waiting_query(ctx.key), analyze: true, format: :map)

      scans = scans(plan, "dispatch_runs")
      assert scans != []
      assert rows_read(scans) <= runs, inspect(scans)
      assert rows_read(nodes(plan)) <= 5 * (runs + walks + workspaces)

      many = claim_queries(ctx.key)
      queue = Enum.filter(many, &(&1 =~ "SKIP LOCKED" and &1 =~ ~s|FROM "dispatch_runs"|))
      assert length(queue) == 1
      assert length(many) == length(few)
    end
  end

  # The statements a claim by `key` runs, which claims a run.
  defp claim_queries(key) do
    handler = "claim-queries-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == parent, do: send(parent, {:claim_query, meta.query})
      end,
      nil
    )

    try do
      assert {:ok, %{run: %{}}} = claim(key)
    after
      :telemetry.detach(handler)
    end

    collect_queries([])
  end

  defp collect_queries(acc) do
    receive do
      {:claim_query, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The rows the plan's nodes read, over every loop: those returned and those a filter
  # removed. EXPLAIN gives both per loop; a node never run has 0 loops.
  defp rows_read(nodes) do
    nodes
    |> Enum.map(fn node ->
      (node["Actual Rows"] + Map.get(node, "Rows Removed by Filter", 0)) * node["Actual Loops"]
    end)
    |> Enum.sum()
  end

  # The plan's nodes that read `table`.
  defp scans(node, table), do: Enum.filter(nodes(node), &(&1["Relation Name"] == table))

  # The plan's nodes, `node` and every node under it.
  defp nodes(%{} = node), do: [node | Enum.flat_map(Map.get(node, "Plans", []), &nodes/1)]
end
