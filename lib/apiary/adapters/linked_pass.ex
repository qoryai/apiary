defmodule Apiary.Adapters.LinkedPass do
  # A connect pass of an organisation's connection to an adapter whose return came back
  # `linked` (`Apiary.Adapters.Connections.complete_return/4`): the adapter may report the
  # grant it linked under that pass, once, naming the pass's nonce
  # (`Apiary.Adapters.Grants.report/2`, the integration contract's `grant.schema.json`).
  # The table and its rules are `20261025120200_keep_each_linked_pass_of_a_connection`'s.
  #
  # `nonce` is the 16 bytes of the pass's nonce, `linked_at` when Qory Apiary accepted the
  # return, and `reported_at` when it accepted the grant report under that nonce, nil until
  # then. A row goes with its connection.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use Ecto.Schema

  alias Apiary.Adapters.Connection
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Repo

  @typedoc "A connect pass whose return came back linked."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "adapter_linked_passes" do
    field :nonce, :binary, redact: true
    field :linked_at, :utc_datetime_usec
    field :reported_at, :utc_datetime_usec

    belongs_to :organisation, Organisation
    belongs_to :adapter, Node
    belongs_to :connection, Connection
  end

  # Keeps the pass with `nonce` of `connection` as linked at `now`, inside the caller's
  # transaction, which holds the connection's row. A return is accepted once per nonce
  # (check 5 of the return), so the row is new.
  @doc false
  @spec insert(Connection.t(), <<_::128>>, DateTime.t()) :: {:ok, t} | {:error, term}
  def insert(%Connection{} = connection, <<_::128>> = nonce, %DateTime{} = now) do
    Repo.insert(%__MODULE__{
      organisation_id: connection.organisation_id,
      adapter_id: connection.adapter_id,
      connection_id: connection.id,
      nonce: nonce,
      linked_at: now
    })
  end
end
