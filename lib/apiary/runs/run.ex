defmodule Apiary.Runs.Run do
  @moduledoc """
  A run as the workspace knows it: the projection of the run's events.

  `run_id` is the subject of the run's events, unique within the workspace. The row is
  created in state `pending` when the run registers (`Apiary.Runs.Registration`), or by
  the receiver on the first event of an unknown subject. The folded fields are folded
  from the events by the projector, so they can be rebuilt from `events` alone. The
  registration fields (`registered_at`, `registration_labels`, `registration_about`,
  `registration_digest`, `registration_interval_seconds`, `registration_answer_digest`)
  are the registration's own: written once, when the run registers, and kept by a
  rebuild.
  """
  use Ecto.Schema

  @typedoc "A run of a workspace."
  @type t :: %__MODULE__{}

  @states ~w(pending running completed failed cancelled lost)

  # The names a release before this one wrote, each with the state it reads as. The `CHECK`
  # on the column still allows them, so that rows an older release writes while a deploy
  # rolls out are stored, and every family and filter counts them as their new state.
  @old_states %{"succeeded" => "completed", "timed_out" => "cancelled", "ended" => "cancelled"}

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
    # When the last heartbeat counts as heard, by its own time and the clock offset below
    # (`Apiary.Runs.Liveness.heard_at/3`).
    field :last_heartbeat_at, :utc_datetime_usec
    field :elapsed_seconds, :integer
    field :heartbeat_interval_seconds, :integer
    # The smallest arrival less own time over the run's heartbeats, and for a run a gateway
    # opened its ping's, in milliseconds (`Apiary.Runs.Fold`); nil until the first.
    field :clock_offset_ms, :integer

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

    # The run's registration, as `Apiary.Runs.Registration` stored it: when it registered;
    # its labels, `about` and heartbeat interval as the body sent them (the interval holds
    # the run until its heartbeats say their own, `Apiary.Runs.Liveness`); the SHA-256 of
    # the body's bytes, by which a repeat of the same registration is told from another;
    # and the digest of the run configuration it was given, which a repeat is given again.
    # All nil for a run that did not register. Not folded: a rebuild keeps them.
    field :registered_at, :utc_datetime_usec
    field :registration_labels, :map
    field :registration_about, :map
    field :registration_digest, :binary
    field :registration_interval_seconds, :integer
    field :registration_answer_digest, :string

    has_many :events, Apiary.Runs.Event
    has_many :log_chunks, Apiary.Runs.LogChunk
    has_many :connections, Apiary.Runs.Connection

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Every state a run can be in: pending, running, completed, failed, cancelled and lost. The
  `CHECK` on the column also allows the old names `old_states/0` lists.
  """
  def states, do: @states

  @doc """
  The names a release before this one stored a state under, which the `CHECK` on the column
  still allows: `succeeded` reads as completed, `timed_out` and `ended` as cancelled
  (`current_state/1`).
  """
  def old_states, do: Map.keys(@old_states)

  @doc "The state a stored name reads as: an old name its new state, any other name itself."
  @spec current_state(String.t()) :: String.t()
  def current_state(state), do: Map.get(@old_states, state, state)

  @doc """
  `states` and every old name that reads as one of them, for a query of the stored column:
  a run an older release stored as `succeeded` counts and lists as completed.
  """
  @spec with_old_names([String.t()]) :: [String.t()]
  def with_old_names(states),
    do: states ++ for({old, new} <- @old_states, new in states, do: old)

  @doc "The states of a run that has not ended: the workspace counts these as alive."
  def alive_states, do: ~w(pending running)

  @doc "The states of a run that ended well: completed, its outcome a success."
  def ended_well_states, do: ~w(completed)

  @doc """
  The states of a run that was stopped before it said how it went: cancelled, by a person,
  by a rule such as its time limit, or because its work was no longer needed.
  """
  def cancelled_states, do: ~w(cancelled)

  @doc """
  The states of a run that ended badly: failed and lost. The four families, alive, ended
  well, cancelled and ended badly, are `Apiary.Runs.Filters.families/0`.
  """
  def ended_badly_states, do: ~w(failed lost)

  @doc """
  The days a lost run counts as lost recently, from its `lost_at`: the Overview lists it
  that long, and retention prunes nothing of it before (`Apiary.Retention`), so the record
  a gateway kept through a shorter outage still finds the run.
  """
  def lost_days, do: 7

  @doc """
  Whether the run was refused at its start and never started: failed with no exit time, as
  the fold stores a `dev.qory.run.refused` (`Apiary.Runs.Fold`), its `reason` the refusal's
  code, if it gave one. An exit decides over a refusal, so a run with an exit time is not.
  """
  @spec refused?(t() | map()) :: boolean()
  def refused?(%{state: "failed", exited_at: nil}), do: true
  def refused?(_run), do: false

  @doc "Whether a gateway opened the run, with no session: no runtime, command, host or terminal."
  @spec no_session?(t() | map()) :: boolean()
  def no_session?(%{opened_by: "gateway"}), do: true
  def no_session?(_run), do: false
end
