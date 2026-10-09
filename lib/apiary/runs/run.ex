defmodule Apiary.Runs.Run do
  @moduledoc """
  A run as the workspace knows it: the projection of the run's events.

  `run_id` is the subject of the run's events, unique within the workspace. The row
  is created by the receiver on the first event of an unknown subject, in state
  `pending`; every other field is folded from the events by the projector, so
  the row can be rebuilt from `events` alone.
  """
  use Ecto.Schema

  @typedoc "A run of a workspace."
  @type t :: %__MODULE__{}

  @states ~w(pending running succeeded ended failed timed_out lost)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "runs" do
    field :run_id, Ecto.UUID

    # The run's target as its labels named it (`Apiary.Lingo.Domain`): the system and the
    # path, kept on the run beside `target_id`, both nil when the labels name none.
    field :target_system, :string
    field :target_path, :string
    field :labels, :map, default: %{}
    # What the run said it is about: `about` of `run.started`, each member as the fold
    # kept it (`Apiary.Runs.Fold`), nil or empty when it said none. A subject is a map
    # with "type" and "ref", and "url" and "title" only when it carried them.
    field :about_kind, :string
    field :about_title, :string
    field :about_subjects, {:array, :map}, default: []
    field :about_details, :map
    # What opened the run, `opened_by` of `run.started`: "session", a Forager session around
    # a runtime, or "gateway", a gateway with no session, whose start says no runtime,
    # command or host and whose exit no state or exit code. Nil until a start says it.
    field :opened_by, :string
    field :runtime, :string
    field :runtime_version, :string
    field :forager_version, :string
    field :contract_version, :integer
    field :command, :string
    field :args, {:array, :string}, default: []
    field :dir, :string
    field :interactive, :boolean
    # The pseudo-terminal's size as the record last said it: `terminal` of `run.started`,
    # then each `run.resized`. Null on pipes, and when Forager reported no size.
    field :terminal_cols, :integer
    field :terminal_rows, :integer
    field :host, :string
    field :wall, :string
    field :image, :string

    field :state, :string, default: "pending"
    field :started_at, :utc_datetime_usec
    field :exited_at, :utc_datetime_usec
    field :exit_code, :integer
    field :signal, :string
    field :reason, :string
    # The quiet period the gateway applied, of an exit with the reason "quiet"; nil otherwise.
    field :quiet_seconds, :integer
    field :duration_ms, :integer

    field :last_event_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :elapsed_seconds, :integer
    field :heartbeat_interval_seconds, :integer

    field :policy_digest, :string
    field :run_configuration_digest, :string
    field :reported_run_configuration_digest, :string

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
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :access_key, Apiary.AccessKeys.AccessKey
    # The node of the key the run's ping came with, and the instance id that ping claimed:
    # copied when the run is created and never moved, both nil for a key that names no node.
    belongs_to :node, Apiary.Nodes.Node
    field :instance_id, :string
    belongs_to :target, Apiary.Runs.Target

    has_many :events, Apiary.Runs.Event
    has_many :log_chunks, Apiary.Runs.LogChunk
    has_many :connections, Apiary.Runs.Connection

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every state a run can be in, as the `CHECK` on the column lists them."
  def states, do: @states

  @doc "The states of a run that has not ended: the workspace counts these as alive."
  def alive_states, do: ~w(pending running)

  @doc """
  The states of a run that ended well: succeeded, and ended. A run ends `ended` when its exit
  says no state and a reason that is no failure (`Apiary.Runs.Fold.exit_state/2`): a run a
  gateway opened that was quiet, whose run credential expired or whose issuer reported it
  ended.
  """
  def ended_well_states, do: ~w(succeeded ended)

  @doc """
  The states of a run that ended badly: failed, timed out and lost. Every surface counts
  runs in the same three families (alive, ended well, ended badly).
  """
  def ended_badly_states, do: ~w(failed timed_out lost)

  @doc "Whether a gateway opened the run, with no session: no runtime, command, host or terminal."
  @spec no_session?(t() | map()) :: boolean()
  def no_session?(%{opened_by: "gateway"}), do: true
  def no_session?(_run), do: false
end
