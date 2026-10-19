defmodule Apiary.Dispatches.HandoverTest do
  # A node pool's starter on a dispatch its pool claimed (`Apiary.Dispatches.Handover`):
  # `dispatched/3` and `handover/3`, each refusal in the contract's order, the lapse
  # judged before anything else and committed, the runs the handover cannot form ended
  # in its transaction and answered as a dispatch that ended, a failure that writes
  # nothing, and the run a handover registers: on the pool, its instance the run's id, its
  # labels and its run variables from the target, what it is about from the step and the
  # work item, its run key bound to the gateway and its parts never inspected, the slot
  # kept, one audit entry.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures, only: [contract_key_fixture: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Nodes, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Inputs, Slots}
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Registration, Run, RunKey}
  alias Apiary.Sources.Comment
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})

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

  defp claimed!(ctx) do
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())
    dispatch
  end

  defp handover(key, dispatch_id),
    do: Dispatches.handover(key, id(dispatch_id), %{body: @body})

  defp dispatched(key, dispatch_id, external \\ nil),
    do: Dispatches.dispatched(key, id(dispatch_id), %{external: external})

  defp id(%Dispatch{public_id: public_id}), do: public_id
  defp id(public_id), do: public_id

  defp dispatch!(%Dispatch{id: id}), do: Repo.get!(Dispatch, id)
  defp queue_run!(%DispatchRun{id: id}), do: Repo.get!(DispatchRun, id)
  defp runs, do: Repo.aggregate(Run, :count)
  defp entries, do: Repo.all(from e in Entry, where: e.action == "dispatch.handover")

  # Past its lease, as the clock would have it ten minutes and more after the claim.
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

  # The run of the queue and its dispatch ended with `cause`, the slot freed once.
  # An explore run its handover could not form gave an error, stored with its end; a
  # prebuild gave nothing.
  defp ended!(ctx, %DispatchRun{} = run, %Dispatch{} = dispatch, cause) do
    outcome =
      if run.step != "prebuild" and cause in [:variables_invalid, :ticket_gone, :inputs_invalid],
        do: :error

    assert %DispatchRun{state: :ended, end_cause: ^cause, result_outcome: ^outcome, result: nil} =
             queue_run!(run)

    assert %Dispatch{end_cause: ^cause, ended_at: %DateTime{} = at, slot_freed_at: at} =
             dispatch!(dispatch)

    assert Slots.held(ctx.pool.id) == 0
    assert runs() == 0
    assert entries() == []
  end

  describe "a handover of an explore run" do
    test "registers the run through the gateway, on the pool, its instance the run's id", ctx do
      {work_item, queued} = queued!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)
      in_use = Nodes.instances_in_use(ctx.pool, Dispatches.now())

      assert {:ok, handed} = handover(ctx.key, dispatch)
      assert handed.dispatch_run.id == queued.id
      assert handed.work_item.id == work_item.id
      assert handed.domain == "software"
      assert handed.target == %{system: "forge.example.com", path: "acme/shop"}

      run = Repo.get!(Run, handed.run.id)
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
      assert DateTime.diff(run.attach_by, run.run_key_issued_at) == 600
      assert run.run_key_issued_at == DateTime.truncate(run.registered_at, :second) |> usec()

      # The run key is the run's, bound to the gateway, and given once: the run keeps its
      # payload and signature.
      assert {:ok, grant, payload} = RunKey.verify(handed.run_key)
      assert payload == run.run_key_payload
      assert is_binary(run.run_key_signature)

      # Neither part shows when the run is inspected, as a crash report would show the run
      # the handover broadcasts.
      for shown <- [inspect(run, limit: :infinity), inspect(handed.run, limit: :infinity)] do
        refute shown =~ "run_key_payload"
        refute shown =~ "run_key_signature"
        refute shown =~ inspect(run.run_key_payload)
      end

      assert grant.run_id == run_id
      assert grant.instance_id == run_id
      assert grant.node_id == ctx.pool.public_id
      assert grant.workspace == ctx.scope.workspace.public_id
      assert grant.gateway == ctx.gateway.public_id
      {gateway_key, _seed} = ctx.gateway_key
      assert grant.gateway_public_keys == [gateway_key.public_key]
      assert DateTime.diff(grant.attach_by, grant.issued) == 600

      # The dispatch handed over, its slot kept; the run counts by its slot alone.
      assert %Dispatch{handed_over_at: at, slot_freed_at: nil, ended_at: nil} =
               dispatch!(dispatch)

      assert at == run.registered_at
      assert queue_run!(queued).state == :handed_over
      assert Slots.held(ctx.pool.id) == 1
      assert Nodes.instances_in_use(ctx.pool, Dispatches.now()) == in_use

      # One audit entry, by the pool's key, about the registered run.
      assert [entry] = entries()
      assert {entry.subject_kind, entry.subject_id} == {"run", run.id}
      assert {entry.actor_kind, entry.actor_id} == {:access_key, ctx.key.id}
      assert entry.details == %{"dispatch_id" => dispatch.public_id, "step" => "explore"}
    end

    test "leaves the run's id refused at the run endpoint, under any key", ctx do
      {_work_item, queued} = queued!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)
      assert {:ok, _handed} = handover(ctx.key, dispatch)

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

    test "gives the explore input, from the rows Qory keeps", ctx do
      {work_item, _queued} = queued!(ctx, %{first_instruction: "Look at the cart first."})
      item = Repo.get!(Apiary.Sources.Item, work_item.item_id)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      assert {:ok, %{inputs: inputs}} = handover(ctx.key, dispatch)
      inputs = inputs |> Jason.encode!() |> Jason.decode!()

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

  describe "a prebuild's handover" do
    test "is served: its collection's target, its input exactly the ref it was queued for",
         ctx do
      {collection, queued} = prebuild!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      assert {:ok, handed} = handover(ctx.key, dispatch)
      assert handed.work_item == nil
      assert handed.domain == "software"
      assert handed.target == %{system: collection.target_system, path: collection.target_path}
      assert Jason.encode!(handed.inputs) == ~s({"version":1,"environment_ref":"env-1"})

      run = Repo.get!(Run, handed.run.id)
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

      assert queue_run!(queued).state == :handed_over
      assert [%Entry{details: %{"step" => "prebuild"}}] = entries()
    end

    test "ends the run collection_ended when its collection ended, was unassigned, moved or lost its target",
         ctx do
      other = workspace_fixture(ctx.scope.organisation)

      for change <- [
            [ended_at: DateTime.utc_now(), ended_reason: :not_listed],
            [workspace_id: nil],
            [workspace_id: other.id],
            [target_system: nil, target_path: nil]
          ] do
        {collection, queued} = prebuild!(ctx)
        dispatch = claimed!(ctx)
        :ok = dispatched(ctx.key, dispatch)

        {1, _rows} =
          Repo.update_all(from(c in Apiary.Adapters.Collection, where: c.id == ^collection.id),
            set: change
          )

        assert handover(ctx.key, dispatch) == {:error, :gone}
        ended!(ctx, queued, dispatch, :collection_ended)
        assert handover(ctx.key, dispatch) == {:error, :gone}
      end
    end

    test "is served with its Backlog switch off, or a collection with no items", ctx do
      {collection, _queued} = prebuild!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      {1, _rows} =
        Repo.update_all(from(c in Apiary.Adapters.Collection, where: c.id == ^collection.id),
          set: [backlog: false, items: false]
        )

      assert {:ok, _handed} = handover(ctx.key, dispatch)
    end

    test "gives the ref it was claimed for, while a newer one waits", ctx do
      {collection, _queued} = prebuild!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      # The collection's ref changes after the claim: another prebuild waits for the new
      # one, and the claimed run keeps the ref it was queued for.
      {:ok, _waiting} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-2") end)

      assert {:ok, handed} = handover(ctx.key, dispatch)
      assert Jason.encode!(handed.inputs) == ~s({"version":1,"environment_ref":"env-1"})
    end

    test "superseded while its lease lapsed is gone", ctx do
      {collection, queued} = prebuild!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      # Another prebuild of the collection and pool waits while the first is claimed.
      {:ok, _waiting} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-2") end)

      lapse!(dispatch)
      assert handover(ctx.key, dispatch) == {:error, :gone}
      assert %DispatchRun{state: :ended, end_cause: :superseded} = queue_run!(queued)
      assert %Dispatch{end_cause: :run_ended, stale_at: %DateTime{}} = dispatch!(dispatch)
      assert runs() == 0
    end
  end

  describe "the refusals, in their order" do
    test "an id not of a dispatch's shape, an unknown one and another pool's are one answer, forbidden",
         ctx do
      queued!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)
      %{access_key: other} = enrolled_key_fixture(ctx.scope, pool_fixture(ctx.scope))

      for {key, id} <- [
            {ctx.key, "dp_0000000000000000"},
            {ctx.key, "not a dispatch"},
            {ctx.key, nil},
            {ctx.key, String.upcase(dispatch.public_id)},
            {other, dispatch.public_id}
          ] do
        assert handover(key, id) == {:error, :forbidden}
        assert dispatched(key, id) == {:error, :forbidden}
      end

      # Another organisation's pool.
      %{scope: elsewhere} = sign_up_fixture()
      %{key: elsewhere_key} = handover_place_fixture(elsewhere)
      assert handover(elsewhere_key, dispatch) == {:error, :forbidden}

      assert runs() == 0
      assert dispatch!(dispatch).handed_over_at == nil
    end

    test "a key that is no longer a pool's verified key is unauthorized", ctx do
      queued!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      %{access_key: node_key} = contract_key_fixture(ctx.scope, %{})
      assert handover(node_key, dispatch) == {:error, :unauthorized}

      {1, _rows} =
        Repo.update_all(from(k in AccessKey, where: k.id == ^ctx.key.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert handover(ctx.key, dispatch) == {:error, :unauthorized}
      assert dispatched(ctx.key, dispatch) == {:error, :unauthorized}
    end

    test "a dispatch that ended is gone, before handed_over and lease_expired", ctx do
      {work_item, _queued} = queued!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      {:ok, _changed} =
        Repo.transact(fn -> Dispatches.cancel_for_close([work_item.id], Dispatches.now()) end)

      lapse!(dispatch)
      assert handover(ctx.key, dispatch) == {:error, :gone}
      assert dispatched(ctx.key, dispatch) == {:error, :gone}
    end

    test "a second handover is handed_over, before lease_expired, and a run handed over then ended is gone",
         ctx do
      queued!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)
      assert {:ok, handed} = handover(ctx.key, dispatch)

      assert handover(ctx.key, dispatch) == {:error, :handed_over}
      # A dispatched after the handover changes nothing.
      assert dispatched(ctx.key, dispatch) == :ok
      assert length(entries()) == 1
      assert runs() == 1

      {:ok, _ended} =
        Repo.transact(fn ->
          Dispatches.end_run_released(handed.dispatch_run.id, Dispatches.now())
        end)

      assert handover(ctx.key, dispatch) == {:error, :gone}
    end

    test "a lease lapsed and not yet swept lapses first, committed: lease_expired, the run waits again",
         ctx do
      {_work_item, queued} = queued!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)
      lapse!(dispatch)

      assert handover(ctx.key, dispatch) == {:error, :lease_expired}
      assert %Dispatch{stale_at: %DateTime{}, slot_freed_at: %DateTime{}} = dispatch!(dispatch)
      assert queue_run!(queued).state == :waiting
      assert Slots.held(ctx.pool.id) == 0
      assert dispatched(ctx.key, dispatch) == {:error, :lease_expired}
      assert handover(ctx.key, dispatch) == {:error, :lease_expired}
      assert runs() == 0

      # Handed over through a later dispatch, the stale one is handed_over.
      later = claimed!(ctx)
      :ok = dispatched(ctx.key, later)
      assert {:ok, _handed} = handover(ctx.key, later)
      assert handover(ctx.key, dispatch) == {:error, :handed_over}
      assert dispatched(ctx.key, dispatch) == {:error, :lease_expired}
    end

    test "before dispatched is not_dispatched, before no_gateway", ctx do
      queued!(ctx)
      dispatch = claimed!(ctx)
      set_node!(ctx.pool, gateway_choice: :direct)

      assert handover(ctx.key, dispatch) == {:error, :not_dispatched}
      :ok = dispatched(ctx.key, dispatch)
      assert handover(ctx.key, dispatch) == {:error, :no_gateway}
    end

    test "no_gateway for each cause, the dispatch left claimed", ctx do
      {_work_item, queued} = queued!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)
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
        assert handover(ctx.key, dispatch) == {:error, :no_gateway}
        assert %Dispatch{handed_over_at: nil, ended_at: nil} = dispatch!(dispatch)
        assert queue_run!(queued).state == :claimed
        mend.()
      end

      assert runs() == 0
      assert {:ok, _handed} = handover(ctx.key, dispatch)
    end

    test "a run that cannot be stored is unavailable, and nothing is written", ctx do
      {_work_item, queued} = queued!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

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
          assert handover(ctx.key, dispatch) == {:error, :unavailable}
        end)

      assert log =~ "a handover could not be made: Ecto.ConstraintError"
      refute log =~ queued.run_id
      assert runs() == 1
      assert entries() == []

      assert %Dispatch{handed_over_at: nil, ended_at: nil, slot_freed_at: nil} =
               dispatch!(dispatch)

      assert queue_run!(queued).state == :claimed

      Repo.delete!(in_the_way)
      assert {:ok, _handed} = handover(ctx.key, dispatch)
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
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      assert {:ok, handed} = handover(ctx.key, dispatch)

      run = Repo.get!(Run, handed.run.id)

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
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      assert {:ok, handed} = handover(ctx.key, dispatch)

      assert Repo.get!(Run, handed.run.id).registration_labels == %{
               "forge" => "forge.example.com",
               "repository" => "acme/shop",
               "repositories" => "acme/shop"
             }
    end

    test "a saved list that breaks the rules now ends the run variables_invalid, gone", ctx do
      target = further!(ctx, "acme/docs")

      {1, _rows} =
        Repo.update_all(from(t in Apiary.Runs.Target, where: t.id == ^target.id),
          set: [further_repositories: ["other/docs"]]
        )

      {_work_item, queued} = queued!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      assert handover(ctx.key, dispatch) == {:error, :gone}
      ended!(ctx, queued, dispatch, :variables_invalid)
    end
  end

  describe "a run its handover cannot form" do
    test "with run variables that break their rules ends variables_invalid, gone", ctx do
      {_work_item, queued} = queued!(ctx, %{target_path: "acme/shop/web"})
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      assert handover(ctx.key, dispatch) == {:error, :gone}
      ended!(ctx, queued, dispatch, :variables_invalid)
      assert dispatched(ctx.key, dispatch) == {:error, :gone}
    end

    test "whose software work item lost its target after the claim ends inputs_invalid, gone",
         ctx do
      {work_item, queued} = queued!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [target_system: nil, target_path: nil]
        )

      assert handover(ctx.key, dispatch) == {:error, :gone}
      ended!(ctx, queued, dispatch, :inputs_invalid)
    end

    test "whose work item's ticket is gone ends ticket_gone, gone", ctx do
      {work_item, queued} = queued!(ctx)
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: [item_id: nil])

      assert handover(ctx.key, dispatch) == {:error, :gone}
      ended!(ctx, queued, dispatch, :ticket_gone)
    end

    test "whose input breaks the contract's rules ends inputs_invalid, gone", ctx do
      {work_item, queued} = queued!(ctx)

      # Written to the row, past the changeset that now refuses it: one stored before then.
      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [first_instruction: "Look \e[31mhere\e[0m."]
        )

      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      assert handover(ctx.key, dispatch) == {:error, :gone}
      ended!(ctx, queued, dispatch, :inputs_invalid)
    end

    test "whose answers name a member by a name the contract refuses ends inputs_invalid, gone",
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

      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      assert handover(ctx.key, dispatch) == {:error, :gone}
      ended!(ctx, queued, dispatch, :inputs_invalid)
    end

    test "ends a stale dispatch of it run_ended", ctx do
      {work_item, queued} = queued!(ctx)
      stale = claimed!(ctx)
      lapse!(stale)
      assert handover(ctx.key, stale) == {:error, :lease_expired}

      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: [item_id: nil])

      assert handover(ctx.key, dispatch) == {:error, :gone}
      ended!(ctx, queued, dispatch, :ticket_gone)
      assert %Dispatch{end_cause: :run_ended} = dispatch!(stale)
    end
  end

  describe "a handover in a workspace of the general domain" do
    test "labels the run with the domain's target labels, and gives it no run variables",
         ctx do
      with_domain(ctx.scope, "general")

      {_work_item, _queued} =
        queued!(ctx, %{target_system: "ads.example.com", target_path: "accounts/1234/-a"})

      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      assert {:ok, handed} = handover(ctx.key, dispatch)
      assert handed.target == %{system: "ads.example.com", path: "accounts/1234/-a"}

      run = Repo.get!(Run, handed.run.id)

      assert run.registration_labels == %{
               "system" => "ads.example.com",
               "path" => "accounts/1234/-a"
             }

      assert run.registration_variables == nil
    end

    test "hands over a run whose work item has no target: its domain, no target, an input without one",
         ctx do
      with_domain(ctx.scope, "general")
      {work_item, queued} = queued!(ctx, %{target_system: nil, target_path: nil})
      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)

      assert {:ok, handed} = handover(ctx.key, dispatch)
      assert {handed.dispatch_run.id, handed.work_item.id} == {queued.id, work_item.id}
      assert {handed.domain, handed.target} == {"general", nil}

      inputs = handed.inputs |> Jason.encode!() |> Jason.decode!()
      assert inputs["domain"] == "general"
      refute Map.has_key?(inputs, "target")

      run = Repo.get!(Run, handed.run.id)
      assert {run.registration_labels, run.registration_variables} == {%{}, nil}
      assert queue_run!(queued).state == :handed_over
    end
  end

  describe "the explore input" do
    test "names a person whose account is deleted former member, untranslated", ctx do
      {work_item, _queued} = queued!(ctx)

      {1, _rows} =
        Repo.update_all(from(u in Apiary.Accounts.User, where: u.id == ^ctx.scope.user.id),
          set: [deleted_at: DateTime.utc_now(:second), email: nil]
        )

      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)
      assert {:ok, %{inputs: inputs}} = handover(ctx.key, dispatch)

      assert inputs |> Jason.encode!() |> Jason.decode!() |> get_in(["instruction", "by"]) ==
               %{"name" => "former member"}

      assert Inputs.former_member() == "former member"
      assert work_item.taken_in_by_id == ctx.scope.user.id
    end

    test "gives the comments not deleted, oldest first, each author as the source named them",
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

      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)
      assert {:ok, %{inputs: inputs}} = handover(ctx.key, dispatch)
      inputs = inputs |> Jason.encode!() |> Jason.decode!()

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

      dispatch = claimed!(ctx)
      :ok = dispatched(ctx.key, dispatch)
      assert {:ok, %{inputs: inputs}} = handover(ctx.key, dispatch)

      encoded = Jason.encode!(inputs)
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

  describe "dispatched" do
    test "records when, and the job it names, once", ctx do
      queued!(ctx)
      dispatch = claimed!(ctx)
      external = %{type: "batch", ref: "job-1", url: "https://jobs.example.com/job-1"}

      assert dispatched(ctx.key, dispatch, external) == :ok

      assert %Dispatch{
               dispatched_at: %DateTime{} = at,
               external_type: "batch",
               external_ref: "job-1",
               external_url: "https://jobs.example.com/job-1"
             } = dispatch!(dispatch)

      other = %{type: "other", ref: "job-2", url: "https://jobs.example.com/job-2"}
      assert dispatched(ctx.key, dispatch, other) == :ok
      assert %Dispatch{dispatched_at: ^at, external_ref: "job-1"} = dispatch!(dispatch)
    end

    test "with no job named records when alone", ctx do
      queued!(ctx)
      dispatch = claimed!(ctx)
      assert dispatched(ctx.key, dispatch) == :ok

      assert %Dispatch{dispatched_at: %DateTime{}, external_type: nil, external_ref: nil} =
               dispatch!(dispatch)
    end

    test "after the lease lapsed is lease_expired, the lapse committed", ctx do
      {_work_item, queued} = queued!(ctx)
      dispatch = claimed!(ctx)
      lapse!(dispatch)

      assert dispatched(ctx.key, dispatch) == {:error, :lease_expired}
      assert %Dispatch{stale_at: %DateTime{}, dispatched_at: nil} = dispatch!(dispatch)
      assert queue_run!(queued).state == :waiting
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
