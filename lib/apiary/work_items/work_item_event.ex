defmodule Apiary.WorkItems.WorkItemEvent do
  # A work item event: one thing that happened to a work item, at `at`, kept in the order
  # it happened.
  #
  # `kind` is what happened: `:taken_in`, `:closed` or `:undone`. Who did it is
  # `actor_kind`, `:person`, `:adapter` or `:instance`, with `actor_id`, the person's
  # account or the adapter's node, and none for the instance. `data` is what else the
  # event says, a JSON object of 16,384 bytes at most as the database encodes it.
  #
  # An event is of its work item's workspace, held to it by the composite key, and goes
  # with it.
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @typedoc "One thing that happened to a work item."
  @type t :: %__MODULE__{}

  @typedoc "What happened to a work item."
  @type kind :: :taken_in | :closed | :undone

  @typedoc "Who did it: a person, an adapter or the instance."
  @type actor_kind :: :person | :adapter | :instance

  @kinds [:taken_in, :closed, :undone]
  @actor_kinds [:person, :adapter, :instance]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "work_item_events" do
    field :kind, Ecto.Enum, values: @kinds
    field :actor_kind, Ecto.Enum, values: @actor_kinds
    field :actor_id, :binary_id
    field :at, :utc_datetime_usec
    field :data, :map, default: %{}

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
  end

  # kinds/0 is every kind of event, as the database holds them.
  @doc false
  @spec kinds() :: [kind]
  def kinds, do: @kinds

  # actor_kinds/0 is every kind of actor, as the database holds them.
  @doc false
  @spec actor_kinds() :: [actor_kind]
  def actor_kinds, do: @actor_kinds

  # changeset/2 is the changeset of an event: its kind, who did it and when, and its data.
  # An actor of the instance has no id, and every other one has one. The database holds
  # the data to a JSON object of the bound the moduledoc names: an event it refuses is an
  # error on `data`.
  @doc false
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = event, attrs) do
    event
    |> cast(attrs, [:kind, :actor_kind, :actor_id, :at, :data])
    |> validate_required([:kind, :actor_kind, :at, :data])
    |> validate_actor()
    |> check_constraint(:data, name: :work_item_events_data_check)
    |> check_constraint(:actor_id, name: :work_item_events_actor_check)
  end

  defp validate_actor(changeset) do
    case get_field(changeset, :actor_kind) do
      :instance -> put_change(changeset, :actor_id, nil)
      nil -> changeset
      _person_or_adapter -> validate_required(changeset, [:actor_id])
    end
  end
end
