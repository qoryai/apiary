defmodule Apiary.WorkItems.Answer do
  # An answer: what a member answered to one question a run of a take in of a work item
  # asked, or a member's comment on the proposal a run of a take in wrote
  # (`Apiary.WorkItems.Moves`), read by the take in's next run
  # (`Apiary.WorkItems.take_in_answers/2`, `Apiary.WorkItems.take_in_changes/2`) and
  # shown on the work item's page.
  #
  # `take_in` and `attempt` name the run, `position` the question's place among its
  # questions, from 1, `question` the question as the run asked it, 1 to 20,000
  # characters, and `answer` the answer, 1 to 2,000 characters, both counted as code
  # points; `custom` is true for the member's text, false for the title of an option the
  # run offered. A comment has no `question` and no `custom`, `position` 1 and
  # `answer` its text, 1 to 2,000 characters; `proposal_version` is the version of the
  # proposal it is on, and once a saved update of the proposal read it, `done_version` is
  # that update's version and `done_at` when it was saved, both nil while it is open.
  # `answered_by_id` is the member who answered or commented, nil once their account's row
  # is gone, and `answered_at` when. One row per work item, take in, attempt and
  # position. A row is of its work item's workspace, held to it by the composite key,
  # and follows it, as its events do.
  @moduledoc false
  use Ecto.Schema

  @typedoc "An answer to one question of a run of a take in."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "work_item_answers" do
    field :take_in, :integer
    field :attempt, :integer
    field :position, :integer
    field :question, :string
    field :answer, :string
    field :custom, :boolean
    field :proposal_version, :integer
    field :done_version, :integer
    field :done_at, :utc_datetime_usec
    field :answered_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :answered_by, Apiary.Accounts.User
  end
end
