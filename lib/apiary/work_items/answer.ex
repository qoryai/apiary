defmodule Apiary.WorkItems.Answer do
  # An answer: what a member answered to one question a run of a take in of a work item
  # asked (`Apiary.WorkItems.Moves`), read by the take in's next run
  # (`Apiary.WorkItems.take_in_answers/2`) and shown on the work item's page.
  #
  # `take_in` and `attempt` name the run, `position` the question's place among its
  # questions, from 1, `question` the question as the run asked it and `answer` the
  # answer, each 1 to 2,000 characters, counted as code points. `answered_by_id` is the
  # member who answered, nil once their account's row is gone, and `answered_at` when.
  # One answer per work item, take in, attempt and position. An answer is of its work
  # item's workspace, held to it by the composite key, and follows it, as its events do.
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
    field :answered_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :answered_by, Apiary.Accounts.User
  end
end
