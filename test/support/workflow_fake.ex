defmodule ApiaryWeb.WorkflowFake do
  @moduledoc """
  A test-only stand-in for the stage runner and the artifacts, until they land on
  `next`: `Apiary.Stages` (status/1, inputs/1, artifact_index/1, approve/3,
  request_changes/4, resolve_escalation/4, move/4), `Apiary.Artifacts.list/1` and
  `ApiaryWeb.ArtifactComponents.list/1`, with the names and return shapes of the shared
  contract. `ApiaryWeb.WorkItemLive.Workflow` calls whatever `install/0` puts in the
  application's environment.

  `install/0` changes the whole node, so a test module that calls it is not async, and
  puts the environment back with `uninstall/1` when it ends. A work item reads what
  `put_work_item/2` gave it. The actions record their calls (`calls/1`) and change
  nothing.

  When `Apiary.Stages` and `Apiary.Artifacts` land, the tests use them and this module
  goes.
  """

  @key ApiaryWeb.WorkItemLive.Workflow

  @doc "Puts the fake in the application's environment: what was there before."
  def install do
    case Agent.start(fn -> %{} end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    previous = Application.get_env(:apiary, @key)

    Application.put_env(:apiary, @key,
      stages: __MODULE__,
      artifacts: __MODULE__.Artifacts,
      artifact_components: __MODULE__.Components
    )

    previous
  end

  @doc "Puts back what `install/0` found."
  def uninstall(nil), do: Application.delete_env(:apiary, @key)
  def uninstall(previous), do: Application.put_env(:apiary, @key, previous)

  @doc """
  What `work_item` reads: `status` (`Apiary.Stages.status/1`), `inputs`, `index`
  (`artifact_index/1`) and `artifacts` (`Apiary.Artifacts.list/1`).
  """
  def put_work_item(work_item, attrs),
    do: Agent.update(__MODULE__, &Map.put(&1, {:work_item, work_item.id}, Map.new(attrs)))

  @doc "The actions done on `work_item`, oldest first."
  def calls(work_item),
    do: Agent.get(__MODULE__, &Enum.reverse(Map.get(&1, {:calls, work_item.id}, [])))

  @doc false
  def work_item(id), do: Agent.get(__MODULE__, &Map.get(&1, {:work_item, id}, %{}))

  defp record(work_item, call) do
    Agent.update(
      __MODULE__,
      &Map.update(&1, {:calls, work_item.id}, [call], fn calls -> [call | calls] end)
    )

    {:ok, work_item}
  end

  ## Apiary.Stages

  def status(work_item), do: work_item(work_item.id)[:status]
  def inputs(work_item), do: work_item(work_item.id)[:inputs] || []
  def artifact_index(work_item), do: work_item(work_item.id)[:index] || []
  def approve(_scope, work_item, note), do: record(work_item, {:approve, note})

  def request_changes(_scope, work_item, note, version),
    do: record(work_item, {:request_changes, note, version})

  def resolve_escalation(_scope, work_item, how, note),
    do: record(work_item, {:resolve_escalation, how, note})

  def move(_scope, work_item, stage_id, note), do: record(work_item, {:move, stage_id, note})

  defmodule Artifacts do
    @moduledoc "`Apiary.Artifacts.list/1`, as `ApiaryWeb.WorkflowFake` registered it."
    def list(work_item), do: ApiaryWeb.WorkflowFake.work_item(work_item.id)[:artifacts] || []
  end

  defmodule Components do
    @moduledoc "`ApiaryWeb.ArtifactComponents.list/1`: each artifact's type and version."
    use Phoenix.Component

    attr :id, :string, required: true
    attr :artifacts, :list, required: true

    def list(assigns) do
      ~H"""
      <ul id={@id}>
        <li :for={artifact <- @artifacts}>{artifact.type} v{artifact.number}</li>
      </ul>
      """
    end
  end
end
