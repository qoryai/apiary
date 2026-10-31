defmodule ApiaryWeb.StagesLive.Calls do
  # Temporary until Apiary.Processes lands (piece F) and Apiary.Artifacts.types/1 lands
  # (piece A): the Stages page calls F and A through this module alone, with the names and
  # the arguments of the shared contract (the workflow model's spec, § Shared API). When
  # F and A land, each function here becomes a call of theirs, and this module goes.
  #
  # Until then:
  # - the feature `workflow_model` is not in `Apiary.Features` yet, so `workflow_model?/0`
  #   reads the application environment `:stages_stub_flag` (false unless a test sets it)
  #   while the feature is unknown;
  # - versions live in the process dictionary of the page's process: they last as long
  #   as the page, and a reload starts again from version 1, the software type's default;
  # - a work item's stage is `st_explore`, as F's migration gives every open work item;
  # - `process.edit` is checked as `harness.save` (owners and admins), and reading as
  #   `work_item.read` (members), the actions `Apiary.Access` has today.
  @moduledoc false

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Workspace

  @store :stages_stub_versions
  @assigned :stages_stub_assigned
  @explore "st_explore"
  @standard_types [
    {"acceptance-criteria", :document},
    {"explainer", :document},
    {"decision-record", :document},
    {"mockup", :image},
    {"screenshot", :image},
    {"demo-video", :video},
    {"change", :structured},
    {"proposal", :structured},
    {"questions", :structured},
    {"verdict", :structured}
  ]

  ## The feature and access

  @doc false
  def workflow_model? do
    if :workflow_model in Apiary.Features.all(),
      do: Apiary.Features.on?(:workflow_model),
      else: Application.get_env(:apiary, :stages_stub_flag, false) == true
  end

  # `process.edit`: owners and admins.
  @doc false
  def may_edit?(%Scope{workspace: %Workspace{} = workspace} = scope),
    do: Apiary.Access.can?(scope, :"harness.save", workspace)

  @doc false
  def may_read?(%Scope{workspace: %Workspace{} = workspace} = scope),
    do: Apiary.Access.can?(scope, :"work_item.read", workspace)

  ## Apiary.Processes

  @doc false
  def default_document(_domain) do
    %{
      "schema" => "qory.process/v1",
      "machine" => "default",
      "stages" => [
        %{
          "id" => @explore,
          "name" => "Explore",
          "inputs" => [],
          "sequence" => [
            %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "explore-a-ticket"}]}}
          ],
          "outputs" => [%{"type" => "proposal", "required" => true}],
          "gate" => %{"kind" => "person", "approvers" => "members"}
        }
        | for {id, name} <- [
                {"st_shape", "Shape"},
                {"st_build", "Build"},
                {"st_verify", "Verify"},
                {"st_release", "Release"}
              ] do
            %{
              "id" => id,
              "name" => name,
              "inputs" => [],
              "sequence" => [],
              "outputs" => [],
              "gate" => %{"kind" => "person", "approvers" => "members"}
            }
          end
      ]
    }
  end

  @doc false
  def current(%Workspace{} = workspace),
    do: Enum.find(list_versions(workspace), &(&1.status == :current))

  @doc false
  def get_version!(id), do: Enum.find(all_versions(), &(&1.id == id)) || raise("no version")

  # Newest first.
  @doc false
  def list_versions(%Workspace{} = workspace) do
    case Process.get({@store, workspace.id}) do
      nil ->
        first = %{
          id: Apiary.PublicId.generate("pv"),
          workspace_id: workspace.id,
          number: 1,
          status: :current,
          document: default_document(workspace.domain),
          author_id: nil,
          based_on_id: nil,
          inserted_at: DateTime.utc_now()
        }

        Process.put({@store, workspace.id}, [first])
        [first]

      versions ->
        versions
    end
  end

  defp all_versions do
    for {{@store, _id}, versions} <- Process.get(), version <- versions, do: version
  end

  defp put_versions(workspace_id, versions), do: Process.put({@store, workspace_id}, versions)

  @doc false
  def save(%Scope{} = scope, %Workspace{} = workspace, document, opts) do
    trial? = Keyword.get(opts, :trial, false)

    with :ok <- authorize(scope),
         [] <- validate(document) do
      versions = list_versions(workspace)
      based_on = Enum.find(versions, &(&1.status == :current))

      version = %{
        id: Apiary.PublicId.generate("pv"),
        workspace_id: workspace.id,
        number: length(versions) + 1,
        status: if(trial?, do: :trial, else: :current),
        document: document,
        author_id: scope.user.id,
        based_on_id: based_on && based_on.id,
        inserted_at: DateTime.utc_now()
      }

      versions =
        Enum.map(versions, fn
          %{status: :current} = v when not trial? -> %{v | status: :past}
          %{status: :trial} = v when trial? -> drop(workspace, v)
          v -> v
        end)

      put_versions(workspace.id, [version | versions])
      {:ok, version}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      errors when is_list(errors) -> {:error, errors}
    end
  end

  @doc false
  def make_current(%Scope{} = scope, %{status: :trial, workspace_id: id} = trial) do
    with :ok <- authorize(scope) do
      versions =
        for v <- Process.get({@store, id}, []) do
          cond do
            v.id == trial.id -> %{v | status: :current}
            v.status == :current -> %{v | status: :past}
            true -> v
          end
        end

      put_versions(id, versions)
      {:ok, Enum.find(versions, &(&1.id == trial.id))}
    end
  end

  # Moves the trial's work items back to the current version.
  @doc false
  def drop_trial(%Scope{} = scope, %{status: :trial, workspace_id: id} = trial) do
    with :ok <- authorize(scope) do
      versions =
        for v <- Process.get({@store, id}, []),
            do: if(v.id == trial.id, do: drop(%{id: id}, v), else: v)

      put_versions(id, versions)
      {:ok, Enum.find(versions, &(&1.id == trial.id))}
    end
  end

  defp drop(%{id: workspace_id}, version) do
    assigned = Process.get({@assigned, workspace_id}, %{})

    Process.put(
      {@assigned, workspace_id},
      Map.reject(assigned, fn {_item, version_id} -> version_id == version.id end)
    )

    %{version | status: :dropped}
  end

  @doc false
  def assign(%Scope{} = scope, work_item, %{workspace_id: workspace_id} = version) do
    stage_id = @explore

    with :ok <- authorize(scope) do
      if stage(version.document, stage_id) do
        assigned = Process.get({@assigned, workspace_id}, %{})
        Process.put({@assigned, workspace_id}, Map.put(assigned, work_item.id, version.id))
        {:ok, work_item}
      else
        {:error, {:missing_stage, stage_id}}
      end
    end
  end

  # The version id a work item is on: its trial's, else the current version's.
  @doc false
  def version_for(%{id: id, workspace: %Workspace{} = workspace}) do
    Map.get(Process.get({@assigned, workspace.id}, %{}), id) || current(workspace).id
  end

  @doc false
  def stage(%{"stages" => stages}, stage_id), do: Enum.find(stages, &(&1["id"] == stage_id))

  @doc false
  def diff(older, newer) do
    old = Map.new(Enum.with_index(older["stages"]), fn {s, i} -> {s["id"], {s, i}} end)
    new = Map.new(Enum.with_index(newer["stages"]), fn {s, i} -> {s["id"], {s, i}} end)
    kept_old = for s <- older["stages"], Map.has_key?(new, s["id"]), do: s["id"]
    kept_new = for s <- newer["stages"], Map.has_key?(old, s["id"]), do: s["id"]

    machine =
      if older["machine"] != newer["machine"],
        do: [{:machine_changed, nil, %{from: older["machine"], to: newer["machine"]}}],
        else: []

    removed =
      for s <- older["stages"],
          not Map.has_key?(new, s["id"]),
          do: {:stage_removed, s["id"], %{name: s["name"]}}

    changes =
      for s <- newer["stages"], reduce: [] do
        acc ->
          case Map.get(old, s["id"]) do
            nil ->
              [{:stage_added, s["id"], %{name: s["name"]}} | acc]

            {before, _index} ->
              acc
              |> changed(:stage_renamed, before, s, "name")
              |> moved(kept_old, kept_new, s)
              |> changed(:sequence_changed, before, s, "sequence")
              |> changed(:inputs_changed, before, s, "inputs")
              |> changed(:outputs_changed, before, s, "outputs")
              |> changed(:gate_changed, before, s, "gate")
          end
      end

    machine ++ removed ++ Enum.reverse(changes)
  end

  defp changed(acc, kind, before, now, key) do
    if before[key] == now[key],
      do: acc,
      else: [{kind, now["id"], %{name: now["name"], from: before["name"]}} | acc]
  end

  defp moved(acc, kept_old, kept_new, s) do
    from = Enum.find_index(kept_old, &(&1 == s["id"]))
    to = Enum.find_index(kept_new, &(&1 == s["id"]))

    if from == to,
      do: acc,
      else: [{:stage_moved, s["id"], %{name: s["name"], from: from + 1, to: to + 1}} | acc]
  end

  # The placement check, as spec addition 9 has it: a missing workflow, a missing type, and
  # an input that no earlier stage lists as an output.
  @doc false
  def placement_check(%{"stages" => stages}, declared_workflows, artifact_types) do
    type_names = MapSet.new(artifact_types, & &1.name)

    {problems, _outputs} =
      Enum.reduce(stages, {[], MapSet.new()}, fn stage, {acc, earlier} ->
        id = stage["id"]

        workflows =
          for name <- workflow_names(stage),
              name not in declared_workflows,
              uniq: true,
              do: {:missing_workflow, id, name}

        types =
          for %{"type" => type} <- stage["inputs"] ++ stage["outputs"],
              not MapSet.member?(type_names, type),
              uniq: true,
              do: {:missing_type, id, type}

        inputs =
          for %{"type" => type} <- stage["inputs"],
              not MapSet.member?(earlier, type),
              do: {:input_not_output, id, type}

        outputs = MapSet.union(earlier, MapSet.new(stage["outputs"], & &1["type"]))
        {acc ++ workflows ++ types ++ inputs, outputs}
      end)

    problems
  end

  @doc false
  def workflow_names(stage) do
    Enum.flat_map(stage["sequence"], fn
      %{"loop" => %{"body" => body}} -> Enum.map(body, & &1["workflow"])
      %{"workflow" => name} -> [name]
    end)
  end

  # The workflows the workspace's harness declares: explore-a-ticket by hand (spec
  # addition 16, a transition), and the workflow the Workflow page saved, where there is one.
  @doc false
  def declared_workflows(%Workspace{} = workspace) do
    case Apiary.Stacks.Sources.current(workspace) do
      %{workflow: name} when name != "explore-a-ticket" -> ["explore-a-ticket", name]
      _none -> ["explore-a-ticket"]
    end
  end

  ## Apiary.Artifacts

  @doc false
  def types(%Workspace{}),
    do: for({name, view} <- @standard_types, do: %{name: name, base_view: view})

  # The Artifact types section of the workspace's settings (piece A, section
  # `artifact_types`). Not a verified route until piece A adds it.
  @doc false
  def artifact_types_path(%Scope{organisation: organisation, workspace: workspace}),
    do:
      "/" <>
        Phoenix.Param.to_param(organisation) <>
        "/" <> Phoenix.Param.to_param(workspace) <> "/settings/artifact-types"

  ## The checks a save makes, until the schema of piece F

  defp authorize(scope), do: if(may_edit?(scope), do: :ok, else: {:error, :forbidden})

  @doc false
  def validate(%{"stages" => stages}) do
    ids = Enum.map(stages, & &1["id"])

    duplicate =
      if length(Enum.uniq(ids)) == length(ids), do: [], else: [{nil, :duplicate_id}]

    duplicate ++ Enum.flat_map(stages, &validate_stage/1)
  end

  defp validate_stage(stage) do
    id = stage["id"]

    [
      String.trim(stage["name"] || "") == "" && {id, :blank_name},
      Enum.any?(stage["sequence"], &bad_entry?/1) && {id, :bad_sequence},
      match?(%{"kind" => "person", "approvers" => %{"members" => []}}, stage["gate"]) &&
        {id, :no_approvers}
    ]
    |> Enum.filter(& &1)
  end

  defp bad_entry?(%{"loop" => %{"rounds" => rounds, "body" => body}}),
    do:
      not (is_integer(rounds) and rounds in 1..10) or body == [] or
        Enum.any?(body, &(not match?(%{"workflow" => name} when name != "", &1)))

  defp bad_entry?(%{"workflow" => name}), do: not (is_binary(name) and name != "")
  defp bad_entry?(_entry), do: true
end
