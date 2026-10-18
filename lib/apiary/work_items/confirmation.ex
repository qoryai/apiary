defmodule Apiary.WorkItems.Confirmation do
  # A confirmation: a member's confirmation of the proposal a run of a take in of a work
  # item made (`Apiary.WorkItems.Moves`), at most one per take in. It makes the work item
  # ready for Shape.
  #
  # `take_in` and `attempt` name the run. `result` is the run's result as Qory read it
  # (`Apiary.Explore.Result`), kept so the proposal outlives the run's events. `changes`
  # holds the fields the member changed before confirming, by name, empty for none:
  # `"complexity"` (`{"level", "reason"}`), `"understanding"`, `"scope_in"` and
  # `"scope_out"` (lists of entries) and `"approach"` (`Apiary.WorkItems.Proposal`).
  # `confirmed_by_id` is the member, nil once their account's row is gone, and
  # `confirmed_at` when. A confirmation is of its work item's workspace, held to it by the
  # composite key, and follows it, as its events do.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A member's confirmation of the proposal of a take in."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "work_item_confirmations" do
    field :take_in, :integer
    field :attempt, :integer
    field :result, :map
    field :changes, :map, default: %{}
    field :confirmed_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :confirmed_by, Apiary.Accounts.User
  end
end
