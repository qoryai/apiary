defmodule ApiaryWeb.WorkflowFake do
  @moduledoc """
  A test-only stand-in for piece A on the work item page, until it lands on `next`:
  `Apiary.Artifacts.list/1` is the stage runner's stand-in, `Apiary.StagesArtifactsStub`,
  so the page and `Apiary.Stages` read the same artifacts; and
  `ApiaryWeb.ArtifactComponents.list/1` is `Components.list/1`, each artifact's type and
  newest version, and `Apiary.Artifacts.topic/1` is `ArtifactTopic.topic/1`. The read of
  the harness that `Apiary.Stages.check_workflows/2` calls is `read/2`, which gives what
  `check_result/2` put for the workspace. `ApiaryWeb.WorkItemLive.Workflow` calls whatever
  `install/0` puts in the application's environment.

  `install/0` changes the whole node, so a test module that calls it is not async, and
  puts the environment back with `uninstall/1` when it ends. When `Apiary.Artifacts` and
  `ApiaryWeb.ArtifactComponents` land, the tests use them and this module goes.
  """

  @key ApiaryWeb.WorkItemLive.Workflow

  @doc "Puts the fake in the application's environment: what was there before."
  def install do
    case Agent.start(fn -> %{} end, name: __MODULE__.Reads) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    previous = Application.get_env(:apiary, @key)

    Application.put_env(:apiary, @key,
      artifacts: Apiary.StagesArtifactsStub,
      artifact_components: __MODULE__.Components,
      artifact_topic: __MODULE__.ArtifactTopic,
      harness_read: &__MODULE__.read/2
    )

    previous
  end

  @doc "Puts back what `install/0` found."
  def uninstall(nil), do: Application.delete_env(:apiary, @key)
  def uninstall(previous), do: Application.put_env(:apiary, @key, previous)

  @doc """
  What the read of the harness gives for `workspace`: `{:ok, names}`, the workflow names
  the harness lists, or `{:error, reason}` as `Apiary.Stacks.Sources.read/2` gives it.
  """
  def check_result(workspace, result),
    do: Agent.update(__MODULE__.Reads, &Map.put(&1, workspace.id, result))

  @doc "The read of the harness: what `check_result/2` put, else `{:ok, []}`."
  def read(_scope, workspace),
    do: Agent.get(__MODULE__.Reads, &Map.get(&1, workspace.id, {:ok, []}))

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
