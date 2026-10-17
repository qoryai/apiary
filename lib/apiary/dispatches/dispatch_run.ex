defmodule Apiary.Dispatches.DispatchRun do
  # A run of the provisioner contract, waiting in its workspace's queue: one queue per
  # workspace, which any node pool of the workspace may claim from.
  #
  # `run_id` is the run's id, a UUID Qory gives it when it queues the run, unique on the
  # instance: the `run_id` the contract carries, and, once the run is handed over, the run
  # id of the run registered for it (`Apiary.Runs.Run`, whose `dispatch_run_id` names this
  # row). A run released before its handover with retry, or whose lease lapsed, waits
  # again with the same `run_id`; any other new run is a new row with a new one.
  #
  # `step` is the step the run is for, in the contract's pattern. `take_in` is the take in
  # of the work item the run is for, and `attempt` counts its runs within that take in,
  # from 1 to `of`: the database holds `1 <= attempt <= of`, and one row per work item,
  # take in and attempt.
  #
  # `state` is `:waiting`, `:claimed`, `:handed_over` or `:ended`. An ended run has its
  # end cause, `end_cause`, and only an ended one has it (`end_causes/0`). `queued_at`
  # orders the queue, oldest first.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @typedoc "A run of a workspace's queue."
  @type t :: %__MODULE__{}

  @states [:waiting, :claimed, :handed_over, :ended]
  # The causes a run of the queue, or a dispatch of one, ends for, and where each is named:
  # `released`, the starter's release (release.schema.json); `closed` and `undone`, its
  # work item closed or undone before its handover (refusal.schema.json, 410 gone);
  # `run_ended`, the run ended by its outcome or its exit after its handover, and a stale
  # dispatch with its run (handover.schema.json); `lost`, a handed-over run the liveness
  # check ended.
  @end_causes [:released, :closed, :undone, :run_ended, :lost]

  # The contract's step pattern, definitions.schema.json `$defs.step`.
  @step ~r/\A[a-z][a-z_]{0,39}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "dispatch_runs" do
    field :run_id, Ecto.UUID
    field :step, :string
    field :take_in, :integer
    field :attempt, :integer
    field :of, :integer
    field :state, Ecto.Enum, values: @states, default: :waiting
    field :end_cause, Ecto.Enum, values: @end_causes
    field :queued_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem

    has_many :dispatches, Apiary.Dispatches.Dispatch
    has_one :run, Apiary.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end

  # states/0 is every state a run of the queue can be in.
  @doc false
  @spec states() :: [atom]
  def states, do: @states

  # end_causes/0 is every cause a run of the queue, or a dispatch, ends for.
  @doc false
  @spec end_causes() :: [atom]
  def end_causes, do: @end_causes

  # queue_changeset/2 is the changeset of a new run of the queue: its work item, its step,
  # its take in, its attempt and the attempts it is of, and when it was queued, each
  # within the bounds above, waiting, with a fresh `run_id`. A value the database refuses
  # all the same is an error on its field. The organisation and the workspace are the
  # caller's to put.
  @doc false
  @spec queue_changeset(t, map) :: Ecto.Changeset.t()
  def queue_changeset(%__MODULE__{} = run, attrs) do
    run
    |> cast(attrs, [:work_item_id, :step, :take_in, :attempt, :of, :queued_at])
    |> validate_required([:work_item_id, :step, :take_in, :attempt, :of, :queued_at])
    |> validate_format(:step, @step)
    |> validate_number(:take_in, greater_than_or_equal_to: 1)
    |> validate_number(:of, greater_than_or_equal_to: 1)
    |> validate_number(:attempt, greater_than_or_equal_to: 1)
    |> validate_attempt()
    |> put_change(:run_id, Ecto.UUID.generate())
    |> put_change(:state, :waiting)
    |> check_constraint(:step, name: :dispatch_runs_step_check)
    |> check_constraint(:take_in, name: :dispatch_runs_take_in_check)
    |> check_constraint(:attempt, name: :dispatch_runs_attempt_check)
    |> unique_constraint(:run_id, name: :dispatch_runs_run_id_index)
    |> unique_constraint(:attempt, name: :dispatch_runs_work_item_id_take_in_attempt_index)
    |> foreign_key_constraint(:work_item_id, name: :dispatch_runs_work_item_id_fkey)
  end

  # At most `of`, in the words Ecto gives a bound.
  defp validate_attempt(changeset) do
    case get_field(changeset, :of) do
      of when is_integer(of) -> validate_number(changeset, :attempt, less_than_or_equal_to: of)
      _of -> changeset
    end
  end
end
