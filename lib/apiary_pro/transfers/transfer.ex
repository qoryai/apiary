defmodule ApiaryPro.Transfers.Transfer do
  @moduledoc """
  A pending offer of an organisation's ownership (`ApiaryPro.Transfers`), one per organisation
  at most, deleted when it is accepted or withdrawn: the audit trail keeps what happened.

  - `:to_admin`: the ownership of an organisation whose owners are all suspended offered
    to one of its admins, `recipient_id`, who becomes an owner on accepting; always an
    instance admin's, the arbiter's (`arbitrated`, with its `reason`), for any
    organisation but the instance organisation. It names no operator: a client's is in the
    entry of the offer alone, so the purge of an operator a client has left takes no
    offer of it with it.

  `organisation_id` is the organisation key, and unique: one pending offer per organisation.
  Nothing is cast from a form: `ApiaryPro.Transfers` sets every field.
  """
  # Hidden (`ApiaryPro.Flags.transfers?/0`), so not in the published documentation:
  #
  # - `:to_operator`: an organisation that is no client offered to the operator
  #   `operator_id` by its owner; an owner of the operator accepts, and it becomes the
  #   operator's client.
  use Ecto.Schema

  @kinds [:to_admin, :to_operator]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "transfers" do
    field :kind, Ecto.Enum, values: @kinds
    field :arbitrated, :boolean, default: false
    field :reason, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :operator, Apiary.Organisations.Organisation
    belongs_to :recipient, Apiary.Accounts.User
    belongs_to :offered_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  # A kind of `kinds/0`. Hidden, as `:to_operator` is.
  @typedoc false
  @type kind :: :to_admin | :to_operator

  @typedoc "A pending offer."
  @type t :: %__MODULE__{}

  @doc "kinds/0 is the kinds of offer."
  @spec kinds() :: [kind]
  def kinds, do: @kinds
end
