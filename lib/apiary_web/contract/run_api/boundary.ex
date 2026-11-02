defmodule ApiaryWeb.Contract.RunApi.Boundary do
  @moduledoc false

  # The one place the run API calls the workflow model's modules: `Apiary.Artifacts`,
  # `Apiary.Processes`, `Apiary.Stages` and the feature `workflow_model` of
  # `Apiary.Features`. `Apiary.Artifacts`, `Apiary.Processes` and `Apiary.Features` are
  # read from the application's configuration at the call, so a test sets stubs:
  #
  #     config :apiary, ApiaryWeb.Contract.RunApi.Boundary,
  #       artifacts: Apiary.Artifacts,
  #       processes: Apiary.Processes,
  #       features: Apiary.Features
  #
  # `Apiary.Stages` is called directly, and it calls `Apiary.Artifacts` with no stub.
  #
  # The names and the return shapes are those of the workflow model's shared API. The
  # columns `workflow`, `stage_id` and `round` of `dispatch_runs` are nil for a run of the
  # queue outside the workflow model.

  alias Apiary.Artifacts.{Filename, Type}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.WorkItems.WorkItem

  @feature :workflow_model

  # The types every workflow may write, whatever its `writes` list.
  @always_writable ["verdict", "questions"]

  defp module(name, default) do
    :apiary
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(name, default)
  end

  defp artifacts, do: module(:artifacts, Apiary.Artifacts)
  defp processes, do: module(:processes, Apiary.Processes)
  defp features, do: module(:features, Apiary.Features)

  ## The feature

  # on?/0 is whether the instance has the feature `workflow_model`. False where the
  # features module does not list it.
  @spec on?() :: boolean
  def on? do
    features = features()
    @feature in features.all() and features.on?(@feature)
  end

  # route_feature/0 is the feature the run API's routes belong to, as
  # `ApiaryWeb.Features.Routes` reads it: `workflow_model`.
  @spec route_feature() :: atom
  def route_feature, do: @feature

  ## The run's columns of the workflow model

  @spec workflow(DispatchRun.t()) :: String.t() | nil
  def workflow(%DispatchRun{workflow: workflow}), do: workflow

  @spec stage_id(DispatchRun.t()) :: String.t() | nil
  def stage_id(%DispatchRun{stage_id: stage_id}), do: stage_id

  @spec round(DispatchRun.t()) :: pos_integer | nil
  def round(%DispatchRun{round: round}), do: round

  ## Processes

  # writable?/3 is whether a run of `workflow` in `workspace` may write the artifact type
  # `type`: verdict and questions always; any type when the workflow has no name, when the
  # harness does not declare it, or when its declaration has no `writes` list; else a
  # type of that list.
  @spec writable?(struct, String.t() | nil, String.t()) :: boolean
  def writable?(_workspace, _workflow, type) when type in @always_writable, do: true
  def writable?(_workspace, nil, _type), do: true

  def writable?(workspace, workflow, type) do
    case writes(workspace, workflow) do
      :any -> true
      writes -> type in writes
    end
  end

  # writes/2 is the `writes` option of `Apiary.Artifacts.push/5` for a run of `workflow`:
  # the declaration's list, or `:any` for a workflow with no name, one the harness does
  # not declare, or a declaration whose list is nil.
  @spec writes(struct, String.t() | nil) :: [String.t()] | :any
  def writes(_workspace, nil), do: :any

  def writes(workspace, workflow) do
    case processes().workflow_declaration(workspace, workflow) do
      %{writes: writes} when is_list(writes) -> writes
      _any_type -> :any
    end
  end

  ## Artifacts

  # name?/1 is whether `name` follows the rule of an artifact's type and name
  # (`Apiary.Artifacts.Type.name?/1`).
  @spec name?(term) :: boolean
  def name?(name), do: Type.name?(name)

  # standard?/1 is whether `name` is the name of a standard artifact type
  # (`Apiary.Artifacts.Type.standard_names/0`).
  @spec standard?(term) :: boolean
  def standard?(name), do: name in Type.standard_names()

  # filename?/1 is whether `name` is a filename an artifact's file may have
  # (`Apiary.Artifacts.Filename.valid?/1`).
  @spec filename?(term) :: boolean
  def filename?(name), do: Filename.valid?(name)

  @spec type(struct, String.t()) :: map | nil
  def type(workspace, name), do: artifacts().type(workspace, name)

  @spec push(term, struct, String.t(), [map], keyword) :: {:ok, map} | {:error, term}
  def push(actor, work_item, type, files, opts),
    do: artifacts().push(actor, work_item, type, files, opts)

  @spec get_version!(String.t()) :: map
  def get_version!(id), do: artifacts().get_version!(id)

  @spec newest(struct, String.t()) :: map | nil
  def newest(work_item, type), do: artifacts().newest(work_item, type, "main")

  @spec open_file(map) :: {:ok, Path.t() | Enumerable.t()} | {:error, term}
  def open_file(file), do: artifacts().open_file(file)

  ## Stages

  @spec status(WorkItem.t()) :: map | nil
  def status(work_item), do: Apiary.Stages.status(work_item)

  @spec inputs(WorkItem.t()) :: [map]
  def inputs(work_item), do: Apiary.Stages.inputs(work_item)

  @spec artifact_index(WorkItem.t()) :: [map]
  def artifact_index(work_item), do: Apiary.Stages.artifact_index(work_item)

  @spec notes(WorkItem.t()) :: [map]
  def notes(work_item), do: Apiary.Stages.notes(work_item)
end
