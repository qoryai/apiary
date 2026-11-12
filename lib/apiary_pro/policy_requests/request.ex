defmodule ApiaryPro.PolicyRequests.Request do
  @moduledoc """
  A request an operator sends its clients for changes to their security policy
  (`ApiaryPro.PolicyRequests`): `changes`, the rules to add, change or remove and the mode,
  as `Apiary.Policy.requested_changes/1` validated them when the request was written, and
  `note`, why the operator's harness needs them. `organisation_id` is the operator's;
  `author_id` the person of the operator who wrote it. Each client it went to answers
  separately (`ApiaryPro.PolicyRequests.Answer`). `withdrawn_at` is when the operator withdrew
  it from the clients that had not answered.

  Nothing is cast from a form: `ApiaryPro.PolicyRequests` sets every field.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "policy_requests" do
    field :note, :string
    field :changes, :map
    field :withdrawn_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :author, Apiary.Accounts.User
    has_many :answers, ApiaryPro.PolicyRequests.Answer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @typedoc "A policy request."
  @type t :: %__MODULE__{}
end
