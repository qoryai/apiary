defmodule ApiaryPro.Operators.OperatorInvitation do
  @moduledoc """
  An operator's invitation of its client's first owner: a row beside the core's
  invitation (`Apiary.Organisations.Invitation`), keyed by its `invitation_id`, written in
  the transaction that writes the invitation (`ApiaryPro.Operators.invite_owner/4`). Its
  person joins the client as its owner, where every other invitation makes a member
  (`ApiaryPro.Invitations`). `organisation_id` is the client, the invitation's
  organisation, and `operator_id` the operator that sent it. The row goes with the
  invitation, with the client and with the operator.
  """
  use Ecto.Schema

  @primary_key {:invitation_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "operator_invitations" do
    field :organisation_id, :binary_id
    field :operator_id, :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @typedoc "An operator's invitation of its client's first owner."
  @type t :: %__MODULE__{
          invitation_id: Ecto.UUID.t() | nil,
          organisation_id: Ecto.UUID.t() | nil,
          operator_id: Ecto.UUID.t() | nil
        }
end
