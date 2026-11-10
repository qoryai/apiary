defmodule Apiary.ModelChoices.Fallback do
  # A fallback of a model choice (`Apiary.ModelChoices.ModelChoice`): a model provider
  # (`connection_id`) whose keys runs use while every key of the choice's provider is in
  # cooldown, at its `position` among the choice's fallbacks, from 0, with a model id
  # (`model_id`) and an effort value (`effort`), each empty for the provider's default
  # model and the runtime's default effort, as on the choice. A provider is at most once
  # among a choice's fallbacks, and never the choice's provider.
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
    field :model_id, :string
    field :effort, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :model_choice, Apiary.ModelChoices.ModelChoice
    belongs_to :connection, Apiary.Connections.Connection

    timestamps(type: :utc_datetime_usec)
  end
end
