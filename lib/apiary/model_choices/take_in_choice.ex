defmodule Apiary.ModelChoices.TakeInChoice do
  # The model choice a person sends with a take in of a work item, level 1, for every run
  # of that take in (`take_in`): the fields of an `Apiary.ModelChoices.ModelChoice`, and
  # `provider_chosen`, whether the take in chose a model provider. Removing the provider
  # sets `connection_id` to nil and keeps the rest, so a row with `provider_chosen` and no
  # `connection_id` chose a provider that is gone. Written by `Apiary.WorkItems` in the
  # take in's transaction, and never changed after.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A take in's model choice."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "take_in_model_choices" do
    field :take_in, :integer
    field :provider_chosen, :boolean, default: false
    field :value_id, :string
    field :model_id, :string
    field :effort, :string
    field :tiers, :map

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :connection, Apiary.Connections.Connection
    belongs_to :created_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
