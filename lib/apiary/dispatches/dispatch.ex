defmodule Apiary.Dispatches.Dispatch do
  # One claim of one run of the queue (`Apiary.Dispatches.DispatchRun`) by one node pool
  # of its workspace, `pool_id`, with the access key the claim was signed with,
  # `access_key_id`.
  #
  # `public_id` is its name outside the database, the contract's `dispatch_id`: `dp_`,
  # then sixteen lowercase Crockford base32 characters (`Apiary.PublicId`), made once with
  # it and never claimed again. The column's default, `dispatch_public_id()`, is the same
  # shape.
  #
  # `claimed_at` is when the pool claimed it, and `lease_until` the one deadline, ten
  # minutes from the claim in whole seconds, as the claim answer gives it. `dispatched_at`
  # is when the starter said it started the job; `external_type`, `external_ref` and
  # `external_url` are that job at the system that runs it, as the starter named it then:
  # external, set together or not at all. `handed_over_at` is when its handover was
  # answered, before `lease_until`; `stale_at` when its lease lapsed before a handover, at
  # or after `lease_until`, never both. `ended_at` and `end_cause` are set together
  # (`Apiary.Dispatches.DispatchRun.end_causes/0`). `slot_freed_at` is when the slot of the
  # pool's instance limit it took at the claim was freed, once. At most one dispatch of a
  # run is live and not stale at a time.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Apiary.Dispatches.DispatchRun

  @typedoc "A claim of a run of a workspace's queue."
  @type t :: %__MODULE__{}

  @prefix "dp"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :public_id}
  schema "dispatches" do
    field :public_id, :string, read_after_writes: true
    field :claimed_at, :utc_datetime_usec
    field :lease_until, :utc_datetime_usec
    field :dispatched_at, :utc_datetime_usec
    field :external_type, :string
    field :external_ref, :string
    field :external_url, :string
    field :handed_over_at, :utc_datetime_usec
    field :stale_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :end_cause, Ecto.Enum, values: DispatchRun.end_causes()
    field :slot_freed_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :dispatch_run, DispatchRun
    belongs_to :pool, Apiary.Nodes.Node
    belongs_to :access_key, Apiary.AccessKeys.AccessKey

    timestamps(type: :utc_datetime_usec)
  end

  # prefix/0 is the prefix of a dispatch's public id, `dp`.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # new_public_id/0 is a fresh `public_id` for a dispatch: `dp_` and 16 characters.
  @doc false
  @spec new_public_id() :: String.t()
  def new_public_id, do: Apiary.PublicId.generate(@prefix)

  # public_id?/1 says whether `value` is a dispatch's `public_id` in shape, `dp_…`.
  @doc false
  @spec public_id?(term) :: boolean
  def public_id?(value), do: Apiary.PublicId.valid?(@prefix, value)

  # claim_changeset/2 is the changeset of a new dispatch: the run of the queue it claims,
  # the node pool and the access key that claimed it, when, and its lease, after the claim
  # and in whole seconds, with a fresh public id. A value the database refuses all the
  # same is an error on its field. The organisation and the workspace are the caller's to
  # put.
  @doc false
  @spec claim_changeset(t, map) :: Ecto.Changeset.t()
  def claim_changeset(%__MODULE__{} = dispatch, attrs) do
    dispatch
    |> cast(attrs, [:dispatch_run_id, :pool_id, :access_key_id, :claimed_at, :lease_until])
    |> validate_required([:dispatch_run_id, :pool_id, :access_key_id, :claimed_at, :lease_until])
    |> validate_lease()
    |> put_change(:public_id, new_public_id())
    |> check_constraint(:lease_until, name: :dispatches_lease_check)
    |> unique_constraint(:public_id, name: :dispatches_public_id_index)
    |> unique_constraint(:dispatch_run_id, name: :dispatches_live_index)
    |> foreign_key_constraint(:dispatch_run_id, name: :dispatches_dispatch_run_id_fkey)
    |> foreign_key_constraint(:pool_id, name: :dispatches_pool_id_fkey)
    |> foreign_key_constraint(:access_key_id, name: :dispatches_access_key_id_fkey)
  end

  # After the claim, in whole seconds, as the database holds it.
  defp validate_lease(changeset) do
    with %DateTime{} = claimed_at <- get_field(changeset, :claimed_at),
         %DateTime{microsecond: {usec, _precision}} = lease_until <-
           get_field(changeset, :lease_until),
         false <- usec == 0 and DateTime.compare(lease_until, claimed_at) == :gt do
      add_error(changeset, :lease_until, "is invalid")
    else
      _held_or_unset -> changeset
    end
  end
end
