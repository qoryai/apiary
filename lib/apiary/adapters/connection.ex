defmodule Apiary.Adapters.Connection do
  # An organisation's connection to an adapter of the instance (a node of kind `adapter`,
  # `na_…`), made when an owner or an admin of the organisation starts connecting it
  # (`Apiary.Adapters.connect/2`). The table and its rules are
  # `20261015131100_let_a_pool_be_served_by_an_adapter`'s.
  #
  # `state` is where it stands: `:pending` from the start, `:connected` once the adapter's
  # first listing names it after it was activated (`activated_at`, the person who started
  # it came back with a return that says it is linked), `:ended` from either, for
  # `ended_reason`, which is final. `pass_nonce` is the 16 bytes of the nonce of the
  # latest connect pass made for it, and `pass_nonce_used_at` when a return under that
  # nonce came back. `created_by_id` is the person who pressed Install last.
  #
  # `public_id` is its name outside the database: `ac_`, then sixteen lowercase Crockford
  # base32 characters, made once with it (`Apiary.PublicId`).
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use Ecto.Schema

  alias Apiary.Accounts.User
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation

  @typedoc "An organisation's connection to an adapter of the instance."
  @type t :: %__MODULE__{}

  @typedoc "Where a connection stands."
  @type state :: :pending | :connected | :ended

  @typedoc "Why a connection ended."
  @type ended_reason :: :adapter_reported | :organisation_deleted | :integration_deleted

  @prefix "ac"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :public_id}
  schema "adapter_connections" do
    field :public_id, :string
    field :state, Ecto.Enum, values: [:pending, :connected, :ended]
    field :pass_nonce, :binary, redact: true
    field :pass_nonce_used_at, :utc_datetime_usec
    field :activated_at, :utc_datetime_usec
    field :connected_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    field :ended_reason, Ecto.Enum,
      values: [:adapter_reported, :organisation_deleted, :integration_deleted]

    belongs_to :organisation, Organisation
    belongs_to :adapter, Node
    belongs_to :created_by, User

    timestamps(type: :utc_datetime_usec)
  end

  # The prefix of a connection's public id.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # Whether `id` is a connection's public id, in the shape `Apiary.PublicId` makes.
  @doc false
  @spec public_id?(term) :: boolean
  def public_id?(id), do: Apiary.PublicId.valid?(@prefix, id)
end
