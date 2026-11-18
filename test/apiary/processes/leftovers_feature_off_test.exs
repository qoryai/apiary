defmodule Apiary.Processes.LeftoversFeatureOffTest do
  # With the feature `workflow_model` off, a run reads the workflow the Harness page saved,
  # whatever the process has, so no workflow's override in a workspace is a leftover:
  # a close and the job delete none, and a provider or a key that such an override uses
  # is still in use. A save of the process is refused with the feature off.
  #
  # Not async: the module switches the instance's features, which are the whole node's.
  use Apiary.DataCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures, only: [work_item_fixture: 1]

  alias Apiary.{Connections, Dispatches, ModelChoices, Processes, Stages, TimeLimits, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.ModelChoices.ModelChoice
  alias Apiary.Processes.LeftoversJob
  alias Apiary.TimeLimits.TimeLimit

  @moduletag with_features: Apiary.Features.all() -- [:workflow_model]

  @workflow "gone-workflow"

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
        keys: [
          %{value_id: "main", value: "sk-leftovers-off-0123456789"},
          %{value_id: "spare", value: "sk-leftovers-off-spare-0123456789"}
        ]
      })

    # An override of a workflow that no version has.
    {:ok, _choice} =
      ModelChoices.put_choice(scope, {:workspace, @workflow}, %{
        provider: provider.public_id,
        key: "spare",
        tiers: @tiers
      })

    {:ok, _limit} = TimeLimits.put_limit(scope, :workspace, @workflow, 45)

    %{scope: scope, provider: provider}
  end

  defp choice(scope),
    do:
      Repo.one(
        from c in ModelChoice,
          where:
            c.workspace_id == ^scope.workspace.id and is_nil(c.target_id) and
              c.workflow == @workflow
      )

  defp time_limit(scope),
    do:
      Repo.one(
        from l in TimeLimit,
          where:
            l.workspace_id == ^scope.workspace.id and is_nil(l.target_id) and
              l.workflow == @workflow
      )

  test "a close, a run's end and the job delete nothing", %{scope: scope} do
    refute Stages.on?()
    refute @workflow in Processes.kept_workflows(scope.workspace)

    # A run of the workflow that ended, as a stage's run would have it.
    work_item = work_item_fixture(scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    {:ok, :ok} =
      Repo.transact(fn ->
        {1, _rows} =
          Repo.update_all(from(r in DispatchRun, where: r.id == ^queued.id),
            set: [
              state: :ended,
              end_cause: :build_failed,
              result_outcome: :error,
              workflow: @workflow
            ]
          )

        {:ok, Processes.delete_leftovers_after_runs([queued.id])}
      end)

    {:ok, _closed} = WorkItems.close(scope, Repo.reload!(work_item))
    refute_enqueued(worker: LeftoversJob)

    {:ok, _job} =
      Oban.insert(LeftoversJob.for_workspace(scope.organisation.id, scope.workspace.id))

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
    assert %ModelChoice{} = choice(scope)
    assert %TimeLimit{minutes: 45} = time_limit(scope)
  end

  test "its provider and its key are still in use", %{scope: scope, provider: provider} do
    assert [%{level: 4, workflow: @workflow}] = ModelChoices.places_using(provider)
    assert {:error, {:model_in_use, [_place]}} = Connections.delete_provider(scope, provider)

    assert [%{level: 4, workflow: @workflow}] = ModelChoices.key_places(provider.secret_id)
    assert {:error, %Ecto.Changeset{}} = Connections.delete_provider_key(scope, provider, "spare")

    assert {:error, %Ecto.Changeset{}} =
             Connections.rename_provider_key(scope, provider, "spare", "other")

    assert %ModelChoice{value_id: "spare"} = choice(scope)
  end
end
