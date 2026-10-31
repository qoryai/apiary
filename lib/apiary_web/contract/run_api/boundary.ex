defmodule ApiaryWeb.Contract.RunApi.Boundary do
  @moduledoc false

  # The one place the run API calls the workflow model's modules: `Apiary.Artifacts`,
  # `Apiary.Processes`, `Apiary.Stages` and the feature `workflow_model` of
  # `Apiary.Features`. Each module is read from the application's configuration at the
  # call, so the run API compiles before those modules exist, and a test sets stubs:
  #
  #     config :apiary, ApiaryWeb.Contract.RunApi.Boundary,
  #       artifacts: Apiary.Artifacts,
  #       processes: Apiary.Processes,
  #       stages: Apiary.Stages,
  #       features: Apiary.Features
  #
  # The names and the return shapes are those of the workflow model's shared API. The
  # columns `workflow`, `stage_id` and `round` of `dispatch_runs` are read with
  # `Map.get/2`, nil while a run of the queue has none of them.

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
  defp stages, do: module(:stages, Apiary.Stages)
  defp features, do: module(:features, Apiary.Features)

  ## The feature

  # on?/0 is whether the instance has the feature `workflow_model`. False where the
  # features module does not list it yet.
  @spec on?() :: boolean
  def on? do
    features = features()
    @feature in features.all() and features.on?(@feature)
  end

  # route_feature/0 is the feature the run API's routes belong to, as
  # `ApiaryWeb.Features.Routes` reads it: `workflow_model` where `Apiary.Features` lists
  # it, else `factory`, whose work items the run API serves. Read from `Apiary.Features`
  # itself, never from the configured module: the gate in the endpoint reads that one.
  @spec route_feature() :: atom
  def route_feature,
    do: if(@feature in Apiary.Features.all(), do: @feature, else: :factory)

  ## The run's columns of the workflow model

  @spec workflow(struct) :: String.t() | nil
  def workflow(dispatch_run), do: Map.get(dispatch_run, :workflow)

  @spec stage_id(struct) :: String.t() | nil
  def stage_id(dispatch_run), do: Map.get(dispatch_run, :stage_id)

  @spec round(struct) :: pos_integer | nil
  def round(dispatch_run), do: Map.get(dispatch_run, :round)

  ## Processes

  # writable?/3 is whether a run of `workflow` in `workspace` may write the artifact type
  # `type`: verdict and questions always; any type when the workflow has no name, when the
  # harness does not declare it, or when its declaration has no `writes` list; else a
  # type of that list.
  @spec writable?(struct, String.t() | nil, String.t()) :: boolean
  def writable?(_workspace, _workflow, type) when type in @always_writable, do: true
  def writable?(_workspace, nil, _type), do: true

  def writable?(workspace, workflow, type) do
    case processes().workflow_declaration(workspace, workflow) do
      %{writes: writes} when is_list(writes) -> type in writes
      _any_type -> true
    end
  end

  ## Artifacts

  @spec type(struct, String.t()) :: map | nil
  def type(workspace, name), do: artifacts().type(workspace, name)

  @spec push(term, struct, String.t(), [map], keyword) :: {:ok, map} | {:error, term}
  def push(actor, work_item, type, files, opts),
    do: artifacts().push(actor, work_item, type, files, opts)

  @spec list(struct) :: [map]
  def list(work_item), do: artifacts().list(work_item)

  @spec versions(map) :: [map]
  def versions(artifact), do: artifacts().versions(artifact)

  @spec get_version!(String.t()) :: map
  def get_version!(id), do: artifacts().get_version!(id)

  @spec newest(struct, String.t()) :: map | nil
  def newest(work_item, type), do: artifacts().newest(work_item, type)

  @spec open_file(map) :: {:ok, Path.t() | Enumerable.t()} | {:error, term}
  def open_file(file), do: artifacts().open_file(file)

  ## Stages

  @spec status(struct) :: map
  def status(work_item), do: stages().status(work_item)

  @spec inputs(struct) :: [map]
  def inputs(work_item), do: stages().inputs(work_item)

  @spec artifact_index(struct) :: [map]
  def artifact_index(work_item), do: stages().artifact_index(work_item)

  # notes/1 is the notes people left for the run's work item. The workflow model's shared
  # API has no source for them yet, so the list is empty.
  @spec notes(struct) :: [map]
  def notes(_work_item), do: []
end
