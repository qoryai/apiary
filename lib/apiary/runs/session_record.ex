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
  session's `dev.qory.runtime.started`, nil when none says it (the run's settings are not
  what ran); and, from the session's `dev.qory.runtime.result` events (`Apiary.Runs.Sessions`),
  `cost_usd` and the four token counts of the session's last result line that has them,
  `turns` and `duration_ms`, each summed over the lines, and `error`, true when any line is
  an error. A value no result carried is nil, which means unknown and never 0.

  The `Apiary.Runs.SessionKeyWindow` rows of the session hold the utilization of each
  model key and window that the gateway's reports gave while the session ran.
  """
  use Ecto.Schema

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

    timestamps(type: :utc_datetime_usec)
  end
end
