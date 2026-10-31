defmodule ApiaryWeb.WorkflowFake do
  @moduledoc """
  A test-only stand-in for piece A on the work item page, until it lands on `next`:
  `Apiary.Artifacts.list/1` is the stage runner's stand-in, `Apiary.StagesArtifactsStub`,
  so the page and `Apiary.Stages` read the same artifacts; and
  `ApiaryWeb.ArtifactComponents.list/1` is `Components.list/1`, each artifact's type and
  newest version. It also stands in for `Apiary.Stages.check_workflows/2` until the
  stage runner's next round brings it (`Checks`), and for the work item's topics,
  `Apiary.Stages.topic/1` (`StageTopic`) and `Apiary.Artifacts.topic/1` (`ArtifactTopic`). `ApiaryWeb.WorkItemLive.Workflow`
  calls whatever `install/0` puts in the application's environment.

  `install/0` changes the whole node, so a test module that calls it is not async, and
  puts the environment back with `uninstall/1` when it ends. When `Apiary.Artifacts` and
  `ApiaryWeb.ArtifactComponents` land, the tests use them and this module goes.
  """

  @key ApiaryWeb.WorkItemLive.Workflow

  @doc "Puts the fake in the application's environment: what was there before."
  def install do
    case Agent.start(fn -> %{} end, name: __MODULE__.Checks) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    previous = Application.get_env(:apiary, @key)

    Application.put_env(:apiary, @key,
      artifacts: Apiary.StagesArtifactsStub,
      artifact_components: __MODULE__.Components,
      workflow_checks: __MODULE__.Checks,
      stage_topic: __MODULE__.StageTopic,
      artifact_topic: __MODULE__.ArtifactTopic
    )

    previous
  end

  @doc "Puts back what `install/0` found."
  def uninstall(nil), do: Application.delete_env(:apiary, @key)
  def uninstall(previous), do: Application.put_env(:apiary, @key, previous)

  @doc """
  What Check again gives for `work_item`: `:ok` (the stage starts: its state is
  `running`), `:still_missing`, or another reason, returned as `{:error, reason}`.
  """
  def check_result(work_item, result),
    do: Agent.update(__MODULE__.Checks, &Map.put(&1, work_item.id, result))

  defmodule Checks do
    @moduledoc "`Apiary.Stages.check_workflows/2`, with the shapes the stage runner gives."
    import Ecto.Query, only: [from: 2]

    def check_workflows(_scope, work_item) do
      case Agent.get(__MODULE__, &Map.get(&1, work_item.id, :still_missing)) do
        :ok ->
          query = from w in Apiary.WorkItems.WorkItem, where: w.id == ^work_item.id
          Apiary.Repo.update_all(query, set: [stage_state: :running])
          {:ok, Apiary.Repo.get!(Apiary.WorkItems.WorkItem, work_item.id)}

        reason ->
          {:error, reason}
      end
    end
  end

  defmodule StageTopic do
    @moduledoc "`Apiary.Stages.topic/1`, until the stage runner has it."
    def topic(work_item), do: "test_stages:" <> work_item.public_id
  end

  defmodule ArtifactTopic do
    @moduledoc "`Apiary.Artifacts.topic/1`, until piece A has it."
    def topic(work_item), do: "test_artifacts:" <> work_item.public_id
  end

  defmodule Components do
    @moduledoc "`ApiaryWeb.ArtifactComponents.list/1`: each artifact's type and newest version."
    use Phoenix.Component

    attr :id, :string, required: true
    attr :artifacts, :list, required: true

    def list(assigns) do
      ~H"""
      <ul id={@id}>
        <li :for={artifact <- @artifacts}>{artifact.type} v{hd(artifact.versions).number}</li>
      </ul>
      """
    end
  end
end
