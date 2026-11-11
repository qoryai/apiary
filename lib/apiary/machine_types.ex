defmodule Apiary.MachineTypes do
  @moduledoc """
  The instance's machine types, which an instance admin keeps in Instance settings ›
  Machine types: each a key, a name and a spec (`Apiary.MachineTypes.MachineType`), one of
  them the default. Process documents, stages and runs use a type by its key; the key
  `default` means the default type, wherever a process document has a machine type. A
  type sets the size of the machine a run starts on, and no image.

  **Which type a run is on.** A workflow entry of a process document picks a type
  (`machine`), else the document's `machine`, the workspace's default, applies, else the
  instance's default type. When a run is queued, `resolve/1` reads the key of its type
  into the type's key and spec, and the run of the queue keeps both, so a later change
  of the type changes no queued run. A key no type has resolves to the default type.

  **Pools.** A node pool's claim may have `offers`, the machines it can start (the
  provisioner contract's `$defs/machine_spec`); the pool keeps those of its latest claim
  (`nodes.offers`). A pool with offers serves a type when one of the offers fits it
  (`fits?/2`); a pool with none serves the default type alone. A type that no pool with
  offers fits is refused while any pool has offers. On an instance where no pool has
  offers, such as a fresh one with no pools, no type is refused for that reason.

  **Changes** are the instance admin's, after a recent sign-in, as a change of the
  instance's settings is (`Apiary.InstanceConfig.authorize_save/1`), and each one is an
  `instance.configure` entry in the trail of the instance's organisation, with the type
  before and after. A type that a process document uses is kept, and so is the default.

  **A key change** (`update/3`) breaks every file that uses the key. In its transaction,
  each workspace's current and trial process that uses the key gets a new version with the
  key changed (`Apiary.Processes.rekey_machine/3`), and so does the newest process of each
  workspace type that an instance admin saved
  (`Apiary.Processes.TypeTemplates.rekey_machine/3`). A workspace type whose newest
  process is a copy of the Qory harness's keeps that copy, with the key of before: its
  runs start on the default type until the harness changes the key. Each run that waits
  in the queue on the key gets the key of after, and the new version where its version
  got one, so a pool claims it as before. Past versions, the runs that started or ended,
  and their dispatches keep the key of before. `key_change/1` counts what the change
  updates, the runs that wait on the key among them, lists the Qory harness's
  `process.yaml` files that the instance admin fixes, and counts the files that each
  organisation fixes in its harness repositories, with no workspace, workflow or
  repository of an organisation.
  """
  import Ecto.Query

  alias Apiary.Accounts.Scope
  alias Apiary.{Audit, InstanceConfig, Processes, Repo}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.MachineTypes.MachineType
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Processes.{TypeTemplate, TypeTemplates, Version}

  @reserved "default"

  @typedoc """
  A spec as the provisioner contract writes it, with string keys: `vcpus`, `memory_mib`,
  `disk_gib`, `arch` and `virtualization`.
  """
  @type spec :: %{String.t() => pos_integer | String.t() | boolean}

  @typedoc """
  A place that uses a type: a workspace's or a workspace type's process (`place`, its
  name), the organisation of the workspace (`organisation_id`), nil for a workspace type,
  and the workflow of the entry that runs on it, nil for the document's default.
  """
  @type use :: %{
          place: String.t(),
          organisation_id: Ecto.UUID.t() | nil,
          workflow: String.t() | nil
        }

  @doc "The key that means the instance's default type."
  @spec reserved() :: String.t()
  def reserved, do: @reserved

  @doc "Every type, in the order they were added."
  @spec list() :: [MachineType.t()]
  def list, do: Repo.all(from t in MachineType, order_by: [asc: t.inserted_at, asc: t.key])

  @doc "The default type, nil on an instance with none."
  @spec default_type() :: MachineType.t() | nil
  def default_type, do: Repo.one(from t in MachineType, where: t.is_default)

  @doc "The type of the key `key`, nil for none."
  @spec get(term) :: MachineType.t() | nil
  def get(key) when is_binary(key), do: Repo.get_by(MachineType, key: key)
  def get(_key), do: nil

  @doc "The spec of `type`, as the provisioner contract writes it."
  @spec spec(MachineType.t()) :: spec
  def spec(%MachineType{} = type) do
    %{
      "vcpus" => type.vcpus,
      "memory_mib" => type.memory_mib,
      "disk_gib" => type.disk_gib,
      "arch" => type.arch,
      "virtualization" => type.virtualization
    }
  end

  @doc """
  resolve/1 is the type that a run for the key `key` is queued on: `{key, spec}` of the
  type with that key, or of the default type for nil, `default` or a key no type has.
  `{"default", nil}` on an instance with no default type.
  """
  @spec resolve(String.t() | nil) :: {String.t(), spec | nil}
  def resolve(key) do
    case resolved(key) do
      %MachineType{} = type -> {type.key, spec(type)}
      nil -> {@reserved, nil}
    end
  end

  @doc """
  queued_on/1 is the machine type fields of a run queued for the key `key`
  (`resolve/1`): `machine_type` and `machine_spec`, and `machine_type_was_default`, true
  when the type is the default type, or when the instance has no default type.
  """
  @spec queued_on(String.t() | nil) :: %{
          machine_type: String.t(),
          machine_spec: spec | nil,
          machine_type_was_default: boolean
        }
  def queued_on(key) do
    case resolved(key) do
      %MachineType{} = type ->
        %{
          machine_type: type.key,
          machine_spec: spec(type),
          machine_type_was_default: type.is_default
        }

      nil ->
        %{machine_type: @reserved, machine_spec: nil, machine_type_was_default: true}
    end
  end

  defp resolved(key) when is_binary(key) and key != @reserved do
    Repo.one(
      from t in MachineType,
        where: t.key == ^key or t.is_default,
        order_by: [desc: fragment("? = ?", t.key, ^key)],
        limit: 1
    )
  end

  defp resolved(_key), do: default_type()

  @doc """
  fits?/2 is whether a machine of the spec `offer` fits the spec `spec`, by the provisioner
  contract's rule: `vcpus`, `memory_mib` and `disk_gib` each at least the spec's, the same
  `arch`, and `virtualization` where the spec has it.
  """
  @spec fits?(spec, spec) :: boolean
  def fits?(%{} = offer, %{} = spec) do
    offer["vcpus"] >= spec["vcpus"] and offer["memory_mib"] >= spec["memory_mib"] and
      offer["disk_gib"] >= spec["disk_gib"] and offer["arch"] == spec["arch"] and
      (offer["virtualization"] == true or spec["virtualization"] != true)
  end

  @doc "The node pools of the instance that are not deleted, by name."
  @spec pools() :: [Node.t()]
  def pools do
    Repo.all(
      from n in Node,
        where: n.kind == :pool and is_nil(n.deleted_at),
        order_by: [asc: n.name, asc: n.id]
    )
  end

  @doc """
  serves?/2 is whether the pool `pool` serves the type `type`: one of its offers fits the
  type, or it has none and the type is the default.
  """
  @spec serves?(Node.t(), MachineType.t()) :: boolean
  def serves?(%Node{offers: offers}, %MachineType{} = type) when is_list(offers),
    do: Enum.any?(offers, &fits?(&1, spec(type)))

  def serves?(%Node{}, %MachineType{is_default: default?}), do: default?

  @doc """
  fitted?/2 is whether a type of the spec `spec` may be kept, given the pools `pools`:
  while any pool has offers, one of them fits it; with none, any spec may.
  """
  @spec fitted?(spec, [Node.t()]) :: boolean
  def fitted?(spec, pools) do
    case for(%Node{offers: offers} <- pools, is_list(offers), offer <- offers, do: offer) do
      [] -> not Enum.any?(pools, &is_list(&1.offers))
      offers -> Enum.any?(offers, &fits?(&1, spec))
    end
  end

  @doc """
  unserved/2 is the key of the machine type of the newest run of the work item
  `work_item_id` that waits in the queue, when no pool that serves the workspace's runs
  (the pools of the Machines set-up step) can take it by its type (`serves?/2`, the
  claim's rule); nil when one can, when no pool serves them, or when no run waits.
  """
  @spec unserved(%Workspace{}, Ecto.UUID.t()) :: String.t() | nil
  def unserved(%Workspace{} = workspace, work_item_id) when is_binary(work_item_id) do
    run =
      Repo.one(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item_id and r.state == :waiting,
          order_by: [desc: r.queued_at, desc: r.id],
          limit: 1
      )

    with %DispatchRun{} <- run,
         [_pool | _rest] = pools <- Apiary.WorkspaceSetup.serving_pools(workspace),
         default = default_type(),
         {key, _spec, _was_default?} = type <- run_type(run, default),
         false <- Enum.any?(pools, &takes?(&1, type, default)) do
      key
    else
      _served -> nil
    end
  end

  # A run's type and spec, and whether the type was the default when the run was queued;
  # the default's for a run queued before machine types.
  defp run_type(%DispatchRun{machine_spec: %{} = spec} = run, _default),
    do: {run.machine_type, spec, run.machine_type_was_default}

  defp run_type(%DispatchRun{}, %MachineType{} = default),
    do: {default.key, spec(default), true}

  defp run_type(%DispatchRun{}, nil), do: nil

  # The claim's rule (`Apiary.Dispatches.claim/4`): with offers, one of them fits the spec;
  # without, the run is of the default type, or was queued on the default of then.
  defp takes?(%Node{offers: offers}, {_name, spec, _was_default?}, _default)
       when is_list(offers),
       do: Enum.any?(offers, &fits?(&1, spec))

  defp takes?(%Node{}, {key, _spec, was_default?}, default),
    do: was_default? or match?(%MachineType{key: ^key}, default)

  ## What uses a type

  @doc """
  uses/1 is what uses the type of the key `key`, in each workspace's current or trial process
  and in the newest version of each workspace type's process: each workflow entry that
  runs on the type (`used_by/0`), and each document whose default is the type while every
  entry picks a type, as the document alone.
  """
  @spec uses(String.t()) :: [use]
  def uses(key) when is_binary(key) do
    for {^key, use} <- all_uses(), do: use
  end

  @doc """
  used_by/0 is the number of uses of each type, by its key, in the documents of `uses/1`.
  A workflow entry runs on the type it picks, else on its document's default, else on the
  instance's default type; an entry or a document whose type is `default` runs on the
  instance's default type, as a run queued for it does (`resolve/1`).
  """
  @spec used_by() :: %{String.t() => non_neg_integer}
  def used_by do
    all_uses() |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()
  end

  # Each use in the documents of `uses/1` with the key of its type, once.
  defp all_uses do
    default = with %MachineType{key: key} <- default_type(), do: key

    documents()
    |> Enum.flat_map(fn {place, document} -> uses_in(place, document, default) end)
    |> Enum.filter(&is_binary(elem(&1, 0)))
    |> Enum.uniq()
  end

  defp picked(name) when is_binary(name) and name != @reserved, do: name
  defp picked(_name), do: nil

  # Each process document that can start a run, with its place: the workspaces' current
  # and trial versions, by the workspace's name and organisation, and each workspace
  # type's newest version, by the type's name and no organisation.
  defp documents do
    workspaces =
      Repo.all(
        from v in Version,
          join: w in Workspace,
          on: w.id == v.workspace_id,
          where: v.status in [:current, :trial] and is_nil(w.deletion_marked_at),
          order_by: [asc: w.name, asc: v.number],
          select: {%{place: w.name, organisation_id: w.organisation_id}, v.document}
      )

    types =
      Repo.all(
        from t in TypeTemplate,
          distinct: t.type,
          order_by: [asc: t.type, desc: t.number],
          select: {t.type, t.name, t.document}
      )

    workspaces ++
      for {type, name, document} <- types,
          do:
            {%{place: name || Processes.type_text_defaults(type).name, organisation_id: nil},
             document}
  end

  # The uses of one document, `default` the key of the instance's default type, nil for
  # none: each entry with the type it runs on, and the document alone with the type it
  # picks as its default when no entry runs on that type.
  defp uses_in(place, %{} = document, default) do
    document_type = picked(document["machine"])
    inherited = document_type || default

    entries =
      for %{} = entry <- entries(document) do
        name =
          case entry["machine"] do
            @reserved -> default
            nil -> inherited
            picked -> picked
          end

        {name, Map.put(place, :workflow, entry["workflow"])}
      end

    if is_binary(document_type) and not Enum.any?(entries, &(elem(&1, 0) == document_type)),
      do: [{document_type, Map.put(place, :workflow, nil)} | entries],
      else: entries
  end

  defp uses_in(_place, _document, _default), do: []

  @doc """
  uses_key?/2 is whether the process document `document` has the key `key` as its
  `machine` or as a workflow entry's.
  """
  @spec uses_key?(term, String.t()) :: boolean
  def uses_key?(%{} = document, key) when is_binary(key),
    do: document["machine"] == key or Enum.any?(entries(document), &(&1["machine"] == key))

  def uses_key?(_document, _key), do: false

  @doc """
  rekey/3 is the process document `document` with the key `to` in each place that has the
  key `from`: its `machine` and each workflow entry's, a loop's body included.
  """
  @spec rekey(map, String.t(), String.t()) :: map
  def rekey(%{} = document, from, to) do
    case key_replaced(document, from, to) do
      %{"stages" => stages} = document when is_list(stages) ->
        %{document | "stages" => Enum.map(stages, &rekey_stage(&1, from, to))}

      document ->
        document
    end
  end

  defp rekey_stage(%{"sequence" => sequence} = stage, from, to) when is_list(sequence),
    do: %{stage | "sequence" => Enum.map(sequence, &rekey_entry(&1, from, to))}

  defp rekey_stage(stage, _from, _to), do: stage

  defp rekey_entry(%{"loop" => %{"body" => body} = loop} = entry, from, to) when is_list(body),
    do: %{entry | "loop" => %{loop | "body" => Enum.map(body, &key_replaced(&1, from, to))}}

  defp rekey_entry(entry, from, to), do: key_replaced(entry, from, to)

  defp key_replaced(%{"machine" => from} = map, from, to), do: %{map | "machine" => to}
  defp key_replaced(map, _from, _to), do: map

  @typedoc """
  A `process.yaml` of the Qory harness that uses a key: the repository's address
  without its scheme (`repository`), the module the file is in (`module`), the file's
  path in the repository (`path`), nil for a commit whose files are not kept, and the
  commit it was read at.
  """
  @type file :: %{
          repository: String.t(),
          module: String.t(),
          path: String.t() | nil,
          commit: String.t() | nil
        }

  @typedoc """
  The files of an organisation's harness repositories that use a key: the
  organisation's name (`name`) and the number of files (`files`).
  """
  @type organisation_files :: %{name: String.t(), files: pos_integer}

  @doc """
  key_change/1 is what a change of the key of `type` updates and breaks: `workspaces`,
  the number of workspaces with a current or trial process that uses the key;
  `templates`, the number of workspace types whose newest process, an instance admin's
  save, uses it and is rewritten; `waiting`, the number of runs that wait in the queue
  on it; `files`, the Qory harness's files that the instance admin fixes; and
  `organisations`, by organisation name, the number of files in the organisation's
  harness repositories that the organisation fixes.

  The files are each `process.yaml` that a current or trial process that uses the key
  was read from (`Apiary.Processes.harness_origin/1`: `git`, `module` and `commit`),
  where the version read from the file uses the key too, and the Qory harness's file at
  the commit `main` was at when it was last read where a workspace type's copy of it
  uses the key, one per repository, module and commit. A file of the Qory harness, read
  from its address or with the `source` `qory`, is in `files`; any other file counts for
  the organisation of each workspace whose process comes from it. Neither has a workspace's name, a workflow or the address of an
  organisation's repository, which an instance admin does not see across organisations.
  """
  @spec key_change(MachineType.t()) :: %{
          workspaces: non_neg_integer,
          templates: non_neg_integer,
          waiting: non_neg_integer,
          files: [file],
          organisations: [organisation_files]
        }
  def key_change(%MachineType{key: key}) do
    {qory, others} = key |> sources() |> Enum.split_with(&qory_source?/1)

    %{
      workspaces:
        key |> Processes.machine_key_versions() |> Enum.uniq_by(& &1.workspace_id) |> length(),
      templates: key |> TypeTemplates.machine_key_types() |> Enum.count(&is_nil(&1.release)),
      waiting: Repo.aggregate(waiting(key), :count),
      files: qory_files(qory),
      organisations: organisation_files(others)
    }
  end

  # Each harness file that a process using `key` was read from, with the template's
  # `source` and the organisation of the workspace, nil for a workspace type's copy of the
  # Qory harness. A version's harness file is in the list only where the version with that
  # file's `template` uses the key too: a key that a person's edit added later is in no
  # harness file.
  defp sources(key) do
    versions =
      for %Version{} = version <- Processes.machine_key_versions(key),
          %{template: %{"git" => git, "module" => module} = template, document: document} <-
            [Processes.harness_origin(version)],
          is_binary(git) and is_binary(module),
          uses_key?(document, key),
          do: {file_key(template), template["source"], version.workspace.organisation_id}

    versions ++ harness_copy(key)
  end

  defp file_key(template), do: {template["git"], template["module"], template["commit"]}

  # A file of the Qory harness: read from its address, or saved as the Qory harness's
  # (`source` "qory") at an address the instance had before.
  defp qory_source?({{git, _module, _commit}, source, _organisation_id}),
    do: source == "qory" or git == Apiary.Harnesses.Qory.git()

  defp qory_files(sources) do
    sources
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(fn {git, module, commit} ->
      %{repository: repository(git), module: module, path: file_path(commit), commit: commit}
    end)
    |> Enum.sort_by(&{&1.repository, &1.module, &1.commit})
  end

  defp organisation_files(sources) do
    counts =
      sources
      |> Enum.map(fn {file, _source, organisation_id} -> {file, organisation_id} end)
      |> Enum.uniq()
      |> Enum.frequencies_by(&elem(&1, 1))
      |> Map.delete(nil)

    Repo.all(from o in Organisation, where: o.id in ^Map.keys(counts), select: {o.id, o.name})
    |> Enum.map(fn {id, name} -> %{name: name, files: counts[id]} end)
    |> Enum.sort_by(&{&1.name, &1.files})
  end

  # The Qory harness's file at the commit `main` was at when it was last read, where the
  # newest process of a workspace type is a copy of it (`release` set) that uses `key`: a
  # key change leaves such a copy as it is.
  defp harness_copy(key) do
    if Enum.any?(TypeTemplates.machine_key_types(key), &(&1.release != nil)) do
      git = Apiary.Harnesses.Qory.git()
      module = Apiary.Harnesses.Qory.template_module()
      [{{git, module, Apiary.Harnesses.Qory.current()}, "qory", nil}]
    else
      []
    end
  end

  # The path of the Qory harness's file in its repository, as its files kept at `commit`
  # resolve it (`Apiary.Harnesses.Qory.template_file/1`), nil for a commit with none kept.
  defp file_path(commit), do: Apiary.Harnesses.Qory.template_file(commit)

  # A git address as people write it: no scheme, no trailing slash, no `.git`.
  defp repository(git) do
    git
    |> String.replace(~r{\A[a-z][a-z0-9+.-]*://}, "")
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
  end

  @doc """
  entries/1 is every workflow entry of a process document, a loop's body included, in
  order.
  """
  @spec entries(map) :: [map]
  def entries(%{"stages" => stages}) when is_list(stages) do
    for %{} = stage <- stages,
        entry <- List.wrap(stage["sequence"]),
        entry <- body(entry),
        is_map(entry),
        do: entry
  end

  def entries(_document), do: []

  defp body(%{"loop" => %{"body" => body}}) when is_list(body), do: body
  defp body(entry), do: [entry]

  @doc """
  run_key/2 is the key a run of a workflow entry is queued for, given `key`, the entry's
  key, else its document's, and `workspace_key`, the document's key, the workspace's
  default: `key` where a type has it or where it is the reserved key `default`, which
  means the instance's default type; else `workspace_key` where a type has it; else the
  reserved key `default`. A key no type has stays in the document, and its runs start on
  the workspace's default type until a type has the key.
  """
  @spec run_key(String.t() | nil, String.t() | nil) :: String.t()
  def run_key(@reserved, _workspace_key), do: @reserved

  def run_key(key, workspace_key) do
    keys =
      Repo.all(
        from t in MachineType,
          where: t.key in ^Enum.filter([key, workspace_key], &is_binary/1),
          select: t.key
      )

    cond do
      key in keys -> key
      workspace_key in keys -> workspace_key
      true -> @reserved
    end
  end

  ## Changes

  @doc """
  create/2 adds a type with `attrs`: `key`, `name`, `vcpus`, `memory_mib`, `disk_gib`,
  `arch`, `virtualization` and `is_default`, the default from then on when true. `{:ok,
  type}`; `{:error, changeset}`, with `:no_pool` on `:vcpus` for a spec no pool fits
  (`fitted?/2`); `{:error, :sudo}`; `{:error, :not_found}` for anyone outside the
  instance's organisation; or `{:error, :forbidden}` for anyone else there but an
  instance admin.
  """
  @spec create(Scope.t() | nil, map) ::
          {:ok, MachineType.t()} | {:error, Ecto.Changeset.t() | :sudo | :not_found | :forbidden}
  def create(scope, attrs) do
    with :ok <- InstanceConfig.authorize_save(scope) do
      changeset =
        MachineType.create_changeset(%MachineType{}, attrs)

      transact(fn ->
        with {:ok, changeset} <- fitted(changeset),
             {:ok, type} <- Repo.insert(changeset),
             {:ok, type} <- defaulted(type, attrs),
             :ok <- record(scope, nil, type) do
          {:ok, type}
        end
      end)
    end
  end

  @doc """
  update/3 changes the key, the name and the spec of `type` to `attrs`, and
  makes it the default when `is_default` is true. A key change updates the processes that
  use the key, in the same transaction (the moduledoc). The results of `create/2`;
  `{:error, :not_found}` for a type deleted since; and `{:error, :stale}` where a
  workspace type's process was saved during the key change
  (`Apiary.Processes.TypeTemplates.rekey_machine/3`), after which nothing is written.
  """
  @spec update(Scope.t() | nil, MachineType.t(), map) ::
          {:ok, MachineType.t()}
          | {:error, Ecto.Changeset.t() | :sudo | :forbidden | :not_found | :stale}
  def update(scope, %MachineType{} = type, attrs) do
    with :ok <- InstanceConfig.authorize_save(scope) do
      transact(fn ->
        with {:ok, current} <- locked(type),
             changeset = MachineType.changeset(current, attrs),
             {:ok, changeset} <- fitted(changeset),
             {:ok, updated} <- Repo.update(changeset),
             :ok <- rekeyed(scope, current, updated),
             {:ok, updated} <- defaulted(updated, attrs),
             :ok <- record(scope, current, updated) do
          {:ok, updated}
        end
      end)
    end
  end

  @doc """
  make_default/2 makes `type` the default, and the type that was the default no longer
  one. The results of `update/3`.
  """
  @spec make_default(Scope.t() | nil, MachineType.t()) ::
          {:ok, MachineType.t()} | {:error, :sudo | :forbidden | :not_found}
  def make_default(scope, %MachineType{} = type) do
    with :ok <- InstanceConfig.authorize_save(scope) do
      transact(fn ->
        with {:ok, current} <- locked(type),
             {:ok, updated} <- defaulted(current, %{is_default: true}),
             :ok <- record(scope, current, updated) do
          {:ok, updated}
        end
      end)
    end
  end

  @doc """
  delete/2 deletes `type`. `{:ok, type}`; `{:error, :default}` for the default type;
  `{:error, {:in_use, uses}}` for a type that a process document uses (`uses/1`); or the
  refusals of `update/3`.
  """
  @spec delete(Scope.t() | nil, MachineType.t()) ::
          {:ok, MachineType.t()}
          | {:error, :default | {:in_use, [use]} | :sudo | :forbidden | :not_found}
  def delete(scope, %MachineType{} = type) do
    with :ok <- InstanceConfig.authorize_save(scope) do
      transact(fn ->
        with {:ok, current} <- locked(type),
             :ok <- if(current.is_default, do: {:error, :default}, else: :ok),
             [] <- uses(current.key),
             {:ok, deleted} <- Repo.delete(current),
             :ok <- record(scope, current, nil) do
          {:ok, deleted}
        else
          [_use | _rest] = uses -> {:error, {:in_use, uses}}
          other -> other
        end
      end)
    end
  end

  @doc """
  hold/0 locks the table of types in `SHARE` mode until the caller's transaction ends, so
  that no type changes or goes while a save of a process document or a take in of a work
  item commits (Apiary.WorkItems.Moves). A change of the types (`transact/1`) waits for
  the lock, and takes it before it reads what uses a type, so a deletion and a key change
  read every document saved before them, and a take in that waits for a key change reads
  the version after it. Inside a transaction only.
  """
  @spec hold() :: :ok
  def hold do
    Repo.query!("LOCK TABLE machine_types IN SHARE MODE")
    :ok
  end

  # Changes of the types one at a time: the table is locked against other writers, so
  # two saves cannot leave two defaults, or delete a type a save makes the default.
  defp transact(fun) do
    Repo.transact(fn ->
      Repo.query!("LOCK TABLE machine_types IN SHARE ROW EXCLUSIVE MODE")
      fun.()
    end)
  end

  defp locked(%MachineType{id: id}) do
    case Repo.one(from t in MachineType, where: t.id == ^id, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      type -> {:ok, type}
    end
  end

  # The processes that use the key of before, with the key of after.
  defp rekeyed(_scope, %MachineType{key: key}, %MachineType{key: key}), do: :ok

  defp rekeyed(scope, %MachineType{key: from}, %MachineType{key: to}) do
    with :ok <- Processes.rekey_machine(scope, from, to),
         :ok <- TypeTemplates.rekey_machine(scope, from, to) do
      # The runs that wait in the queue on the key, which `key_change/1` counts: a claim
      # matches a run's type by its key.
      Repo.update_all(waiting(from), set: [machine_type: to, updated_at: DateTime.utc_now()])
      :ok
    end
  end

  # The runs of the queue that wait on the type of key `key`.
  defp waiting(key),
    do: from(r in DispatchRun, where: r.state == :waiting and r.machine_type == ^key)

  defp fitted(%Ecto.Changeset{valid?: false} = changeset),
    do: {:error, %{changeset | action: :validate}}

  defp fitted(changeset) do
    spec = changeset |> Ecto.Changeset.apply_changes() |> spec()

    if fitted?(spec, pools()),
      do: {:ok, changeset},
      else:
        {:error,
         changeset
         |> Ecto.Changeset.add_error(:vcpus, "no pool fits", validation: :no_pool)
         |> Map.put(:action, :validate)}
  end

  # The type made the default when `is_default` in `attrs` is true, and the default
  # before it no longer one.
  defp defaulted(%MachineType{is_default: true} = type, _attrs), do: {:ok, type}

  defp defaulted(%MachineType{} = type, attrs) do
    if attrs[:is_default] == true or attrs["is_default"] in [true, "true"] do
      now = DateTime.utc_now()

      Repo.update_all(from(t in MachineType, where: t.is_default),
        set: [is_default: false, updated_at: now]
      )

      type |> Ecto.Changeset.change(is_default: true, updated_at: now) |> Repo.update()
    else
      {:ok, type}
    end
  end

  # The trail's entry of a change of a type: its key, name and spec before and
  # after, nil for none.
  defp record(scope, before, after_) do
    with {:ok, organisation} <- instance_organisation(),
         {:ok, _entry} <-
           Audit.record(
             Repo,
             Scope.in_organisation(scope, organisation),
             :"instance.configure",
             organisation,
             %{before: %{machine_type: stored(before)}, after: %{machine_type: stored(after_)}}
           ),
         do: :ok
  end

  defp stored(nil), do: nil

  defp stored(%MachineType{} = type),
    do:
      type
      |> spec()
      |> Map.merge(%{
        "key" => type.key,
        "name" => type.name,
        "default" => type.is_default
      })

  # The instance's organisation, whose trail has the entry; its owners are the instance's
  # admins.
  defp instance_organisation do
    with id when is_binary(id) <- Apiary.Edition.instance_organisation_id(),
         %Organisation{} = organisation <- Repo.get(Organisation, id) do
      {:ok, organisation}
    else
      _none -> {:error, :forbidden}
    end
  end
end
