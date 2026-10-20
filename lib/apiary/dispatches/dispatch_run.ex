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
  # A run for the step `prebuild` (`prebuild_changeset/2`) has no work item and no take
  # in: it builds the environment of a collection's target (`source_collection_id`) for
  # one node pool of its workspace, `pool_id`, which alone may claim it, and names the
  # collection's `environment_ref` it was queued for. At most one waits per collection and
  # pool (`Apiary.Dispatches.queue_prebuild/3`). `environment_ref_at` is when it took that
  # `environment_ref`: when it was queued, and again whenever the ref changes while it
  # waits, or as it waits again with its environment record's `queued_ref`
  # (`Apiary.Dispatches.Slots`); `queued_at` stays as it was, so the ref's time is this.
  # Every other run is held for no pool and has none of the three
  # (`20261017160000_queue_prebuilds`).
  #
  # `state` is `:waiting`, `:claimed`, `:handed_over` or `:ended`. An ended run has its
  # end cause, `end_cause`, and only an ended one has it (`end_causes/0`). `end_detail` is
  # the refusal's code of a run ended `run_refused`, nil for any other. `queued_at`
  # orders the queue, oldest first.
  #
  # `result_outcome` is what the run gave once Qory reads it as decided
  # (`Apiary.Dispatches.Settle`, `result_outcomes/0`), and `result` the run's result, a
  # JSON object, for a `:proposal` or `:questions` only, until retention clears it
  # (`Apiary.Retention`). Only a run that is not a prebuild has an outcome: one ended
  # `run_ended`, once decided, and `:error` for one whose handover could not form it
  # (`Apiary.Dispatches.Handover`). Qory writes both; no changeset casts them
  # (`20261019001000_keep_what_a_run_of_the_queue_gave`).
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
  # check ended; `collection_ended`, the collection of a prebuild ended, was assigned to
  # none or to another workspace, has no target or no `environment_ref`, or its
  # connection ended, before its handover; `superseded`, a claimed prebuild whose lease
  # lapsed while another prebuild of its collection and pool waited or went back to
  # waiting (`Apiary.Dispatches.Slots`); `variables_invalid`, `ticket_gone` and
  # `inputs_invalid`, a claimed run whose handover could not form its run variables, its
  # work item's ticket, or the step's input (`Apiary.Dispatches.Handover`), 410 gone;
  # `prebuilt`, a prebuild handed over whose starter reported the image it built
  # (prebuilt.schema.json), its registered run left to its outcome; `provider_gone`,
  # `runtime_unserved`, `key_gone` and `model_gone`, a claimed explore run whose model
  # choice its handover could not form: its model provider is gone, fails its integrity
  # code, does not apply to the workspace, has a description the catalogue changed since
  # the provider was added, or has an endpoint address the endpoint rule refuses
  # (`provider_gone`); no longer serves the runtime (`runtime_unserved`); no longer has
  # the chosen key (`key_gone`); or no longer lists the chosen model or effort value
  # (`model_gone`) (`Apiary.Dispatches.RunSettings`), 410 gone; `secrets_not_allowed`, a
  # claimed explore run whose model choice has a provider, whose gateway has an active key
  # made without the stored-secrets flag (`allow_secrets`), so the gateway may not get
  # the run's model key (`Apiary.Dispatches.Handover`), 410 gone; `run_refused`, a run
  # its gateway refused before it started (`dev.qory.run.refused`), not queued again, with
  # the refusal's code kept as `end_detail` (`Apiary.Dispatches.RunEnd.refused/1`).
  @end_causes [
    :released,
    :closed,
    :undone,
    :run_ended,
    :lost,
    :collection_ended,
    :superseded,
    :variables_invalid,
    :ticket_gone,
    :inputs_invalid,
    :prebuilt,
    :provider_gone,
    :runtime_unserved,
    :key_gone,
    :model_gone,
    :secrets_not_allowed,
    :run_refused
  ]

  # What a run gave (`Apiary.Explore.Result.outcome/1`).
  @result_outcomes [:proposal, :questions, :error, :none, :refused]

  # The step that builds a collection's environment for a node pool.
  @prebuild "prebuild"

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
    field :end_detail, :string
    field :queued_at, :utc_datetime_usec
    field :environment_ref, :string
    field :environment_ref_at, :utc_datetime_usec
    field :result_outcome, Ecto.Enum, values: @result_outcomes
    field :result, :map

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :source_collection, Apiary.Adapters.Collection
    belongs_to :pool, Apiary.Nodes.Node

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

  # result_outcomes/0 is every outcome a run of the queue can have given.
  @doc false
  @spec result_outcomes() :: [atom]
  def result_outcomes, do: @result_outcomes

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

  # prebuild/0 is the step that builds a collection's environment for a node pool.
  @doc false
  @spec prebuild() :: String.t()
  def prebuild, do: @prebuild

  # prebuild_changeset/2 is the changeset of a new run of the queue for the step
  # `prebuild`: the collection whose target it builds, the node pool it is held for, the
  # collection's `environment_ref` it is queued for, 1 to 200 characters, and when it was
  # queued, which is when it took that ref (`environment_ref_at`), waiting, with a fresh
  # `run_id`. The organisation and the workspace are the
  # caller's to put.
  @doc false
  @spec prebuild_changeset(t, map) :: Ecto.Changeset.t()
  def prebuild_changeset(%__MODULE__{} = run, attrs) do
    run
    |> cast(attrs, [:source_collection_id, :pool_id, :environment_ref, :queued_at])
    |> validate_required([:source_collection_id, :pool_id, :environment_ref, :queued_at])
    |> validate_length(:environment_ref, min: 1, max: 200, count: :codepoints)
    |> then(&put_change(&1, :environment_ref_at, get_field(&1, :queued_at)))
    |> put_change(:step, @prebuild)
    |> put_change(:run_id, Ecto.UUID.generate())
    |> put_change(:state, :waiting)
    |> check_constraint(:step, name: :dispatch_runs_step_shape_check)
    |> unique_constraint(:run_id, name: :dispatch_runs_run_id_index)
    |> foreign_key_constraint(:source_collection_id,
      name: :dispatch_runs_source_collection_id_fkey
    )
    |> foreign_key_constraint(:pool_id, name: :dispatch_runs_pool_id_fkey)
  end

  # At most `of`, in the words Ecto gives a bound.
  defp validate_attempt(changeset) do
    case get_field(changeset, :of) do
      of when is_integer(of) -> validate_number(changeset, :attempt, less_than_or_equal_to: of)
      _of -> changeset
    end
  end
end
