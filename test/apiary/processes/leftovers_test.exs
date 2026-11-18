defmodule Apiary.Processes.LeftoversTest do
  # A workflow's overrides in a workspace, its model choice (level 4) and its time limit,
  # are kept while the current process version or an open work item's version has the
  # workflow, and deleted when neither has it any more: at a save, at an assign, and,
  # through `Apiary.Processes.LeftoversJob`, once a work item closes. A model provider
  # used only by such a leftover can be deleted.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures, only: [work_item_fixture: 1]

  alias Apiary.{Connections, Dispatches, ModelChoices, Processes, TimeLimits, WorkItems}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.RunSettings
  alias Apiary.ModelChoices.ModelChoice
  alias Apiary.Processes.LeftoversJob
  alias Apiary.TimeLimits.TimeLimit

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
        key: "main",
        tiers: @tiers
      })

    {:ok, _limit} = TimeLimits.put_limit(scope, :workspace, workflow, 45)
    :ok
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
        key: "main",
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
        key: "main",
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
end
