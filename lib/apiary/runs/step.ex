defmodule Apiary.Runs.Step do
  @moduledoc """
  One step of a run's host work or of a session's join, such as a fetch, a compose or the
  start of a wall, folded from its `dev.qory.run.step_started` and its
  `dev.qory.run.step_exited` by `step`, its number in the run from 1. A projection:
  rebuilt from `events`.

  `name`, `kind`, `started_sequence` and `started_at` are the start's, nil until the start
  is folded; `kind` is `fetch`, `compose`, `image`, `setup`, `join` or `wall`, nil for any
  other value. `exit_code`, `duration_ms`, `exited_sequence` and `exited_at` are the
  exit's, nil until the exit is folded. `state` is `running` until then, and the exit's
  `succeeded`, `failed` or `cancelled` after. A step whose run's `dev.qory.run.exited` is
  folded without the step's exit is `cancelled` and keeps no exit
  (`Apiary.Runs.Projector`). The step's log lines are the run's log chunks with its number
  as `step` (`Apiary.Runs.Record.step_log/4`).
  """
  use Ecto.Schema

  @typedoc "One step of one run."
  @type t :: %__MODULE__{}

  @states ~w(running succeeded failed cancelled)
  @kinds ~w(fetch compose image setup join wall)

  @doc "The states a step can be in."
  def states, do: @states

  @doc "The kinds of step the contract lists."
  def kinds, do: @kinds

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "run_steps" do
    field :step, :integer
    field :name, :string
    field :kind, :string
    field :state, :string, default: "running"
    field :exit_code, :integer
    field :duration_ms, :integer
    field :started_sequence, :integer
    field :started_at, :utc_datetime_usec
    field :exited_sequence, :integer
    field :exited_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :run, Apiary.Runs.Run
  end
end
