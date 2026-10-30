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
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Registration, Run, RunCode}
  alias Apiary.Sources.Comment
  alias Apiary.WorkItems.WorkItem

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

  defp claim(ctx), do: Dispatches.claim(ctx.key, Dispatches.now(), @body)

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
      assert inputs["run"] == %{"attempt" => 1, "of" => 3}

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
      assert inputs["answers"] == []
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

  describe "a run the claim cannot form" do
    test "with run variables that break their rules ends variables_invalid", ctx do
      {_work_item, queued} = queued!(ctx, %{target_path: "acme/shop/web"})

      assert claim(ctx) == {:ok, :none}
      ended!(ctx, queued, :variables_invalid)
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

    test "whose answers name a member by a name the contract refuses ends inputs_invalid",
         ctx do
      {work_item, queued} = queued!(ctx)
      %{user: member} = member_fixture(ctx.scope)

      {1, _rows} =
        Repo.update_all(from(u in Apiary.Accounts.User, where: u.id == ^member.id),
          set: [email: "ann\u202Ex#{System.unique_integer([:positive])}@example.com"]
        )

      Repo.insert!(%Apiary.WorkItems.Answer{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        take_in: queued.take_in,
        attempt: 1,
        position: 1,
        question: "Which basket?",
        answer: "The one at checkout.",
        answered_by_id: member.id,
        answered_at: DateTime.utc_now()
      })

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
      assert inputs["answers"] == []

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

    test "with no job named records when alone", ctx do
      queued!(ctx)
      claimed = claimed!(ctx)
      assert dispatched(ctx.key, claimed) == :ok

      assert %Dispatch{dispatched_at: %DateTime{}, external_type: nil, external_ref: nil} =
               dispatch!(claimed)
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
