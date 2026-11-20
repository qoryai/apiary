defmodule Apiary.Runs.Target do
  @moduledoc """
  What the workspace's runs change: one of an adapter's collections, by the adapter
  (`adapter_id`) and the adapter's ref of the collection (`collection_external_ref`), and,
  when the place has one, its address on a system (`system` and `path`, both or neither).
  Created the first time the workspace names it (`insert_new/3`): when a collection with a
  target is assigned to the workspace, or a claim forms a run of it. Unique per workspace
  on adapter and collection ref. A place that is not on a host, such as a support queue,
  has no address. The software domain calls a target a repository and its system a
  forge, and needs an address (`Apiary.Lingo.Domain.check_target/2`).

  `public_id` is the id Qory Apiary gives the target, `tg_` and 16 characters
  (`Apiary.PublicId`): its page is addressed by it, `/:org/:workspace/targets/tg_…`.
  `system` and `path` are the address the adapter sent, the labels a run of the target
  has (`Apiary.Lingo.Domain.target_labels/1`). `insert_new/3` sets the id when it creates
  the target; a row written without one gets the column's default, of the same shape,
  read back on insert.
  """

  # With the `factory` feature:
  # `further_repositories` are the paths in its system that its runs also read, after it,
  # in the order a person put them, empty for none: read through
  # `Apiary.Targets.further_repositories/1`, written whole through
  # `Apiary.Targets.set_further_repositories/3`, which checks them.
  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Apiary.{PublicId, Repo}
  alias Apiary.Adapters.Collection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.WorkItems.WorkItem

  @label_max 256
  # C0 and DEL, C1 (U+0085, the next line, among them), and the line and paragraph
  # separators: what ends a line somewhere, in a log, a YAML comment or a terminal.
  @control ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}\x{2028}\x{2029}]/u

  @doc "The most bytes a label that names a system or a path has."
  def label_max, do: @label_max

  @doc """
  A label as one that can name a target's system or path, or nil: a string of valid
  UTF-8, not empty, at most #{@label_max} bytes, with no control character (C0, DEL, C1
  with U+0085, U+2028, U+2029). A label is Forager's word. One that fails this is
  neither cleaned nor cut, since either would file the run under a target it did not
  name: the run is kept, with its labels as sent, and belongs to no target. Every domain's
  labelling rule asks here, and the projector and the wire (`Apiary.Policy.Serving`)
  both ask the domain, so they always pick the same target, or none.
  """
  @spec label(term) :: String.t() | nil
  def label(label) when is_binary(label) and label != "" and byte_size(label) <= @label_max do
    if String.valid?(label) and not Regex.match?(@control, label), do: label
  end

  def label(_label), do: nil

  @typedoc "A target the workspace's runs named."
  @type t :: %__MODULE__{}

  # Rows of one insert: nine parameters each, well below the 65,535 a query may carry.
  @insert_chunk 1_000

  @doc """
  Creates each of `targets` (`t:Apiary.Lingo.Domain.target/0`), by adapter and collection
  ref, with its address or none, in the workspace `workspace_id` of the organisation
  `organisation_id`, unless the workspace has it already. One seen before keeps its row,
  its public id and its `first_seen_at`, and takes the address given where it differs, so
  a target follows its collection to a new address. A caller passes the collection's
  address as it is now. With `on_conflict: :nothing` one seen before is left as it is,
  its address too. A new one is first seen now. The targets are inserted sorted by
  adapter and collection ref, once each, so two callers that name the same targets take
  them in the same order. The query is kept out of the query log (`log: false`), since
  the labels may be event data.
  """
  @spec insert_new(Ecto.UUID.t(), Ecto.UUID.t(), [Apiary.Lingo.Domain.target()],
          on_conflict: :nothing
        ) :: :ok
  def insert_new(organisation_id, workspace_id, targets, opts \\ []) when is_list(targets) do
    now = DateTime.utc_now()
    on_conflict = if opts[:on_conflict] == :nothing, do: :nothing, else: moved()

    targets
    |> Enum.map(&{{&1.adapter_id, &1.collection_external_ref}, {&1.system, &1.path}})
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.chunk_every(@insert_chunk)
    |> Enum.each(fn chunk ->
      PublicId.Insert.insert_all(
        __MODULE__,
        for {{adapter_id, ref}, {system, path}} <- chunk do
          %{
            id: Ecto.UUID.generate(),
            public_id: Apiary.PublicId.generate("tg"),
            organisation_id: organisation_id,
            workspace_id: workspace_id,
            adapter_id: adapter_id,
            collection_external_ref: ref,
            system: system,
            path: path,
            first_seen_at: now,
            inserted_at: now,
            updated_at: now
          }
        end,
        on_conflict: on_conflict,
        conflict_target: [:workspace_id, :adapter_id, :collection_external_ref],
        log: false
      )
    end)
  end

  # The update of a target seen before whose address differs from the one given.
  defp moved do
    from t in __MODULE__,
      where:
        fragment(
          "(?, ?) IS DISTINCT FROM (EXCLUDED.system, EXCLUDED.path)",
          t.system,
          t.path
        ),
      update: [
        set: [
          system: fragment("EXCLUDED.system"),
          path: fragment("EXCLUDED.path"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
  end

  @doc """
  The target as the contracts write it, `{collection, address?}`: the ref of its
  collection and, for a target with an address, `address` with its `system` and `path`.
  A target without an address has no `address` member.
  """
  @spec document(Apiary.Lingo.Domain.target()) :: Jason.OrderedObject.t()
  def document(%{collection_external_ref: ref, system: system, path: path})
      when is_binary(ref) do
    address =
      if is_binary(system) and is_binary(path),
        do: [{"address", Jason.OrderedObject.new([{"system", system}, {"path", path}])}],
        else: []

    Jason.OrderedObject.new([{"collection", ref} | address])
  end

  @doc """
  The query of the row of `target` in the workspace `workspace_id`, by its adapter and its
  collection ref.
  """
  @spec by_key(Ecto.UUID.t(), Apiary.Lingo.Domain.target()) :: Ecto.Query.t()
  def by_key(workspace_id, %{adapter_id: adapter_id, collection_external_ref: ref}) do
    from t in __MODULE__,
      where: t.workspace_id == ^workspace_id,
      where: t.adapter_id == ^adapter_id and t.collection_external_ref == ^ref
  end

  @doc """
  The id of the row of `target` in the workspace `workspace_id` of the organisation
  `organisation_id`, by its adapter and collection ref, made with `insert_new/4` where
  there is none. A row seen before keeps its address, also one another caller makes
  between the read and the insert (`on_conflict: :nothing`). Kept out of the query log
  (`log: false`), since the address may be event data.
  """
  @spec id_of(Ecto.UUID.t(), Ecto.UUID.t(), Apiary.Lingo.Domain.target()) :: Ecto.UUID.t()
  def id_of(organisation_id, workspace_id, %{} = target) do
    query = from(t in by_key(workspace_id, target), select: t.id)

    Repo.one(query, log: false) ||
      (
        :ok = insert_new(organisation_id, workspace_id, [target], on_conflict: :nothing)
        Repo.one!(query, log: false)
      )
  end

  @doc """
  The target of the run of a workspace's queue `dispatch_run_id`: its work item's target,
  else its prebuild's collection's; nil for none. Read without a lock, and kept out of
  the query log (`log: false`), since the address may be event data.
  """
  @spec dispatched(Ecto.UUID.t()) :: Apiary.Lingo.Domain.target() | nil
  def dispatched(dispatch_run_id) do
    Repo.one(
      from(d in DispatchRun,
        left_join: w in WorkItem,
        on: w.id == d.work_item_id,
        left_join: c in Collection,
        on: c.id == d.source_collection_id,
        where: d.id == ^dispatch_run_id,
        select: {w, c}
      ),
      log: false
    )
    |> case do
      {%WorkItem{} = work_item, _collection} ->
        WorkItem.target(work_item)

      {nil, %Collection{} = collection} ->
        Collection.target(collection)

      _none ->
        nil
    end
  end

  @doc """
  The id of the row in the workspace `workspace_id` of the target of the run of a
  workspace's queue `dispatch_run_id` (`dispatched/1`), by adapter and collection ref,
  whatever address the row has; nil for a run without a target, and for a target without
  a row.
  """
  @spec dispatched_id(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  def dispatched_id(workspace_id, dispatch_run_id) do
    case dispatched(dispatch_run_id) do
      %{} = target -> Repo.one(from(t in by_key(workspace_id, target), select: t.id), log: false)
      nil -> nil
    end
  end

  @doc """
  The id of the one target of the workspace `workspace_id` at the address `system` and
  `path`, as a run's labels name it; nil when no target or more than one has that
  address, since two targets of two collections can share one.
  """
  @spec id_at(Ecto.UUID.t(), String.t(), String.t()) :: Ecto.UUID.t() | nil
  def id_at(workspace_id, system, path) do
    case ids_at(workspace_id, [{system, path}]) do
      %{{^system, ^path} => id} -> id
      _none -> nil
    end
  end

  @doc """
  The ids of the targets of the workspace `workspace_id` at each of the addresses
  `addresses`, `{system, path}`: a map of each address that exactly one target has to that
  target's id. An address of no target, or of more than one, is left out.
  """
  @spec ids_at(Ecto.UUID.t(), [{String.t(), String.t()}]) :: %{
          {String.t(), String.t()} => Ecto.UUID.t()
        }
  def ids_at(_workspace_id, []), do: %{}

  def ids_at(workspace_id, addresses) do
    addresses = Enum.uniq(addresses)

    Repo.all(
      from(t in __MODULE__,
        join:
          p in fragment(
            "SELECT * FROM unnest(?::text[], ?::text[]) AS p(system, path)",
            ^Enum.map(addresses, &elem(&1, 0)),
            ^Enum.map(addresses, &elem(&1, 1))
          ),
        on: t.system == p.system and t.path == p.path,
        where: t.workspace_id == ^workspace_id,
        group_by: [t.system, t.path],
        having: count(t.id) == 1,
        select: {{t.system, t.path}, type(fragment("(array_agg(?))[1]", t.id), :binary_id)}
      ),
      log: false
    )
    |> Map.new()
  end

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "targets" do
    field :public_id, :string, read_after_writes: true
    field :collection_external_ref, :string
    field :system, :string
    field :path, :string
    field :first_seen_at, :utc_datetime_usec
    # The target's own mode of the security policy; nil follows the workspace's. Changed
    # through `Apiary.Policy.set_mode/3`.
    field :egress_mode, :string
    # The further repositories its runs also read, after it, in order; empty for none.
    # Written whole through `Apiary.Targets.set_further_repositories/3`.
    field :further_repositories, {:array, :string}, default: []

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :adapter, Apiary.Nodes.Node
    has_many :runs, Apiary.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end
end
