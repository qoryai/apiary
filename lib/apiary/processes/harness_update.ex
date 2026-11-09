defmodule Apiary.Processes.HarnessUpdate do
  @moduledoc """
  Updates a workspace's process (`Apiary.Processes`) from its harness: the `process.yaml`
  of the harness the workspace takes, at the version its harness choice follows, saved as
  a version of the process.

  ## Update from harness

  `read/2` reads the harness's template at the chosen version and compares it with the
  workspace's current version: the stages (`Apiary.Processes.diff/2`), the artifact types
  the template lists that the workspace does not have, and the stack, where the
  template's differs from the one the workspace's harness choice has. For the Qory
  harness, the template is the one of its stored files at the commit the choice's
  version was at when last read, and is read once where none is stored; for a harness
  repository, it is read as the scope's person reads a source's templates, from the
  module the process came from. `save/4` saves it as the current version, with the record
  of the commit as its `template` (`Apiary.Processes.save_harness/5`), adds the artifact
  types the workspace does not have, and copies the template's stack. The version replaces every edit saved since:
  nothing is merged. A save turns the switch below on; a save with `trial: true` saves a
  trial, as the Workflows page saves one, and leaves the switch as it is. Work items in
  progress stay on their version, and work items taken in after a save follow the version
  it saved.

  ## Keep the process at the latest

  A switch of the workspace, `workspaces.keep_process_latest` (`keep_latest?/1`,
  `set_keep_latest/3`). It applies where the harness follows a branch (`following/1`),
  never to one pinned to a tag or a commit. Until it is set, it is on for the Qory harness
  and off for a harness repository. A person's save of edits turns it off
  (`Apiary.Processes.save/4`).

  While it is on, for the Qory harness, each later commit of the followed branch that the
  refresh of the Qory harness reads is saved as a version, with no author, even when the
  process is unchanged (`follow_all/0`). No version is saved where the template fails a
  check: no template of the workspace's type, a process that fails
  `Apiary.Processes.validate/1` or has a machine type the instance does not have, artifact
  types that fail the template check, or a stack that cannot be copied. A workspace whose current
  version has no harness commit, as one made with no template, is not updated. The
  feature `workflow_model` must be on.

  Following a harness repository's branch needs a read of the repository at each later
  commit, which Qory Apiary makes only when a person reads the repository or a run is
  queued: the switch has no effect there yet.

  ## Who

  `read/2`, `save/4` and `set_keep_latest/3` need `process.edit`, and a save that copies a
  stack also needs `harness.save`. The switch's change leaves one entry of
  `process.edit` in the audit trail, `change` `keep_latest` with `on`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, Artifacts, Audit, Features, Processes, Repo, Stacks}
  alias Apiary.Accounts.Scope
  alias Apiary.Artifacts.{TemplateTypes, Type}
  alias Apiary.Harnesses.Qory
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Processes.Version
  alias Apiary.Stacks.Sources

  @typedoc """
  The version of the harness an update reads: a branch, a tag or a commit, with its name
  or full id.
  """
  @type harness_version :: {:branch | :tag | :commit, String.t()}

  @typedoc """
  What `read/2` returns, for a page to show and for `save/4`:

    * `source`: `:qory` or `:repository`; `git`, the harness's address;
    * `version`: the version of the harness the choice follows, as read;
    * `commit`: the full id of the commit read;
    * `in_use`: the commit the current version was made from
      (`Apiary.Processes.harness_template/1`), nil for none;
    * `base`: the current version, which the update replaces;
    * `document`: the template's process;
    * `changes`: the differences from `base` to `document` (`Apiary.Processes.diff/2`);
    * `added_types`: the entries of the template's `artifact_types` that the workspace does
      not have, in the template's order: a standard type it does not show, by its name
      alone, and a custom type no custom type of the workspace has the name of;
    * `stack`: `%{from: stack, to: stack}` where the template's stack differs from the
      stack of the workspace's harness choice, else nil;
    * `template`: the record the saved version keeps as its `template`.
  """
  @type update :: %{
          source: :qory | :repository,
          git: String.t() | nil,
          version: harness_version,
          commit: String.t(),
          in_use: String.t() | nil,
          base: Version.t(),
          document: Processes.document(),
          changes: [Processes.change()],
          added_types: [map],
          stack: %{from: String.t() | nil, to: String.t()} | nil,
          template: map,
          artifact_types: [map] | nil
        }

  @typedoc """
  Why `read/2` found nothing to save:

    * `:no_template`: the harness has no template of the workspace's type at that
      version, of the module the process came from;
    * `{:qory, failure}`: a read of the Qory harness that failed
      (Apiary.Harnesses.Qory);
    * `{:read, reason}`: a read of a harness repository that failed
      (Apiary.Stacks.Sources.templates/2);
    * `{:not_readable, reason}`: a module whose template failed the checks of the read,
      with the reason (Apiary.Stacks.Sources);
    * `{:types, refusals}`: artifact types that fail the template check
      (Apiary.Artifacts.TemplateTypes);
    * `[error]`: a process that fails `Apiary.Processes.validate/1`;
    * a reason of `Apiary.Access`.
  """
  @type reason ::
          :no_template
          | {:qory, term}
          | {:read, term}
          | {:not_readable, term}
          | {:types, list}
          | [Processes.error()]
          | Access.reason()

  ## The harness the workspace follows

  @doc """
  following/1 is the branch the workspace's harness follows: `{:qory, branch}` for the
  Qory harness, `{:repository, branch}` for a harness repository; nil for a harness
  pinned to a tag or a commit.
  """
  @spec following(%Workspace{}) :: {:qory | :repository, String.t()} | nil
  def following(%Workspace{} = workspace) do
    case version(workspace) do
      {choice, {:branch, name}} -> {choice, name}
      _pinned -> nil
    end
  end

  # The choice of the workspace's harness (Apiary.Stacks.Sources.chosen/1), with its
  # version: for the Qory harness as its row has it (Apiary.Harnesses.Qory.row_version/1),
  # for a harness repository the saved version, else the commit of its pin.
  defp version(%Workspace{} = workspace) do
    chosen = Sources.chosen(workspace)

    case chosen do
      %{choice: :qory} ->
        organisation = %Organisation{id: workspace.organisation_id}
        {:qory, Qory.row_version(Stacks.workspace_harness(workspace, organisation))}

      %{choice: :repository, version: {kind, name}} when kind in [:branch, :tag, :commit] ->
        {:repository, {kind, name}}

      # A row saved with no version: pinned at a commit, or, saved before versions, a
      # branch by its name; with no `ref`, the commit `HEAD` is at, as a read takes it.
      %{choice: :repository, pin: pin} ->
        cond do
          Qory.commit?(pin) -> {:repository, {:commit, pin}}
          is_binary(pin) -> {:repository, {:branch, pin}}
          true -> {:repository, {:branch, "HEAD"}}
        end
    end
  end

  @doc """
  keep_latest?/1 is whether the switch Keep the process at the latest is on for the
  workspace: the saved value, else on for the Qory harness and off for a harness
  repository. Off for a harness pinned to a tag or a commit, whatever is saved.
  """
  @spec keep_latest?(%Workspace{}) :: boolean
  def keep_latest?(%Workspace{} = workspace) do
    case following(workspace) do
      nil -> false
      {choice, _branch} -> keep_value(workspace, choice)
    end
  end

  defp keep_value(%Workspace{id: id}, choice) do
    case Repo.one(from w in Workspace, where: w.id == ^id, select: w.keep_process_latest) do
      nil -> choice == :qory
      on? -> on?
    end
  end

  @doc """
  set_keep_latest/3 turns the switch Keep the process at the latest on or off for the
  scope's workspace, under `process.edit`, with one audit entry. `{:ok, workspace}`;
  `{:error, :pinned}` for a harness pinned to a tag or a commit, where the switch does not
  apply; or a reason of `Apiary.Access`.
  """
  @spec set_keep_latest(Scope.t(), %Workspace{}, boolean) ::
          {:ok, %Workspace{}} | {:error, :pinned | Access.reason()}
  def set_keep_latest(%Scope{} = scope, %Workspace{} = workspace, on?) when is_boolean(on?) do
    with :ok <- Access.authorize(scope, :"process.edit", workspace) do
      Repo.transact(fn ->
        held =
          Repo.one(from w in Workspace, where: w.id == ^workspace.id, lock: "FOR NO KEY UPDATE")

        cond do
          is_nil(held) ->
            {:error, :not_found}

          is_nil(following(held)) ->
            {:error, :pinned}

          true ->
            {:ok, updated} =
              held |> Ecto.Changeset.change(keep_process_latest: on?) |> Repo.update()

            {:ok, _entry} =
              Audit.record(Repo, scope, :"process.edit", updated, %{
                after: %{keep_process_latest: on?},
                details: %{change: "keep_latest", on: on?}
              })

            {:ok, updated}
        end
      end)
    end
  end

  @doc """
  status/1 is what a page shows of the workspace's harness and its process: the harness
  choice (Apiary.Stacks.Sources.chosen/1: `source`, `git`, `stack`, `shared`), its
  `version` (`t:harness_version/0`), the branch it follows (`following`, nil for a
  pinned version), `keep_latest` (`keep_latest?/1`, nil where the switch does not apply),
  the current version's `number` and the commit it was made from (`in_use`, nil for
  none), and `head`, the commit the Qory harness's version was at when last read, nil
  before a read and for a harness repository, which is read only when a person reads it
  (`read/2`).
  """
  @spec status(%Workspace{}) :: %{
          source: :qory | :repository,
          git: String.t() | nil,
          stack: String.t() | nil,
          shared: boolean,
          version: harness_version,
          following: String.t() | nil,
          keep_latest: boolean | nil,
          number: pos_integer,
          in_use: String.t() | nil,
          head: String.t() | nil
        }
  def status(%Workspace{} = workspace) do
    chosen = Sources.chosen(workspace)
    {source, version} = version(workspace)
    current = Processes.current(workspace)
    branch = with {_source, name} <- following(workspace), do: name

    %{
      source: source,
      git: chosen.git,
      stack: chosen.stack,
      shared: chosen.shared,
      version: version,
      following: branch,
      keep_latest: if(branch, do: keep_latest?(workspace)),
      number: current.number,
      in_use: in_use(current, chosen),
      head: if(source == :qory, do: Qory.version_commit(version))
    }
  end

  # The commit `version` was made from, where it is a commit of the harness `chosen`.
  defp in_use(version, chosen) do
    template = Processes.harness_template(version)
    if same_harness?(template, chosen), do: template["commit"]
  end

  defp same_harness?(%{"source" => "qory"}, %{choice: :qory}), do: true

  defp same_harness?(%{"source" => "repository", "git" => git}, %{choice: :repository, git: git})
       when is_binary(git),
       do: true

  defp same_harness?(_template, _chosen), do: false

  ## Update from harness

  @doc """
  read/2 reads the harness of the scope's workspace and compares it with its current
  version, under `process.edit` (the moduledoc): `{:ok, update}` (`t:update/0`), or
  `{:error, reason}` (`t:reason/0`). A harness repository is read through its adapters
  or as public, as one of the scope's person's reads (Apiary.Stacks.Sources), so a page
  runs it outside its process.
  """
  @spec read(Scope.t(), %Workspace{}) :: {:ok, update} | {:error, reason}
  def read(%Scope{} = scope, %Workspace{} = workspace) do
    with :ok <- Access.authorize(scope, :"process.edit", workspace) do
      workspace = Repo.get!(Workspace, workspace.id)
      chosen = Sources.chosen(workspace)
      base = Processes.current(workspace)

      case version(workspace) do
        {:qory, version} -> read_qory(workspace, chosen, base, version)
        {:repository, version} -> read_repository(scope, workspace, chosen, base, version)
      end
    end
  end

  defp read_qory(workspace, chosen, base, version) do
    with {:ok, commit} <- qory_commit(version),
         {:ok, template} <- qory_template(workspace, commit),
         :ok <- types_check(template),
         :ok <- Processes.validate(template.process) do
      {:ok, update(workspace, chosen, base, version, commit, template, :qory)}
    end
  end

  # The stored commit of `version`, else the commit a read of it gives now.
  defp qory_commit(version) do
    case Qory.version_commit(version) do
      commit when is_binary(commit) ->
        {:ok, commit}

      nil ->
        case Qory.read(version) do
          {:ok, commit} -> {:ok, commit}
          {:error, failure} -> {:error, {:qory, failure}}
        end
    end
  end

  defp qory_template(%Workspace{type: type}, commit) do
    case Qory.template(commit) do
      %{type: ^type} = template -> {:ok, Map.put(template, :module, Qory.template_module())}
      _none -> {:error, :no_template}
    end
  end

  defp types_check(template) do
    case TemplateTypes.check(template) do
      :ok -> :ok
      {:error, refusals} -> {:error, {:types, refusals}}
    end
  end

  defp read_repository(scope, workspace, chosen, base, version) do
    in_use = Processes.harness_template(base)

    with true <- same_harness?(in_use, chosen) || {:error, :no_template},
         {:ok, source, _stack} <- chosen_source(workspace),
         {:ok, %{commit: commit} = read} <- templates(scope, source),
         {:ok, template} <- module_template(read, in_use["module"], workspace.type) do
      {:ok, update(workspace, chosen, base, version, commit, template, :repository)}
    end
  end

  defp chosen_source(workspace) do
    case Sources.chosen_source(workspace) do
      {:ok, source, stack} -> {:ok, %{source | narrowing: %{}}, stack}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  defp templates(scope, source) do
    case Sources.templates(scope, source) do
      {:ok, read} -> {:ok, read}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  defp module_template(read, module, type) do
    case Enum.find(read.templates, &(&1.module == module)) do
      %{type: ^type} = template ->
        {:ok, template}

      %{} ->
        {:error, :no_template}

      nil ->
        case Enum.find(read.not_readable, &(&1.module == module)) do
          %{reason: reason} -> {:error, {:not_readable, reason}}
          nil -> {:error, :no_template}
        end
    end
  end

  defp update(workspace, chosen, base, {kind, name} = version, commit, template, source) do
    %{
      source: source,
      git: chosen.git,
      version: version,
      commit: commit,
      in_use: in_use(base, chosen),
      base: base,
      document: template.process,
      changes: Processes.diff(base.document, template.process),
      added_types: added_types(workspace, template.artifact_types),
      stack: if(chosen.stack != template.stack, do: %{from: chosen.stack, to: template.stack}),
      artifact_types: template.artifact_types,
      template: %{
        "source" => Atom.to_string(source),
        "git" => chosen.git,
        "commit" => commit,
        "module" => template.module,
        "stack" => template.stack,
        "type" => template.type,
        "version" => nil,
        "ref_kind" => Atom.to_string(kind),
        "ref" => name
      }
    }
  end

  # The entries of `listed` the workspace does not have (`t:update/0`).
  defp added_types(_workspace, nil), do: []

  defp added_types(%Workspace{} = workspace, listed) when is_list(listed) do
    types = Artifacts.all_types(workspace)
    shown = for %Type{standard: true, shown: true, name: name} <- types, do: name
    custom = for %Type{standard: false, name: name} <- types, do: name
    standard = Type.standard_names()

    Enum.filter(listed, fn %{"name" => name} = entry ->
      if map_size(entry) == 1 and name in standard,
        do: name not in shown,
        else: name not in standard and name not in custom
    end)
  end

  @doc """
  save/4 saves `update`, from `read/2`, as a version of the scope's workspace (the
  moduledoc), in one transaction: the version (`Apiary.Processes.save_harness/5`), the
  artifact types the workspace does not have, each with its audit entry, the template's stack, under
  `harness.save` too, and, unless `opts` has `trial: true`, the switch Keep the process at
  the latest turned on. `{:ok, version}`; `{:error, :stale}` where the current version is
  no longer the one `update` compared with; `{:error, :shared}` for a stack to copy into
  the harness the organisation shares; `{:error, {:types, {:invalid, type, error}}}` for
  a custom type whose insert fails; or the errors of
  `Apiary.Processes.save_harness/5`.
  """
  @spec save(Scope.t(), %Workspace{}, update, keyword) ::
          {:ok, Version.t()} | {:error, term}
  def save(%Scope{} = scope, %Workspace{} = workspace, %{} = update, opts \\ []),
    do: save_update(scope, workspace, update, Keyword.get(opts, :trial, false), &keep_on/1)

  # The save of `update`; `after_save`, called with the workspace held, for the switch:
  # turned on by a person's save, and checked still on by the switch's update.
  defp save_update(scope, workspace, update, trial?, after_save) do
    Repo.transact(fn ->
      with {:ok, version} <-
             Processes.save_harness(scope, workspace, update.document, update.template,
               trial: trial?,
               based_on: update.base
             ),
           held = Repo.get!(Workspace, workspace.id),
           :ok <- if(trial?, do: :ok, else: after_save.(held)),
           :ok <- add_types(scope, held, update.artifact_types),
           :ok <- copy_stack(scope, held, update.stack) do
        {:ok, version}
      end
    end)
  end

  defp add_types(scope, workspace, listed) do
    case added_types(workspace, listed) do
      [] ->
        :ok

      added ->
        {standard, custom} = Enum.split_with(added, &(map_size(&1) == 1))

        with :ok <- show_standard(workspace, Enum.map(standard, & &1["name"])) do
          Enum.reduce_while(custom, :ok, fn entry, :ok ->
            case Artifacts.insert_template_type(scope, workspace, entry) do
              {:ok, _type} -> {:cont, :ok}
              {:error, _changeset} -> {:halt, {:error, {:types, {:invalid, entry["name"]}}}}
            end
          end)
        end
    end
  end

  # The standard types `names` shown too, in the order of `Type.standard_names/0`.
  defp show_standard(_workspace, []), do: :ok

  defp show_standard(%Workspace{shown_standard_types: shown} = workspace, names) do
    shown = Enum.filter(Type.standard_names() -- Type.always_on(), &(&1 in (shown ++ names)))

    {1, _rows} =
      Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
        set: [shown_standard_types: shown, updated_at: DateTime.utc_now()]
      )

    :ok
  end

  defp copy_stack(_scope, _workspace, nil), do: :ok

  defp copy_stack(scope, workspace, %{to: stack}) do
    with :ok <- stack_access(scope, workspace),
         do: Sources.put_template_stack(scope, workspace, stack)
  end

  defp stack_access(%Scope{instance: true, user: nil}, _workspace), do: :ok
  defp stack_access(scope, workspace), do: Access.authorize(scope, :"harness.save", workspace)

  defp keep_on(%Workspace{id: id}) do
    {1, _rows} =
      Repo.update_all(from(w in Workspace, where: w.id == ^id), set: [keep_process_latest: true])

    :ok
  end

  # A person's save of edits that came first, which the lock of the save waited for,
  # turned the switch off.
  defp still_on(%Workspace{keep_process_latest: false}), do: {:error, :stopped}
  defp still_on(%Workspace{}), do: :ok

  ## The switch's updates

  @doc """
  follow_all/0 saves a version of each workspace whose switch Keep the process at the
  latest is on and whose harness is the Qory harness on a branch, where the branch was at
  another commit when last read than the commit of its current version (the moduledoc).
  The refresh of the Qory harness calls it after its reads
  (Apiary.Harnesses.QoryRefresh), as the instance. A workspace whose update fails its
  checks, or fails, is one line in the log, and is tried again at the next refresh.
  `:ok`.
  """
  @spec follow_all() :: :ok
  def follow_all do
    if Features.on?(:workflow_model) do
      for workspace <- candidates() do
        case follow(workspace) do
          {:ok, _version_or_none} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "the process was not updated from the Qory harness workspace=#{workspace.id} " <>
                "reason=#{inspect(reason)}"
            )
        end
      end
    end

    :ok
  end

  # The workspaces in use whose switch is not turned off.
  defp candidates do
    Repo.all(
      from w in Workspace,
        join: o in Organisation,
        on: o.id == w.organisation_id,
        where: is_nil(w.deletion_marked_at) and is_nil(o.deletion_marked_at),
        where: is_nil(w.keep_process_latest) or w.keep_process_latest,
        order_by: w.inserted_at
    )
  end

  @doc false
  # follow/1 updates `workspace` from the Qory harness where its switch is on and the
  # branch moved (`follow_all/0`): `{:ok, version}`, `{:ok, nil}` where nothing is due,
  # or `{:error, reason}`.
  @spec follow(%Workspace{}) :: {:ok, Version.t() | nil} | {:error, term}
  def follow(%Workspace{} = workspace) do
    with {:qory, branch} <- following(workspace),
         true <- keep_latest?(workspace),
         head when is_binary(head) <- Qory.head({:branch, branch}),
         base = Processes.current(workspace),
         %{"source" => "qory", "commit" => in_use} when in_use != head <-
           Processes.harness_template(base) do
      update_to(workspace, base, branch, head)
    else
      _nothing_due -> {:ok, nil}
    end
  end

  defp update_to(workspace, base, branch, head) do
    chosen = Sources.chosen(workspace)

    with {:ok, template} <- qory_template(workspace, head),
         :ok <- types_check(template),
         :ok <- Processes.validate(template.process),
         :ok <- Processes.known_machine_types(template.process) do
      update = update(workspace, chosen, base, {:branch, branch}, head, template, :qory)
      organisation = Repo.get!(Organisation, workspace.organisation_id)
      scope = Scope.for_instance(organisation, workspace)
      scope = Scope.put_origin(scope, %{worker: "Apiary.Harnesses.QoryRefresh"})

      save_update(scope, workspace, update, false, &still_on/1)
    end
  end
end
