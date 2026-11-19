defmodule Apiary.Stages.Session do
  # A session of a run of a stage with `shared_run: true` (`Apiary.Processes.shared_run?/1`):
  # one row for each session the stage runner started in the run (`Apiary.Stages.next_session/2`).
  # `sequence` is Qory Apiary's number for the session in the run, from 1; the claim writes
  # the first, at the run's position (`Apiary.Stages.claim_sessions!/3`). `forager_session`,
  # `state` and `reason` are the session's end as the run reported it, nil until then.
  # `verdict_number` is the number of the run's newest `verdict` version at the step on
  # that end, so the next step reads only a newer one. `response` is the step's result, in
  # the form `next_session/2` returns it: `next` is `session`, with the next session's
  # members, or `end`. A row with a `response` is not written again.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A session of a shared run."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "shared_run_sessions" do
    field :sequence, :integer
    field :forager_session, :integer
    field :stage_entry, :integer
    field :loop_entry, :integer
    field :round, :integer
    field :workflow, :string
    field :state, :string
    field :reason, :string
    field :verdict_number, :integer
    field :response, :map

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :dispatch_run, Apiary.Dispatches.DispatchRun

    timestamps(type: :utc_datetime_usec)
  end
end
