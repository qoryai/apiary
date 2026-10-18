defmodule Apiary.Adapters.Connection do
  # An organisation's connection to an adapter of the instance (a node of kind `adapter`,
  # `na_…`), made when an owner or an admin of the organisation starts connecting it
  # (`Apiary.Adapters.connect/2`). The table and its rules are
  # `20261015131100_connect_an_organisation_to_an_adapter`'s, with `pass_expires_at` from
  # `20261016090500_keep_when_a_connection_s_latest_pass_expires`.
  #
  # `state` is where it stands: `:pending` from the start, `:connected` since
  # `connected_at`, once the person who started it came back with a return that says it
  # is linked, `:ended` from either, for `ended_reason`, which is final: `:replaced` when
  # a press of Install ended it and made a new connection in its place, either while it
  # was connected and no listing had named it yet, or while it was pending and its next
  # pass would have expired more than `Apiary.Adapters.ConnectPass.validity/0` seconds
  # ahead (`Apiary.Adapters.Connections.start/3`). `listed_at` is when the adapter's first
  # listing that names it was accepted, and `listing_completed_at` when a listing of it
  # last became complete (`Apiary.Adapters.Collections.post_listing/2`), from
  # `20261017145000_keep_when_a_connection_s_listing_completed`. `pass_nonce` is the 16
  # bytes of the nonce of the latest connect pass made for it, and `pass_nonce_used_at`
  # when a return under that nonce came back. `pass_expires_at` is when that latest pass expires, to the second, as
  # the pass says (`Apiary.Adapters.ConnectPass`), or `nil` for a connection made before
  # it was kept; each new pass of the connection expires strictly later than it, and no
  # more than `validity/0` seconds after it was made, else the connection is replaced
  # (`Apiary.Adapters.Connections.start/3`), so the adapter can always tell the newer
  # pass. `created_by_id` is the person who pressed Install for that latest pass. Once
  # connected, a connection takes no new pass: `pass_nonce`, `pass_expires_at`,
  # `created_by_id` and `connected_at` stay as they are; only `listed_at`,
  # `listing_completed_at` and the end may change.
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
  @type ended_reason ::
          :adapter_reported | :organisation_deleted | :integration_deleted | :replaced

  @prefix "ac"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :public_id}
  schema "adapter_connections" do
    field :public_id, :string
    field :state, Ecto.Enum, values: [:pending, :connected, :ended]
    field :pass_nonce, :binary, redact: true
    field :pass_nonce_used_at, :utc_datetime_usec
    field :pass_expires_at, :utc_datetime
    field :connected_at, :utc_datetime_usec
    field :listed_at, :utc_datetime_usec
    field :listing_completed_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    field :ended_reason, Ecto.Enum,
      values: [:adapter_reported, :organisation_deleted, :integration_deleted, :replaced]

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
