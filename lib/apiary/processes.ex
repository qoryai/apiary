defmodule Apiary.Processes do
  @moduledoc """
  A workspace's process: its stages in order, each with its inputs, its sequence of
  workflows, its outputs and its gate, as one document of
  `priv/schemas/process/v1.schema.json` (`validate/1`). Each save is a new version
  (`Apiary.Processes.Version`), numbered within the workspace.

  ## Versions

  A workspace is made with version 1, the process of the template it is made from, and
  `template` records where that came from, with the keys `source` (`qory` or
  `repository`), `git`, `commit`, `module`, `stack`, `type` and `version`. The Qory
  template's process is the newest version of the type's default process
  (`Apiary.Processes.TypeTemplates.newest/1`, `copy_qory_template/1`). A template of a
  harness source is copied as it was read (`copy_template/4`), and `version` is nil. In
  both, `type` is the template file's `type`, the same value as `workspaces.type`.

  A workspace made with no template gets a copy of that newest version with its `{type,
  number}` as its `template` (`copy_default/1`). One made another way, before the process
  was kept or by a test that inserts it, gets that copy the first time `current/1` reads it.

  A save (`save/4`) makes a new current version, and the version before it past; work
  items taken in after it run under it, and every other work item stays on its version
  (`version_for/1`). A save with `trial: true` makes a trial instead, and leaves the
  current version as it is: an owner or an admin assigns chosen work items to it
  (`assign/3`), then makes it current (`make_current/2`) or drops it
  (`drop_trial/2`), which moves its work items back to the current version. A work item
  is assigned to a version only when that version has the work item's stage.

  ## Who

  Every change asks `process.edit` (owners and admins), of the feature `workflow_model`,
  and leaves one entry of it in the audit trail, in its transaction: `details.change` is
  `save`, `save_trial`, `make_current`, `drop_trial` or `assign`, with the version's
  public id (`version_id`) and `number`. The entry of a save, a make current and a drop
  is the workspace's; the entry of an assign is the work item's, with the version number
  before and after. Reading asks no action, and neither does the copy of the default.

  ## Workflows and types

  A stage's sequence names workflows that the workspace's harness declares
  (`declared_workflows/1`, `workflow_declaration/2`), as the workspace keeps them from
  the last read of its harness source (`record_declared/2`, `declared_snapshot/1`). A
  save keeps a name the harness does not declare; `placement_check/3` lists it, as it
  lists a type the workspace does not have and an input that no earlier stage outputs.

  ## Export

  `export/1` writes the current version, with the workspace type's texts and the
  workspace's artifact types, as a `process.yaml` (`Apiary.Processes.Export`). Its caller
  checks `process.edit`. A download writes no audit entry.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.QoryCopy
  alias Apiary.Kinds.{Bounds, Schema}
  alias Apiary.Lingo.Domain
  alias Apiary.Lingo.Domain.Definition
  alias Apiary.Organisations.Workspace
  alias Apiary.Processes.{Export, TypeTemplate, TypeTemplates, Version}
  alias Apiary.Stacks.{Sources, Stack}
  alias Apiary.WorkItems.WorkItem

  @schema ["schemas", "process", "v1.schema.json"]

  # A document over these is refused before the schema reads it (`Apiary.Kinds.Bounds`).
  # They leave room for the fields the schema does not list, which a save keeps.
  @limits [list: 64, members: 64, nodes: 20_000, string: 4_096, depth: 16]

  # The version of the default process, the copied template (`Apiary.Harnesses.QoryCopy`):
  # a type's versions keep it (`Apiary.Processes.TypeTemplates`), and a higher one here
  # adds the changed default as a new version of each type no instance admin has saved.
  # Raise it when a copy changes the template's process.
  @template_version 2

  # Crockford base32 without i, l, o and u, as `Apiary.PublicId` writes its ids.
  @alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"

  # A snapshot keeps at most this many names; a read lists at most 20 stacks.
  @max_declared 1_000

  @typedoc "A process document, decoded JSON with string keys."
  @type document :: map

  @typedoc """
  A refusal of a document by `validate/1`: where it is, as JSV writes a place (`#` for
  the document, `#/stages/1/name` for the name of the second stage), and why. `:too_large` for a document over the limits; `:schema` for one the
  schema refuses, with the schema's keyword as `detail`; `:duplicate_stage_id` and
  `:duplicate_stage_name` for the second stage with an id or a name another stage has
  (names compared trimmed and without case); `:unchanged` for a save of the document of
  the version it starts from.
  """
  @type error :: %{path: String.t(), error: atom, detail: term}

  @typedoc "A difference `diff/2` lists: what changed, the stage's id (nil for the document), and how."
  @type change ::
          {:stage_added
           | :stage_removed
           | :stage_renamed
           | :stage_moved
           | :sequence_changed
           | :inputs_changed
           | :outputs_changed
           | :gate_changed
           | :machine_changed, String.t() | nil, map}

  @typedoc "A finding of `placement_check/3`, with the stage's id."
  @type finding ::
          {:missing_workflow, String.t(), String.t()}
          | {:missing_type, String.t(), String.t()}
          | {:input_not_output, String.t(), String.t()}

  @typedoc """
  What the harness declares of a workflow: its name, its access level and time limit
  (nil where Qory Apiary does not keep them), and the artifact types it reads (nil for
  any type).
  """
  @type declaration :: %{
          name: String.t(),
          access: :read | :write | nil,
          time_limit: String.t() | nil,
          reads: [String.t()] | nil
        }

  ## The document

  @doc """
  default_document/1 is the default process of a workspace type, given as its domain
  (`Apiary.Lingo.Domain`, a module or its name) or a workspace: the process of the copied
  template (Apiary.Harnesses.QoryCopy.template/0). Every domain takes that one.
  """
  @spec default_document(module | String.t() | %Workspace{}) :: document
  def default_document(_domain_or_workspace), do: QoryCopy.template().process

  @doc """
  default_version/1 is the version of the default process the release ships for the
  domain `domain` (a module or its name): `Apiary.Processes.TypeTemplates` adds a higher
  one as a new version of the type.
  """
  @spec default_version(module | String.t()) :: pos_integer
  def default_version(_domain), do: @template_version

  @doc """
  template/1 is what a workspace of the domain `domain` (a module, or a workspace) keeps
  of the default it copies: `%{"type" => key, "version" => number}`, the key of the
  domain's definition (`Apiary.Lingo.Domain.Definition`) and the number of the newest
  version of the type's default process (`Apiary.Processes.TypeTemplates.newest/1`).
  """
  @spec template(module | %Workspace{}) :: %{String.t() => term}
  def template(%Workspace{} = workspace), do: template(Domain.for_workspace(workspace))

  def template(domain) when is_atom(domain) do
    key = Domain.definition(domain).key
    %{"type" => key, "version" => TypeTemplates.newest(key).number}
  end

  @doc """
  type_texts/1 is what a page shows of the workspace type of `version`, a version of the
  type's default process: its name, its summary and its description, the "How it works"
  text. Each is the version's text where it has one (`Apiary.Processes.TypeTemplate`),
  else the text the release ships (`type_text_defaults/1`).
  """
  @spec type_texts(TypeTemplate.t()) :: %{TypeTemplate.text() => String.t() | nil}
  def type_texts(%TypeTemplate{} = version) do
    for {text, default} <- type_text_defaults(version.type),
        into: %{},
        do: {text, Map.fetch!(version, text) || default}
  end

  @doc """
  type_text_defaults/1 is the texts the release ships for the workspace type with the key
  `type`, translated in the locale of the caller's process: the copied template's texts
  for its type (Apiary.Harnesses.QoryCopy.texts/0). Another domain's name is its
  `c:Apiary.Lingo.Domain.type_name/0` and its summary its
  `c:Apiary.Lingo.Domain.type_line/0`, with no description. For a key no type has, the
  name is the key, with no summary or description.
  """
  @spec type_text_defaults(String.t()) :: %{TypeTemplate.text() => String.t() | nil}
  def type_text_defaults(type) when is_binary(type) do
    case Enum.find(Domain.choices(), &(Domain.definition(&1).key == type)) do
      nil ->
        %{name: type, summary: nil, description: nil}

      domain ->
        if type == QoryCopy.template().type,
          do: QoryCopy.texts(),
          else: %{name: domain.type_name(), summary: domain.type_line(), description: nil}
    end
  end

  @doc """
  qory_workflows/0 is the workflows the Qory harness declares: the names of the copied
  `software` stack (Apiary.Harnesses.QoryCopy.workflows/1). It does not follow
  `Apiary.Lingo.Domain.Definition.qory_harness/0`, whose stack `core` lists no workflows.
  """
  @spec qory_workflows() :: [String.t()]
  def qory_workflows, do: QoryCopy.workflows("software")

  @doc """
  validate/1 checks `document` against the schema (`priv/schemas/process/v1.schema.json`)
  and the rules it cannot say: every stage id and every stage name once. `:ok`, or
  `{:error, errors}` (`t:error/0`). Fields the schema does not list are kept. A
  workflow the harness does not declare is no error here (`placement_check/3`).
  """
  @spec validate(term) :: :ok | {:error, [error]}
  def validate(document) when is_map(document) do
    cond do
      not Bounds.within?(document, @limits) ->
        {:error, [%{path: "#", error: :too_large, detail: Map.new(@limits)}]}

      true ->
        case JSV.validate(document, root(), cast: false) do
          {:ok, _document} ->
            case duplicates(document["stages"]) do
              [] -> :ok
              errors -> {:error, errors}
            end

          {:error, %JSV.ValidationError{errors: errors}} ->
            {:error, Enum.map(errors, &schema_error/1)}
        end
    end
  end

  def validate(_document), do: {:error, [%{path: "#", error: :schema, detail: :type}]}

  @doc false
  def root, do: Schema.file!(@schema)

  defp schema_error(%JSV.Validator.Error{kind: kind, data_path: path}),
    do: %{path: JSV.ErrorFormatter.format_data_path(path), error: :schema, detail: kind}

  defp duplicates(stages) do
    stages
    |> Enum.with_index()
    |> Enum.reduce({[], MapSet.new(), MapSet.new()}, fn {stage, index}, {errors, ids, names} ->
      name = stage["name"] |> String.trim() |> String.downcase()

      errors =
        errors
        |> add_if(stage["id"] in ids, "#/stages/#{index}/id", :duplicate_stage_id)
        |> add_if(name in names, "#/stages/#{index}/name", :duplicate_stage_name)

      {errors, MapSet.put(ids, stage["id"]), MapSet.put(names, name)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp add_if(errors, true, path, error), do: [%{path: path, error: error, detail: nil} | errors]
  defp add_if(errors, false, _path, _error), do: errors

  @doc """
  new_stage_id/0 is a fresh stage id: `st_` and 10 random Crockford base32 characters,
  50 random bits. A stage keeps its id for good.
  """
  @spec new_stage_id() :: String.t()
  def new_stage_id do
    <<bits::50, _rest::6>> = :crypto.strong_rand_bytes(7)
    "st_" <> for(<<(chunk::5 <- <<bits::50>>)>>, into: "", do: <<Enum.at(@alphabet, chunk)>>)
  end

  @doc """
  stage/2 is the stage with the id `stage_id` of `document`, or of a version's document,
  nil for none.
  """
  @spec stage(document | Version.t(), String.t() | nil) :: map | nil
  def stage(%Version{document: document}, stage_id), do: stage(document, stage_id)

  def stage(%{"stages" => stages}, stage_id) when is_list(stages),
    do: Enum.find(stages, &(is_map(&1) and &1["id"] == stage_id))

  def stage(_document, _stage_id), do: nil

  @doc """
  workflows/1 is the workflow names of a stage's sequence, in order, a loop's body
  included, each once.
  """
  @spec workflows(map) :: [String.t()]
  def workflows(%{} = stage) do
    stage
    |> Map.get("sequence", [])
    |> Enum.flat_map(fn
      %{"loop" => %{"body" => body}} -> body
      entry -> [entry]
    end)
    |> Enum.map(& &1["workflow"])
    |> Enum.uniq()
  end

  ## Reading the versions

  @doc """
  current/1 is the workspace's current version. A workspace with no version yet gets
  version 1 here, a copy of its type's default (`copy_default/1`).
  """
  @spec current(%Workspace{}) :: Version.t()
  def current(%Workspace{} = workspace) do
    case current_row(workspace) do
      %Version{} = version ->
        version

      nil ->
        # Two first reads at once insert one row; the other's insert does nothing.
        {:ok, _inserted_or_none} = copy_default(workspace, on_conflict: :nothing)
        current_row(workspace) || raise(Ecto.NoResultsError, queryable: Version)
    end
  end

  defp current_row(%Workspace{id: id}, lock \\ nil) do
    query = from v in Version, where: v.workspace_id == ^id and v.status == :current
    query = if lock == :update, do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  @doc """
  export/1 is the bytes of the workspace's `process.yaml`, from its current version
  (`Apiary.Processes.Export`). It checks no access, as `current/1` checks none.
  """
  @spec export(%Workspace{}) :: binary
  def export(%Workspace{} = workspace), do: Export.file(workspace)

  @doc """
  copy_default/1 inserts the workspace's version 1, a copy of the newest version of its
  type's default process (`Apiary.Processes.TypeTemplates.newest/1`), with no author and
  that version's `{type, number}` as its `template`: called where the workspace is
  created, in that transaction. `{:ok, version}`.
  """
  @spec copy_default(%Workspace{}, keyword) :: {:ok, Version.t()} | {:error, term}
  def copy_default(%Workspace{} = workspace, opts \\ []) do
    key = Domain.definition(Domain.for_workspace(workspace)).key
    newest = TypeTemplates.newest(key)

    insert_first(workspace, newest.document, %{"type" => key, "version" => newest.number}, opts)
  end

  @doc """
  copy_qory_template/1 inserts version 1 of `workspace`, made from the Qory template, with
  no author: the newest version of its type's default process, and the record of the
  template (the moduledoc). Called where the workspace is created, in that transaction.
  `{:ok, version}`.
  """
  @spec copy_qory_template(%Workspace{}) :: {:ok, Version.t()} | {:error, term}
  def copy_qory_template(%Workspace{} = workspace) do
    key = Domain.definition(Domain.for_workspace(workspace)).key
    newest = TypeTemplates.newest(key)
    harness = Definition.qory_harness()

    insert_first(
      workspace,
      newest.document,
      %{
        "source" => "qory",
        "git" => harness.git,
        "commit" => harness.latest,
        "module" => QoryCopy.template_module(),
        "stack" => Workspace.qory_stack(workspace),
        "type" => QoryCopy.template().type,
        "version" => newest.number
      },
      []
    )
  end

  @doc """
  copy_template/4 inserts version 1 of `workspace`, made from a template of a harness
  source by the person `author_id`: `document`, the template's process, and `template`, its
  record (Apiary.Stacks.Sources.save_start/3). The author is the scope's person, because
  a version with no author reads as copied from the workspace type on the Stages page.
  Called where the workspace is created, in that transaction. `{:ok, version}`.
  """
  @spec copy_template(%Workspace{}, document, map, Ecto.UUID.t() | nil) ::
          {:ok, Version.t()} | {:error, term}
  def copy_template(%Workspace{} = workspace, document, %{} = template, author_id) do
    workspace
    |> first_version(document, template)
    |> Map.put(:author_id, author_id)
    |> Repo.insert()
  end

  defp insert_first(%Workspace{} = workspace, document, template, opts),
    do: workspace |> first_version(document, template) |> Repo.insert(opts)

  defp first_version(%Workspace{} = workspace, document, template) do
    %Version{
      organisation_id: workspace.organisation_id,
      workspace_id: workspace.id,
      public_id: Apiary.PublicId.generate("pv"),
      number: 1,
      status: :current,
      document: document,
      template: template
    }
  end

  @doc """
  get_version!/1 is the version with the id `id`, its row id or its public id (`pv_…`).
  Raises `Ecto.NoResultsError` for none.
  """
  @spec get_version!(String.t()) :: Version.t()
  def get_version!("pv_" <> _rest = public_id), do: Repo.get_by!(Version, public_id: public_id)
  def get_version!(id) when is_binary(id), do: Repo.get!(Version, id)

  @doc "list_versions/1 is every version of the workspace, the newest first."
  @spec list_versions(%Workspace{}) :: [Version.t()]
  def list_versions(%Workspace{id: id}) do
    Repo.all(from v in Version, where: v.workspace_id == ^id, order_by: [desc: v.number])
  end

  @doc """
  version_for/1 is the version the work item runs under: the one it keeps, else its
  workspace's current version.
  """
  @spec version_for(%WorkItem{}) :: Version.t()
  def version_for(%WorkItem{process_version_id: id}) when is_binary(id),
    do: Repo.get!(Version, id)

  def version_for(%WorkItem{workspace_id: workspace_id}),
    do: current(Repo.get!(Workspace, workspace_id))

  ## Changing the versions

  @doc """
  save/4 saves `document` as a new version of the workspace, the scope's, under
  `process.edit`. The new version is current, and the version that was current is past;
  with `trial: true` it is a trial, and the current version stays. `based_on:`, a
  version of the workspace, is the version the save starts from, the current one by
  default. A stage with no `id` is given a new one (`new_stage_id/0`).

  `{:ok, version}`; `{:error, errors}` (`t:error/0`) for a document `validate/1` refuses
  or that is the document of the version the save starts from; or a reason of
  `Apiary.Access`.
  """
  @spec save(Scope.t(), %Workspace{}, term, keyword) ::
          {:ok, Version.t()} | {:error, [error] | Access.reason()}
  def save(%Scope{} = scope, %Workspace{} = workspace, document, opts \\ []) do
    trial? = Keyword.get(opts, :trial, false)
    document = with_stage_ids(document)

    Repo.transact(fn ->
      with {:ok, scope, workspace} <- hold(scope, workspace),
           :ok <- Access.check(scope, :"process.edit", workspace),
           :ok <- validate(document),
           {:ok, base} <- base(workspace, Keyword.get(opts, :based_on)),
           :ok <- changed(base, document),
           {:ok, version} <- insert_version(scope, workspace, base, document, trial?),
           {:ok, _entry} <-
             record(scope, workspace, version, if(trial?, do: "save_trial", else: "save"), %{
               based_on: base.number
             }) do
        {:ok, version}
      end
    end)
  end

  @doc false
  # The document with a new id (`new_stage_id/0`) on each stage that has none.
  def with_stage_ids(%{"stages" => stages} = document) when is_list(stages) do
    stages =
      Enum.map(stages, fn
        %{} = stage when not is_map_key(stage, "id") -> Map.put(stage, "id", new_stage_id())
        stage -> stage
      end)

    %{document | "stages" => stages}
  end

  def with_stage_ids(document), do: document

  defp base(workspace, nil), do: {:ok, current(workspace)}

  defp base(workspace, %Version{id: id}), do: base(workspace, id)

  defp base(%Workspace{id: workspace_id}, id) when is_binary(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Version{} = version <-
           Repo.one(from v in Version, where: v.id == ^id and v.workspace_id == ^workspace_id) do
      {:ok, version}
    else
      _none -> {:error, :not_found}
    end
  end

  defp changed(%Version{document: document}, document),
    do: {:error, [%{path: "#", error: :unchanged, detail: nil}]}

  defp changed(_base, _document), do: :ok

  defp insert_version(scope, workspace, base, document, trial?) do
    number =
      Repo.one(from v in Version, where: v.workspace_id == ^workspace.id, select: max(v.number))

    status =
      if trial? do
        :trial
      else
        retire_current(workspace)
        :current
      end

    Repo.insert(%Version{
      organisation_id: workspace.organisation_id,
      workspace_id: workspace.id,
      public_id: Apiary.PublicId.generate("pv"),
      number: (number || 0) + 1,
      status: status,
      document: document,
      author_id: scope.user && scope.user.id,
      based_on_id: base.id
    })
  end

  defp retire_current(%Workspace{id: id}) do
    Repo.update_all(
      from(v in Version, where: v.workspace_id == ^id and v.status == :current),
      set: [status: :past, updated_at: DateTime.utc_now()]
    )
  end

  @doc """
  make_current/2 makes the trial `trial` the workspace's current version, under
  `process.edit`; the version that was current is past. Its work items stay on it, and
  every other work item stays on its version. `{:ok, version}`; `{:error, :not_trial}`
  for a version that is not a trial, made current or dropped since it was read; or a
  reason of `Apiary.Access`.
  """
  @spec make_current(Scope.t(), Version.t()) ::
          {:ok, Version.t()} | {:error, :not_trial | Access.reason()}
  def make_current(%Scope{} = scope, %Version{} = trial) do
    Repo.transact(fn ->
      with {:ok, scope, workspace} <- hold(scope, trial),
           :ok <- Access.check(scope, :"process.edit", trial),
           {:ok, trial} <- held_trial(trial),
           replaced = current_row(workspace, :update),
           _retired = retire_current(workspace),
           {:ok, version} <- trial |> Ecto.Changeset.change(status: :current) |> Repo.update(),
           {:ok, _entry} <-
             record(scope, workspace, version, "make_current", %{
               replaced: replaced && replaced.number
             }) do
        {:ok, version}
      end
    end)
  end

  @doc """
  drop_trial/2 drops the trial `trial`, under `process.edit`, and moves its work items
  back to the workspace's current version. `{:ok, version}`, the dropped version;
  `{:error, :not_trial}` for a version that is not a trial; `{:error, {:missing_stage,
  stage_id}}` where a work item of the trial is in a stage the current version does not
  have, which is assigned elsewhere first; or a reason of `Apiary.Access`.
  """
  @spec drop_trial(Scope.t(), Version.t()) ::
          {:ok, Version.t()}
          | {:error, :not_trial | {:missing_stage, String.t()} | Access.reason()}
  def drop_trial(%Scope{} = scope, %Version{} = trial) do
    Repo.transact(fn ->
      with {:ok, scope, workspace} <- hold(scope, trial),
           :ok <- Access.check(scope, :"process.edit", trial),
           {:ok, trial} <- held_trial(trial),
           current = current_row(workspace, :update) || current(workspace),
           items = trial_items(trial),
           :ok <- stages_in(items, current),
           {moved, _} <-
             Repo.update_all(
               from(w in WorkItem, where: w.id in ^Enum.map(items, & &1.id)),
               set: [process_version_id: current.id, updated_at: DateTime.utc_now()]
             ),
           {:ok, version} <- trial |> Ecto.Changeset.change(status: :dropped) |> Repo.update(),
           {:ok, _entry} <- record(scope, workspace, version, "drop_trial", %{moved: moved}) do
        {:ok, version}
      end
    end)
  end

  defp trial_items(%Version{id: id}) do
    Repo.all(
      from w in WorkItem,
        where: w.process_version_id == ^id,
        order_by: w.number,
        lock: "FOR UPDATE"
    )
  end

  defp stages_in(items, version) do
    case Enum.find(items, &(&1.stage_id && is_nil(stage(version, &1.stage_id)))) do
      nil -> :ok
      %WorkItem{stage_id: stage_id} -> {:error, {:missing_stage, stage_id}}
    end
  end

  defp held_trial(%Version{id: id}) do
    case Repo.one(from v in Version, where: v.id == ^id, lock: "FOR UPDATE") do
      %Version{status: :trial} = trial -> {:ok, trial}
      _other -> {:error, :not_trial}
    end
  end

  @doc """
  assign/3 makes `work_item` run under `version`, a version of its workspace that is not
  dropped, under `process.edit`. The work item keeps its stage, its stage's state and its
  place in the stage's sequence; a run in progress finishes under the version it started
  with. The work item's runs queued and not yet claimed (`:waiting`) move to `version`
  with it; a run claimed or later keeps its version. `{:ok, work_item}`, unchanged
  where it is on the version already;
  `{:error, {:missing_stage, stage_id}}` where `version` does not have the work item's
  stage; `{:error, :dropped}` for a dropped version; or a reason of `Apiary.Access`.
  """
  @spec assign(Scope.t(), %WorkItem{}, Version.t()) ::
          {:ok, %WorkItem{}}
          | {:error, {:missing_stage, String.t()} | :dropped | Access.reason()}
  def assign(%Scope{} = scope, %WorkItem{} = work_item, %Version{} = version) do
    Repo.transact(fn ->
      with {:ok, scope, workspace} <- hold(scope, work_item),
           :ok <- Access.check(scope, :"process.edit", work_item),
           %WorkItem{} = work_item <- held_item(work_item),
           {:ok, version} <- assignable(version, workspace) do
        before = version_for(work_item)

        cond do
          before.id == version.id and work_item.process_version_id == version.id ->
            {:ok, work_item}

          work_item.stage_id && is_nil(stage(version, work_item.stage_id)) ->
            {:error, {:missing_stage, work_item.stage_id}}

          true ->
            with {:ok, assigned} <-
                   work_item
                   |> Ecto.Changeset.change(process_version_id: version.id)
                   |> Repo.update(),
                 {_runs, _} <-
                   Repo.update_all(
                     from(r in DispatchRun,
                       where: r.work_item_id == ^work_item.id and r.state == :waiting
                     ),
                     set: [process_version_id: version.id, updated_at: DateTime.utc_now()]
                   ),
                 {:ok, _entry} <-
                   Audit.record(Repo, scope, :"process.edit", assigned, %{
                     before: %{process_version: before.number},
                     after: %{process_version: version.number},
                     details: %{
                       change: "assign",
                       version_id: version.public_id,
                       number: version.number
                     }
                   }),
                 do: {:ok, assigned}
        end
      else
        nil -> {:error, :not_found}
        other -> other
      end
    end)
  end

  defp held_item(%WorkItem{id: id}),
    do: Repo.one(from w in WorkItem, where: w.id == ^id, lock: "FOR UPDATE")

  defp assignable(%Version{id: id}, %Workspace{id: workspace_id}) do
    case Repo.one(from v in Version, where: v.id == ^id and v.workspace_id == ^workspace_id) do
      nil -> {:error, :not_found}
      %Version{status: :dropped} -> {:error, :dropped}
      %Version{} = version -> {:ok, version}
    end
  end

  # The scope's places and the workspace of `subject` held, the workspace `FOR NO KEY
  # UPDATE`, so the changes of one workspace's process take turns, and the scope read
  # again: `{:ok, scope, workspace}`, or `{:error, :not_found}` for a subject of another
  # workspace than the scope's.
  defp hold(%Scope{} = scope, subject) do
    :ok = Access.lock_places(scope)
    workspace_id = workspace_id(subject)

    with %Workspace{id: ^workspace_id} <- scope.workspace,
         %Workspace{} = workspace <-
           Repo.one(
             from w in Workspace,
               where: w.id == ^workspace_id and w.organisation_id == ^scope.organisation.id,
               lock: "FOR NO KEY UPDATE"
           ) do
      {:ok, Access.reload(scope, lock: :share), workspace}
    else
      _other -> {:error, :not_found}
    end
  end

  defp workspace_id(%Workspace{id: id}), do: id
  defp workspace_id(%{workspace_id: id}), do: id

  defp record(scope, workspace, version, change, details) do
    Audit.record(Repo, scope, :"process.edit", workspace, %{
      after: %{process_version: version.number, status: Atom.to_string(version.status)},
      details:
        Map.merge(
          %{change: change, version_id: version.public_id, number: version.number},
          details
        )
    })
  end

  ## The differences

  @doc """
  diff/2 is what changed from `older` to `newer`, two versions or documents; `older` nil
  for none, as before version 1. First a change of the document's `machine`, then, for
  each stage of `newer` in its order, whether it was added, or renamed, moved, or had its
  sequence, inputs, outputs or gate changed, then each stage `older` had and `newer`
  does not, in `older`'s order. A stage is moved when its place among the stages both
  have changed, beyond what another stage's move explains.

  Each change is `{kind, stage_id, detail}`: `%{name, position}` for an added stage
  (position from 0), `%{name}` for a removed one, `%{from, to}` for the rest, the value
  before and after (a position for a move, the document's machine for
  `:machine_changed`, whose stage id is nil).
  """
  @spec diff(Version.t() | document | nil, Version.t() | document) :: [change]
  def diff(%Version{document: older}, newer), do: diff(older, newer)
  def diff(older, %Version{document: newer}), do: diff(older, newer)
  def diff(nil, newer), do: diff(%{"stages" => []}, newer)

  def diff(%{} = older, %{} = newer) do
    old_stages = Map.get(older, "stages", [])
    new_stages = Map.get(newer, "stages", [])
    old_by_id = Map.new(old_stages, &{&1["id"], &1})
    new_ids = MapSet.new(new_stages, & &1["id"])
    moved = moved(Enum.map(old_stages, & &1["id"]), Enum.map(new_stages, & &1["id"]))

    machine =
      if older != %{"stages" => []} and older["machine"] != newer["machine"],
        do: [{:machine_changed, nil, %{from: older["machine"], to: newer["machine"]}}],
        else: []

    changed =
      new_stages
      |> Enum.with_index()
      |> Enum.flat_map(fn {stage, position} ->
        id = stage["id"]

        case old_by_id do
          %{^id => old} -> stage_changes(old, stage, Map.get(moved, id))
          _ -> [{:stage_added, id, %{name: stage["name"], position: position}}]
        end
      end)

    removed =
      for stage <- old_stages,
          stage["id"] not in new_ids,
          do: {:stage_removed, stage["id"], %{name: stage["name"]}}

    machine ++ changed ++ removed
  end

  defp stage_changes(old, new, move) do
    id = new["id"]

    [
      old["name"] != new["name"] && {:stage_renamed, id, %{from: old["name"], to: new["name"]}},
      move && {:stage_moved, id, move},
      field_change(:sequence_changed, id, old, new, "sequence"),
      field_change(:inputs_changed, id, old, new, "inputs"),
      field_change(:outputs_changed, id, old, new, "outputs"),
      field_change(:gate_changed, id, old, new, "gate")
    ]
    |> Enum.filter(& &1)
  end

  defp field_change(kind, id, old, new, field) do
    if Map.get(old, field, []) != Map.get(new, field, []),
      do: {kind, id, %{from: Map.get(old, field), to: Map.get(new, field)}}
  end

  # The stages both orders have, outside their longest common subsequence: the fewest
  # moves that turn the older order into the newer. Each with its position before and
  # after, among all the stages of each document.
  defp moved(old_ids, new_ids) do
    common = MapSet.intersection(MapSet.new(old_ids), MapSet.new(new_ids))
    old_common = Enum.filter(old_ids, &(&1 in common))
    new_common = Enum.filter(new_ids, &(&1 in common))
    kept = MapSet.new(lcs(old_common, new_common))
    old_at = old_ids |> Enum.with_index() |> Map.new()
    new_at = new_ids |> Enum.with_index() |> Map.new()

    for id <- new_common, id not in kept, into: %{} do
      {id, %{from: old_at[id], to: new_at[id]}}
    end
  end

  # The longest common subsequence of two lists of distinct ids, at most 50 each.
  defp lcs(a, b) do
    a = List.to_tuple(a)
    b = List.to_tuple(b)
    n = tuple_size(a)
    m = tuple_size(b)

    table =
      for i <- (n - 1)..0//-1, j <- (m - 1)..0//-1, reduce: %{} do
        table ->
          value =
            if elem(a, i) == elem(b, j),
              do: 1 + Map.get(table, {i + 1, j + 1}, 0),
              else: max(Map.get(table, {i + 1, j}, 0), Map.get(table, {i, j + 1}, 0))

          Map.put(table, {i, j}, value)
      end

    walk(a, b, 0, 0, table, [])
  end

  defp walk(a, b, i, j, _table, acc) when i >= tuple_size(a) or j >= tuple_size(b),
    do: Enum.reverse(acc)

  defp walk(a, b, i, j, table, acc) do
    cond do
      elem(a, i) == elem(b, j) ->
        walk(a, b, i + 1, j + 1, table, [elem(a, i) | acc])

      Map.get(table, {i + 1, j}, 0) >= Map.get(table, {i, j + 1}, 0) ->
        walk(a, b, i + 1, j, table, acc)

      true ->
        walk(a, b, i, j + 1, table, acc)
    end
  end

  ## Workflows and types

  @doc """
  record_declared/2 keeps `names` as the workflows the workspace's harness lists now: it
  replaces the names the workspace kept, with the time of this call
  (`declared_snapshot/1`). Call it with the names that
  Apiary.Stacks.Sources.chosen_workflows/2 returns for the workspace's harness: its
  choice, else the harness the organisation shares, else the Qory harness, whose names
  are `qory_workflows/0`, with no read. The Stages page calls it on open, Workspace
  settings > Workflow on open and after a harness choice is saved, and Check again on a
  work item; a saved workflow does not change it. Each name is kept once, sorted, at
  most 1,000. `:ok`.
  """
  @spec record_declared(%Workspace{}, [String.t()]) :: :ok
  def record_declared(%Workspace{id: id, organisation_id: organisation_id}, names)
      when is_list(names) do
    names =
      names |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort() |> Enum.take(@max_declared)

    {_one_or_none, _} =
      Repo.update_all(
        from(w in "workspaces",
          where: w.id == type(^id, :binary_id),
          where: w.organisation_id == type(^organisation_id, :binary_id)
        ),
        set: [declared_workflows: names, declared_workflows_read_at: DateTime.utc_now()]
      )

    :ok
  end

  @doc """
  declared_snapshot/1 is the workflow names the workspace kept at the last
  `record_declared/2`: `%{names: names, read_at: time}`, or nil before the first. It
  covers only the workspace's harness as Apiary.Stacks.Sources.chosen_workflows/2
  finds it (the choice, else the harness the organisation shares, else the Qory
  harness): not a harness file of a repository, and not the stack chosen for a target.
  """
  @spec declared_snapshot(%Workspace{}) :: %{names: [String.t()], read_at: DateTime.t()} | nil
  def declared_snapshot(%Workspace{id: id}) do
    Repo.one(
      from w in "workspaces",
        where: w.id == type(^id, :binary_id) and not is_nil(w.declared_workflows_read_at),
        select: %{
          names: w.declared_workflows,
          read_at: type(w.declared_workflows_read_at, :utc_datetime_usec)
        }
    )
  end

  @doc """
  declared_workflows/1 is the names of the workflows the workspace may place in a stage,
  sorted: for a workspace on the Qory harness, `qory_workflows/0`; the names of the
  workspace's snapshot (`declared_snapshot/1`), which covers only the workspace's harness,
  as Apiary.Stacks.Sources.chosen_workflows/2 finds it; and the workflow saved on the
  workspace's Workflow page, at the workspace or a target of it. Before the first
  snapshot, a workspace on another harness has only the saved workflow.
  """
  @spec declared_workflows(%Workspace{}) :: [String.t()]
  def declared_workflows(%Workspace{} = workspace) do
    workspace
    |> declared_names(saved_workflows(workspace))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Transition: the saved workflow is added by hand for a workspace with no snapshot or a
  # snapshot older than its save. Remove it once the snapshot is written wherever a
  # workspace's harness is chosen or saved.
  defp declared_names(workspace, saved) do
    harness =
      case Sources.chosen(workspace) do
        %{choice: :qory} -> qory_workflows()
        _repository -> []
      end

    snapshot =
      case declared_snapshot(workspace) do
        %{names: names} -> names
        nil -> []
      end

    harness ++ snapshot ++ Enum.map(saved, & &1.workflow)
  end

  @doc """
  workflow_declaration/2 is what the workspace's harness declares of the workflow `name`
  (`t:declaration/0`), nil for a name `declared_workflows/1` does not have. `access` is
  the level recorded with the saved workflow where one is, else nil: the level the
  workflow declares in its stack. `time_limit` and `reads` are nil, since Qory Apiary
  keeps neither of them: nil `reads` means any type.
  """
  @spec workflow_declaration(%Workspace{}, String.t()) :: declaration | nil
  def workflow_declaration(%Workspace{} = workspace, name) when is_binary(name) do
    saved = saved_workflows(workspace)

    if name in declared_names(workspace, saved) do
      access =
        saved
        |> Enum.filter(&(&1.workflow == name))
        |> Enum.sort_by(&(not is_nil(&1.target_id)))
        |> Enum.find_value(& &1.access)

      %{name: name, access: access, time_limit: nil, reads: nil}
    end
  end

  defp saved_workflows(%Workspace{id: id, organisation_id: organisation_id}) do
    Repo.all(
      from s in Stack,
        where: s.organisation_id == ^organisation_id and s.workspace_id == ^id,
        where: not is_nil(s.workflow),
        select: %{workflow: s.workflow, access: s.access, target_id: s.target_id}
    )
  end

  @doc """
  placement_check/3 lists what keeps `document`'s stages from running as placed, stage
  by stage in order:

    * `{:missing_workflow, stage_id, name}`: a workflow of the stage's sequence that
      `declared` does not have. That stage does not start until the name is declared
      again or replaced;
    * `{:missing_type, stage_id, type}`: an input's or an output's type that
      `artifact_types` does not have;
    * `{:input_not_output, stage_id, type}`: an input that no earlier stage lists as an
      output.

  `declared` is the workflow names or their declarations (`workflow_declaration/2`);
  `artifact_types`, the type names, or maps with a `name`.
  """
  @spec placement_check(document | Version.t(), [String.t() | declaration], [
          String.t() | map
        ]) :: [finding]
  def placement_check(%Version{document: document}, declared, artifact_types),
    do: placement_check(document, declared, artifact_types)

  def placement_check(%{} = document, declared, artifact_types) do
    declared = Map.new(declared, &declared_entry/1)
    types = MapSet.new(artifact_types, &type_name/1)

    document
    |> Map.get("stages", [])
    |> Enum.reduce({[], MapSet.new()}, fn stage, {findings, earlier} ->
      id = stage["id"]
      inputs = Map.get(stage, "inputs", [])
      outputs = Map.get(stage, "outputs", [])
      workflows = workflows(stage)

      missing_workflows =
        for name <- workflows, not is_map_key(declared, name), do: {:missing_workflow, id, name}

      missing_types =
        for type <- Enum.uniq(Enum.map(inputs ++ outputs, & &1["type"])),
            type not in types,
            do: {:missing_type, id, type}

      not_output =
        for type <- Enum.uniq(Enum.map(inputs, & &1["type"])),
            type not in earlier,
            do: {:input_not_output, id, type}

      earlier = Enum.reduce(outputs, earlier, &MapSet.put(&2, &1["type"]))
      {findings ++ missing_workflows ++ missing_types ++ not_output, earlier}
    end)
    |> elem(0)
  end

  defp declared_entry(name) when is_binary(name), do: {name, %{name: name}}
  defp declared_entry(%{name: name} = declaration), do: {name, declaration}

  defp type_name(name) when is_binary(name), do: name
  defp type_name(%{name: name}), do: name
  defp type_name(%{"name" => name}), do: name
end
