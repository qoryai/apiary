defmodule Apiary.Adapters.Collection do
  # A collection an adapter's listing names through a connection (`Apiary.Adapters.Connection`):
  # a place at the source that items are listed from, such as a project or a board. The
  # table and its rules are `20261017141000_keep_an_adapter_s_collections`'s.
  #
  # `external_ref` is the adapter's ref for it, which the core compares and stores and
  # never reads meaning into; `url`, `title` and the target (`target_system`,
  # `target_path`, both or neither) are as the listing last gave them, and
  # `last_listed_at` is the `started_at` of the newest listing that named it.
  # `environment_ref` is the adapter's id of its environment definition, as that listing
  # gave it, compared and stored, never read; nil when that listing named it without one,
  # so it has none. It is live until `ended_at`, for `ended_reason`, which is final:
  # `:disconnected`, `:not_listed` (a complete listing left it out) or
  # `:connection_ended`. One collection per adapter and ref is live at a time.
  # `grant_id` is the grant of its connection (`Apiary.Adapters.Grant`) that covers it, as
  # set by the latest listing that had it; nil for a collection last listed before the
  # contract had it (`20261025160700_keep_a_grant_s_account_and_its_collections`). A
  # grant end ends the live collections whose `grant_id` is that grant, as a disconnect
  # ends them. `workspace_id` is the one workspace it is assigned to, or none. `backlog` is whether
  # its items come into that workspace's Backlog, on unless a person turned it off
  # (`Apiary.Adapters.Collections.set_backlog/3`, for a target, or
  # `Apiary.Adapters.Collections.set_collection_backlog/4`, for the collection alone,
  # with or without a target); it stays with the collection when it moves to another
  # workspace. `items` is false while the latest listing that named it said it has no
  # items; a listing that names it without `items` makes it true, and one that leaves it
  # out keeps it. A collection is linked while it is assigned to a
  # workspace, `backlog` is on, it has items and so does its adapter
  # (`Apiary.Nodes.Node`'s `items`) (`linked?/1`): the adapter mirrors it, and its items
  # and comments are taken. `backlog` keeps its value while the collection or its adapter
  # has no items.
  #
  # `public_id` is its name outside the database: `sc_`, then sixteen lowercase Crockford
  # base32 characters, made once with it (`Apiary.PublicId`).
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use Ecto.Schema

  alias Apiary.Adapters.{Connection, Grant}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}

  @typedoc "A collection an adapter's listing names."
  @type t :: %__MODULE__{}

  @typedoc "Why a collection ended."
  @type ended_reason :: :disconnected | :not_listed | :connection_ended

  @prefix "sc"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :public_id}
  schema "source_collections" do
    field :public_id, :string
    field :external_ref, :string
    field :url, :string
    field :title, :string
    field :target_system, :string
    field :target_path, :string
    field :environment_ref, :string
    field :last_listed_at, :utc_datetime
    field :ended_at, :utc_datetime_usec
    field :backlog, :boolean, default: true
    field :items, :boolean, default: true

    field :ended_reason, Ecto.Enum, values: [:disconnected, :not_listed, :connection_ended]

    belongs_to :organisation, Organisation
    belongs_to :adapter, Node
    belongs_to :connection, Connection
    belongs_to :grant, Grant
    belongs_to :workspace, Workspace

    timestamps(type: :utc_datetime_usec)
  end

  # The prefix of a collection's public id.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # Whether `collection`, with its adapter loaded, is linked: assigned to a workspace,
  # with its Backlog on, and with items, it and its adapter. An ended one is told apart by
  # its `ended_at`.
  @doc false
  @spec linked?(t) :: boolean
  def linked?(%__MODULE__{adapter: %Node{items: adapter_items}} = collection),
    do:
      is_binary(collection.workspace_id) and collection.backlog == true and
        collection.items == true and adapter_items == true

  # Whether `id` is a collection's public id, in the shape `Apiary.PublicId` makes.
  @doc false
  @spec public_id?(term) :: boolean
  def public_id?(id), do: Apiary.PublicId.valid?(@prefix, id)
end
