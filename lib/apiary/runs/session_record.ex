defmodule Apiary.Runs.SessionRecord do
  @moduledoc """
  The record of one session of a run: one row for each Forager session number of a run
  (`session_number`, from 1), written by `Apiary.Runs.Sessions`. Unlike the run's other
  projections it is kept when `Apiary.Retention` deletes the run's events: the row is
  all that is left of what the session measured, and a rebuild writes it again but never
  deletes it.

  From the run and its place in the queue: `dispatch_run_id`, `work_item_id`, `target_id`,
  `stage_id`, `workflow` and `attempt` (`dispatch_runs.attempt`: a run that continues a
  paused run has the paused run's attempt plus 1). `stage_id`, `workflow` and `attempt`
  are nil for a run the queue did not start.

  From the events: `started_at` and `ended_at`, the times of the session's
  `dev.qory.session.started` and `dev.qory.session.exited`, nil until the event is
  projected, and nil for the end of a session that never ended; `model`, from the
  session's `dev.qory.runtime.started`, else the run's `run_settings` model; and, from the
  session's `dev.qory.runtime.result` events (`Apiary.Runs.Sessions`), `cost_usd`, the four
  token counts and `duration_ms` of the session's last result line that has them, `turns`,
  summed over the lines, and `error`, true when any line is an error. A value no result
  carried is nil, which means unknown and never 0.

  The `Apiary.Runs.SessionKeyWindow` rows of the session hold the utilization of each
  model key and window that the gateway's reports gave while the session ran.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @typedoc "The record of one session of one run."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "session_records" do
    field :stage_id, :string
    field :workflow, :string
    field :attempt, :integer
    field :session_number, :integer
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :turns, :integer
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cache_read_tokens, :integer
    field :cache_write_tokens, :integer
    field :cost_usd, :decimal
    field :model, :string
    field :error, :boolean, default: false

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :run, Apiary.Runs.Run
    belongs_to :dispatch_run, Apiary.Dispatches.DispatchRun
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :target, Apiary.Runs.Target

    has_many :key_windows, Apiary.Runs.SessionKeyWindow

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(stage_id workflow attempt session_number started_at ended_at duration_ms turns
             input_tokens output_tokens cache_read_tokens cache_write_tokens cost_usd model
             error dispatch_run_id work_item_id target_id)a

  @doc """
  The changeset of a record of a run: `attrs` are the record's fields, and the run's
  organisation, workspace and id are the caller's to put. Each count is 0 or more, the
  session's number and the attempt 1 or more; a value the database refuses all the same is
  an error on its field.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = record, attrs) do
    record
    |> cast(attrs, @fields)
    |> validate_required([:session_number])
    |> validate_number(:session_number, greater_than_or_equal_to: 1)
    |> validate_number(:attempt, greater_than_or_equal_to: 1)
    |> validate_number(:turns, greater_than_or_equal_to: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cache_read_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cache_write_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cost_usd, greater_than_or_equal_to: 0)
    |> unique_constraint(:session_number, name: :session_records_run_id_session_number_index)
    |> check_constraint(:session_number, name: :session_records_session_number_check)
    |> check_constraint(:attempt, name: :session_records_attempt_check)
    |> check_constraint(:turns, name: :session_records_turns_check)
    |> check_constraint(:duration_ms, name: :session_records_duration_check)
    |> check_constraint(:input_tokens, name: :session_records_tokens_check)
    |> check_constraint(:cost_usd, name: :session_records_cost_check)
  end
end
