defmodule Apiary.Environments.Record do
  # The environment record of a collection (`Apiary.Adapters.Collection`) for one node
  # pool of the collection's workspace: one per pool and collection. The table and its
  # rules are `20261017155000_keep_environments`'s.
  #
  # `image`, `size`, `commit`, `built_at` and `reported_ref` are the last good build, set
  # together or not at all: the image pinned by its digest, its size in bytes, and the
  # commit and the `environment_ref` the job read; `built_ref` is set with them, the
  # `environment_ref` the prebuild that made the image was queued for. The image serves a
  # run only while `built_ref` is its collection's `environment_ref`
  # (`Apiary.Environments.image_for/2`).
  # `built_target_system` and `built_target_path` are the target that build was built
  # for, the registered run's target when it was recorded, or none. `built_queued_at` is
  # when the prebuild that made the image took the `environment_ref` it built, its run of
  # the queue's `environment_ref_at`, written with the image, or none: a build or a
  # failure of a prebuild that took its ref before it leaves the record as it is
  # (`Apiary.Environments.newer_build?/2`). `failure_cause`
  # (`failure_causes/0`), `failure_reason` (a starter's release alone has one) and
  # `failed_at` are the last build that failed, which leaves the last good build as it
  # was; a build recorded since clears them. `lost_ref` is the `environment_ref` whose
  # build for the pool was lost once and queued again, or none: a second loss of that ref
  # ends the runs that wait for it (`Apiary.Dispatches.RunEnd`), and a build recorded
  # since clears it. The record is made when the first prebuild of its collection is
  # queued for its pool (`Apiary.Dispatches.queue_prebuild/3`).
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A collection's environment record for one node pool."
  @type t :: %__MODULE__{}

  @failure_causes [:released, :lost, :timed_out, :failed]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "environments" do
    field :image, :string
    field :size, :integer
    field :commit, :string
    field :built_at, :utc_datetime_usec
    field :reported_ref, :string
    field :built_ref, :string
    field :built_target_system, :string
    field :built_target_path, :string
    field :built_queued_at, :utc_datetime_usec
    field :failure_cause, Ecto.Enum, values: @failure_causes
    field :failure_reason, :string
    field :failed_at, :utc_datetime_usec
    field :lost_ref, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :pool, Apiary.Nodes.Node
    belongs_to :source_collection, Apiary.Adapters.Collection

    timestamps(type: :utc_datetime_usec)
  end

  # failure_causes/0 is every cause a build is recorded as failed for: the starter's
  # release, the run lost, the run past its time, or the run's exit `failed`.
  @doc false
  @spec failure_causes() :: [atom]
  def failure_causes, do: @failure_causes
end
