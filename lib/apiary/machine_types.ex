defmodule Apiary.MachineTypes do
  @moduledoc """
  The instance's machine types, which an instance admin keeps in Instance settings ›
  Machine types: each a name and a spec (`Apiary.MachineTypes.MachineType`), one of them
  the default. The name `default` means the default type, wherever a process document
  has a machine type.

  **Which type a run is on.** A workflow entry of a process document picks a type
  (`machine`), else the document's `machine`, the workspace's default, applies, else the
  instance's default type. When a run is queued, `resolve/1` reads the name of its type
  into the type's name and spec, and the run of the queue keeps both, so a later change
  of the type changes no queued run. A name no type has, after the type was deleted,
  resolves to the default type.

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
  """
  import Ecto.Query

  alias Apiary.Accounts.Scope
  alias Apiary.{Audit, InstanceConfig, Processes, Repo}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.MachineTypes.MachineType
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Processes.{TypeTemplate, Version}

  @reserved "default"

  @typedoc """
  A spec as the provisioner contract writes it, with string keys: `vcpus`, `memory_mib`,
  `disk_gib`, `arch` and `virtualization`.
  """
  @type spec :: %{String.t() => pos_integer | String.t() | boolean}

  @typedoc """
  A place that uses a type: a workspace's or a workspace type's process (`place`, its
  name), and the workflow of the entry that runs on it, nil for the document's default.
  """
  @type use :: %{place: String.t(), workflow: String.t() | nil}

  @doc "The name that means the instance's default type."
  @spec reserved() :: String.t()
  def reserved, do: @reserved

  @doc "Every type, in the order they were added."
  @spec list() :: [MachineType.t()]
  def list, do: Repo.all(from t in MachineType, order_by: [asc: t.inserted_at, asc: t.name])

  @doc "The default type, nil on an instance with none."
  @spec default_type() :: MachineType.t() | nil
  def default_type, do: Repo.one(from t in MachineType, where: t.is_default)

  @doc "The type named `name`, nil for none."
  @spec get(term) :: MachineType.t() | nil
  def get(name) when is_binary(name), do: Repo.get_by(MachineType, name: name)
  def get(_name), do: nil

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
  resolve/1 is the type that a run for the name `name` is queued on: `{name, spec}` of the
  type with that name, or of the default type for nil, `default` or a name no type has.
  `{"default", nil}` on an instance with no default type.
  """
  @spec resolve(String.t() | nil) :: {String.t(), spec | nil}
  def resolve(name) do
    case resolved(name) do
      %MachineType{} = type -> {type.name, spec(type)}
      nil -> {@reserved, nil}
    end
  end

  @doc """
  queued_on/1 is the machine type fields of a run queued for the name `name`
  (`resolve/1`): `machine_type` and `machine_spec`, and `machine_type_was_default`, true
  when the type is the default type, or when the instance has no default type.
  """
  @spec queued_on(String.t() | nil) :: %{
          machine_type: String.t(),
          machine_spec: spec | nil,
          machine_type_was_default: boolean
        }
  def queued_on(name) do
    case resolved(name) do
      %MachineType{} = type ->
        %{
          machine_type: type.name,
          machine_spec: spec(type),
          machine_type_was_default: type.is_default
        }

      nil ->
        %{machine_type: @reserved, machine_spec: nil, machine_type_was_default: true}
    end
  end

  defp resolved(name) when is_binary(name) and name != @reserved do
    Repo.one(
      from t in MachineType,
        where: t.name == ^name or t.is_default,
        order_by: [desc: fragment("? = ?", t.name, ^name)],
        limit: 1
    )
  end

  defp resolved(_name), do: default_type()

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
  unserved/2 is the name of the machine type of the newest run of the work item
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
         {name, _spec, _was_default?} = type <- run_type(run, default),
         false <- Enum.any?(pools, &takes?(&1, type, default)) do
      name
    else
      _served -> nil
    end
  end

  # A run's type and spec, and whether the type was the default when the run was queued;
  # the default's for a run queued before machine types.
  defp run_type(%DispatchRun{machine_spec: %{} = spec} = run, _default),
    do: {run.machine_type, spec, run.machine_type_was_default}

  defp run_type(%DispatchRun{}, %MachineType{} = default),
    do: {default.name, spec(default), true}

  defp run_type(%DispatchRun{}, nil), do: nil

  # The claim's rule (`Apiary.Dispatches.claim/4`): with offers, one of them fits the spec;
  # without, the run is of the default type, or was queued on the default of then.
  defp takes?(%Node{offers: offers}, {_name, spec, _was_default?}, _default)
       when is_list(offers),
       do: Enum.any?(offers, &fits?(&1, spec))

  defp takes?(%Node{}, {name, _spec, was_default?}, default),
    do: was_default? or match?(%MachineType{name: ^name}, default)

  ## What uses a type

  @doc """
  uses/1 is what uses the type named `name`, in each workspace's current or trial process
  and in the newest version of each workspace type's process: each workflow entry that
  runs on the type (`used_by/0`), and each document whose default is the type while every
  entry picks a type, as the document alone.
  """
  @spec uses(String.t()) :: [use]
  def uses(name) when is_binary(name) do
    for {^name, use} <- all_uses(), do: use
  end

  @doc """
  used_by/0 is the number of uses of each type, by its name, in the documents of `uses/1`.
  A workflow entry runs on the type it picks, else on its document's default, else on the
  instance's default type; an entry or a document whose type is `default` runs on the
  instance's default type, as a run queued for it does (`resolve/1`).
  """
  @spec used_by() :: %{String.t() => non_neg_integer}
  def used_by do
    all_uses() |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()
  end

  # Each use in the documents of `uses/1` with the name of its type, once.
  defp all_uses do
    default = with %MachineType{name: name} <- default_type(), do: name

    documents()
    |> Enum.flat_map(fn {place, document} -> uses_in(place, document, default) end)
    |> Enum.filter(&is_binary(elem(&1, 0)))
    |> Enum.uniq()
  end

  defp picked(name) when is_binary(name) and name != @reserved, do: name
  defp picked(_name), do: nil

  # Each process document that can start a run, with the name of its place: the
  # workspaces' current and trial versions, and each workspace type's newest version.
  defp documents do
    workspaces =
      Repo.all(
        from v in Version,
          join: w in Workspace,
          on: w.id == v.workspace_id,
          where: v.status in [:current, :trial] and is_nil(w.deletion_marked_at),
          order_by: [asc: w.name, asc: v.number],
          select: {w.name, v.document}
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
          do: {name || Processes.type_text_defaults(type).name, document}
  end

  # The uses of one document, `default` the name of the instance's default type, nil for
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

        {name, %{place: place, workflow: entry["workflow"]}}
      end

    if is_binary(document_type) and not Enum.any?(entries, &(elem(&1, 0) == document_type)),
      do: [{document_type, %{place: place, workflow: nil}} | entries],
      else: entries
  end

  defp uses_in(_place, _document, _default), do: []

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
  unknown/1 is the places in a process document whose machine type no type has: the
  document's `machine` and each workflow entry's, as `#/machine` and
  `#/stages/<i>/sequence/<j>/machine` or `…/loop/body/<k>/machine`. `default` and an
  absent value are known.
  """
  @spec unknown(map) :: [String.t()]
  def unknown(%{} = document) do
    names = MapSet.new(Repo.all(from t in MachineType, select: t.name))
    known? = &(&1 in [nil, @reserved] or MapSet.member?(names, &1))

    top = if known?.(document["machine"]), do: [], else: ["#/machine"]

    stages =
      for {%{} = stage, i} <- Enum.with_index(List.wrap(document["stages"])),
          {entry, j} <- Enum.with_index(List.wrap(stage["sequence"])),
          path <- entry_paths(entry, "#/stages/#{i}/sequence/#{j}"),
          do: path

    top ++ for({path, machine} <- stages, not known?.(machine), do: path)
  end

  defp entry_paths(%{"loop" => %{"body" => body}}, at) when is_list(body) do
    for {%{} = entry, k} <- Enum.with_index(body),
        do: {"#{at}/loop/body/#{k}/machine", entry["machine"]}
  end

  defp entry_paths(%{} = entry, at), do: [{"#{at}/machine", entry["machine"]}]
  defp entry_paths(_entry, _at), do: []

  ## Changes

  @doc """
  create/2 adds a type with `attrs`: `name`, `vcpus`, `memory_mib`, `disk_gib`, `arch`,
  `virtualization` and `is_default`, the default from then on when true. `{:ok, type}`;
  `{:error, changeset}`, with `:no_pool` on `:vcpus` for a spec no pool fits
  (`fitted?/2`); `{:error, :sudo}`; or `{:error, :forbidden}`.
  """
  @spec create(Scope.t() | nil, map) ::
          {:ok, MachineType.t()} | {:error, Ecto.Changeset.t() | :sudo | :forbidden}
  def create(scope, attrs) do
    with :ok <- InstanceConfig.authorize_save(scope) do
      changeset = MachineType.create_changeset(%MachineType{}, attrs)

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
  update/3 changes the spec of `type` to `attrs`, and makes it the default when
  `is_default` is true; its name stays. The results of `create/2`, and `{:error,
  :not_found}` for a type deleted since.
  """
  @spec update(Scope.t() | nil, MachineType.t(), map) ::
          {:ok, MachineType.t()}
          | {:error, Ecto.Changeset.t() | :sudo | :forbidden | :not_found}
  def update(scope, %MachineType{} = type, attrs) do
    with :ok <- InstanceConfig.authorize_save(scope) do
      transact(fn ->
        with {:ok, current} <- locked(type),
             changeset = MachineType.spec_changeset(current, attrs),
             {:ok, changeset} <- fitted(changeset),
             {:ok, updated} <- Repo.update(changeset),
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
             [] <- uses(current.name),
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
  that no type changes or goes while a save of a process document checks its types
  (`Apiary.Processes.known_machine_types/1`) and commits. A change of the types
  (`transact/1`) waits for the lock, and takes it before it reads what uses a type, so a
  deletion reads every document saved before it. Inside a transaction only.
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

  # The trail's entry of a change of a type: its name and spec before and after, nil for
  # none.
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
    do: type |> spec() |> Map.merge(%{"name" => type.name, "default" => type.is_default})

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
