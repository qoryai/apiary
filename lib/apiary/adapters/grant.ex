defmodule Apiary.Adapters.Grant do
  # A grant of an organisation's connection to an adapter of the instance: the access the
  # adapter's source gives for one external account, which the adapter reports after a
  # person's linked connect return (the integration contract's `grant.schema.json`,
  # `Apiary.Adapters.Grants`). The table and its rules are
  # `20261025120000_keep_an_organisation_s_grants`'s.
  #
  # `grant_ref` is the adapter's ref to the grant, stable for its external account, which
  # Qory Apiary compares and stores and never parses. `account_ref` and `account_title`
  # are the external account's id at the source and its display name, as set by the
  # latest accepted report; nil for a grant reported before the contract had them
  # (`20261025160700_keep_a_grant_s_account_and_its_collections`) and not reported since.
  # `pass_nonce` is the 16 bytes of the nonce of the connect pass it was last reported
  # under. `state` is `:live` from `granted_at`, the time of the report Qory Apiary last
  # accepted for it, and `:ended` from `ended_at`, for `ended_reason`, which is final:
  # `:connection_ended` when its connection ended, `:adapter_reported` when the adapter
  # reported that the source no longer covers it (`POST /v1/grants/end`), which leaves
  # the connection. A report of the same ref under a newer pass of the same connection
  # replaces the live grant in place: its nonce, its account and `granted_at` change, its
  # id stays.
  #
  # `public_id` is its name outside the database: `ag_`, then sixteen lowercase Crockford
  # base32 characters, made once with it (`Apiary.PublicId`).
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use Ecto.Schema

  alias Apiary.Adapters.Connection
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation

  @typedoc "A grant of an organisation's connection to an adapter."
  @type t :: %__MODULE__{}

  @prefix "ag"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :public_id}
  schema "adapter_grants" do
    field :public_id, :string
    field :grant_ref, :string
    field :account_ref, :string
    field :account_title, :string
    field :state, Ecto.Enum, values: [:live, :ended]
    field :pass_nonce, :binary, redact: true
    field :granted_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :ended_reason, Ecto.Enum, values: [:connection_ended, :adapter_reported]

    belongs_to :organisation, Organisation
    belongs_to :adapter, Node
    belongs_to :connection, Connection

    timestamps(type: :utc_datetime_usec)
  end

  # The prefix of a grant's public id.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix
end
