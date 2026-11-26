defmodule Apiary.ModelChoices.Fallback do
  # A fallback of a model choice (`Apiary.ModelChoices.ModelChoice`): a model provider
  # (`connection_id`) whose keys runs use while every key of the choice's provider is in
  # cooldown, at its `position` among the choice's fallbacks, from 0, with the runtime its
  # runs use (`runtime`, a name of `Apiary.Kinds.Runtimes`, one the provider serves) and a
  # tier map (`tiers`) with every tier, as a choice at levels 4 to 6 has. A provider is
  # at most once among a choice's fallbacks, and never the choice's provider or a
  # provider of its key group (`Apiary.ModelKeys.Group`).
  #
  # Changed only through `Apiary.ModelChoices`, which writes a choice's fallbacks again
  # with each save of it.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A fallback of a model choice."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "model_choice_fallbacks" do
    field :position, :integer
    field :runtime, :string
    field :tiers, :map

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :model_choice, Apiary.ModelChoices.ModelChoice
    belongs_to :connection, Apiary.Connections.Connection

    timestamps(type: :utc_datetime_usec)
  end
end
