defmodule Apiary.Processes.LeftoversFeatureOffTest do
  # With the feature `workflow_model` off, a run reads the workflow the Harness page saved,
  # whatever the process has, so no workflow's override in a workspace is a leftover:
  # a close and the job delete none, and a provider that such an override uses is still
  # in use. A save of the process is refused with the feature off.
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

    # The checks read this workspace's jobs alone: a test that races changes outside the
    # sandbox commits the jobs of its closes, which every test then sees (`Apiary.Races`).
    args = %{"organisation_id" => scope.organisation.id, "workspace_id" => scope.workspace.id}
    refute_enqueued(worker: LeftoversJob, args: args)

    assert :ok = perform_job(LeftoversJob, args)
    assert %ModelChoice{} = choice(scope)
    assert %TimeLimit{minutes: 45} = time_limit(scope)
  end

  test "its provider is still in use; a key of the provider is renamed and deleted",
       %{scope: scope, provider: provider} do
    assert [%{level: 4, workflow: @workflow}] = ModelChoices.places_using(provider)
    assert {:error, {:model_in_use, [_place]}} = Connections.delete_provider(scope, provider)

    assert {:ok, _provider} = Connections.rename_provider_key(scope, provider, "spare", "other")
    provider = Repo.reload!(provider)
    assert {:ok, _provider} = Connections.delete_provider_key(scope, provider, "other")

    assert %ModelChoice{connection_id: provider_id} = choice(scope)
    assert provider_id == provider.id
  end
end
