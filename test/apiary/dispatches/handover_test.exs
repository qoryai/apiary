defmodule Apiary.Dispatches.HandoverTest do
  # The run a claim registers (`Apiary.Dispatches.Handover.register/2`, through
  # `Apiary.Dispatches.claim/3`), and a node pool's starter on a dispatch its pool claimed
  # (`dispatched/3`): the run registered on the pool, its instance the run's id, its labels
  # and its run variables from the target, what it is about from the step and the work
  # item, its run code bound to the gateway and its grant, the dispatch and the run of the
  # queue left claimed; the runs the claim cannot form ended in its transaction, and the
  # claim's next run taken; no gateway and a failure, after which nothing is written;
  # each refusal of `dispatched/3` in the contract's order, the lapse judged before
  # anything else and committed, and the handover at the first `dispatched`.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures, only: [contract_key_fixture: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, ExploreInputsSchema, Nodes, Repo, WorkItems}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Inputs, Slots}
  alias Apiary.Harnesses.{Builtin, Qory, RunHarness}
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Registration, Run, RunCode}
  alias Apiary.Sources.Comment
  alias Apiary.WorkItems.WorkItem
  alias Apiary.PublicGitServer
  alias Apiary.QoryHarnessFixture

  @moduletag needs: :factory

  @body ~s({"version":3,"time":"2026-10-18T12:00:00Z"})

  setup do
    %{scope: scope} = sign_up_fixture()
    Map.put(handover_place_fixture(scope), :scope, scope)
  end

  defp queued!(ctx, attrs \\ %{}) do
    work_item = work_item_fixture(ctx.scope, attrs)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {work_item, run}
  end

  defp prebuild!(ctx, attrs \\ %{}) do
    collection = collection_fixture(ctx.scope, attrs)

    {:ok, run} =
      Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

    {collection, run}
  end

  defp claim(ctx),
    do: Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now(), @body)

  # A claim that took a run: what it took.
  defp claimed!(ctx) do
    {:ok, %{dispatch: %Dispatch{}} = claimed} = claim(ctx)
    claimed
  end

  defp dispatched(key, dispatch_id, external \\ nil),
    do: Dispatches.dispatched(key, id(dispatch_id), %{external: external})

  defp id(%{dispatch: %Dispatch{public_id: public_id}}), do: public_id
  defp id(%Dispatch{public_id: public_id}), do: public_id
  defp id(public_id), do: public_id

  defp dispatch!(%{dispatch: dispatch}), do: dispatch!(dispatch)
  defp dispatch!(%Dispatch{id: id}), do: Repo.get!(Dispatch, id)
  defp queue_run!(%DispatchRun{id: id}), do: Repo.get!(DispatchRun, id)
  defp runs, do: Repo.aggregate(Run, :count)

  # The runs registered for a run of the queue, a run whose start failed left out.
  defp queue_runs,
    do: Repo.aggregate(from(r in Run, where: not is_nil(r.dispatch_run_id)), :count)

  # The run the claim `claimed` registered, failed with `cause` once it left its run of
  # the queue: its id and its public id kept, its node's run id another, its dispatch the
  # claim's.
  defp start_failed!(%{registered: registered, dispatch: dispatch}, cause) do
    run = Repo.get!(Run, registered.id)

    assert %Run{
             state: "failed",
             reason: ^cause,
             start_failure: ^cause,
             start_failed_at: %DateTime{},
             dispatch_run_id: nil,
             run_documents: nil
           } = run

    assert run.dispatch_id == dispatch.id
    assert run.public_id == registered.public_id
    assert run.node_run_id != registered.node_run_id
    assert run.node_instance_id == run.node_run_id
    run
  end

  defp dispatches, do: Repo.aggregate(Dispatch, :count)

  # The inputs of the run's documents, as JSON decodes them.
  defp inputs(%{documents: %{inputs: inputs}}), do: inputs |> Jason.encode!() |> Jason.decode!()

  # Past its lease, as the clock would have it ten minutes and more after the claim.
  defp lapse!(%{dispatch: dispatch}), do: lapse!(dispatch)

  defp lapse!(%Dispatch{id: id}) do
    now = DateTime.utc_now()

    lease_until = %{
      DateTime.truncate(DateTime.add(now, -60, :second), :second)
      | microsecond: {0, 6}
    }

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set: [claimed_at: DateTime.add(now, -700, :second), lease_until: lease_until]
      )
  end

  defp set_node!(%Node{id: id}, fields),
    do: {1, _rows} = Repo.update_all(from(n in Node, where: n.id == ^id), set: fields)

  # The run of the queue and the dispatch the claim wrote for it ended with `cause`, the
  # slot freed once, no run registered. An explore run the claim could not form gave an
  # error, stored with its end; a prebuild gave nothing.
  defp ended!(ctx, %DispatchRun{} = run, cause) do
    outcome =
      if run.step != "prebuild" and cause in [:variables_invalid, :ticket_gone, :inputs_invalid],
        do: :error

    assert %DispatchRun{state: :ended, end_cause: ^cause, result_outcome: ^outcome, result: nil} =
             queue_run!(run)

    assert [%Dispatch{end_cause: ^cause, ended_at: %DateTime{} = at, slot_freed_at: at}] =
             Repo.all(from d in Dispatch, where: d.dispatch_run_id == ^run.id)

    assert Slots.held(ctx.pool.id) == 0
    assert runs() == 0
  end

  describe "the run a claim of an explore run registers" do
    test "is registered through the gateway, on the pool, its instance the run's id", ctx do
      {work_item, queued} = queued!(ctx)
      claimed = claimed!(ctx)
      assert claimed.run.id == queued.id
      assert claimed.work_item.id == work_item.id
      assert claimed.documents.domain == "software"
      assert claimed.documents.target == %{system: "forge.example.com", path: "acme/shop"}
      assert claimed.documents.work_item.id == work_item.id
      assert claimed.gateway_url == ctx.gateway.url

      run = Repo.get!(Run, claimed.registered.id)
      run_id = queued.run_id
      pool_id = ctx.pool.id
      key_id = ctx.key.id
      gateway_id = ctx.gateway.id
      dispatch_run_id = queued.id

      assert %Run{
               node_run_id: ^run_id,
               node_id: ^pool_id,
               node_instance_id: ^run_id,
               access_key_id: ^key_id,
               gateway_id: ^gateway_id,
               dispatch_run_id: ^dispatch_run_id,
               state: "pending",
               forager_version: nil,
               contract_version: nil,
               registration_interval_seconds: nil,
               registration_answer_digest: nil,
               attached_at: nil,
               run_key_payload: nil,
               run_key_signature: nil,
               run_code_public_key: nil,
               projected_sequence: 1
             } = run

      assert run.registration_labels == %{
               "forge" => "forge.example.com",
               "repository" => "acme/shop",
               "repositories" => "acme/shop"
             }

      assert run.registration_about == %{
               "kind" => "explore",
               "subjects" => [%{"type" => "work_item", "ref" => work_item.public_id}]
             }

      assert run.registration_variables == %{
               "QORY_RUN_SYSTEM" => "forge.example.com",
               "QORY_RUN_REPOSITORIES" => "acme/shop"
             }

      assert run.registration_digest == :crypto.hash(:sha256, @body)

      # The run code: its SHA-256 kept, never the code; its expiry 15 minutes after the
      # claim, the attach window with it; the grant its run key is made from at the
      # code's redemption, bound to the gateway.
      assert run.run_code_sha256 != nil
      refute inspect(run, limit: :infinity) =~ claimed.run_code

      assert DateTime.diff(run.run_code_expires_at, run.run_key_issued_at) ==
               RunCode.ttl_seconds()

      assert run.attach_by == run.run_code_expires_at
      assert run.run_key_issued_at == DateTime.truncate(run.registered_at, :second) |> usec()

      {gateway_key, _seed} = ctx.gateway_key

      assert run.run_code_grant == %{
               "run_id" => run_id,
               "instance_id" => run_id,
               "node_id" => ctx.pool.public_id,
               "workspace" => ctx.scope.workspace.public_id,
               "gateway" => ctx.gateway.public_id,
               "gateway_url" => ctx.gateway.url,
               "gateway_public_keys" => [Apiary.Contract.Ed25519.encode(gateway_key.public_key)]
             }

      # The dispatch and the run of the queue stay claimed, the slot held; the run counts
      # by its slot alone.
      assert %Dispatch{handed_over_at: nil, slot_freed_at: nil, ended_at: nil} =
               dispatch!(claimed)

      assert queue_run!(queued).state == :claimed
      assert Slots.held(ctx.pool.id) == 1
      assert Nodes.instances_in_use(ctx.pool, Dispatches.now()) == 1
    end

    test "leaves the run's id refused at the run endpoint, under any key", ctx do
      {_work_item, queued} = queued!(ctx)
      _claimed = claimed!(ctx)

      %{access_key: node_key} = contract_key_fixture(ctx.scope, %{})

      body =
        Jason.encode!(%{
          "version" => 1,
          "run_id" => queued.run_id,
          "time" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
        })

      {:ok, registration} = Registration.parse(Jason.decode!(body))

      for key <- [node_key, ctx.key] do
        assert Registration.register(key, registration, %{body: body, contract_version: 1}) ==
                 {:error, :run_id_used}
      end
    end

    test "has the explore input, from the rows Qory keeps", ctx do
      {work_item, _queued} = queued!(ctx, %{first_instruction: "Look at the cart first."})
      item = Repo.get!(Apiary.Sources.Item, work_item.item_id)
      inputs = inputs(claimed!(ctx))

      assert inputs["version"] == 1
      assert inputs["work_item"]["id"] == work_item.public_id
      assert inputs["work_item"]["number"] == work_item.number
      assert inputs["run"] == %{"attempt" => 1}

      assert inputs["ticket"] == %{
               "external_ref" => work_item.external_ref,
               "url" => work_item.url,
               "title" => work_item.title,
               "body" => item.body,
               "filed_by" => %{"name" => "Avery Example", "kind" => "person"},
               "filed_at" => DateTime.to_iso8601(item.source_created_at),
               "collection" => work_item.collection_title
             }

      # Who took it in, by the local part of their address.
      [local | _] = String.split(ctx.scope.user.email, "@")
      assert inputs["instruction"]["text"] == "Look at the cart first."
      assert inputs["instruction"]["by"] == %{"name" => local}
      assert inputs["instruction"]["at"] =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/
      assert inputs["comments"] == []
      assert inputs["comments_omitted"] == 0

      # The answers, the proposal and the review comments are artifacts the run pulls.
      for key <- ~w(answers proposal changes facts solution),
          do: refute(Map.has_key?(inputs, key))

      assert inputs["target"] == %{"system" => "forge.example.com", "path" => "acme/shop"}
      assert inputs["domain"] == "software"
    end
  end

  describe "the run a claim of a prebuild registers" do
    # A claim takes a prebuild only on an instance with a registry.
    @describetag needs: [:factory, :registry]

    test "has its collection's target, its input exactly the ref it was queued for", ctx do
      {collection, queued} = prebuild!(ctx)
      claimed = claimed!(ctx)

      assert claimed.documents.work_item == nil
      assert claimed.documents.domain == "software"

      assert claimed.documents.target == %{
               system: collection.target_system,
               path: collection.target_path
             }

      assert Jason.encode!(claimed.documents.inputs) ==
               ~s({"version":1,"environment_ref":"env-1"})

      run = Repo.get!(Run, claimed.registered.id)
      assert run.registration_about == %{"kind" => "prebuild"}

      assert run.registration_labels == %{
               "forge" => collection.target_system,
               "repository" => collection.target_path,
               "repositories" => collection.target_path
             }

      assert run.registration_variables == %{
               "QORY_RUN_SYSTEM" => collection.target_system,
               "QORY_RUN_REPOSITORIES" => collection.target_path
             }

      assert queue_run!(queued).state == :claimed
    end

    test "is registered with its Backlog switch off, or a collection with no items", ctx do
      {collection, _queued} = prebuild!(ctx)

      {1, _rows} =
        Repo.update_all(from(c in Apiary.Adapters.Collection, where: c.id == ^collection.id),
          set: [backlog: false, items: false]
        )

      assert %{registered: %Run{}} = claimed!(ctx)
    end

    test "keeps the ref it was claimed for, while a newer one waits", ctx do
      {collection, _queued} = prebuild!(ctx)
      claimed = claimed!(ctx)

      # The collection's ref changes after the claim: another prebuild waits for the new
      # one, and the claimed run keeps the ref it was queued for.
      {:ok, _waiting} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-2") end)

      assert :ok = dispatched(ctx.key, claimed)
      assert runs() == 1
      run = Repo.get!(Run, claimed.registered.id)
      assert run.dispatch_run_id == claimed.run.id
    end

    test "superseded while its lease lapsed is gone, its registered run failed", ctx do
      {collection, queued} = prebuild!(ctx)
      claimed = claimed!(ctx)

      # Another prebuild of the collection, pool and ref waits while the first is claimed.
      {:ok, _waiting} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      lapse!(claimed)
      assert dispatched(ctx.key, claimed) == {:error, :gone}
      assert %DispatchRun{state: :ended, end_cause: :superseded} = queue_run!(queued)
      assert %Dispatch{end_cause: :run_ended, stale_at: %DateTime{}} = dispatch!(claimed)
      assert queue_runs() == 0
      start_failed!(claimed, "lease_lapsed")
    end

    test "ends collection_ended when its collection ended, was unassigned, moved or lost its target",
         ctx do
      other = workspace_fixture(ctx.scope.organisation)

      # The claim ends the run as it takes it, before it claims it: no dispatch.
      for change <- [
            [ended_at: DateTime.utc_now(), ended_reason: :not_listed],
            [workspace_id: nil],
            [workspace_id: other.id],
            [target_system: nil, target_path: nil]
          ] do
        {collection, queued} = prebuild!(ctx)
        before = dispatches()

        {1, _rows} =
          Repo.update_all(from(c in Apiary.Adapters.Collection, where: c.id == ^collection.id),
            set: change
          )

        assert claim(ctx) == {:ok, :none}
        assert %DispatchRun{state: :ended, end_cause: :collection_ended} = queue_run!(queued)
        assert dispatches() == before
        assert runs() == 0
      end
    end
  end

  describe "a claim with no gateway, or that fails" do
    test "is no_gateway for each cause, and writes nothing", ctx do
      {_work_item, queued} = queued!(ctx)
      other_workspace = workspace_fixture(ctx.scope.organisation)
      elsewhere = gateway_fixture(%{ctx.scope | workspace: other_workspace})
      {gateway_key, _seed} = ctx.gateway_key

      causes = [
        {fn -> set_node!(ctx.pool, gateway_choice: :direct) end,
         fn -> set_node!(ctx.pool, gateway_choice: :default) end},
        {fn -> set_node!(ctx.gateway, default_gateway: false) end,
         fn -> set_node!(ctx.gateway, default_gateway: true) end},
        {fn -> set_node!(ctx.pool, gateway_choice: :named, gateway_id: elsewhere.id) end,
         fn -> set_node!(ctx.pool, gateway_choice: :default, gateway_id: nil) end},
        {fn ->
           Repo.update_all(from(k in AccessKey, where: k.id == ^gateway_key.id),
             set: [revoked_at: DateTime.utc_now()]
           )
         end,
         fn ->
           Repo.update_all(from(k in AccessKey, where: k.id == ^gateway_key.id),
             set: [revoked_at: nil]
           )
         end}
      ]

      for {break, mend} <- causes do
        break.()
        assert claim(ctx) == {:error, :no_gateway}
        assert queue_run!(queued).state == :waiting
        assert {dispatches(), runs()} == {0, 0}
        mend.()
      end

      assert %{registered: %Run{}} = claimed!(ctx)
    end

    test "a run that cannot be stored is unavailable, and nothing is written", ctx do
      {_work_item, queued} = queued!(ctx)

      # A row of the run's id in the workspace already, which no product path writes: the
      # registered run cannot be inserted.
      in_the_way =
        Repo.insert!(%Run{
          number:
            Apiary.RunEventsFixtures.next_run_number(
              ctx.scope.organisation.id,
              ctx.scope.workspace.id
            ),
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id,
          node_run_id: queued.run_id,
          state: "pending"
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert claim(ctx) == {:error, :unavailable}
        end)

      assert log =~ "a claim could not be made: Ecto.ConstraintError"
      refute log =~ queued.run_id
      assert runs() == 1
      assert dispatches() == 0
      assert queue_run!(queued).state == :waiting
      assert Slots.held(ctx.pool.id) == 0

      Repo.delete!(in_the_way)
      assert %{registered: %Run{}} = claimed!(ctx)
    end
  end

  describe "the refusals of dispatched, in their order" do
    test "an id not of a dispatch's shape, an unknown one and another pool's are one answer, forbidden",
         ctx do
      queued!(ctx)
      claimed = claimed!(ctx)
      %{access_key: other} = enrolled_key_fixture(ctx.scope, pool_fixture(ctx.scope))

      for {key, id} <- [
            {ctx.key, "dp_0000000000000000"},
            {ctx.key, "not a dispatch"},
            {ctx.key, nil},
            {ctx.key, String.upcase(claimed.dispatch.public_id)},
            {other, claimed.dispatch.public_id}
          ] do
        assert dispatched(key, id) == {:error, :forbidden}
      end

      # Another organisation's pool.
      %{scope: elsewhere} = sign_up_fixture()
      %{key: elsewhere_key} = handover_place_fixture(elsewhere)
      assert dispatched(elsewhere_key, claimed) == {:error, :forbidden}

      assert %Dispatch{handed_over_at: nil, dispatched_at: nil} = dispatch!(claimed)
    end

    test "a key that is no longer a pool's verified key is unauthorized", ctx do
      queued!(ctx)
      claimed = claimed!(ctx)

      %{access_key: node_key} = contract_key_fixture(ctx.scope, %{})
      assert dispatched(node_key, claimed) == {:error, :unauthorized}

      {1, _rows} =
        Repo.update_all(from(k in AccessKey, where: k.id == ^ctx.key.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert dispatched(ctx.key, claimed) == {:error, :unauthorized}
      assert %Dispatch{handed_over_at: nil, dispatched_at: nil} = dispatch!(claimed)
    end

    test "a dispatch that ended is gone, before lease_expired, its registered run deleted",
         ctx do
      {work_item, _queued} = queued!(ctx)
      claimed = claimed!(ctx)

      {:ok, _changed} =
        Repo.transact(fn -> Dispatches.cancel_for_close([work_item.id], Dispatches.now()) end)

      assert runs() == 0
      lapse!(claimed)
      assert dispatched(ctx.key, claimed) == {:error, :gone}
    end

    test "a dispatch of a run that ended after its handover is gone", ctx do
      {_work_item, queued} = queued!(ctx)
      claimed = claimed!(ctx)
      assert dispatched(ctx.key, claimed) == :ok

      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^queued.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      assert dispatched(ctx.key, claimed) == {:error, :gone}
    end

    test "a lease lapsed and not yet swept lapses first, committed: lease_expired, the run waits again",
         ctx do
      {_work_item, queued} = queued!(ctx)
      claimed = claimed!(ctx)
      lapse!(claimed)

      assert dispatched(ctx.key, claimed) == {:error, :lease_expired}

      assert %Dispatch{stale_at: %DateTime{}, slot_freed_at: %DateTime{}, dispatched_at: nil} =
               dispatch!(claimed)

      assert queue_run!(queued).state == :waiting
      assert Slots.held(ctx.pool.id) == 0
      assert queue_runs() == 0
      failed = start_failed!(claimed, "lease_lapsed")
      assert dispatched(ctx.key, claimed) == {:error, :lease_expired}

      # A later claim registers the run anew, with another code, under the run of the
      # queue's run id; the stale dispatch stays lease_expired, and the failed run stays
      # failed.
      later = claimed!(ctx)
      assert later.run_code != claimed.run_code
      assert later.registered.id != claimed.registered.id
      assert later.registered.node_run_id == claimed.registered.node_run_id
      assert later.registered.dispatch_run_id == queued.id
      assert dispatched(ctx.key, later) == :ok
      assert dispatched(ctx.key, claimed) == {:error, :lease_expired}
      assert Repo.get!(Run, failed.id).state == "failed"
      assert runs() == 2
    end
  end

  describe "the first dispatched" do
    test "broadcasts the run its claim registered as changed, and a later one does not",
         ctx do
      _queued = queued!(ctx)
      %{registered: %Run{id: id} = run} = claimed = claimed!(ctx)
      Phoenix.PubSub.subscribe(Apiary.PubSub, Apiary.Runs.topic(run.workspace_id, id))

      assert dispatched(ctx.key, claimed) == :ok
      assert_received {:run_changed, %Run{id: ^id}}

      assert dispatched(ctx.key, claimed) == :ok
      refute_received {:run_changed, %Run{}}
    end
  end

  # The target of the work items queued here, with `paths` its runs also read, saved as an
  # owner saves them.
  defp further!(ctx, paths) do
    :ok =
      Apiary.Runs.Target.insert_new(ctx.scope.organisation.id, ctx.scope.workspace.id, [
        %{system: "forge.example.com", path: "acme/shop"}
      ])

    target = Apiary.Targets.get(ctx.scope, "forge.example.com", "acme/shop")
    {:ok, target} = Apiary.Targets.set_further_repositories(ctx.scope, target, paths)
    target
  end

  describe "the further repositories of the run's target" do
    test "follow its repository in QORY_RUN_REPOSITORIES, in the order saved", ctx do
      further!(ctx, "acme/docs\nacme/tools")
      {_work_item, _queued} = queued!(ctx)

      run = Repo.get!(Run, claimed!(ctx).registered.id)

      assert run.registration_variables == %{
               "QORY_RUN_SYSTEM" => "forge.example.com",
               "QORY_RUN_REPOSITORIES" => "acme/shop,acme/docs,acme/tools"
             }

      assert run.registration_labels == %{
               "forge" => "forge.example.com",
               "repository" => "acme/shop",
               "repositories" => "acme/shop,acme/docs,acme/tools"
             }
    end

    test "an empty saved list gives the repositories label its repository alone", ctx do
      further!(ctx, "")
      {_work_item, _queued} = queued!(ctx)

      assert Repo.get!(Run, claimed!(ctx).registered.id).registration_labels == %{
               "forge" => "forge.example.com",
               "repository" => "acme/shop",
               "repositories" => "acme/shop"
             }
    end

    test "a saved list that breaks the rules now ends the run variables_invalid at the claim",
         ctx do
      target = further!(ctx, "acme/docs")

      {1, _rows} =
        Repo.update_all(from(t in Apiary.Runs.Target, where: t.id == ^target.id),
          set: [further_repositories: ["other/docs"]]
        )

      {_work_item, queued} = queued!(ctx)

      assert claim(ctx) == {:ok, :none}
      ended!(ctx, queued, :variables_invalid)
    end
  end

  describe "the harness at the claim" do
    # A run whose harness walk resolved `git` on `ref`, its pin at the commit the walk at
    # the queue read.
    defp walked!(ctx, git, ref, at, changes \\ []) do
      {_work_item, queued} = queued!(ctx)

      walk_resolved!(
        queued,
        [
          origin: :setting,
          workflow: "explore-a-ticket",
          document: %{"extends" => %{"git" => git, "ref" => ref, "stack" => "software"}},
          pins: [%{"git" => git, "ref" => ref, "at" => at}]
        ] ++ changes
      )

      queued
    end

    # The info/refs requests the test's stub answered for the Qory harness's repository.
    defp ref_reads do
      path = URI.parse(Qory.git()).path <> "/info/refs"

      Stream.repeatedly(fn ->
        receive do
          {:git_request, "GET", _host, ^path, _headers} -> :read
          {:git_request, _method, _host, _path, _headers} -> :other
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
      |> Enum.count(&(&1 == :read))
    end

    # A host that answers every request with `status`.
    defp answer!(status),
      do: PublicGitServer.serve(%{}, answer: fn conn -> Plug.Conn.send_resp(conn, status, "") end)

    defp walk!(%DispatchRun{id: id}), do: Repo.get_by!(RunHarness, dispatch_run_id: id)

    test "the Qory harness is at the commit its branch is at when the claim reads it, which the walk's pin records",
         ctx do
      queued = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      # main moved after the walk at the queue read it.
      newer = QoryHarnessFixture.serve!(QoryHarnessFixture.explore_named("Discover"))

      claimed = claimed!(ctx)

      assert claimed.documents.harness.harness == %{
               "extends" => %{"git" => Qory.git(), "ref" => newer.commit, "stack" => "software"}
             }

      assert walk!(queued).pins == [%{"git" => Qory.git(), "ref" => "main", "at" => newer.commit}]

      # The walk keeps the version the settings chose, and nothing is stored of the read.
      assert walk!(queued).document["extends"]["ref"] == "main"
      assert Qory.head("main") == QoryHarnessFixture.commit()
    end

    test "the Qory harness at a tag is at the tag's commit", ctx do
      tagged = QoryHarnessFixture.serve!(QoryHarnessFixture.files(), tags: ["v1.0.0"])
      queued = walked!(ctx, Qory.git(), "v1.0.0", tagged.commit, ref_kind: :tag)

      assert claimed!(ctx).documents.harness.harness["extends"]["ref"] == tagged.commit
      assert [%{"at" => at}] = walk!(queued).pins
      assert at == tagged.commit
    end

    test "a walk's ref kind is a branch, a tag or a commit, or none", ctx do
      queued = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      id = Ecto.UUID.dump!(walk!(queued).id)

      for kind <- [nil, "branch", "tag", "commit"] do
        assert {:ok, %{num_rows: 1}} =
                 Repo.query("UPDATE run_harnesses SET ref_kind = $1 WHERE id = $2", [kind, id])
      end

      assert_raise Postgrex.Error, ~r/run_harnesses_ref_kind_check/, fn ->
        Repo.query!("UPDATE run_harnesses SET ref_kind = 'latest' WHERE id = $1", [id])
      end
    end

    test "a test work item's built-in harness is at the commit of qory's main", ctx do
      {:ok, work_item} = WorkItems.take_in_test(ctx.scope, "Hello! Where are you running?")
      [queued] = Repo.all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)
      git = Builtin.document()["extends"]["git"]

      assert claimed!(ctx).documents.harness.harness == %{
               "extends" => %{
                 "git" => git,
                 "ref" => QoryHarnessFixture.builtin_commit(),
                 "path" => "examples/hello"
               }
             }

      assert walk!(queued).pins == [
               %{"git" => git, "ref" => "main", "at" => QoryHarnessFixture.builtin_commit()}
             ]
    end

    test "a branch the built-in harness's repository does not have ends the run, marked built-in",
         ctx do
      {:ok, work_item} = WorkItems.take_in_test(ctx.scope, "Hello! Where are you running?")
      [queued] = Repo.all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)
      walk = walk!(queued)
      git = Builtin.git()

      walk
      |> Ecto.Changeset.change(
        document: put_in(walk.document, ["extends", "ref"], "gone"),
        pins: [%{"git" => git, "ref" => "gone", "at" => "gone"}]
      )
      |> Repo.update!()

      ExUnit.CaptureLog.capture_log(fn -> assert claim(ctx) == {:ok, :none} end)

      assert %DispatchRun{end_cause: :harness_unresolved, end_detail: "ref_missing"} =
               queue_run!(queued)

      assert %RunHarness{
               failure: "ref_missing",
               failure_rule: %{
                 "rule" => "claim",
                 "values" => %{"url" => ^git, "ref" => "gone", "builtin" => true}
               }
             } = walk!(queued)
    end

    test "a ref the Qory harness does not have ends the run harness_unresolved, ref_missing",
         ctx do
      queued = walked!(ctx, Qory.git(), "gone", QoryHarnessFixture.commit())

      log = ExUnit.CaptureLog.capture_log(fn -> assert claim(ctx) == {:ok, :none} end)

      assert %DispatchRun{
               state: :ended,
               end_cause: :harness_unresolved,
               end_detail: "ref_missing",
               result_outcome: :error
             } = queue_run!(queued)

      assert [%Dispatch{end_cause: :harness_unresolved, ended_at: %DateTime{}}] =
               Repo.all(from d in Dispatch, where: d.dispatch_run_id == ^queued.id)

      assert %RunHarness{
               state: :failed,
               origin: nil,
               document: nil,
               failure: "ref_missing",
               failed_source: "https://github.com/qoryai/harness",
               failure_rule: %{
                 "rule" => "claim",
                 "values" => %{"url" => "https://github.com/qoryai/harness", "ref" => "gone"}
               }
             } = walk!(queued)

      assert Slots.held(ctx.pool.id) == 0
      assert runs() == 0
      assert log =~ "end_cause=harness_unresolved failure=ref_missing"
    end

    test "a read that meets the host's limit leaves the run queued, and records the time once",
         ctx do
      queued = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      answer!(429)

      assert claim(ctx) == {:ok, :none}
      assert %DispatchRun{state: :waiting} = queue_run!(queued)
      assert %RunHarness{state: :resolved, read_failed_at: %DateTime{} = first} = walk!(queued)

      assert claim(ctx) == {:ok, :none}
      assert %DispatchRun{state: :waiting} = queue_run!(queued)
      assert walk!(queued).read_failed_at == first
      assert runs() == 0
    end

    test "a read that still fails 10 minutes after the first ends the run harness_unresolved, harness_unreadable",
         ctx do
      queued = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      answer!(429)
      assert claim(ctx) == {:ok, :none}

      walk!(queued)
      |> Ecto.Changeset.change(read_failed_at: DateTime.add(Dispatches.now(), -601))
      |> Ecto.Changeset.force_change(:updated_at, DateTime.add(Dispatches.now(), -31))
      |> Repo.update!()

      ExUnit.CaptureLog.capture_log(fn -> assert claim(ctx) == {:ok, :none} end)

      assert %DispatchRun{end_cause: :harness_unresolved, end_detail: "harness_unreadable"} =
               queue_run!(queued)

      assert %RunHarness{
               state: :failed,
               failure: "harness_unreadable",
               failure_rule: %{
                 "rule" => "claim",
                 "values" => %{
                   "url" => "https://github.com/qoryai/harness",
                   "ref" => "main",
                   "cause" => %{"cause" => "rate_limited"},
                   "host" => "github.com",
                   "port" => 443
                 }
               }
             } = walk!(queued)

      assert runs() == 0
    end

    test "a read that met a server error leaves the run queued", ctx do
      queued = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      answer!(500)

      ExUnit.CaptureLog.capture_log(fn -> assert claim(ctx) == {:ok, :none} end)
      assert %DispatchRun{state: :waiting} = queue_run!(queued)
      assert %RunHarness{state: :resolved, read_failed_at: %DateTime{}} = walk!(queued)
    end

    test "a read that met another 5xx status ends the run at once", ctx do
      queued = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      answer!(501)

      ExUnit.CaptureLog.capture_log(fn -> assert claim(ctx) == {:ok, :none} end)

      assert %DispatchRun{end_cause: :harness_unresolved, end_detail: "harness_unreadable"} =
               queue_run!(queued)

      assert %RunHarness{failure_rule: %{"values" => %{"cause" => %{"cause" => "failed"}}}} =
               walk!(queued)
    end

    test "a read that succeeds clears the first failure, so a later failure waits again",
         ctx do
      queued = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      answer!(429)
      assert claim(ctx) == {:ok, :none}

      # The failure was an hour before; the next read succeeds, and the claim takes the run.
      walk!(queued)
      |> Ecto.Changeset.change(read_failed_at: DateTime.add(Dispatches.now(), -3600))
      |> Ecto.Changeset.force_change(:updated_at, DateTime.add(Dispatches.now(), -3600))
      |> Repo.update!()

      QoryHarnessFixture.serve!()
      claimed = claimed!(ctx)
      assert walk!(queued).read_failed_at == nil

      # The pool's starter releases the run, and a read a minute later times out.
      assert Dispatches.release(ctx.key, claimed.dispatch.public_id, %{reason: "No machine."}) ==
               :ok

      assert queue_run!(queued).state == :waiting

      walk!(queued)
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.force_change(:updated_at, DateTime.add(Dispatches.now(), -60))
      |> Repo.update!()

      answer!(504)
      ExUnit.CaptureLog.capture_log(fn -> assert claim(ctx) == {:ok, :none} end)

      assert %DispatchRun{state: :waiting} = queue_run!(queued)
      assert %RunHarness{read_failed_at: %DateTime{} = failed_at} = walk!(queued)
      assert DateTime.diff(Dispatches.now(), failed_at) < 60
    end

    test "a claim does not read again, for 30 seconds, an address and ref whose runs all failed",
         ctx do
      queued = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      answer!(429)
      assert claim(ctx) == {:ok, :none}
      assert ref_reads() == 1

      assert claim(ctx) == {:ok, :none}
      assert ref_reads() == 0
      assert %DispatchRun{state: :waiting} = queue_run!(queued)

      # A run of the same address and ref with no failed read: the claim reads it again.
      other = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      assert claim(ctx) == {:ok, :none}
      assert ref_reads() == 1
      assert %DispatchRun{state: :waiting} = queue_run!(other)

      # 31 seconds after the last failure.
      for run <- [queued, other] do
        walk!(run)
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.force_change(:updated_at, DateTime.add(Dispatches.now(), -31))
        |> Repo.update!()
      end

      assert claim(ctx) == {:ok, :none}
      assert ref_reads() == 1
    end

    test "a claim of a pool at its limit reads no harness", ctx do
      set_node!(ctx.pool, instance_limit: 1)
      at = String.duplicate("ab", 20)
      walked!(ctx, "https://code.example.com/acme/harness", "main", at)
      assert claimed!(ctx)

      walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      QoryHarnessFixture.serve!()

      assert claim(ctx) == {:ok, :none}
      assert ref_reads() == 0
    end

    test "a read that fails for another cause ends the run at once", ctx do
      queued = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      answer!(404)

      ExUnit.CaptureLog.capture_log(fn -> assert claim(ctx) == {:ok, :none} end)

      assert %DispatchRun{end_cause: :harness_unresolved, end_detail: "harness_unreadable"} =
               queue_run!(queued)

      assert %RunHarness{failure_rule: %{"values" => %{"cause" => %{"cause" => "not_found"}}}} =
               walk!(queued)
    end

    test "a run whose read waits is passed, and the claim takes the next run", ctx do
      waiting = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      at = String.duplicate("ab", 20)
      next = walked!(ctx, "https://code.example.com/acme/harness", "main", at)
      answer!(429)

      assert claimed!(ctx).run.id == next.id
      assert %DispatchRun{state: :waiting} = queue_run!(waiting)
    end

    # The repo's event of each query runs in the process that sent the query: there,
    # `Repo.in_transaction?/0` is whether the query ran in a transaction.
    test "the claim reads the harness before its transaction, never inside it", ctx do
      queued = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      QoryHarnessFixture.serve!()
      handler = "claim-walks-#{System.unique_integer()}"
      test = self()

      # The read of the waiting runs' walks, the one query that joins the runs to their walks.
      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test and meta.source == "dispatch_runs" and
               meta.query =~ ~s(INNER JOIN "run_harnesses"),
             do: send(test, {:walks_read, Repo.in_transaction?()})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert claimed!(ctx).run.id == queued.id
      assert ref_reads() == 1
      assert_received {:walks_read, false}
      refute_received {:walks_read, true}
    end

    test "the claim reads each address and ref once, for every run that has them", ctx do
      first = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      second = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      QoryHarnessFixture.serve!()

      assert claimed!(ctx).run.id == first.id
      assert ref_reads() == 1

      assert claimed!(ctx).run.id == second.id
      assert ref_reads() == 1
    end

    test "the Qory harness at a full commit id is sent at that commit, with no read", ctx do
      commit = QoryHarnessFixture.commit()
      queued = walked!(ctx, Qory.git(), commit, commit)
      PublicGitServer.serve(%{}, answer: fn _conn -> flunk("no read at the claim") end)

      assert claimed!(ctx).documents.harness.harness["extends"]["ref"] == commit
      assert walk!(queued).pins == [%{"git" => Qory.git(), "ref" => commit, "at" => commit}]
    end

    test "a harness repository on a branch is sent at the commit the walk's pin records, with no read",
         ctx do
      git = "https://code.example.com/acme/harness"
      at = String.duplicate("ab", 20)
      queued = walked!(ctx, git, "main", at)
      PublicGitServer.serve(%{}, answer: fn _conn -> flunk("no read at the claim") end)

      assert claimed!(ctx).documents.harness.harness["extends"]["ref"] == at
      assert walk!(queued).pins == [%{"git" => git, "ref" => "main", "at" => at}]
      assert walk!(queued).document["extends"]["ref"] == "main"
    end

    test "a harness repository at a commit is sent at that commit", ctx do
      git = "https://code.example.com/acme/harness"
      commit = String.duplicate("cd", 20)
      walked!(ctx, git, commit, commit)
      assert claimed!(ctx).documents.harness.harness["extends"]["ref"] == commit
    end

    test "a harness repository whose pin is no commit is sent as the walk resolved it", ctx do
      walked!(ctx, "https://code.example.com/acme/harness", "main", "main")
      assert claimed!(ctx).documents.harness.harness["extends"]["ref"] == "main"
    end

    test "a run at another step with the column NULL is read and claimed at its first claim, with no files kept",
         ctx do
      queued = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      QoryHarnessFixture.serve!()

      # Queued before the first read of the Qory harness, at a step other than explore: it
      # is known not to be a run of Explore without the files.
      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^queued.id),
          set: [explore: nil, step: "build", workflow: "explore-a-ticket"]
        )

      {_count, _rows} = Repo.delete_all("qory_harness_heads")
      {_count, _rows} = Repo.delete_all("qory_harness_files")

      assert claimed!(ctx).run.id == queued.id
      assert ref_reads() == 1
      assert %DispatchRun{explore: false} = queue_run!(queued)
    end

    test "a run not known to be a run of Explore stays queued, with no read, and is claimed once it is known",
         ctx do
      queued = walked!(ctx, Qory.git(), "main", QoryHarnessFixture.commit())
      QoryHarnessFixture.serve!()

      # Queued before the first read of the Qory harness: no files kept, and the column NULL.
      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^queued.id),
          set: [explore: nil, workflow: "explore-a-ticket"]
        )

      {_count, _rows} = Repo.delete_all("qory_harness_heads")
      {_count, _rows} = Repo.delete_all("qory_harness_files")

      # A read of its walk stores no files, so the claim reads nothing.
      assert claim(ctx) == {:ok, :none}
      assert ref_reads() == 0
      assert %DispatchRun{state: :waiting, explore: nil} = queue_run!(queued)

      # The first read keeps the files: the next claim sets the column and takes the run.
      {:ok, _commit} = Qory.read({:branch, "main"})

      assert claimed!(ctx).run.id == queued.id
      assert %DispatchRun{explore: true} = queue_run!(queued)
    end
  end

  describe "a run the claim cannot form" do
    test "with run variables that break their rules ends variables_invalid", ctx do
      {work_item, queued} = queued!(ctx, %{target_path: "acme/shop/web"})

      log = ExUnit.CaptureLog.capture_log(fn -> assert claim(ctx) == {:ok, :none} end)
      ended!(ctx, queued, :variables_invalid)

      # One line in the instance's log, with the run, the variable and its rule.
      assert [line] =
               log |> String.split("\n") |> Enum.filter(&(&1 =~ "end_cause=variables_invalid"))

      assert line =~ "[warning]"
      assert line =~ "run_id=#{queued.run_id} work_item=#{work_item.public_id}"
      assert line =~ "variable=QORY_RUN_REPOSITORIES rule=repositories_invalid"
      assert line =~ "target_path=acme/shop/web"
    end

    test "whose software work item has no target ends inputs_invalid", ctx do
      {work_item, queued} = queued!(ctx)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [target_system: nil, target_path: nil]
        )

      assert claim(ctx) == {:ok, :none}
      ended!(ctx, queued, :inputs_invalid)
    end

    test "whose work item's ticket is gone ends ticket_gone", ctx do
      {work_item, queued} = queued!(ctx)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: [item_id: nil])

      assert claim(ctx) == {:ok, :none}
      ended!(ctx, queued, :ticket_gone)
    end

    @tag needs: [:factory, :workflow_model]
    test "with the workflow model, escalates its work item's stage run_stopped", ctx do
      {work_item, _queued} = queued!(ctx)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: [item_id: nil])

      :ok = Apiary.Stages.subscribe(work_item)
      assert claim(ctx) == {:ok, :none}

      assert %WorkItem{stage_state: :escalated} = Repo.get!(WorkItem, work_item.id)

      assert %Apiary.Stages.Escalation{
               cause: :run_stopped,
               points: [
                 %{
                   "text" =>
                     "The run stopped: it did not start, because the work item's ticket is no longer in Qory Apiary.",
                   "action" => "run_again",
                   "fix" => "Close the work item, or take the ticket in again."
                 }
               ]
             } = Repo.get_by!(Apiary.Stages.Escalation, work_item_id: work_item.id)

      public_id = work_item.public_id
      assert_receive {:stage_changed, ^public_id}
    end

    test "whose input breaks the contract's rules ends inputs_invalid", ctx do
      {work_item, queued} = queued!(ctx)

      # Written to the row, past the changeset that now refuses it: one stored before then.
      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [first_instruction: "Look \e[31mhere\e[0m."]
        )

      assert claim(ctx) == {:ok, :none}
      ended!(ctx, queued, :inputs_invalid)
    end

    test "ends a stale dispatch of it run_ended", ctx do
      {work_item, queued} = queued!(ctx)
      stale = claimed!(ctx)
      lapse!(stale)
      assert dispatched(ctx.key, stale) == {:error, :lease_expired}

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: [item_id: nil])

      assert claim(ctx) == {:ok, :none}
      assert %DispatchRun{state: :ended, end_cause: :ticket_gone} = queue_run!(queued)
      assert %Dispatch{end_cause: :run_ended} = dispatch!(stale)
      assert Slots.held(ctx.pool.id) == 0
      assert queue_runs() == 0
      start_failed!(stale, "lease_lapsed")
    end

    test "is ended, and the claim takes the next waiting run", ctx do
      {_work_item, broken} = queued!(ctx, %{target_path: "acme/shop/web"})
      {_work_item, next} = queued!(ctx)

      claimed = claimed!(ctx)
      assert claimed.run.id == next.id
      assert %DispatchRun{state: :ended, end_cause: :variables_invalid} = queue_run!(broken)
      assert runs() == 1
    end
  end

  describe "the run a claim registers in a workspace of the example domain" do
    test "has the domain's target labels, and no run variables", ctx do
      with_domain(ctx.scope, "example")

      {_work_item, _queued} =
        queued!(ctx, %{target_system: "ads.example.com", target_path: "accounts/1234/-a"})

      claimed = claimed!(ctx)
      assert claimed.documents.target == %{system: "ads.example.com", path: "accounts/1234/-a"}

      run = Repo.get!(Run, claimed.registered.id)

      assert run.registration_labels == %{
               "platform" => "ads.example.com",
               "account" => "accounts/1234/-a"
             }

      assert run.registration_variables == nil
    end

    test "of a work item with no target: its domain, no target, an input without one", ctx do
      with_domain(ctx.scope, "example")
      {work_item, queued} = queued!(ctx, %{target_system: nil, target_path: nil})

      claimed = claimed!(ctx)
      assert {claimed.run.id, claimed.work_item.id} == {queued.id, work_item.id}
      assert {claimed.documents.domain, claimed.documents.target} == {"example", nil}

      inputs = inputs(claimed)
      assert inputs["domain"] == "example"
      refute Map.has_key?(inputs, "target")

      run = Repo.get!(Run, claimed.registered.id)
      assert {run.registration_labels, run.registration_variables} == {%{}, nil}
      assert queue_run!(queued).state == :claimed
    end
  end

  describe "the explore input" do
    test "names a person whose account is deleted former member, untranslated", ctx do
      {work_item, _queued} = queued!(ctx)

      {1, _rows} =
        Repo.update_all(from(u in Apiary.Accounts.User, where: u.id == ^ctx.scope.user.id),
          set: [deleted_at: DateTime.utc_now(:second), email: nil]
        )

      assert get_in(inputs(claimed!(ctx)), ["instruction", "by"]) == %{"name" => "former member"}
      assert Inputs.former_member() == "former member"
      assert work_item.taken_in_by_id == ctx.scope.user.id
    end

    test "has the comments not deleted, oldest first, each author as the source named them",
         ctx do
      {work_item, _queued} = queued!(ctx)
      at = DateTime.utc_now(:second)

      for {ref, minutes, name, kind, deleted} <- [
            {"c2", 2, "Example triage", :automation, nil},
            {"c1", 1, "Avery Example", :person, nil},
            {"c3", 3, "Gone Example", :person, DateTime.utc_now()}
          ] do
        comment!(
          work_item,
          ref,
          DateTime.add(at, minutes, :minute),
          name,
          kind,
          "Said #{ref}.",
          deleted
        )
      end

      inputs = inputs(claimed!(ctx))

      assert inputs["comments"] == [
               %{
                 "by" => %{"name" => "Avery Example", "kind" => "person"},
                 "at" => DateTime.to_iso8601(DateTime.add(at, 1, :minute)),
                 "body" => "Said c1."
               },
               %{
                 "by" => %{"name" => "Example triage", "kind" => "automation"},
                 "at" => DateTime.to_iso8601(DateTime.add(at, 2, :minute)),
                 "body" => "Said c2."
               }
             ]

      assert inputs["comments_omitted"] == 0
    end

    test "keeps within 768 KiB, the oldest comments left out and counted", ctx do
      {work_item, _queued} = queued!(ctx)
      at = DateTime.utc_now(:second)
      body = String.duplicate("x", 60_000)

      for n <- 1..20,
          do:
            comment!(
              work_item,
              "c#{n}",
              DateTime.add(at, n, :second),
              "Avery Example",
              :person,
              "#{n} " <> body,
              nil
            )

      encoded = Jason.encode!(claimed!(ctx).documents.inputs)
      assert byte_size(encoded) <= Inputs.max_bytes()
      decoded = Jason.decode!(encoded)
      kept = decoded["comments"]
      assert decoded["comments_omitted"] + length(kept) == 20
      assert decoded["comments_omitted"] > 0

      # The newest kept, oldest first; one more would not fit.
      first_kept = decoded["comments_omitted"] + 1
      assert hd(kept)["body"] == "#{first_kept} " <> body
      assert List.last(kept)["body"] == "20 " <> body
      one_more = byte_size(Jason.encode!(%{"body" => "#{first_kept - 1} " <> body}))
      assert byte_size(encoded) + one_more > Inputs.max_bytes()
    end
  end

  describe "the explore input of a test work item" do
    @line "Hello! Where are you running?"
    @without_ticket Path.expand(
                      "../../fixtures/contract/explore/v1/inputs/without-ticket.json",
                      __DIR__
                    )

    defp test_item!(ctx) do
      {:ok, work_item} = WorkItems.take_in_test(ctx.scope, @line)
      [queued] = Repo.all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)
      {work_item, queued}
    end

    test "has the line as its instruction, no ticket and no comments, and the run is claimed",
         ctx do
      with_domain(ctx.scope, "example")
      {work_item, queued} = test_item!(ctx)

      claimed = claimed!(ctx)
      assert {claimed.run.id, claimed.work_item.id} == {queued.id, work_item.id}
      assert queue_run!(queued).state == :claimed

      inputs = inputs(claimed)
      assert ExploreInputsSchema.validate(inputs) == :ok
      refute Map.has_key?(inputs, "ticket")

      [local | _] = String.split(ctx.scope.user.email, "@")

      assert inputs["instruction"] == %{
               "text" => @line,
               "by" => %{"name" => local},
               "at" =>
                 work_item.taken_in_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
             }

      assert {inputs["comments"], inputs["comments_omitted"]} == {[], 0}
      refute Map.has_key?(inputs, "answers")

      # The members the contract's input without a ticket has, in its order.
      fixture = @without_ticket |> File.read!() |> Jason.decode!(objects: :ordered_objects)
      keys = &Enum.map(&1.values, fn {key, _value} -> key end)
      assert keys.(claimed.documents.inputs) == keys.(fixture)
    end

    test "in a software workspace, is claimed with no target, no labels and no run variables",
         ctx do
      {work_item, queued} = test_item!(ctx)

      claimed = claimed!(ctx)
      assert {claimed.run.id, claimed.work_item.id} == {queued.id, work_item.id}
      assert {claimed.documents.domain, claimed.documents.target} == {"software", nil}
      assert queue_run!(queued).state == :claimed

      inputs = inputs(claimed)
      assert ExploreInputsSchema.validate(inputs) == :ok
      assert inputs["instruction"]["text"] == @line
      refute Map.has_key?(inputs, "ticket")
      refute Map.has_key?(inputs, "target")

      run = Repo.get!(Run, claimed.registered.id)
      assert {run.registration_labels, run.registration_variables} == {%{}, nil}
    end

    test "is formed with no ticket, while any other work item without one is ticket_gone",
         ctx do
      {test_item, test_run} = test_item!(ctx)
      run = %{domain: "example", target: nil}

      assert {:ok, inputs} = Inputs.explore(Repo.reload!(test_item), test_run, run)
      inputs = inputs |> Jason.encode!() |> Jason.decode!()
      assert ExploreInputsSchema.validate(inputs) == :ok
      assert inputs["instruction"]["text"] == @line

      {work_item, queued} = queued!(ctx)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: [item_id: nil])

      assert Inputs.explore(Repo.reload!(work_item), queued, run) == {:error, :ticket_gone}
    end
  end

  describe "dispatched" do
    test "within the lease hands the dispatch over, the slot kept", ctx do
      {_work_item, queued} = queued!(ctx)
      claimed = claimed!(ctx)

      assert dispatched(ctx.key, claimed) == :ok

      assert %Dispatch{
               dispatched_at: %DateTime{} = at,
               handed_over_at: at,
               slot_freed_at: nil,
               ended_at: nil
             } = dispatch!(claimed)

      assert queue_run!(queued).state == :handed_over
      assert Slots.held(ctx.pool.id) == 1
      assert Repo.get!(Run, claimed.registered.id).state == "pending"
    end

    test "records when, and the job it names, once", ctx do
      queued!(ctx)
      claimed = claimed!(ctx)
      external = %{type: "batch", ref: "job-1", url: "https://jobs.example.com/job-1"}

      assert dispatched(ctx.key, claimed, external) == :ok

      assert %Dispatch{
               dispatched_at: %DateTime{} = at,
               external_type: "batch",
               external_ref: "job-1",
               external_url: "https://jobs.example.com/job-1"
             } = dispatch!(claimed)

      other = %{type: "other", ref: "job-2", url: "https://jobs.example.com/job-2"}
      assert dispatched(ctx.key, claimed, other) == :ok
      assert %Dispatch{dispatched_at: ^at, external_ref: "job-1"} = dispatch!(claimed)
    end

    test "records the vendor's machine type the first dispatched reports, once", ctx do
      queued!(ctx)
      claimed = claimed!(ctx)

      assert Dispatches.dispatched(ctx.key, id(claimed), %{
               external: nil,
               machine_type: "example-type"
             }) == :ok

      assert %Dispatch{dispatched_at: %DateTime{} = at, vendor_machine_type: "example-type"} =
               dispatch!(claimed)

      assert Dispatches.dispatched(ctx.key, id(claimed), %{
               external: nil,
               machine_type: "example-type-2"
             }) == :ok

      assert %Dispatch{dispatched_at: ^at, vendor_machine_type: "example-type"} =
               dispatch!(claimed)
    end

    test "with no job named records when alone", ctx do
      queued!(ctx)
      claimed = claimed!(ctx)
      assert dispatched(ctx.key, claimed) == :ok

      assert %Dispatch{
               dispatched_at: %DateTime{},
               external_type: nil,
               external_ref: nil,
               vendor_machine_type: nil
             } = dispatch!(claimed)
    end

    test "after the lease lapsed is lease_expired, the lapse committed", ctx do
      {_work_item, queued} = queued!(ctx)
      claimed = claimed!(ctx)
      lapse!(claimed)

      assert dispatched(ctx.key, claimed) == {:error, :lease_expired}
      assert %Dispatch{stale_at: %DateTime{}, dispatched_at: nil} = dispatch!(claimed)
      assert queue_run!(queued).state == :waiting
      assert queue_runs() == 0
      start_failed!(claimed, "lease_lapsed")
    end
  end

  defp comment!(work_item, ref, at, name, kind, body, deleted_at) do
    Repo.insert!(%Comment{
      organisation_id: work_item.organisation_id,
      item_id: work_item.item_id,
      external_ref: ref,
      url: "https://forge.example.com/acme/shop/issues/12#" <> ref,
      author_name: name,
      author_kind: kind,
      body: body,
      body_format: "markdown",
      source_created_at: at,
      source_updated_at: at,
      deleted_at: deleted_at
    })
  end

  defp usec(%DateTime{} = at), do: %{at | microsecond: {0, 6}}
end
