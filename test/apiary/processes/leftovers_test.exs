defmodule Apiary.Processes.LeftoversTest do
  # A workflow's overrides in a workspace, its model choice (level 4) and its time limit,
  # are kept while the current process version or an open work item's version has the
  # workflow, or a run of it has not ended, and deleted when none of these has it any
  # more: at a save, a make current, a drop of a trial and an assign, and, through
  # `Apiary.Processes.LeftoversJob`, once a work item closes or is undone or a run ends.
  # A model provider used only by such a leftover can be deleted. A choice uses no key: a
  # key of its provider is deleted and renamed as any other, and deletes no leftover.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.DispatchedRunsFixtures, only: [handed_over: 4, handover_place_fixture: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures, only: [backlog_ticket_fixture: 1, work_item_fixture: 1]

  alias Apiary.{Connections, Dispatches, ModelChoices, Processes, TimeLimits, WorkItems}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{DispatchRun, RunEnd, RunSettings}
  alias Apiary.ModelChoices.{Fallback, ModelChoice}
  alias Apiary.Processes.LeftoversJob
  alias Apiary.TimeLimits.TimeLimit
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @workflow "explore-a-ticket"

  @tiers %{
    "thinking" => %{"model" => "claude-opus-5-5", "effort" => "high"},
    "balanced" => %{"model" => "claude-sonnet-5-5", "effort" => "medium"},
    "light" => %{"model" => "claude-haiku-5-5", "effort" => "low"}
  }

  setup do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-leftovers-0123456789"}]
      })

    %{scope: scope, provider: provider}
  end

  defp override!(scope, provider, workflow \\ @workflow) do
    {:ok, _choice} =
      ModelChoices.put_choice(scope, {:workspace, workflow}, %{
        provider: provider.public_id,
        tiers: @tiers
      })

    {:ok, _limit} = TimeLimits.put_limit(scope, :workspace, workflow, 45)
    :ok
  end

  defp on!(scope, provider, workflow) do
    {:ok, choice} =
      ModelChoices.put_choice(scope, {:workspace, workflow}, %{
        provider: provider.public_id,
        tiers: @tiers
      })

    choice
  end

  defp choice(scope, workflow \\ @workflow),
    do:
      Repo.one(
        from c in ModelChoice,
          where:
            c.workspace_id == ^scope.workspace.id and is_nil(c.target_id) and
              c.workflow == ^workflow
      )

  defp time_limit(scope, workflow \\ @workflow),
    do:
      Repo.one(
        from l in TimeLimit,
          where:
            l.workspace_id == ^scope.workspace.id and is_nil(l.target_id) and
              l.workflow == ^workflow
      )

  # The workspace's process with Explore's sequence set to `workflows`, saved.
  defp explore!(scope, workflows) do
    document = Processes.current(scope.workspace).document

    stages =
      for stage <- document["stages"] do
        if stage["name"] == "Explore",
          do: Map.put(stage, "sequence", for(w <- workflows, do: %{"workflow" => w})),
          else: stage
      end

    {:ok, version} = Processes.save(scope, scope.workspace, Map.put(document, "stages", stages))
    version
  end

  # A work item on the current version, which it keeps when a later version is saved.
  defp open_item!(scope) do
    work_item = work_item_fixture(scope)
    {:ok, work_item} = Processes.assign(scope, work_item, Processes.current(scope.workspace))
    work_item
  end

  defp removals(id),
    do:
      Repo.all(
        from e in Entry,
          where:
            e.subject_id == ^id and fragment("?->>'cause'", e.details) == "workflow_not_in_use"
      )

  test "a workflow removed from the current version, with no open work item on another, loses its overrides",
       %{scope: scope, provider: provider} do
    override!(scope, provider)
    %{id: choice_id} = choice(scope)
    %{id: limit_id} = time_limit(scope)

    explore!(scope, ["shape-a-ticket"])

    assert choice(scope) == nil
    assert time_limit(scope) == nil

    assert [%Entry{action: "model_choice.write"} = entry] = removals(choice_id)
    assert entry.details["change"] == "choice_removed"
    assert entry.details["workflow"] == @workflow
    assert entry.actor_id == scope.user.id
    assert [%Entry{action: "time_limit.edit"} = entry] = removals(limit_id)
    assert entry.details["change"] == "time_limit_removed"
    assert entry.before == %{"minutes" => 45}
  end

  test "an open work item on an older version keeps the overrides, and its run uses them; its close deletes them",
       %{scope: scope, provider: provider} do
    # A run takes a workflow's choice over the workspace's default.
    {:ok, _default} =
      ModelChoices.put_choice(scope, :workspace, %{
        provider: provider.public_id,
        tiers: @tiers
      })

    override!(scope, provider)
    _place = handover_place_fixture(scope, allow_secrets: true)

    # The work item's first run enters Explore of version 1, which runs explore-a-ticket,
    # and the work item stays on version 1.
    work_item = work_item_fixture(scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    v1 = Processes.current(scope.workspace)
    assert Repo.reload!(work_item).process_version_id == v1.id
    assert queued.workflow == @workflow

    explore!(scope, ["shape-a-ticket"])

    assert %ModelChoice{} = choice(scope)
    assert %TimeLimit{minutes: 45} = time_limit(scope)
    assert @workflow in Processes.kept_workflows(scope.workspace)
    assert {4, %ModelChoice{workflow: @workflow}} = RunSettings.choice_in_effect(queued)

    %{id: choice_id} = choice(scope)
    {:ok, _closed} = WorkItems.close(scope, Repo.reload!(work_item))

    # The close leaves the delete to the job, which runs once it commits.
    assert %ModelChoice{} = choice(scope)

    assert_enqueued(
      worker: LeftoversJob,
      args: %{"organisation_id" => scope.organisation.id, "workspace_id" => scope.workspace.id}
    )

    assert %{failure: 0, success: success} = Oban.drain_queue(queue: :default)
    assert success >= 1

    assert choice(scope) == nil
    assert time_limit(scope) == nil

    # The job deletes as the instance.
    assert [%Entry{actor_kind: :instance, actor_id: nil} = entry] = removals(choice_id)
    assert entry.details["change"] == "choice_removed"
  end

  test "a close followed by a take in again moves the work item to the current version, and its old version's overrides go",
       %{scope: scope, provider: provider} do
    override!(scope, provider)
    ticket = backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    v1 = Processes.current(scope.workspace)
    assert Repo.reload!(work_item).process_version_id == v1.id

    v2 = explore!(scope, ["shape-a-ticket"])
    assert %ModelChoice{} = choice(scope)

    {:ok, _closed} = WorkItems.close(scope, Repo.reload!(work_item))

    {:ok, _again} =
      WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

    assert Repo.reload!(work_item).process_version_id == v2.id

    assert %{failure: 0} = Oban.drain_queue(queue: :default)
    assert Repo.reload!(work_item).process_version_id == v2.id
    assert choice(scope) == nil
    assert time_limit(scope) == nil
  end

  test "a workflow that comes back to the process starts with no override",
       %{scope: scope, provider: provider} do
    # A leftover as one made before overrides were deleted: the workflow is in no version.
    override!(scope, provider, "write-a-brief")

    explore!(scope, [@workflow, "write-a-brief"])

    assert choice(scope, "write-a-brief") == nil
    assert time_limit(scope, "write-a-brief") == nil
  end

  test "a renamed workflow's overrides go with its old name", %{scope: scope, provider: provider} do
    explore!(scope, ["write-a-brief"])
    override!(scope, provider, "write-a-brief")

    explore!(scope, ["write-the-brief"])

    assert choice(scope, "write-a-brief") == nil
    assert time_limit(scope, "write-a-brief") == nil
  end

  test "an assign that moves the last open work item off a version deletes what only it kept",
       %{scope: scope, provider: provider} do
    override!(scope, provider)
    work_item = open_item!(scope)
    explore!(scope, ["shape-a-ticket"])
    assert %ModelChoice{} = choice(scope)

    {:ok, _assigned} =
      Processes.assign(scope, Repo.reload!(work_item), Processes.current(scope.workspace))

    assert choice(scope) == nil
    assert time_limit(scope) == nil
  end

  test "a time limit alone follows the same rule", %{scope: scope} do
    {:ok, _limit} = TimeLimits.put_limit(scope, :workspace, @workflow, 30)
    work_item = open_item!(scope)
    explore!(scope, ["shape-a-ticket"])
    assert %TimeLimit{minutes: 30} = time_limit(scope)

    {:ok, _closed} = WorkItems.close(scope, Repo.reload!(work_item))
    assert %{failure: 0, success: success} = Oban.drain_queue(queue: :default)
    assert success >= 1

    assert time_limit(scope) == nil
  end

  test "a provider used only by a leftover is not in use, and its deletion deletes the leftover",
       %{scope: scope, provider: provider} do
    # A leftover as one made before overrides were deleted: the workflow is in no version.
    {:ok, _choice} =
      ModelChoices.put_choice(scope, {:workspace, "gone-workflow"}, %{
        provider: provider.public_id,
        tiers: @tiers
      })

    %{id: choice_id} = choice(scope, "gone-workflow")

    assert ModelChoices.places_using(provider) == []
    assert {:ok, _deleted} = Connections.delete_provider(scope, provider)

    assert choice(scope, "gone-workflow") == nil
    assert [%Entry{}] = removals(choice_id)
  end

  test "a provider used by a kept override is still in use", %{scope: scope, provider: provider} do
    override!(scope, provider)

    assert [%{level: 4, workflow: @workflow}] = ModelChoices.places_using(provider)
    assert {:error, {:model_in_use, [_place]}} = Connections.delete_provider(scope, provider)
  end

  describe "a queued run of a workflow the process no longer has" do
    setup %{scope: scope, provider: provider} do
      # A run takes a workflow's choice over the workspace's default.
      {:ok, _default} =
        ModelChoices.put_choice(scope, :workspace, %{
          provider: provider.public_id,
          tiers: @tiers
        })

      override!(scope, provider)
      place = handover_place_fixture(scope, allow_secrets: true)

      # The run waits on version 1, which runs explore-a-ticket; an assign moves the work
      # item to version 2, which does not, and the waiting run keeps its workflow.
      work_item = work_item_fixture(scope)
      {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      assert queued.workflow == @workflow
      v2 = explore!(scope, ["shape-a-ticket"])

      {:ok, _assigned} = Processes.assign(scope, Repo.reload!(work_item), v2)
      assert Repo.reload!(work_item).process_version_id == v2.id
      assert %DispatchRun{state: :waiting, workflow: @workflow} = Repo.reload!(queued)

      # Kept while the run waits, whatever runs meanwhile.
      assert %{failure: 0} = Oban.drain_queue(queue: :default)
      assert %ModelChoice{} = choice(scope)
      assert %TimeLimit{minutes: 45} = time_limit(scope)
      assert @workflow in Processes.kept_workflows(scope.workspace)

      assert {4, %ModelChoice{workflow: @workflow}} =
               RunSettings.choice_in_effect(Repo.reload!(queued))

      %{work_item: Repo.reload!(work_item), queued: queued, key: place.key}
    end

    test "keeps the overrides until it ends before its handover, then the job deletes them",
         %{scope: scope, work_item: work_item, queued: queued} do
      %{id: choice_id} = choice(scope)

      # A held run whose environment build failed ends while it waits, its work item open.
      {:ok, _told} =
        Repo.transact(fn ->
          _held = Repo.one!(from w in WorkItem, where: w.id == ^work_item.id, lock: "FOR UPDATE")

          {:ok,
           Dispatches.end_held(
             [work_item.id],
             scope.workspace.id,
             %{system: work_item.target_system, path: work_item.target_path},
             DateTime.utc_now()
           )}
        end)

      assert %DispatchRun{state: :ended} = Repo.reload!(queued)
      assert Repo.reload!(work_item).state == :exploring
      assert %ModelChoice{} = choice(scope)

      assert_enqueued(
        worker: LeftoversJob,
        args: %{"organisation_id" => scope.organisation.id, "workspace_id" => scope.workspace.id}
      )

      assert %{failure: 0} = Oban.drain_queue(queue: :default)
      assert choice(scope) == nil
      assert time_limit(scope) == nil
      assert [%Entry{actor_kind: :instance}] = removals(choice_id)
    end

    test "keeps the overrides while it is handed over, until it ends",
         %{scope: scope, work_item: work_item, queued: queued, key: key} do
      %{dispatch_run: %DispatchRun{state: :handed_over}} =
        handed_over(scope, key, queued, %{})

      # A save while the run is handed over keeps them.
      explore!(scope, ["shape-a-ticket", "write-a-brief"])
      assert %{failure: 0} = Oban.drain_queue(queue: :default)
      assert %ModelChoice{} = choice(scope)

      # The lost-run check ends the run, its work item open.
      _changed = RunEnd.lose(DateTime.add(DateTime.utc_now(), 86_400, :second))
      assert %DispatchRun{state: :ended} = Repo.reload!(queued)
      assert Repo.reload!(work_item).state == :exploring

      assert_enqueued(
        worker: LeftoversJob,
        args: %{"organisation_id" => scope.organisation.id, "workspace_id" => scope.workspace.id}
      )

      assert %{failure: 0} = Oban.drain_queue(queue: :default)
      assert choice(scope) == nil
      assert time_limit(scope) == nil
    end
  end

  test "a run's end enqueues no job where its workflow has no override", %{scope: scope} do
    work_item = work_item_fixture(scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    {:ok, :ok} =
      Repo.transact(fn ->
        {1, _rows} =
          Repo.update_all(from(r in DispatchRun, where: r.id == ^queued.id),
            set: [state: :ended, end_cause: :build_failed, result_outcome: :error]
          )

        {:ok, Processes.delete_leftovers_after_runs([queued.id])}
      end)

    refute_enqueued(worker: LeftoversJob)
  end

  describe "a key" do
    setup %{scope: scope, provider: provider} do
      {:ok, _provider} =
        Connections.add_provider_key(scope, provider, %{
          value_id: "spare",
          value: "sk-leftovers-spare-0123456789"
        })

      %{provider: Repo.reload!(provider)}
    end

    test "of a provider that only a leftover chooses is deleted, and the leftover stays",
         %{scope: scope, provider: provider} do
      %{id: choice_id} = on!(scope, provider, "gone-workflow")

      assert {:ok, _provider} = Connections.delete_provider_key(scope, provider, "spare")

      assert %ModelChoice{id: ^choice_id} = choice(scope, "gone-workflow")
      assert removals(choice_id) == []
    end

    test "of a provider that a kept override chooses is renamed and deleted",
         %{scope: scope, provider: provider} do
      %{id: choice_id} = on!(scope, provider, @workflow)

      assert {:ok, _provider} =
               Connections.rename_provider_key(scope, provider, "spare", "other")

      provider = Repo.reload!(provider)
      assert {:ok, _provider} = Connections.delete_provider_key(scope, provider, "other")

      assert %ModelChoice{id: ^choice_id} = choice(scope)
      assert removals(choice_id) == []
    end
  end

  test "an undo deletes, through the job, what only the work item kept",
       %{scope: scope, provider: provider} do
    # The work item's version has write-a-brief, which its run does not run, so only the
    # undo enqueues the job.
    explore!(scope, [@workflow, "write-a-brief"])
    override!(scope, provider, "write-a-brief")
    ticket = backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    explore!(scope, ["shape-a-ticket"])
    assert %ModelChoice{} = choice(scope, "write-a-brief")

    {:ok, _undone} = WorkItems.undo(scope, Repo.reload!(work_item))
    assert %ModelChoice{} = choice(scope, "write-a-brief")

    assert_enqueued(
      worker: LeftoversJob,
      args: %{"organisation_id" => scope.organisation.id, "workspace_id" => scope.workspace.id}
    )

    assert %{failure: 0} = Oban.drain_queue(queue: :default)
    assert choice(scope, "write-a-brief") == nil
    assert time_limit(scope, "write-a-brief") == nil
  end

  # The workspace's process with Explore's sequence set to `workflows`, as a document.
  defp explore_document(scope, workflows) do
    document = Processes.current(scope.workspace).document

    stages =
      for stage <- document["stages"] do
        if stage["name"] == "Explore",
          do: Map.put(stage, "sequence", for(w <- workflows, do: %{"workflow" => w})),
          else: stage
      end

    Map.put(document, "stages", stages)
  end

  test "a trial keeps nothing, and its make current deletes what the old version kept",
       %{scope: scope, provider: provider} do
    override!(scope, provider)

    {:ok, trial} =
      Processes.save(scope, scope.workspace, explore_document(scope, ["shape-a-ticket"]),
        trial: true
      )

    assert %ModelChoice{} = choice(scope)

    {:ok, _current} = Processes.make_current(scope, trial)
    assert choice(scope) == nil
    assert time_limit(scope) == nil
  end

  test "a drop of a trial deletes what only its work items kept", %{
    scope: scope,
    provider: provider
  } do
    {:ok, trial} =
      Processes.save(scope, scope.workspace, explore_document(scope, ["write-a-brief"]),
        trial: true
      )

    work_item = work_item_fixture(scope)
    {:ok, _assigned} = Processes.assign(scope, work_item, trial)
    override!(scope, provider, "write-a-brief")
    assert "write-a-brief" in Processes.kept_workflows(scope.workspace)

    {:ok, _dropped} = Processes.drop_trial(scope, trial)
    assert choice(scope, "write-a-brief") == nil
    assert time_limit(scope, "write-a-brief") == nil
  end

  test "a save from the harness deletes what no version keeps", %{
    scope: scope,
    provider: provider
  } do
    override!(scope, provider)
    current = Processes.current(scope.workspace)

    {:ok, _version} =
      Processes.save_harness(
        scope,
        scope.workspace,
        explore_document(scope, ["shape-a-ticket"]),
        %{"commit" => String.duplicate("a", 40)},
        based_on: current
      )

    assert choice(scope) == nil
    assert time_limit(scope) == nil
  end

  test "a provider that only a leftover has as a fallback can be deleted, and the leftover goes",
       %{scope: scope, provider: provider} do
    {:ok, fallback} =
      Connections.create_provider(scope, %{
        provider: "deepseek",
        keys: [%{value_id: "main", value: "sk-leftovers-fallback-0123456789"}]
      })

    # A workflow's choice takes no fallbacks of its own today; a row with one stands for a
    # leftover kept from before that rule.
    %ModelChoice{id: id} = on!(scope, provider, "gone-workflow")

    Repo.insert!(%Fallback{
      organisation_id: scope.organisation.id,
      model_choice_id: id,
      connection_id: fallback.id,
      position: 0,
      runtime: ModelChoices.default_runtime().name,
      tiers: @tiers
    })

    %{id: choice_id} = choice(scope, "gone-workflow")

    assert ModelChoices.places_using(fallback) == []
    assert {:ok, _deleted} = Connections.delete_provider(scope, fallback)

    assert choice(scope, "gone-workflow") == nil
    assert [%Entry{}] = removals(choice_id)
    assert Repo.get(Apiary.Connections.Connection, provider.id)
  end

  test "a job whose workspace is gone completes, and one whose workspace is marked is cancelled",
       %{scope: scope, provider: provider} do
    {:ok, _job} =
      Oban.insert(LeftoversJob.for_workspace(scope.organisation.id, Ecto.UUID.generate()))

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)

    override!(scope, provider, "gone-workflow")

    {1, _rows} =
      Repo.update_all(
        from(w in Apiary.Organisations.Workspace, where: w.id == ^scope.workspace.id),
        set: [
          deletion_marked_at: DateTime.utc_now(),
          purge_after: DateTime.add(DateTime.utc_now(), 30, :day),
          purge_trigger: "grace_period"
        ]
      )

    {:ok, _job} =
      Oban.insert(LeftoversJob.for_workspace(scope.organisation.id, scope.workspace.id))

    assert %{cancelled: 1, failure: 0} = Oban.drain_queue(queue: :default)
    assert %ModelChoice{} = choice(scope, "gone-workflow")
  end
end
