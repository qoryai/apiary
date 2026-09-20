defmodule Apiary.Runs.Run do
  @moduledoc """
  A run as the hive knows it: the projection of the run's events.

  `run_id` is the subject of the run's events, unique within the hive. The row
  is created by the receiver on the first event of an unknown subject, in state
  `pending`; every other field is folded from the events by the projector, so
  the row can be rebuilt from `events` alone.
  """
  use Ecto.Schema

  @typedoc "A run of a hive."
  @type t :: %__MODULE__{}

  @states ~w(pending running succeeded failed timed_out lost closed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "runs" do
    field :run_id, Ecto.UUID

    field :forge, :string
    field :repository, :string
    field :task, :string
    field :labels, :map, default: %{}
    field :runtime, :string
    field :runtime_version, :string
    field :runner_version, :string
    field :contract_version, :integer
    field :command, :string
    field :args, {:array, :string}, default: []
    field :dir, :string
    field :interactive, :boolean
    field :host, :string
    field :wall, :string
    field :image, :string

    field :state, :string, default: "pending"
    field :started_at, :utc_datetime_usec
    field :exited_at, :utc_datetime_usec
    field :exit_code, :integer
    field :signal, :string
    field :reason, :string
    field :duration_ms, :integer

    field :last_event_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :elapsed_seconds, :integer
    field :heartbeat_interval_seconds, :integer

    field :policy_digest, :string
    field :run_configuration_digest, :string
    field :reported_run_configuration_digest, :string

    field :closed_at, :utc_datetime_usec
    field :lost_at, :utc_datetime_usec

    # Set by `Apiary.Retention` when it deleted the run's events, or its log bytes alone.
    field :events_pruned_at, :utc_datetime_usec
    field :log_pruned_at, :utc_datetime_usec

    field :event_count, :integer, default: 0
    field :denied_count, :integer, default: 0
    field :projected_sequence, :integer, default: 0

    # The cost the run reported: the sum of `cost_usd` over its session result events
    # (`Apiary.Runs.Fold`). Null until a result carried one; never zero for "unknown".
    field :cost_usd, :decimal

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    belongs_to :access_key, Apiary.AccessKeys.AccessKey
    belongs_to :repository_record, Apiary.Runs.Repository, foreign_key: :repository_id
    belongs_to :closed_by, Apiary.Accounts.User

    has_many :events, Apiary.Runs.Event
    has_many :log_chunks, Apiary.Runs.LogChunk
    has_many :connections, Apiary.Runs.Connection

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every state a run can be in, as the `CHECK` on the column lists them."
  def states, do: @states

  @doc "The states of a run that has not ended: the hive counts these as alive."
  def alive_states, do: ~w(pending running)

  @doc "The one state of a run that ended well."
  def ended_well_states, do: ~w(succeeded)

  @doc """
  The states of a run that ended badly: failed, timed out, lost and closed. A closed run
  was stopped by the hive, not by a failure of its own; it sits in this family so that
  every surface counts runs in the same three families (alive, ended well, ended badly).
  """
  def ended_badly_states, do: ~w(failed timed_out lost closed)
end
