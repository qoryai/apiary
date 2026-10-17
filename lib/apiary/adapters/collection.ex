defmodule Apiary.Adapters.Collection do
  # A collection an adapter's listing names through a connection (`Apiary.Adapters.Connection`):
  # a place at the source that items are listed from, such as a project or a board. The
  # table and its rules are `20261017170300_keep_an_adapter_s_collections`'s.
  #
  # `external_ref` is the adapter's ref for it, which the core compares and stores and
  # never reads meaning into; `url`, `title` and the target (`target_system`,
  # `target_path`, both or neither) are as the listing last gave them, and
  # `last_listed_at` is the `started_at` of the newest listing that named it. It is live
  # until `ended_at`, for `ended_reason`, which is final: `:disconnected`, `:not_listed`
  # (a complete listing left it out) or `:connection_ended`. One collection per adapter
  # and ref is live at a time. `workspace_id` is the one workspace it is linked to, or
  # none.
  #
  # `public_id` is its name outside the database: `sc_`, then sixteen lowercase Crockford
  # base32 characters, made once with it (`Apiary.PublicId`).
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use Ecto.Schema

  alias Apiary.Adapters.Connection
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
    field :last_listed_at, :utc_datetime
    field :ended_at, :utc_datetime_usec

    field :ended_reason, Ecto.Enum, values: [:disconnected, :not_listed, :connection_ended]

    belongs_to :organisation, Organisation
    belongs_to :adapter, Node
    belongs_to :connection, Connection
    belongs_to :workspace, Workspace

    timestamps(type: :utc_datetime_usec)
  end

  # The prefix of a collection's public id.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # Whether `id` is a collection's public id, in the shape `Apiary.PublicId` makes.
  @doc false
  @spec public_id?(term) :: boolean
  def public_id?(id), do: Apiary.PublicId.valid?(@prefix, id)
end
