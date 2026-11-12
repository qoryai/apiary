defmodule ApiaryPro.PolicyRequests.Answer do
  @moduledoc """
  One client's answer to a policy request of its operator (`ApiaryPro.PolicyRequests`), one
  per request and client, `pending` from when the request is sent until:

  - `accepted`: made in the client's policy by `answered_by_id`, in the workspaces of
    `workspace_ids`;
  - `declined`: by `answered_by_id`, with an optional `reason`;
  - `withdrawn`: by the operator before the client answered, or when the client was
    dropped, `reason` `dropped`.

  `organisation_id` is the client's; `request_id` the operator's request. Nothing is cast
  from a form: `ApiaryPro.PolicyRequests` sets every field.
  """
  use Ecto.Schema

  @states [:pending, :accepted, :declined, :withdrawn]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "policy_request_answers" do
    field :state, Ecto.Enum, values: @states, default: :pending
    field :reason, :string
    field :workspace_ids, {:array, :binary_id}, default: []
    field :answered_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :request, ApiaryPro.PolicyRequests.Request
    belongs_to :answered_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @typedoc "A state of `states/0`."
  @type state :: :pending | :accepted | :declined | :withdrawn

  @typedoc "A client's answer."
  @type t :: %__MODULE__{}

  @doc "states/0 is the states of an answer: pending, accepted, declined or withdrawn."
  @spec states() :: [state]
  def states, do: @states
end
