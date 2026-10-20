defmodule Apiary.Environments.Record do
  # The environment record of a collection (`Apiary.Adapters.Collection`) for one node
  # pool of the collection's workspace: one per pool and collection. The table and its
  # rules are `20261017155000_keep_environments`'s.
  #
  # `queued_ref`, `queued_at`, `queued_target_system` and `queued_target_path` are the
  # collection's `environment_ref` and target the last prebuild for the pool was queued
  # for, and when: a record queued before its target was kept has its collection's target
  # as it was when the migration that keeps it ran, or none. `image`, `size`, `commit`,
  # `built_at` and `reported_ref` are the last good build, set together or not at all: the
  # image pinned by its digest, its size in bytes, and the commit and the
  # `environment_ref` the job read, which are compared and stored, never read.
  # `built_target_system` and `built_target_path` are the target that build was built
  # for, the registered run's target when it was recorded, or none. `built_queued_at` is
  # when the prebuild that made the image took the `environment_ref` it built, its run of
  # the queue's `environment_ref_at`, written with the image, or none: a `prebuilt` or a
  # failure of a prebuild that took its ref before it leaves the record as it is
  # (`Apiary.Environments.newer_build?/2`). `failure_cause`
  # (`failure_causes/0`), `failure_reason` (a starter's release alone has one) and
  # `failed_at` are the last build that failed, which leaves the last good build as it
  # was; a build recorded since clears them. `retired_at` is when the collection's
  # `environment_ref` went from a value to none: the image is retired for new runs, and
  # the record keeps the rest. It is cleared, and the record served again, by a build
  # whose run took its ref after the retirement; a build whose run took its ref before
  # leaves it retired (`Apiary.Environments.record_build/4`).
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A collection's environment record for one node pool."
  @type t :: %__MODULE__{}

  @failure_causes [:released, :lost, :timed_out]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "environments" do
    field :queued_ref, :string
    field :queued_at, :utc_datetime_usec
    field :queued_target_system, :string
    field :queued_target_path, :string
    field :image, :string
    field :size, :integer
    field :commit, :string
    field :built_at, :utc_datetime_usec
    field :reported_ref, :string
    field :built_target_system, :string
    field :built_target_path, :string
    field :built_queued_at, :utc_datetime_usec
    field :failure_cause, Ecto.Enum, values: @failure_causes
    field :failure_reason, :string
    field :failed_at, :utc_datetime_usec
    field :retired_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :pool, Apiary.Nodes.Node
    belongs_to :source_collection, Apiary.Adapters.Collection

    timestamps(type: :utc_datetime_usec)
  end

  # failure_causes/0 is every cause a build is recorded as failed for: the starter's
  # release, the run lost, or the run past its time.
  @doc false
  @spec failure_causes() :: [atom]
  def failure_causes, do: @failure_causes
end
