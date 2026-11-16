defmodule Apiary.Stages.Skip do
  # A workflow entry of a stage that the stage runner passed over, with no run, because
  # its condition was not met (`Apiary.Stages.Runner`). The condition is `{input: T}`, where
  # no version of `input` that the stage read had a file of more than 0 bytes, or
  # `{track: ID}`, where the work item is not on the track `track`; exactly one of `input`
  # and `track` is set. `negated` is true where the condition was an `unless` that held.
  # It has the take in, the
  # entry's position and its workflow, and `after_attempt`, the newest attempt of the take
  # in when the runner passed it over (0 for none), which places it among the runs on the
  # work item page. Nothing changes a skip once it is written.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A workflow entry passed over."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "stage_skips" do
    field :stage_id, :string
    field :take_in, :integer
    field :stage_entry, :integer
    field :loop_entry, :integer
    field :round, :integer
    field :workflow, :string
    field :input, :string
    field :track, :string
    field :negated, :boolean, default: false
    field :after_attempt, :integer
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :process_version, Apiary.Processes.Version
  end
end
