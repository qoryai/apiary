defmodule Apiary.Harnesses.RunHarness do
  # The harness walk of an explore run of the queue (`Apiary.Harnesses.Walk`), one per run
  # of the queue, written when the run is queued (`Apiary.Dispatches`) and by the walk's
  # job (`Apiary.Harnesses.WalkJob`). The table and its rules are
  # `20261025150000_keep_each_run_s_harness_walk`'s.
  #
  #   * `state`: `:pending` until the job ends, then `:resolved` or `:failed`. A claim
  #     takes no run whose walk is pending.
  #   * `origin`, once resolved: `:file`, the target's harness file, whose harness section
  #     has `extends` or lists modules without it; `:setting`, the harness document of the
  #     most specific level of the stacks (`Apiary.Stacks.Resolution`), its row `stack_id`
  #     and its owner `owner_organisation_id`, the section in `document`; `:builtin`, a
  #     test work item's run, the built-in section (`Apiary.Harnesses.Builtin`) in
  #     `document`, with no stack, owner or link, read only; `:none`, a run with no
  #     workflow, for which nothing is read.
  #   * `workflow` and `harness_hidden`: the run's workflow and whether its harness is
  #     hidden.
  #   * `access_level`: what the run may do on its target, `:read` or `:write`, the level
  #     the walk resolved; `:read` until it resolves, and for a run with no workflow.
  #   * `target_version`: the version at which the walk read the target's harness file, nil
  #     where it read none.
  #   * `pins`: one `%{"git", "ref", "at"}` per remote source, `at` the version its read
  #     returned, or its `ref` for a source with no link, which the walk does not read.
  #   * `harness_links`: one `%{"grant_id", "adapter_id", "grant_ref", "resources"}` per
  #     link the run reads its harness sources through (`Apiary.Harnesses.entries/1`).
  #   * `failure`, once failed: the code (`Apiary.Harnesses.Walk.failures/0`), with
  #     `failed_source`, the source as shown, nil for none or for a hidden harness;
  #     `failure_rule`, `%{"message", "values"}`, the format rule an `invalid` source
  #     breaks; and `failure_adapter`, the adapter's name, for `adapter_unavailable`.
  #   * `attempts`: the job's attempts so far.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use Ecto.Schema

  @typedoc "The harness walk of a run of the queue."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "run_harnesses" do
    field :state, Ecto.Enum, values: [:pending, :resolved, :failed]
    field :origin, Ecto.Enum, values: [:file, :setting, :builtin, :none]
    field :workflow, :string
    field :access_level, Ecto.Enum, values: [:read, :write], default: :read
    field :target_version, :string
    field :document, :map
    field :pins, {:array, :map}, default: []
    field :harness_links, {:array, :map}, default: []
    field :harness_hidden, :boolean, default: false
    field :failure, :string
    field :failed_source, :string
    field :failure_rule, :map
    field :failure_adapter, :string
    field :attempts, :integer, default: 0

    belongs_to :dispatch_run, Apiary.Dispatches.DispatchRun
    belongs_to :stack, Apiary.Stacks.Stack
    belongs_to :owner_organisation, Apiary.Organisations.Organisation

    timestamps(type: :utc_datetime_usec)
  end
end
