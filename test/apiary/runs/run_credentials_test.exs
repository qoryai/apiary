defmodule Apiary.Runs.RunCredentialsTest do
  # The work credential entry a claim records for its run (`Apiary.Runs.RunCredentials`,
  # through `Apiary.Dispatches.claim/3`): the adapter's apply items filled with the run's
  # target path, its collection as the resource and its access level. The collection is a
  # prebuild's, or for a run with a work item one that can change the run's target; none
  # where there is no such collection or no apply item, and the run ended
  # `target_access_gone` where the collection or its connection ended, or the target path
  # is refused.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Dispatches
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Run, RunCredential, RunCredentials}
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @apply [
    %{
      "hosts" => ["git.example.com"],
      "scheme" => "basic",
      "username" => "token-user",
      "paths" => ["/{target.path}.git/*", "/{target.path}/*"]
    },
    %{
      "hosts" => ["api.git.example.com"],
      "scheme" => "bearer",
      "paths" => ["/repos/{target.path}", "/repos/{target.path}/*", "/repos/acme/shop"]
    }
  ]

  # The gateway's keys are allowed stored secrets: a run with a work entry ends
  # `secrets_not_allowed` under a key that is not (the last describe).
  setup do
    %{scope: scope} = sign_up_fixture()
    Map.put(handover_place_fixture(scope, allow_secrets: true), :scope, scope)
  end

  @target %{system: "forge.example.com", path: "acme/shop"}

  # A run of the queue for a new work item of the scope, whose target is acme/shop at
  # forge.example.com, whose ticket's adapter declares `apply` (nil for none), and whose
  # ticket's collection can change that target, as a code forge's issue's does
  # (`target_candidate!/1`).
  defp queued!(ctx, apply \\ @apply) do
    work_item = work_item_fixture(ctx.scope)
    set!(Node, work_item.adapter_id, source_apply: apply)
    target_candidate!(work_item)
    {work_item, queue!(work_item)}
  end

  # A run of the queue for a new work item of the scope, whose target is acme/shop at
  # forge.example.com, from a tracker's ticket: its adapter declares `@apply` but not
  # `targets`, and its collection's target is `ticket_target` (nil for none).
  defp tracker_queued!(ctx, ticket_target \\ nil) do
    work_item = work_item_fixture(ctx.scope)
    set!(Node, work_item.adapter_id, source_apply: @apply, targets: false)

    if ticket_target do
      set!(Collection, collection_of(work_item).id,
        target_collection_external_ref: ticket_target.path,
        target_system: ticket_target.system,
        target_path: ticket_target.path
      )
    end

    {work_item, queue!(work_item)}
  end

  defp queue!(work_item) do
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    run
  end

  # A live collection of the scope's workspace, on a connected connection, that can change
  # `target`, as a code forge's adapter's is, its adapter declaring `@apply`. It has no
  # environment, so a claim takes no prebuild of it before the run.
  defp forge_collection!(ctx, target \\ @target) do
    collection =
      collection_fixture(ctx.scope,
        target_system: target.system,
        target_path: target.path,
        environment_ref: nil
      )

    set!(Node, collection.adapter_id, source_apply: @apply, targets: true)
    collection
  end

  # The work item's target path set to `path`, and its ticket's collection's to match.
  defp retarget!(work_item, path) do
    set!(WorkItem, work_item.id, target_path: path)
    set!(Collection, collection_of(work_item).id, target_path: path)
  end

  defp set!(schema, id, fields),
    do: {1, _rows} = Repo.update_all(from(r in schema, where: r.id == ^id), set: fields)

  defp collection_of(%WorkItem{item_id: item_id}),
    do:
      Repo.one!(
        from c in Collection,
          join: i in Item,
          on: i.collection_id == c.id,
          where: i.id == ^item_id
      )

  defp claim(ctx), do: Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

  defp entries, do: Repo.all(from c in RunCredential, order_by: c.name)

  # The run of the queue ended `target_access_gone` at its claim, with an error and no
  # dispatch or run left, and no entry.
  defp gone!(%DispatchRun{id: id}) do
    assert %DispatchRun{state: :ended, end_cause: :target_access_gone, result_outcome: :error} =
             Repo.get!(DispatchRun, id)

    assert Repo.all(from d in Dispatch, where: d.dispatch_run_id == ^id and is_nil(d.ended_at)) ==
             []

    assert Repo.aggregate(
             from(r in Apiary.RunEventsFixtures.registered_runs(),
               where: r.dispatch_run_id == ^id
             ),
             :count
           ) == 0

    assert entries() == []
  end

  describe "the run of a test work item" do
    test "gets no entry, while the workspace's adapter declares apply items", ctx do
      # A work item of the workspace whose ticket's adapter declares them, its run left
      # out of the queue.
      work_item = work_item_fixture(ctx.scope)
      set!(Node, work_item.adapter_id, source_apply: @apply)

      {:ok, test_item} = Apiary.WorkItems.take_in_test(ctx.scope, "Hello! Where are you running?")
      assert {:ok, %{registered: %Run{} = run, work_item: claimed}} = claim(ctx)
      assert claimed.id == test_item.id
      assert run.registration_labels == %{}
      assert entries() == []
    end
  end

  describe "an explore run whose ticket's adapter declares apply items" do
    test "gets work-1 with the filled paths, a repeat left out, its collection and read access",
         ctx do
      {work_item, queued} = queued!(ctx)
      assert {:ok, %{registered: %Run{} = run}} = claim(ctx)
      collection = collection_of(work_item)

      assert [entry] = entries()

      assert %RunCredential{
               name: "work-1",
               purpose: :work,
               access: :read,
               placeholders: nil
             } = entry

      assert entry.run_id == run.id
      assert entry.organisation_id == ctx.scope.organisation.id
      assert entry.workspace_id == ctx.scope.workspace.id
      assert entry.connection_id == work_item.connection_id
      assert entry.adapter_id == work_item.adapter_id
      assert run.dispatch_run_id == queued.id

      assert entry.resources == [
               %{
                 "collection_id" => collection.id,
                 "external_ref" => collection.external_ref,
                 "path" => "acme/shop"
               }
             ]

      assert entry.apply == [
               %{
                 "hosts" => ["git.example.com"],
                 "scheme" => "basic",
                 "username" => "token-user",
                 "paths" => ["/acme/shop.git/*", "/acme/shop/*"]
               },
               %{
                 "hosts" => ["api.git.example.com"],
                 "scheme" => "bearer",
                 "paths" => ["/repos/acme/shop", "/repos/acme/shop/*"]
               }
             ]
    end

    test "takes the access level of its harness walk", ctx do
      {_work_item, queued} = queued!(ctx)

      case Repo.get_by(RunHarness, dispatch_run_id: queued.id) do
        nil ->
          Repo.insert!(%RunHarness{
            dispatch_run_id: queued.id,
            state: :resolved,
            origin: :none,
            access_level: :write
          })

        walk ->
          set!(RunHarness, walk.id, access_level: :write)
      end

      assert {:ok, %{registered: %Run{}}} = claim(ctx)

      # The sessions' credential reads, and a push entry beside it writes.
      assert [
               %RunCredential{name: "push-1", purpose: :push, access: :write},
               %RunCredential{name: "work-1", purpose: :work, access: :read}
             ] = entries()
    end

    @tag needs: [:factory, :workflow_model]
    test "with the workflow model, a stage entry with read access lowers a write walk", ctx do
      stage = %{
        "id" => "st_r79kph11eg",
        "name" => "Explore",
        "inputs" => [],
        "sequence" => [%{"workflow" => "explore-a-ticket", "access" => "read"}],
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      }

      document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => [stage]}
      {:ok, _version} = Apiary.Processes.save(ctx.scope, ctx.scope.workspace, document)

      {_work_item, queued} = queued!(ctx)
      assert %DispatchRun{stage_id: "st_r79kph11eg"} = Repo.get!(DispatchRun, queued.id)

      case Repo.get_by(RunHarness, dispatch_run_id: queued.id) do
        nil ->
          Repo.insert!(%RunHarness{
            dispatch_run_id: queued.id,
            state: :resolved,
            origin: :none,
            access_level: :write
          })

        walk ->
          set!(RunHarness, walk.id, access_level: :write)
      end

      assert {:ok, %{registered: %Run{}}} = claim(ctx)

      # The adapter is asked for the entry's access when the run asks for its value
      # (`Apiary.Runs.WorkCredential`), so the row is what it reads: no push entry.
      assert [%RunCredential{name: "work-1", access: :read}] = entries()
    end

    # A version of the workspace's process, with `sequence` and `extra` in its one stage.
    defp process!(ctx, sequence, extra \\ %{}) do
      stage =
        Map.merge(
          %{
            "id" => "st_r79kph11eg",
            "name" => "Build",
            "inputs" => [],
            "sequence" => sequence,
            "outputs" => [],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          },
          extra
        )

      document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => [stage]}
      {:ok, version} = Apiary.Processes.save(ctx.scope, ctx.scope.workspace, document)
      version
    end

    # The run's documents, changed by `change` on their decoded form.
    defp documents!(run, change) do
      documents = Repo.get!(Run, run.id).run_documents |> Jason.decode!() |> change.()
      set!(Run, run.id, run_documents: Jason.encode!(documents))
    end

    # The documents the claim sent the run of the queue `queued`, decoded.
    defp sent_documents(queued),
      do: Jason.decode!(Repo.get_by!(Run, dispatch_run_id: queued.id).run_documents)

    # A run of the queue under a version with `from`, moved to a version with `to`.
    defp moved!(ctx, from, to) do
      process!(ctx, from)
      {work_item, queued} = queued!(ctx)
      assert {:ok, _assigned} = Apiary.Processes.assign(ctx.scope, work_item, process!(ctx, to))
      queued
    end

    # The level of the claim of `queued`, whose walk resolved `walk`, `write` unless given:
    # its documents' and its token's. The run's work entry reads whatever its level; the
    # token's level is `write` where the claim recorded a push entry, else `read`.
    defp claimed_levels(ctx, queued, walk \\ :write) do
      section = %{"extends" => %{"git" => "https://code.example.com/team/stacks"}}
      walk_resolved!(queued, origin: :setting, document: section, access_level: walk)

      assert {:ok, %{documents: %{harness: %{access: documents}}}} = claim(ctx)
      entries = entries()
      assert %RunCredential{access: :read} = Enum.find(entries, &(&1.purpose == :work))

      token =
        case Enum.find(entries, &(&1.purpose == :push)) do
          nil -> :read
          %RunCredential{access: :write} -> :write
        end

      assert length(entries) == if(token == :write, do: 2, else: 1)
      {documents, token}
    end

    @tag needs: [:factory, :workflow_model]
    test "a run moved onto an entry of another workflow reads, in its documents and its token",
         ctx do
      queued =
        moved!(ctx, [%{"workflow" => "build", "access" => "read"}], [%{"workflow" => "lint"}])

      assert {"build", 0} = {queued.workflow, queued.stage_entry}
      assert claimed_levels(ctx, queued) == {:read, :read}
    end

    @tag needs: [:factory, :workflow_model]
    test "a run moved to a version with no entry at its place reads", ctx do
      queued = moved!(ctx, [%{"workflow" => "build", "access" => "read"}], [])

      assert claimed_levels(ctx, queued) == {:read, :read}
    end

    @tag needs: [:factory, :workflow_model]
    test "a run whose stage its version does not have reads", ctx do
      process!(ctx, [%{"workflow" => "build", "access" => "read"}])
      {_work_item, queued} = queued!(ctx)
      set!(DispatchRun, queued.id, stage_id: "st_p9w5cvh311")

      assert claimed_levels(ctx, queued) == {:read, :read}
    end

    @tag needs: [:factory, :workflow_model]
    test "a run of a write-no-push entry gets a read credential, and its documents write-no-push",
         ctx do
      process!(ctx, [%{"workflow" => "build", "access" => "write-no-push"}])
      {_work_item, queued} = queued!(ctx)

      assert claimed_levels(ctx, queued) == {:write_no_push, :read}
      assert %{"access" => "write-no-push"} = sent_documents(queued)
    end

    @tag needs: [:factory, :workflow_model]
    test "a run whose walk resolved write-no-push keeps it where its entry sets no level", ctx do
      process!(ctx, [%{"workflow" => "build"}])
      {_work_item, queued} = queued!(ctx)

      assert claimed_levels(ctx, queued, :write_no_push) == {:write_no_push, :read}
      assert %{"access" => "write-no-push"} = sent_documents(queued)
    end

    @tag needs: [:factory, :workflow_model]
    test "an entry never raises the level its walk resolved", ctx do
      process!(ctx, [%{"workflow" => "build", "access" => "write-no-push"}])
      {_work_item, queued} = queued!(ctx)

      assert claimed_levels(ctx, queued, :read) == {:read, :read}
    end

    # The Build stage as one run: `first`, then a loop of implement-changes, which writes,
    # and review-changes, which reads.
    defp shared_build!(ctx, first) do
      process!(
        ctx,
        first ++
          [
            %{
              "loop" => %{
                "rounds" => 3,
                "body" => [
                  %{"workflow" => "implement-changes"},
                  %{"workflow" => "review-changes", "access" => "read"}
                ]
              }
            }
          ],
        %{"shared_run" => true}
      )
    end

    # The levels that the stack file the walk of `queued` read declares for the Build
    # workflows, as the walk records them, `levels` merged over write for each.
    defp table!(queued, levels \\ %{}) do
      write = %{
        "plan-the-build" => :write,
        "implement-changes" => :write,
        "review-changes" => :write
      }

      {1, _rows} =
        Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^queued.id),
          set: [workflow_levels: Map.merge(write, levels)]
        )

      :ok
    end

    # The workspace's harness declares write for every Build workflow, as a read of it
    # after the save records them.
    defp workspace_writes!(ctx) do
      :ok =
        Apiary.Processes.record_declared(ctx.scope.workspace, %{
          "plan-the-build" => :write,
          "implement-changes" => :write,
          "review-changes" => :write
        })
    end

    # A guard against a rule that refuses read beside write: the claim of this run ends
    # `shared_access_differs` where it does. The level comes from the walk of
    # implement-changes, the run's first workflow.
    @tag needs: [:factory, :workflow_model]
    test "a run of a shared stage with a read entry beside a write entry writes, in its documents and its token",
         ctx do
      shared_build!(ctx, [])
      {_work_item, queued} = queued!(ctx)
      assert queued.workflow == "implement-changes"

      assert claimed_levels(ctx, queued) == {:write, :write}
      assert %{"access" => "write", "shared_run" => true} = sent_documents(queued)
    end

    @tag needs: [:factory, :workflow_model]
    test "a run of a shared stage that starts on a read entry writes for the later write entry",
         ctx do
      shared_build!(ctx, [%{"workflow" => "plan-the-build", "access" => "read"}])
      {_work_item, queued} = queued!(ctx)
      :ok = table!(queued)
      assert queued.workflow == "plan-the-build"

      assert claimed_levels(ctx, queued) == {:write, :write}
    end

    @tag needs: [:factory, :workflow_model]
    test "a run of a shared stage that starts on a read walk writes for a later write entry",
         ctx do
      shared_build!(ctx, [%{"workflow" => "plan-the-build"}])
      {_work_item, queued} = queued!(ctx)
      :ok = table!(queued)

      # The walk of plan-the-build resolved read; its harness declares implement-changes
      # write.
      assert claimed_levels(ctx, queued, :read) == {:write, :write}
    end

    @tag needs: [:factory, :workflow_model]
    test "a run of a shared stage reads with the built-in read-only harness or no walk, and writes on a read walk of the harness",
         ctx do
      shared_build!(ctx, [%{"workflow" => "plan-the-build"}])
      {_work_item, queued} = queued!(ctx)
      :ok = table!(queued)
      walk = fn -> Repo.all(from h in RunHarness, where: h.dispatch_run_id == ^queued.id) end

      # The walk of plan-the-build in the workspace's harness resolved read.
      walk_resolved!(queued,
        origin: :setting,
        document: %{"extends" => %{"git" => "https://code.example.com/team/stacks"}},
        access_level: :read
      )

      assert RunCredentials.run_access(queued) == :write

      # The built-in harness of a test work item reads for every workflow.
      assert [%RunHarness{} = row] = walk.()
      set!(RunHarness, row.id, Apiary.Harnesses.Builtin.walked())
      assert RunCredentials.run_access(queued) == :read

      # A run with no walk reads.
      {1, _rows} = Repo.delete_all(from h in RunHarness, where: h.id == ^row.id)
      assert RunCredentials.run_access(queued) == :read
    end

    @tag needs: [:factory, :workflow_model]
    test "a run of a shared stage reads where its harness declares no level for its write workflow",
         ctx do
      shared_build!(ctx, [%{"workflow" => "plan-the-build", "access" => "read"}])
      {_work_item, queued} = queued!(ctx)

      # The stack file of the run's harness lists no level for implement-changes: a walk
      # reads it as read, whatever the workspace's harness declares.
      workspace_writes!(ctx)

      {1, _rows} =
        Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^queued.id),
          set: [workflow_levels: %{"plan-the-build" => :write}]
        )

      assert claimed_levels(ctx, queued) == {:read, :read}
    end

    @tag needs: [:factory, :workflow_model]
    test "a run of a shared stage reads where the stacks record read for its write workflow",
         ctx do
      shared_build!(ctx, [%{"workflow" => "plan-the-build", "access" => "read"}])

      {:ok, stack} =
        Apiary.Stacks.put_stack(
          ctx.scope,
          {:workspace, ctx.scope.workspace, "implement-changes"},
          "extends: {git: https://code.example.com/team/stacks, ref: main, path: core}\n"
        )

      set!(Apiary.Stacks.Stack, stack.id, access: :read)
      {_work_item, queued} = queued!(ctx)
      :ok = table!(queued)

      assert claimed_levels(ctx, queued) == {:read, :read}
    end

    # The work item's target row, by its adapter and its collection ref.
    defp target_row!(ctx, work_item) do
      id =
        Apiary.Runs.Target.id_of(
          ctx.scope.organisation.id,
          ctx.scope.workspace.id,
          WorkItem.target(work_item)
        )

      Repo.get!(Apiary.Runs.Target, id)
    end

    # A row for implement-changes at `target`, recording `access`.
    defp target_stack!(ctx, target, access) do
      {:ok, stack} =
        Apiary.Stacks.put_stack(
          ctx.scope,
          {:target, target, "implement-changes"},
          "extends: {git: https://code.example.com/team/stacks, ref: main, path: core}\n"
        )

      set!(Apiary.Stacks.Stack, stack.id, access: access)
    end

    @tag needs: [:factory, :workflow_model]
    test "a run of a shared stage reads where the stacks record read for its write workflow at its target",
         ctx do
      shared_build!(ctx, [%{"workflow" => "plan-the-build", "access" => "read"}])
      {work_item, queued} = queued!(ctx)
      :ok = table!(queued)
      target_stack!(ctx, target_row!(ctx, work_item), :read)

      assert claimed_levels(ctx, queued) == {:read, :read}
    end

    @tag needs: [:factory, :workflow_model]
    test "a run of a shared stage reads the stacks of its target's collection, not of another collection at the same address",
         ctx do
      shared_build!(ctx, [%{"workflow" => "plan-the-build", "access" => "read"}])
      {work_item, queued} = queued!(ctx)
      :ok = table!(queued)
      target = target_row!(ctx, work_item)

      # A collection of another adapter at the same address records read.
      other =
        target_fixture(%{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id,
          system: target.system,
          path: target.path
        })

      assert other.adapter_id != target.adapter_id
      target_stack!(ctx, target, :write)
      target_stack!(ctx, other, :read)

      assert claimed_levels(ctx, queued) == {:write, :write}
    end

    @tag needs: [:factory, :workflow_model]
    test "a run of a shared stage moved onto another workflow's entry reads", ctx do
      loop = fn body -> [%{"loop" => %{"rounds" => 3, "body" => body}}] end
      implement = %{"workflow" => "implement-changes"}
      review = %{"workflow" => "review-changes", "access" => "read"}

      process!(ctx, loop.([implement, review]), %{"shared_run" => true})
      {work_item, queued} = queued!(ctx)
      :ok = table!(queued)
      to = process!(ctx, loop.([review, implement]), %{"shared_run" => true})
      assert {:ok, _assigned} = Apiary.Processes.assign(ctx.scope, work_item, to)

      queued = Repo.get!(DispatchRun, queued.id)

      assert {"implement-changes", 0, 0} =
               {queued.workflow, queued.stage_entry, queued.loop_entry}

      assert claimed_levels(ctx, queued) == {:read, :read}
    end

    # The walk of `queued` read a target's harness file, which resolved `walk` for the
    # run's workflow and declares `levels` (`workflow_levels`).
    defp file_walk!(queued, walk, levels) do
      walk_resolved!(queued, origin: :file, document: nil, access_level: walk)

      {1, _rows} =
        Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^queued.id),
          set: [workflow_levels: levels]
        )

      :ok
    end

    @tag needs: [:factory, :workflow_model]
    test "a run of a shared stage reads where its target's harness file sets every workflow to read, though the workspace's harness writes",
         ctx do
      shared_build!(ctx, [%{"workflow" => "plan-the-build"}])
      workspace_writes!(ctx)
      {_work_item, queued} = queued!(ctx)

      read = %{
        "plan-the-build" => :read,
        "implement-changes" => :read,
        "review-changes" => :read
      }

      :ok = file_walk!(queued, :read, read)
      assert {:ok, %{documents: %{harness: %{access: :read}}}} = claim(ctx)
      assert [%RunCredential{purpose: :work, access: :read}] = entries()
    end

    @tag needs: [:factory, :workflow_model]
    test "a run of a shared stage that starts on review-changes writes where its target's harness file sets implement-changes to write",
         ctx do
      loop = [
        %{
          "loop" => %{
            "rounds" => 3,
            "body" => [
              %{"workflow" => "review-changes", "access" => "read"},
              %{"workflow" => "implement-changes"}
            ]
          }
        }
      ]

      process!(ctx, loop, %{"shared_run" => true})
      {_work_item, queued} = queued!(ctx)
      assert queued.workflow == "review-changes"

      # The workspace's harness has no level for implement-changes.
      :ok = Apiary.Processes.record_declared(ctx.scope.workspace, %{"review-changes" => :read})

      :ok =
        file_walk!(queued, :read, %{"implement-changes" => :write, "review-changes" => :read})

      assert {:ok, %{documents: %{harness: %{access: :write}}}} = claim(ctx)
      assert Enum.any?(entries(), &match?(%RunCredential{purpose: :push, access: :write}, &1))
    end

    @tag needs: [:factory, :workflow_model]
    test "a run whose stage has no limits reads, whatever its walk resolved", ctx do
      process!(ctx, [%{"workflow" => "build"}])
      {_work_item, queued} = queued!(ctx)
      set!(DispatchRun, queued.id, stage_id: "st_p9w5cvh311")

      assert claimed_levels(ctx, queued, :write) == {:read, :read}
      assert %{"access" => "read"} = sent_documents(queued)
    end

    # Cancel run's confirm says a write run's changes are not pushed
    # (`Apiary.Runs.Cancel.write_run?/2`): a run whose entry lowers its write walk is none,
    # by its credential entries, then by the documents the claim sent it, then by its stage
    # entry.
    for {access, write?} <- [{"write-no-push", false}, {"read", false}, {nil, true}] do
      @tag needs: [:factory, :workflow_model]
      test "Cancel run reads a run of an entry with access #{inspect(access)} as write: #{write?}",
           ctx do
        entry =
          Map.reject(%{"workflow" => "build", "access" => unquote(access)}, &is_nil(elem(&1, 1)))

        process!(ctx, [entry])
        {_work_item, queued} = queued!(ctx)
        claimed_levels(ctx, queued)
        run = Repo.get_by!(Run, dispatch_run_id: queued.id)

        assert Apiary.Runs.Cancel.write_run?(ctx.scope.workspace, run) == unquote(write?)

        Repo.delete_all(from c in RunCredential, where: c.run_id == ^run.id)
        assert Apiary.Runs.Cancel.write_run?(ctx.scope.workspace, run) == unquote(write?)

        set!(Run, run.id, run_documents: nil)
        assert Apiary.Runs.Cancel.write_run?(ctx.scope.workspace, run) == unquote(write?)
      end
    end

    # Cancel run reads the first source the run has: its credential entries before its
    # documents, its documents before its stage entry. Each case gives the sources
    # different levels.
    @tag needs: [:factory, :workflow_model]
    test "Cancel run takes the credential entries first, then the documents", ctx do
      process!(ctx, [%{"workflow" => "build", "access" => "read"}])
      {_work_item, queued} = queued!(ctx)
      claimed_levels(ctx, queued)
      run = Repo.get_by!(Run, dispatch_run_id: queued.id)

      # An entry of write, with documents that say read.
      {1, _rows} =
        Repo.update_all(from(c in RunCredential, where: c.run_id == ^run.id),
          set: [access: :write]
        )

      assert sent_documents(queued)["access"] == "read"
      assert Apiary.Runs.Cancel.write_run?(ctx.scope.workspace, run)

      # No entry, documents that say write, and a stage entry that lowers to read.
      Repo.delete_all(from c in RunCredential, where: c.run_id == ^run.id)
      documents!(run, &Map.put(&1, "access", "write"))
      assert Apiary.Runs.Cancel.write_run?(ctx.scope.workspace, run)

      set!(Run, run.id, run_documents: nil)
      refute Apiary.Runs.Cancel.write_run?(ctx.scope.workspace, run)
    end

    # A text of the documents may have a NUL, which JSON writes as an escape.
    @tag needs: [:factory, :workflow_model]
    test "Cancel run reads the access of documents with a NUL in a text", ctx do
      process!(ctx, [%{"workflow" => "build"}])
      {_work_item, queued} = queued!(ctx)
      claimed_levels(ctx, queued)
      run = Repo.get_by!(Run, dispatch_run_id: queued.id)
      Repo.delete_all(from c in RunCredential, where: c.run_id == ^run.id)

      documents!(run, fn documents ->
        documents
        |> Map.put("access", "write")
        |> put_in(["work_item", "title"], "Checkout \u0000 storefront")
      end)

      assert Repo.get!(Run, run.id).run_documents =~ "\\u0000"
      assert Apiary.Runs.Cancel.write_run?(ctx.scope.workspace, run)
    end

    # The claim reads the run's level once, for its documents and its entries: they take the
    # level it is given, not one read again. The work entry reads at every level, and only
    # `write` has a push entry.
    test "form_work/4 and push_from/3 form the entries of the level they are given", ctx do
      {work_item, queued} = queued!(ctx)

      case Repo.get_by(RunHarness, dispatch_run_id: queued.id) do
        nil ->
          Repo.insert!(%RunHarness{
            dispatch_run_id: queued.id,
            state: :resolved,
            origin: :none,
            access_level: :write
          })

        walk ->
          set!(RunHarness, walk.id, access_level: :write)
      end

      assert RunCredentials.run_access(queued) == :write

      for level <- [:read, :write_no_push, :write] do
        assert {:ok, %RunCredential{name: "work-1", purpose: :work, access: :read} = work} =
                 RunCredentials.form_work(queued, work_item, @target, level)

        push = RunCredentials.push_from(work, level, work_item)

        if level == :write,
          do: assert(%RunCredential{name: "push-1", purpose: :push, access: :write} = push),
          else: assert(push == nil)
      end
    end

    @tag needs: [:factory, :workflow_model]
    test "a run moved onto an entry of its workflow takes that entry's level", ctx do
      queued =
        moved!(ctx, [%{"workflow" => "build", "access" => "read"}], [%{"workflow" => "build"}])

      assert claimed_levels(ctx, queued) == {:write, :write}
    end

    @tag needs: [:factory, :workflow_model]
    test "a run moved onto a lowered entry of its workflow reads", ctx do
      queued =
        moved!(ctx, [%{"workflow" => "build"}], [%{"workflow" => "build", "access" => "read"}])

      assert claimed_levels(ctx, queued) == {:read, :read}
    end

    @tag needs: [:factory, :workflow_model]
    test "a stage's run that stays on its version keeps its entry's level", ctx do
      process!(ctx, [%{"workflow" => "build"}])
      {_work_item, queued} = queued!(ctx)

      assert claimed_levels(ctx, queued) == {:write, :write}
    end

    @tag needs: [:factory, :workflow_model]
    test "an explore-a-ticket run moved onto an entry of another workflow reads", ctx do
      queued = moved!(ctx, [%{"workflow" => "explore-a-ticket"}], [%{"workflow" => "lint"}])

      assert claimed_levels(ctx, queued) == {:read, :read}
    end

    @tag needs: [:factory, :workflow_model]
    test "an explore-a-ticket run moved to a version with no entry at its place reads", ctx do
      queued = moved!(ctx, [%{"workflow" => "explore-a-ticket"}], [])

      assert claimed_levels(ctx, queued) == {:read, :read}
    end

    @tag needs: [:factory, :workflow_model]
    test "an explore-a-ticket run whose stage its version does not have reads", ctx do
      process!(ctx, [%{"workflow" => "explore-a-ticket"}])
      {_work_item, queued} = queued!(ctx)
      set!(DispatchRun, queued.id, stage_id: "st_p9w5cvh311")

      assert claimed_levels(ctx, queued) == {:read, :read}
    end

    @tag needs: [:factory, :workflow_model]
    test "an explore-a-ticket entry with read access reads, in its documents and its token",
         ctx do
      process!(ctx, [%{"workflow" => "explore-a-ticket", "access" => "read"}])
      {_work_item, queued} = queued!(ctx)

      assert claimed_levels(ctx, queued) == {:read, :read}
    end

    test "fills the target path exactly as the adapter wrote it", ctx do
      ctx = %{ctx | scope: with_domain(ctx.scope, "example")}
      {work_item, _queued} = queued!(ctx)
      retarget!(work_item, "Team/Shop%20Two")
      assert {:ok, %{registered: %Run{}}} = claim(ctx)

      assert [%RunCredential{apply: [%{"paths" => paths} | _rest]}] = entries()
      assert paths == ["/Team/Shop%20Two.git/*", "/Team/Shop%20Two/*"]
    end

    test "ends target_access_gone when the collection ended", ctx do
      {work_item, queued} = queued!(ctx)

      set!(Collection, collection_of(work_item).id,
        ended_at: DateTime.utc_now(),
        ended_reason: :not_listed
      )

      assert claim(ctx) == {:ok, :none}
      gone!(queued)
    end

    test "form_work/3 ends target_access_gone when the collection's connection is not connected",
         ctx do
      # A connection that ends closes its work items' runs before a claim takes them
      # (`end_cause` `closed`), so the claim never reaches here for one.
      {work_item, queued} = queued!(ctx)
      target = %{system: "forge.example.com", path: "acme/shop"}

      set!(Connection, work_item.connection_id,
        state: :ended,
        ended_at: DateTime.utc_now(),
        ended_reason: :adapter_reported
      )

      assert RunCredentials.form_work(queued, work_item, target) ==
               {:end, :target_access_gone}
    end

    test "ends target_access_gone for a target path the apply items refuse", ctx do
      ctx = %{ctx | scope: with_domain(ctx.scope, "example")}

      for path <- ["acme/../shop", "acme//shop", "acme/shop*", "acme/shop?x", "acme/shop#x"] do
        {work_item, queued} = queued!(ctx)
        retarget!(work_item, path)
        assert claim(ctx) == {:ok, :none}, inspect(path)
        gone!(queued)
      end
    end

    test "form_work/3 refuses each refused character class before it fills", ctx do
      {work_item, queued} = queued!(ctx)

      # No U+0000: a target is a column of text, which cannot hold one, so no collection's
      # target and no work item's has one.
      spaces =
        [0x09, 0x0A, 0x1F, 0x20, 0x7F, 0xFEFF, 0x85, 0xA0, 0x1680, 0x2000, 0x2005] ++
          [0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

      paths =
        ["acme/../shop", "..", "acme//shop", "acme/shop*", "acme/shop?x", "acme/shop#x"] ++
          for code <- spaces, do: "acme/sh" <> <<code::utf8>> <> "op"

      for path <- paths do
        retarget!(work_item, path)

        assert RunCredentials.form_work(queued, work_item, %{
                 system: "forge.example.com",
                 path: path
               }) ==
                 {:end, :target_access_gone},
               inspect(path)
      end

      for path <- ["acme/shop", "acme/.shop", "acme./shop", "Acme/Shop%2E"] do
        retarget!(work_item, path)

        assert {:ok, %RunCredential{}} =
                 RunCredentials.form_work(queued, work_item, %{
                   system: "forge.example.com",
                   path: path
                 }),
               path
      end
    end
  end

  describe "the collection that can change the run's target" do
    test "is the ticket's, for a ticket from a code forge, before an older one", ctx do
      older = forge_collection!(ctx)
      set!(Collection, older.id, inserted_at: ~U[2026-01-01 00:00:00.000000Z])
      {work_item, _queued} = queued!(ctx)
      assert {:ok, %{registered: %Run{}}} = claim(ctx)

      assert [entry] = entries()
      assert entry.connection_id == work_item.connection_id
      assert entry.adapter_id == work_item.adapter_id
      assert [%{"collection_id" => id}] = entry.resources
      assert id == collection_of(work_item).id
    end

    test "is a forge's collection of the workspace, for a ticket from a tracker", ctx do
      # The tracker's ticket's collection has the same target, and its adapter declares
      # apply items, yet it never counts: its adapter has no `targets`.
      {work_item, _queued} = tracker_queued!(ctx, @target)
      forge = forge_collection!(ctx)
      assert {:ok, %{registered: %Run{}}} = claim(ctx)

      assert [entry] = entries()
      assert entry.connection_id == forge.connection_id
      assert entry.adapter_id == forge.adapter_id
      refute entry.connection_id == work_item.connection_id

      assert entry.resources == [
               %{
                 "collection_id" => forge.id,
                 "external_ref" => forge.external_ref,
                 "path" => "acme/shop"
               }
             ]

      assert [%{"paths" => ["/acme/shop.git/*", "/acme/shop/*"]}, _api] = entry.apply
    end

    test "is found for a work item with no ticket", ctx do
      # A work item whose ticket's row is gone (`item_id` nil): the matching collections
      # are read without it. The claim ends such an explore run `ticket_gone` first.
      {work_item, queued} = tracker_queued!(ctx, @target)
      forge = forge_collection!(ctx)
      forge_id = forge.id

      assert {:ok, %RunCredential{resources: [%{"collection_id" => ^forge_id}]} = entry} =
               RunCredentials.form_work(queued, %{work_item | item_id: nil}, @target)

      assert entry.connection_id == forge.connection_id
      assert entry.adapter_id == forge.adapter_id
    end

    test "is never one of an adapter without targets, even when its target matches", ctx do
      {work_item, queued} = tracker_queued!(ctx, @target)

      for targets <- [nil, false] do
        set!(Node, work_item.adapter_id, targets: targets)
        assert RunCredentials.form_work(queued, work_item, @target) == {:ok, nil}
      end
    end

    test "is the oldest, by when it was kept, then by id", ctx do
      {work_item, queued} = tracker_queued!(ctx)
      at = ~U[2026-01-01 00:00:00.000000Z]
      [first, second, third] = for _n <- 1..3, do: forge_collection!(ctx)
      set!(Collection, first.id, inserted_at: DateTime.add(at, 1))
      set!(Collection, second.id, inserted_at: at)
      set!(Collection, third.id, inserted_at: at)
      [low, _high] = Enum.sort([second.id, third.id])

      assert {:ok, %RunCredential{resources: [%{"collection_id" => ^low}]}} =
               RunCredentials.form_work(queued, work_item, @target)
    end

    test "is a live one on a connected connection, before an older one that is not", ctx do
      {work_item, queued} = tracker_queued!(ctx)
      ended = forge_collection!(ctx)
      disconnected = forge_collection!(ctx)
      live = forge_collection!(ctx)
      set!(Collection, ended.id, ended_at: DateTime.utc_now(), ended_reason: :not_listed)

      set!(Connection, disconnected.connection_id,
        state: :ended,
        ended_at: DateTime.utc_now(),
        ended_reason: :adapter_reported
      )

      for {collection, n} <- Enum.with_index([ended, disconnected, live]) do
        set!(Collection, collection.id,
          inserted_at: DateTime.add(~U[2026-01-01 00:00:00.000000Z], n)
        )
      end

      live_id = live.id

      assert {:ok, %RunCredential{resources: [%{"collection_id" => ^live_id}]}} =
               RunCredentials.form_work(queued, work_item, @target)
    end

    test "ends the run target_access_gone where each one ended or is disconnected", ctx do
      {_work_item, queued} = tracker_queued!(ctx)
      ended = forge_collection!(ctx)
      set!(Collection, ended.id, ended_at: DateTime.utc_now(), ended_reason: :not_listed)
      assert claim(ctx) == {:ok, :none}
      gone!(queued)

      {work_item, queued} = tracker_queued!(ctx)
      disconnected = forge_collection!(ctx)

      set!(Connection, disconnected.connection_id,
        state: :ended,
        ended_at: DateTime.utc_now(),
        ended_reason: :adapter_reported
      )

      assert RunCredentials.form_work(queued, work_item, @target) ==
               {:end, :target_access_gone}
    end
  end

  describe "no entry, and the run runs as before" do
    test "for an adapter that declares no apply items", ctx do
      {_work_item, _queued} = queued!(ctx, nil)
      assert {:ok, %{registered: %Run{}}} = claim(ctx)
      assert entries() == []
    end

    test "for a run with no target", ctx do
      {work_item, queued} = queued!(ctx)
      assert RunCredentials.form_work(queued, work_item, nil) == {:ok, nil}
    end

    test "for a run with no collection that can change its target", ctx do
      {work_item, queued} = tracker_queued!(ctx)

      # One of another target, of another system, and of another workspace.
      forge_collection!(ctx, %{@target | path: "acme/other"})
      forge_collection!(ctx, %{@target | system: "other.example.com"})
      other = collection_fixture(sign_up_fixture().scope, target_path: "acme/shop")
      set!(Collection, other.id, target_system: "forge.example.com")
      set!(Node, other.adapter_id, source_apply: @apply, targets: true)

      # One unassigned, and one in another workspace of the same organisation.
      unassigned = forge_collection!(ctx)
      set!(Collection, unassigned.id, workspace_id: nil)
      elsewhere = forge_collection!(ctx)
      workspace = workspace_fixture(ctx.scope.organisation)
      set!(Collection, elsewhere.id, workspace_id: workspace.id)

      assert RunCredentials.form_work(queued, work_item, @target) == {:ok, nil}
      assert {:ok, %{registered: %Run{}}} = claim(ctx)
      assert entries() == []
    end

    test "for a run with no apply items, even when its collection ended", ctx do
      {work_item, _queued} = queued!(ctx, nil)

      set!(Collection, collection_of(work_item).id,
        ended_at: DateTime.utc_now(),
        ended_reason: :not_listed
      )

      assert {:ok, %{registered: %Run{}}} = claim(ctx)
      assert entries() == []
    end
  end

  describe "a prebuild" do
    @describetag needs: [:factory, :registry]

    test "gets read access to its collection's target", ctx do
      # Its collection's adapter has never said `targets`, and another collection of the
      # workspace can change the same target: the prebuild takes its collection still.
      collection = collection_fixture(ctx.scope, target_path: "acme/app")
      set!(Node, collection.adapter_id, source_apply: @apply)
      assert Repo.get!(Node, collection.adapter_id).targets == nil
      forge_collection!(ctx, %{system: "code.example.com", path: "acme/app"})

      {:ok, _run} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      assert {:ok, %{registered: %Run{}}} = claim(ctx)

      assert [
               %RunCredential{
                 access: :read,
                 resources: [%{"path" => "acme/app", "collection_id" => collection_id}],
                 apply: [%{"paths" => ["/acme/app.git/*", "/acme/app/*"]}, _api]
               }
             ] = entries()

      assert collection_id == collection.id
    end
  end

  describe "the branch a write run may push to" do
    # A run of the queue for a new work item, whose harness walk has `level`.
    defp queued_at!(ctx, level) do
      {work_item, queued} = queued!(ctx)

      case Repo.get_by(RunHarness, dispatch_run_id: queued.id) do
        nil ->
          Repo.insert!(%RunHarness{
            dispatch_run_id: queued.id,
            state: :resolved,
            origin: :none,
            access_level: level
          })

        walk ->
          set!(RunHarness, walk.id, access_level: level)
      end

      {work_item, queued}
    end

    defp branch(%WorkItem{public_id: public_id}), do: "refs/heads/qory/" <> public_id

    # The run configuration with the entries of the claimed run `run`, as it is sent.
    defp document(run) do
      entries =
        for entry <- [RunCredentials.work(run), RunCredentials.push(run)], entry, do: entry.entry

      Jason.encode!(%{"version" => 1, "credentials" => entries})
    end

    defp entry!(purpose), do: Enum.find(entries(), &(&1.purpose == purpose))

    test "a write run has a read work-1 with no push_ref, and a push-1 with the branch", ctx do
      {work_item, _queued} = queued_at!(ctx, :write)
      assert {:ok, %{registered: %Run{} = run}} = claim(ctx)

      assert [%RunCredential{name: "push-1"}, %RunCredential{name: "work-1"}] = entries()
      assert work_item.public_id =~ ~r/\Awi_[0-9a-z]{16}\z/

      assert %RunCredential{access: :read, apply: [_code, _api] = work_apply} = entry!(:work)
      refute Enum.any?(work_apply, &Map.has_key?(&1, "push_ref"))

      assert %RunCredential{access: :write, apply: [_code, _api] = push_apply} = entry!(:push)
      assert Enum.map(push_apply, & &1["push_ref"]) == [branch(work_item), branch(work_item)]

      # Both entries have the same connection, adapter, resource and items, but the branch.
      work = entry!(:work)
      push = entry!(:push)

      assert {work.connection_id, work.adapter_id, work.resources} ==
               {push.connection_id, push.adapter_id, push.resources}

      assert Enum.map(push_apply, &Map.delete(&1, "push_ref")) == work_apply

      # The run configuration has push_ref last in each push item, as the schema orders the
      # members, and `purpose` push on the entry.
      %{entry: %{values: values}} = RunCredentials.push(run)
      assert {"purpose", "push"} = List.keyfind(values, "purpose", 0)
      {"apply", items} = List.keyfind(values, "apply", 0)

      for item <- items,
          do: assert({"push_ref", branch(work_item)} == List.last(item.values))

      [work_entry, push_entry] = Jason.decode!(document(run))["credentials"]
      assert %{"name" => "work-1", "purpose" => "work"} = work_entry
      refute Map.has_key?(work_entry, "placeholders")
      refute Enum.any?(work_entry["apply"], &Map.has_key?(&1, "push_ref"))
      assert %{"name" => "push-1", "purpose" => "push"} = push_entry
      refute Map.has_key?(push_entry, "placeholders")

      assert Enum.map(push_entry["apply"], & &1["push_ref"]) == [
               branch(work_item),
               branch(work_item)
             ]
    end

    for level <- [:read, :write_no_push] do
      test "a #{level} run has a read work-1 with no push_ref and no push entry", ctx do
        {_work_item, _queued} = queued_at!(ctx, unquote(level))
        assert {:ok, %{registered: %Run{} = run}} = claim(ctx)

        assert [%RunCredential{name: "work-1", access: :read, apply: apply}] = entries()
        assert length(apply) == 2
        refute Enum.any?(apply, &Map.has_key?(&1, "push_ref"))
        assert RunCredentials.push(run) == nil
        refute document(run) =~ "push_ref"
        refute document(run) =~ "push"
      end
    end

    test "the same work item has the same branch each time, another work item its own", ctx do
      {work_item, queued} = queued!(ctx)
      {other, other_queued} = queued!(ctx)
      assert work_item.public_id != other.public_id

      refs = fn work_item, queued ->
        for _again <- 1..2 do
          assert {:ok, %RunCredential{} = work} =
                   RunCredentials.form_work(queued, work_item, @target, :write)

          assert %RunCredential{apply: apply} = RunCredentials.push_from(work, :write, work_item)
          apply |> Enum.map(& &1["push_ref"]) |> Enum.uniq()
        end
      end

      assert refs.(work_item, queued) == [[branch(work_item)], [branch(work_item)]]
      assert refs.(other, other_queued) == [[branch(other)], [branch(other)]]
    end

    test "a push_ref in an adapter's template is dropped, and only the push entry gets one",
         ctx do
      template = Enum.map(@apply, &Map.put(&1, "push_ref", "refs/heads/main"))
      work_item = work_item_fixture(ctx.scope)
      set!(Node, work_item.adapter_id, source_apply: template)
      target_candidate!(work_item)
      queued = queue!(work_item)

      for level <- [:read, :write_no_push, :write] do
        assert {:ok, %RunCredential{apply: apply} = work} =
                 RunCredentials.form_work(queued, work_item, @target, level)

        assert length(apply) == 2
        refute Enum.any?(apply, &Map.has_key?(&1, "push_ref")), inspect(level)

        push = RunCredentials.push_from(work, level, work_item)

        if level == :write do
          assert Enum.map(push.apply, & &1["push_ref"]) == [branch(work_item), branch(work_item)]
        else
          assert push == nil
        end
      end

      # A work item with no public id, which the database does not store, ends the run.
      nil_item = %{work_item | public_id: nil}

      assert RunCredentials.form_work(queued, nil_item, @target, :write) ==
               {:end, :write_without_work_item}
    end

    test "a write run with no work item ends write_without_work_item and has no entry", ctx do
      {work_item, queued} = queued!(ctx)
      collection = RunCredentials.work_collection(queued, work_item, @target)

      assert RunCredentials.work_from(queued, nil, collection, @target, :write) ==
               {:end, :write_without_work_item}

      assert RunCredentials.form_work(queued, nil, @target, :write) == {:ok, nil}
      assert entries() == []

      # A work item with no public id has no branch either: the database refuses to store
      # one, so only a struct is such.
      assert RunCredentials.work_from(
               queued,
               %{work_item | public_id: nil},
               collection,
               @target,
               :write
             ) == {:end, :write_without_work_item}

      # No work entry, so no push entry.
      assert RunCredentials.push_from(nil, :write, work_item) == nil
    end

    test "a read or write-no-push run with no work item has a read entry and no push entry",
         ctx do
      {work_item, queued} = queued!(ctx)
      collection = RunCredentials.work_collection(queued, work_item, @target)

      for level <- [:read, :write_no_push] do
        assert {:ok, %RunCredential{access: :read, apply: apply} = work} =
                 RunCredentials.work_from(queued, nil, collection, @target, level)

        assert length(apply) == 2
        refute Enum.any?(apply, &Map.has_key?(&1, "push_ref"))
        assert RunCredentials.push_from(work, level, nil) == nil
      end
    end

    test "the branch of a work item is the fixed string refs/heads/qory/<public id>", ctx do
      {work_item, queued} = queued!(ctx)
      collection = RunCredentials.work_collection(queued, work_item, @target)
      pinned = %{work_item | public_id: "wi_01HZX"}

      assert {:ok, %RunCredential{} = work} =
               RunCredentials.work_from(queued, pinned, collection, @target, :write)

      assert %RunCredential{name: "push-1", purpose: :push, access: :write, apply: apply} =
               RunCredentials.push_from(work, :write, pinned)

      assert Enum.map(apply, & &1["push_ref"]) == [
               "refs/heads/qory/wi_01HZX",
               "refs/heads/qory/wi_01HZX"
             ]
    end

    test "a prebuild has no push_ref and no push entry", ctx do
      collection = collection_fixture(ctx.scope, target_path: "acme/app")
      set!(Node, collection.adapter_id, source_apply: @apply)
      forge_collection!(ctx, %{system: "code.example.com", path: "acme/app"})

      {:ok, _run} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      assert {:ok, %{registered: %Run{}}} = claim(ctx)
      assert [%RunCredential{name: "work-1", apply: apply}] = entries()
      refute Enum.any?(apply, &Map.has_key?(&1, "push_ref"))
    end

    test "the run configuration with push_ref passes the schema, one with another member fails",
         ctx do
      {_work_item, _queued} = queued_at!(ctx, :write)
      assert {:ok, %{registered: %Run{} = run}} = claim(ctx)
      assert Apiary.Policy.Schema.validate(document(run)) == :ok

      for {name, change} <- [
            {"another member", &Map.put(&1, "branch", "main")},
            {"a tag", &Map.put(&1, "push_ref", "refs/tags/v1")},
            {"a name that is no ref", &Map.put(&1, "push_ref", "qory/wi_01")}
          ] do
        decoded = Jason.decode!(document(run))
        changed = update_in(decoded, ["credentials", Access.at(1), "apply", Access.at(0)], change)
        assert {:error, _} = Apiary.Policy.Schema.validate(Jason.encode!(changed)), name
      end

      # A purpose that is none of harness, work and push fails.
      decoded = Jason.decode!(document(run))
      changed = put_in(decoded, ["credentials", Access.at(1), "purpose"], "merge")
      assert {:error, _} = Apiary.Policy.Schema.validate(Jason.encode!(changed))
    end
  end

  describe "the table" do
    test "keeps a row in its run's organisation and workspace, one work and one push entry",
         ctx do
      {work_item, _queued} = queued!(ctx)
      assert {:ok, %{registered: %Run{} = run}} = claim(ctx)
      [entry] = entries()
      other = sign_up_fixture().scope

      row = fn changes ->
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            organisation_id: entry.organisation_id,
            workspace_id: entry.workspace_id,
            run_id: run.id,
            connection_id: work_item.connection_id,
            adapter_id: work_item.adapter_id,
            name: "work-2",
            purpose: "work",
            access: "read",
            resources: [%{"path" => "acme/shop"}],
            apply: [%{"hosts" => ["git.example.com"], "scheme" => "bearer"}],
            inserted_at: DateTime.utc_now()
          },
          changes
        )
      end

      uuids = ~w(id organisation_id workspace_id run_id connection_id adapter_id)a

      insert = fn changes ->
        row = row.(changes)
        row = Enum.reduce(uuids, row, &Map.update!(&2, &1, fn id -> Ecto.UUID.dump!(id) end))
        Repo.insert_all("run_credentials", [row])
      end

      for {changes, constraint} <- [
            {%{}, "run_credentials_work_index"},
            # Another organisation's place: the run is not of that workspace.
            {%{
               name: "harness-2",
               purpose: "harness",
               organisation_id: other.organisation.id,
               workspace_id: other.workspace.id
             }, "run_credentials_run_id_fkey"},
            {%{name: "harness-2", purpose: "harness", workspace_id: other.workspace.id},
             "run_credentials_workspace_id_fkey"},
            {%{name: "harness-1", purpose: "harness", access: "write"},
             "run_credentials_entry_check"},
            {%{name: "harness-1"}, "run_credentials_entry_check"},
            {%{name: "work-10"}, "run_credentials_entry_check"},
            # A work entry is not named for the push, and a push entry reads nowhere.
            {%{name: "push-1"}, "run_credentials_entry_check"},
            {%{name: "push-2", purpose: "push", access: "read"}, "run_credentials_entry_check"},
            # A push entry writes, and its name starts with its purpose.
            {%{name: "push-1", purpose: "push"}, "run_credentials_entry_check"},
            {%{name: "work-2", purpose: "push", access: "write"}, "run_credentials_entry_check"},
            {%{name: "push-0", purpose: "push", access: "write"}, "run_credentials_entry_check"},
            {%{name: "harness-1", purpose: "harness", apply: []}, "run_credentials_values_check"},
            {%{name: "harness-1", purpose: "harness", resources: [1]},
             "run_credentials_values_check"},
            {%{name: "harness-1", purpose: "harness", placeholders: []},
             "run_credentials_values_check"}
          ] do
        error = assert_raise Postgrex.Error, fn -> insert.(changes) end

        assert error.postgres.constraint == constraint,
               inspect({changes, error.postgres.constraint})
      end

      assert {1, _rows} = insert.(%{name: "harness-1", purpose: "harness"})

      # A push entry has a push_ref on every apply item.
      pushing = %{
        name: "push-1",
        purpose: "push",
        access: "write",
        apply: [
          %{
            "hosts" => ["git.example.com"],
            "scheme" => "bearer",
            "push_ref" => "refs/heads/qory/x"
          }
        ]
      }

      error = assert_raise Postgrex.Error, fn -> insert.(Map.delete(pushing, :apply)) end
      assert error.postgres.constraint == "run_credentials_push_ref_check"

      assert {1, _rows} = insert.(pushing)

      error =
        assert_raise Postgrex.Error, fn -> insert.(%{pushing | name: "push-2"}) end

      assert error.postgres.constraint == "run_credentials_push_index"

      # The apply items of the first credential sealed are kept on a work or a push entry
      # alone.
      kept = fn name ->
        Repo.query!(
          "UPDATE run_credentials SET issued_apply = '[{\"hosts\": []}]'::jsonb " <>
            "WHERE run_id = $1 AND name = $2",
          [Ecto.UUID.dump!(run.id), name]
        )
      end

      assert %{num_rows: 1} = kept.("push-1")

      error = assert_raise Postgrex.Error, fn -> kept.("harness-1") end
      assert error.postgres.constraint == "run_credentials_issued_apply_check"

      error =
        assert_raise Postgrex.Error, fn -> insert.(%{name: "harness-1", purpose: "harness"}) end

      assert error.postgres.constraint == "run_credentials_run_id_name_index"

      # Another organisation's connection is not this run's.
      other_connection = ticket_connection_fixture(other)

      error =
        assert_raise Postgrex.Error, fn ->
          insert.(%{name: "harness-2", purpose: "harness", connection_id: other_connection.id})
        end

      assert error.postgres.constraint == "run_credentials_connection_id_fkey"

      # The rows go with their run.
      Repo.delete!(run)
      assert entries() == []
    end
  end

  describe "a gateway key made without allow_secrets" do
    setup do
      %{scope: scope} = sign_up_fixture()
      Map.put(handover_place_fixture(scope), :scope, scope)
    end

    test "ends a run with a work entry secrets_not_allowed, and stores no entry", ctx do
      {_work_item, queued} = queued!(ctx)
      assert {:ok, :none} = claim(ctx)

      assert %DispatchRun{state: :ended, end_cause: :secrets_not_allowed} =
               Repo.get!(DispatchRun, queued.id)

      assert Repo.aggregate(
               from(r in Apiary.RunEventsFixtures.registered_runs(),
                 where: r.dispatch_run_id == ^queued.id
               ),
               :count
             ) == 0

      assert entries() == []
    end

    test "leaves a run without a work entry as it was", ctx do
      {_work_item, queued} = queued!(ctx, nil)
      assert {:ok, %{registered: %Run{dispatch_run_id: id}}} = claim(ctx)
      assert id == queued.id
      assert entries() == []
    end
  end

  describe "why a run ended, as a stage's escalation shows it" do
    # A tracker's ticket, from one integration, whose target only a forge's collection,
    # of another integration, can change: the work entry comes from the forge's.
    defp two_integrations!(ctx, target \\ @target) do
      {work_item, queued} = tracker_queued!(ctx)
      set!(WorkItem, work_item.id, target_system: target.system, target_path: target.path)
      forge = forge_collection!(ctx, target)
      tracker = Repo.get!(Node, work_item.adapter_id)
      forge_adapter = Repo.get!(Node, forge.adapter_id)
      assert Apiary.Adapters.title(tracker) != Apiary.Adapters.title(forge_adapter)

      %{
        work_item: Repo.get!(WorkItem, work_item.id),
        queued: queued,
        forge: forge,
        tracker: "the integration " <> Apiary.Adapters.title(tracker),
        integration: "the integration " <> Apiary.Adapters.title(forge_adapter)
      }
    end

    defp text(%{queued: queued, work_item: work_item}),
      do: Apiary.Stages.StopCause.text(Repo.get!(DispatchRun, queued.id), work_item)

    test "a collection that ended names the target's integration, not the ticket's", ctx do
      two = two_integrations!(ctx)
      set!(Collection, two.forge.id, ended_at: DateTime.utc_now(), ended_reason: :not_listed)

      assert claim(ctx) == {:ok, :none}
      gone!(two.queued)
      org = ctx.scope.organisation.name

      assert text(two) ==
               "The run did not start, because #{two.integration} no longer reaches target acme/shop.\n" <>
                 "Owners and admins of #{org} check #{two.integration} in Organisation settings › Integrations."

      refute text(two) =~ two.tracker
    end

    test "the target's deleted adapter ends the run, and the stop cause shows its integration",
         ctx do
      two = two_integrations!(ctx)
      forge_adapter = Repo.get!(Node, two.forge.adapter_id)
      {:ok, _} = Apiary.Adapters.delete_adapter(instance_admin_scope(), forge_adapter)

      assert claim(ctx) == {:ok, :none}
      gone!(two.queued)
      assert entries() == []
      org = ctx.scope.organisation.name

      assert text(two) ==
               "The run did not start, because #{two.integration} no longer reaches target acme/shop.\n" <>
                 "Owners and admins of #{org} check #{two.integration} in Organisation settings › Integrations."
    end

    test "a path the access rules do not take names its first refused part, and links Destinations",
         ctx do
      ws = ctx.scope.workspace.name

      fix = fn path, without ->
        "Whoever manages #{path} where it is kept renames it without #{without}, or owners and admins of #{ws} remove it on the set-up step Destinations."
      end

      for {path, part, without} <- [
            {"acme/shop?x#y", ~s(the character "?"), "that character"},
            {"acme/sh\u00A0op", "the character U+00A0", "that character"},
            {"acme/../shop", "two dots in a row", "two dots in a row"},
            {"acme//shop", "two slashes in a row", "two slashes in a row"}
          ] do
        two = two_integrations!(ctx, %{system: "forge.example.com", path: path})

        run = %{
          Repo.get!(DispatchRun, two.queued.id)
          | state: :ended,
            end_cause: :target_access_gone
        }

        assert Apiary.Stages.StopCause.text(run, two.work_item) ==
                 "The run did not start, because target #{path} has #{part} in its path, which Qory Apiary does not put in an access rule.\n" <>
                   fix.(path, without),
               inspect(path)

        assert Apiary.Stages.StopCause.set_up_step(run) == :destinations
      end
    end

    test "a path filled out of the grammar by the adapter's access rules sends the person to support",
         ctx do
      # A description's check refuses such apply items at the adapter's start; written
      # here directly.
      two = two_integrations!(ctx, %{system: "forge.example.com", path: "acme/shop"})

      Repo.update_all(from(n in Node, where: n.id == ^two.forge.adapter_id),
        set: [
          source_apply: [
            %{
              "hosts" => ["git.example.com"],
              "scheme" => "bearer",
              "paths" => ["/{target.path} x"]
            }
          ]
        ]
      )

      run = %{
        Repo.get!(DispatchRun, two.queued.id)
        | state: :ended,
          end_cause: :target_access_gone
      }

      assert Apiary.Stages.StopCause.text(run, two.work_item) ==
               "The run did not start, because Qory Apiary could not grant the run access to target acme/shop.\n" <>
                 "Contact support with work item ##{two.work_item.number}."

      assert Apiary.Stages.StopCause.set_up_step(run) == nil
    end

    test "a system that is no host name names the target's integration", ctx do
      # A stored work item's system keeps the rule (`work_items_target_shape_check`), so
      # the system is broken in memory, and on the forge's collection, whose check allows it.
      two = two_integrations!(ctx)
      set!(Collection, two.forge.id, target_system: "forge..example.com")
      work_item = %{two.work_item | target_system: "forge..example.com"}

      run = %{
        Repo.get!(DispatchRun, two.queued.id)
        | state: :ended,
          end_cause: :variables_invalid
      }

      assert Apiary.Stages.StopCause.text(run, work_item) ==
               "The run did not start, because its variable QORY_RUN_SYSTEM, the system forge..example.com of target acme/shop, is not a host name: a-z, 0-9, dots and dashes, with no dot at either end and no two dots in a row.\n" <>
                 "Owners and admins of #{ctx.scope.organisation.name} check #{two.integration} in Organisation settings › Integrations."
    end

    test "a run a claim registered is named to support by its public id", ctx do
      {work_item, queued} = queued!(ctx)
      assert {:ok, %{registered: %Run{public_id: public_id}}} = claim(ctx)

      run = %{
        Repo.get!(DispatchRun, queued.id)
        | state: :ended,
          end_cause: :run_refused,
          end_detail: "machine_busy"
      }

      assert Apiary.Stages.StopCause.text(run, work_item) ==
               "The gateway did not start the run. Qory Apiary has no description for its refusal (machine_busy).\n" <>
                 "Contact support with run #{public_id}."
    end
  end
end
