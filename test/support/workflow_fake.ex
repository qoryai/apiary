defmodule ApiaryWeb.WorkflowFake do
  @moduledoc """
  A test-only stand-in for the workflow model's modules, until they land on `next`:
  `Apiary.Features` and `Apiary.Access` for the feature `workflow_model` and its access
  actions, `Apiary.Stages`, `Apiary.Processes`, `Apiary.Artifacts`,
  `ApiaryWeb.ArtifactComponents` and the board's rows, with the names and return shapes
  of the shared contract. `ApiaryWeb.WorkItemLive.Workflow` calls whatever
  `install/0` puts in the application's environment.

  The fake answers only for what a test registered: the feature is on only for a
  workspace given to `put_workspace/2`, and a work item reads what `put_work_item/2` gave
  it. Everything else is the real module's answer, so tests that register nothing,
  async ones included, see the instance as it is. The actions record their calls
  (`calls/1`) and change nothing.

  When `Apiary.Stages`, `Apiary.Processes` and `Apiary.Artifacts` land, the tests put
  the real modules in its place and this module goes.
  """

  alias Apiary.Accounts.Scope

  @new_actions [:"gate.approve", :"artifact.write"]

  @doc "Puts the fake in the application's environment, once for the whole run."
  def install do
    case Agent.start(fn -> %{} end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Application.put_env(:apiary, ApiaryWeb.WorkItemLive.Workflow,
      features: __MODULE__,
      access: __MODULE__,
      stages: __MODULE__,
      processes: __MODULE__,
      artifacts: __MODULE__.Artifacts,
      artifact_components: __MODULE__.Components,
      board: __MODULE__
    )
  end

  @doc """
  Turns the feature on for `workspace`, with its process versions: `current` (a map
  with `id`, `number`, `status` and `document`), every version (`versions`), the
  harness's workflows (`declared`) and the board's rows (`rows`).
  """
  def put_workspace(workspace, attrs),
    do: Agent.update(__MODULE__, &Map.put(&1, {:workspace, workspace.id}, Map.new(attrs)))

  @doc """
  What `work_item` reads: `status` (`Apiary.Stages.status/1`), `inputs`, `index`
  (`artifact_index/1`), `version` (`Apiary.Processes.version_for/1`) and `artifacts`.
  """
  def put_work_item(work_item, attrs),
    do: Agent.update(__MODULE__, &Map.put(&1, {:work_item, work_item.id}, Map.new(attrs)))

  @doc "The actions done on `work_item`, oldest first."
  def calls(work_item),
    do: Agent.get(__MODULE__, &Enum.reverse(Map.get(&1, {:calls, work_item.id}, [])))

  defp workspace(id), do: Agent.get(__MODULE__, &Map.get(&1, {:workspace, id}))
  defp work_item(id), do: Agent.get(__MODULE__, &Map.get(&1, {:work_item, id}, %{}))

  defp record(work_item, call) do
    Agent.update(
      __MODULE__,
      &Map.update(&1, {:calls, work_item.id}, [call], fn c -> [call | c] end)
    )

    {:ok, work_item}
  end

  ## Apiary.Features

  def all, do: Apiary.Features.all() ++ [:workflow_model]

  def visible?(%Scope{workspace: %{id: id}}, :workflow_model), do: workspace(id) != nil
  def visible?(_scope, :workflow_model), do: false
  def visible?(scope, name), do: Apiary.Features.visible?(scope, name)

  ## Apiary.Access: the new actions take the roles of `work_item.confirm`, members.

  def can?(scope, action, subject) when action in @new_actions,
    do: Apiary.Access.can?(scope, :"work_item.confirm", subject)

  def can?(scope, action, subject), do: Apiary.Access.can?(scope, action, subject)

  def authorize(scope, action, subject) when action in @new_actions,
    do: Apiary.Access.authorize(scope, :"work_item.confirm", subject)

  def authorize(scope, action, subject), do: Apiary.Access.authorize(scope, action, subject)

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

  ## Apiary.Processes

  def version_for(work_item), do: work_item(work_item.id)[:version]
  def current(workspace), do: workspace(workspace.id)[:current]
  def list_versions(workspace), do: workspace(workspace.id)[:versions] || []
  def declared_workflows(workspace), do: workspace(workspace.id)[:declared] || []

  ## The board's rows

  def rows(%Scope{workspace: workspace}), do: workspace(workspace.id)[:rows] || []

  defmodule Artifacts do
    @moduledoc "`Apiary.Artifacts.list/1`, as `ApiaryWeb.WorkflowFake` registered it."
    def list(work_item) do
      Agent.get(
        ApiaryWeb.WorkflowFake,
        &(Map.get(&1, {:work_item, work_item.id}, %{})[:artifacts] || [])
      )
    end
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
