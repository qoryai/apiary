defmodule Apiary.Runs.Run do
  @moduledoc """
  A run as the workspace knows it: the projection of the run's events.

  `public_id` is the run's id in Qory Apiary, `rn_` and sixteen characters
  (`Apiary.PublicId`): the console names and addresses a run by it,
  `/:org/:workspace/runs/:public_id`. The application sets it when it creates the row; the
  column's default, `run_public_id()`, is the same shape.

  `node_run_id` is the node's run id, an external id: the run's id as its node gave it,
  `run_id` and the subject of the run's events in the server contract, unique within the
  workspace. The row is
  created in state `pending` when the run registers (`Apiary.Runs.Registration`), or by
  the receiver on the first event of an unknown subject. The folded fields are folded
  from the events by the projector, so they can be rebuilt from `events` alone. The
  registration fields (`registered_at`, `registration_labels`, `registration_about`,
  `registration_digest`, `registration_interval_seconds`, `registration_answer_digest`,
  `registration_variables`) are the registration's: written once, when the run registers,
  and kept by a rebuild. A run that registered is projected from sequence 1, which its
  registration stands for (`projected_from/1`). A run that registered through a gateway
  keeps its run key and its attach beside them (`through_gateway?/1`), kept by a rebuild
  as well.
  """
  use Ecto.Schema

  @typedoc "A run of a workspace."
  @type t :: run()

  # The struct, whose fields include one of a feature the documentation does not differ by
  # (`docs: false`): the run of a workspace's queue a run is. A private type, so the served
  # docs show its name alone.
  @typep run :: %__MODULE__{}

  @states ~w(pending running completed failed cancelled lost)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :public_id}
  schema "runs" do
    field :public_id, :string, read_after_writes: true
    field :node_run_id, Ecto.UUID

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
    # What the run runs, from its last `session.started` (`Apiary.Runs.Fold`): `runtime`,
    # `runtime_version`, `command`, `args`, `dir`, `interactive` and `image`.
    field :runtime, :string
    field :runtime_version, :string
    field :forager_version, :string
    field :contract_version, :integer
    field :command, :string
    field :args, {:array, :string}, default: []
    field :dir, :string
    field :interactive, :boolean
    # The pseudo-terminal's size as the record last said it: the later by sequence of the
    # last `session.started`'s `terminal` and the last `run.resized`. Null on pipes, and
    # when Forager reported no size.
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
    field :duration_ms, :integer

    field :last_event_at, :utc_datetime_usec
    # When the last heartbeat counts as heard, by its own time and the clock offset below
    # (`Apiary.Runs.Liveness.heard_at/3`).
    field :last_heartbeat_at, :utc_datetime_usec
    field :elapsed_seconds, :integer
    field :heartbeat_interval_seconds, :integer
    # The smallest arrival less own time over the run's heartbeats, in milliseconds
    # (`Apiary.Runs.Fold`); nil until the first.
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
    # The node of the key the run's registration came with, and the node's instance id it
    # claimed: copied when the run is created and never moved, both nil for a key that names
    # no node.
    belongs_to :node, Apiary.Nodes.Node
    field :node_instance_id, :string
    belongs_to :target, Apiary.Runs.Target

    # The run's registration, as `Apiary.Runs.Registration` stored it: when it registered;
    # its labels, `about` and heartbeat interval as the body sent them (the interval the run
    # is held to, before its heartbeats', `Apiary.Runs.Liveness`); the SHA-256 of
    # the body's bytes, by which a repeat of the same registration is told from another;
    # and the digest of the run configuration it was given, which a repeat is given again.
    # All nil for a run that did not register. Not folded: a rebuild keeps them.
    field :registered_at, :utc_datetime_usec
    field :registration_labels, :map
    field :registration_about, :map
    field :registration_digest, :binary
    field :registration_interval_seconds, :integer
    field :registration_answer_digest, :string

    # The run variables Qory set for a run of a workspace's queue when it registered it,
    # each name with its value (`Apiary.Runs.RunVariables`): given to the run after its run
    # configuration's last member at its attach and at every reload it is answered, under
    # the stored configuration's digest (`Apiary.Runs.Attach`,
    # `Apiary.Runs.Registration.fetch/3`). Written once with the registration and never
    # changed; nil for every other run. Not folded: a rebuild keeps it.
    field :registration_variables, :map

    # The run settings Qory wrote for a run of a workspace's queue when it registered it
    # (`Apiary.Dispatches.RunSettings`), as its documents have them, with no key, and
    # the model provider the run uses: its row, its keys' secret's row, the value id of
    # its chosen key, its chain, and the API of the provider the run uses
    # (`provider_api`: `format`, `endpoint`, `auth` and, when the description lists them,
    # `key_prefixes`). Written once with the registration and never changed; nil for every
    # other run, and for an explore run with `factory` or `secrets` off. The provider
    # fields are nil where no provider was chosen, and the two rows become nil should they
    # be deleted. Not folded: a rebuild keeps them. The secret's row id, the key's value
    # id and the API are left out of the struct's inspection.
    field :run_settings, :map
    belongs_to :provider_connection, Apiary.Connections.Connection
    field :provider_secret_id, :binary_id, redact: true
    belongs_to :provider_secret, Apiary.Secrets.Secret, define_field: false
    field :provider_value_id, :string, redact: true
    field :provider_chain, :string
    field :provider_api, :map, redact: true

    # The run's outcome, as its starter gave it (`Apiary.Runs.Outcome`): its state,
    # `succeeded`, `failed` or `cancelled`, and its reason, nil when it gave none; the
    # `time` its body was built at, on the starter's clock; when this server took it; and
    # the SHA-256 of the body's bytes. A repeat, the same state and reason again, changes
    # none of them. All
    # nil for a run that was given none. Not folded: a rebuild keeps them, and the fold
    # reads them, so the outcome decides `state` and `reason` whenever it arrives
    # (`Apiary.Runs.Fold`).
    field :outcome_state, :string
    field :outcome_reason, :string
    field :outcome_time, :utc_datetime_usec
    field :outcome_received_at, :utc_datetime_usec
    field :outcome_digest, :binary

    # What the run's `dev.qory.run.exited` said, folded and kept beside an outcome, which
    # decides `state` and `reason` once there is one: the state the exit means
    # (`Apiary.Runs.Fold.exit_state/2`) and Forager's reason. Nil until an exit is folded.
    field :exit_state, :string
    field :exit_reason, :string

    # When the run's `dev.qory.run.refused` said it did not start, folded, and nil once an
    # exit decides over it, in whichever order the two are folded. The outcome leaves it as
    # it is: a run refused and then given an outcome still never started.
    field :refused_at, :utc_datetime_usec

    # A run that goes through a gateway (`Apiary.Runs.Registration`, `Apiary.Runs.Attach`):
    # the gateway its node's choice resolved to at its registration, nil should the
    # gateway's row be purged; the exact bytes of its run key's payload and its signature,
    # so a repeat is given the same run key, when the run key was made and the end of its
    # attach window; and, once the gateway attached it, when, the heartbeat interval it
    # announced, which the run is held to, the digest of the run configuration it was
    # given, which a repeat of the attach is given again, and the instance id of the
    # gateway that attached it, the one instance that may attach it again and send for it
    # (`Apiary.Runs.Sender`), nil until it is known. All nil for a direct run. Not folded: a
    # rebuild keeps them. The run key's payload and signature are redacted when a run is
    # inspected, so a log of a run never holds what its run key is assembled from.
    belongs_to :gateway, Apiary.Nodes.Node
    field :run_key_payload, :binary, redact: true
    field :run_key_signature, :binary, redact: true
    field :run_key_issued_at, :utc_datetime_usec
    field :attach_by, :utc_datetime_usec
    field :attached_at, :utc_datetime_usec
    field :attach_interval_seconds, :integer
    field :attach_answer_digest, :string
    field :gateway_instance_id, :string
    # A run registered with a run code (`Apiary.Runs.RunCode`), in place of a run key:
    # the code's SHA-256, never the code; when the code expires, 15 minutes after the
    # claim; what its run key grants, fixed at the claim; and the public key that redeemed
    # the code first, nil until then. Until the redemption the run has no run key
    # payload, its `run_key_issued_at` is the claim and its `attach_by` the code's
    # expiry; the redemption sets the run key's four fields and the public key together.
    # All nil for every other run. Not folded: a rebuild keeps them.
    field :run_code_sha256, :binary, redact: true
    field :run_code_expires_at, :utc_datetime_usec
    field :run_code_grant, :map
    field :run_code_public_key, :binary
    # For such a run: the timestamp of the proof of the newest accepted redemption of its
    # code, the first or a retry, in Unix seconds; a retry by the same public key needs a
    # newer one. Nil until the first redemption.
    field :run_code_proof_timestamp, :integer
    # For such a run: its documents, encoded at the claim, which every redemption of its
    # code answers byte for byte. Nil for every other run. Not folded.
    field :run_documents, :binary
    # With the `registry` feature: the SHA-256 of the registry credential the secrets
    # request sealed for the run's gateway last (`Apiary.Registry.Credential`), never the
    # credential; nil until then. Not folded: a rebuild keeps it.
    field :registry_credential_sha256, :binary, redact: true

    # The run of a workspace's queue this run is, set when its claim registers it, unique;
    # nil for every other run.
    belongs_to :dispatch_run, Apiary.Dispatches.DispatchRun
    # For such a run: `released_at`, when its starter released it after the handover,
    # which the run reads as cancelled with the reason `released` (`Apiary.Runs.Fold`).
    # Nothing writes it since a release after the handover is refused (`machine_exists`);
    # a run released before that keeps it. `backstop_at`, set at its attach: when the run
    # is lost should it have no exit by then (`Apiary.Runs.Liveness`); a run of the queue
    # takes no outcome. Nil for every other run. Not folded: a rebuild keeps them.
    field :released_at, :utc_datetime_usec
    field :backstop_at, :utc_datetime_usec
    # For such a run: when the lost-run check ended it for 600 s without a heartbeat and
    # moved its `backstop_at` back to the end of that silence (`Apiary.Dispatches.RunEnd`).
    # Nil for every other run. Not folded: a rebuild keeps it.
    field :silenced_at, :utc_datetime_usec
    # A run a node pool's claim registered whose machine never started it
    # (`Apiary.Dispatches.Handover.fail_start/3`): why, `start_failure`, one of
    # `start_failures/0`, and when, `start_failed_at`, set together; and the dispatch
    # whose claim registered it, `dispatch_id`, nil once the dispatch is deleted. The run
    # reads as failed with `start_failure` as its reason (`Apiary.Runs.Fold.settle/1`).
    # Nil for every other run. Not folded: a rebuild keeps them.
    field :start_failure, :string
    field :start_failed_at, :utc_datetime_usec
    belongs_to :dispatch, Apiary.Dispatches.Dispatch
    # For such a run, not a prebuild: the image its attach gave it, its pool's recorded
    # image for its target (`Apiary.Environments.image_for/2`), named at the top level of
    # every run configuration it is answered from then on
    # (`Apiary.Policy.ComposedConfiguration`). Nil for a run given none, and for every
    # other run. Not folded: a rebuild keeps it.
    field :configured_image, :string
    # Set at its attach, for every run that attaches: what the run started in, which its
    # reloads carry as the gateway checks it (`Apiary.Policy.ComposedConfiguration`).
    # `started_image_from` is `top_level`, the image beside the `security_policy`, the one
    # in `configured_image`; `policy`, the image the `security_policy` named; or `none`,
    # the gateway's default. `started_image` is the image, nil for `none`. Both nil for a
    # run that did not attach, whose reloads are answered as they were. Not folded.
    field :started_image_from, :string
    field :started_image, :string

    has_many :events, Apiary.Runs.Event
    has_many :log_chunks, Apiary.Runs.LogChunk
    has_many :connections, Apiary.Runs.Connection

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Every state a run can be in: pending, running, completed, failed, cancelled and lost. The
  `CHECK` on the column allows these six and no other.
  """
  def states, do: @states

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
  Why a run a node pool's claim registered never started (`start_failure`):
  `machine_not_made`, its pool's starter released its dispatch; `lease_lapsed`, the
  dispatch's lease lapsed before its handover; `machine_stopped`, the machine's log
  arrived before the machine redeemed the run's code. The `CHECK` on the column allows
  these three and no other.
  """
  def start_failures, do: ~w(machine_not_made lease_lapsed machine_stopped)

  @doc """
  Whether the run was refused at its start and never started: failed with no exit time, as
  the fold stores a `dev.qory.run.refused` (`Apiary.Runs.Fold`), its `reason` the refusal's
  code, if it gave one. An exit decides over a refusal, so a run with an exit time is not,
  and so does its starter's outcome, so a run given one is not either. A run whose
  machine never started it (`start_failure`) is failed with no exit time too, its
  `reason` that cause, and reads the same.
  """
  @spec refused?(t() | map()) :: boolean()
  def refused?(%{state: "failed", exited_at: nil} = run),
    do: is_nil(Map.get(run, :outcome_state))

  def refused?(_run), do: false

  @doc """
  Whether the run's state is its starter's outcome and says something other than its exit
  did: given an outcome, and either no exit folded yet, or one whose state differs
  (`exit_state`). A run whose outcome agrees with its exit reads as the exit alone, and so
  does one whose exit was folded before `exit_state` was kept, which has none.
  """
  @spec outcome_differs?(t() | map()) :: boolean()
  def outcome_differs?(%{outcome_state: outcome} = run) when is_binary(outcome) do
    case Map.get(run, :exited_at) do
      nil ->
        true

      _exited_at ->
        exit_state = Map.get(run, :exit_state)
        not is_nil(exit_state) and exit_state != Map.get(run, :state)
    end
  end

  def outcome_differs?(_run), do: false

  @doc """
  Whether the run goes through a gateway: its registration was given a run key, whatever
  has become of the gateway since.
  """
  # A run registered with a run code (`Apiary.Runs.RunCode`) goes through a gateway
  # before its code is redeemed too, with no run key payload until then.
  @spec through_gateway?(t() | map()) :: boolean()
  def through_gateway?(%{run_key_payload: payload}) when is_binary(payload), do: true
  def through_gateway?(%{run_code_sha256: hash}) when is_binary(hash), do: true
  def through_gateway?(_run), do: false

  @doc """
  The sequence a run's projection starts from: 1 for a run that registered, whose
  registration stands for the record's sequence 1, `dev.qory.run.registered`, which is
  never posted, as the ping did before it; 0 for a run its batches created.
  """
  @spec projected_from(map) :: 0 | 1
  def projected_from(%{registered_at: %DateTime{}}), do: 1
  def projected_from(_run), do: 0

  @doc "new_public_id/0 is a fresh `public_id` for a run: `rn_` and 16 characters."
  @spec new_public_id() :: String.t()
  def new_public_id, do: Apiary.PublicId.generate("rn")

  @doc "public_id?/1 says whether `value` is a run's `public_id` in shape, `rn_…`."
  @spec public_id?(term) :: boolean
  def public_id?(value), do: Apiary.PublicId.valid?("rn", value)
end
