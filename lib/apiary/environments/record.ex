defmodule Apiary.Environments.Record do
  # The environment record of a collection (`Apiary.Adapters.Collection`) for one node
  # pool of the collection's workspace: one per pool and collection. The table and its
  # rules are `20261017200100_keep_environments`'s.
  #
  # `queued_ref` and `queued_at` are the collection's `environment_ref` the last prebuild
  # for the pool was queued for, and when. `image`, `size`, `commit`, `built_at` and
  # `reported_ref` are the last good build, set together or not at all: the image pinned
  # by its digest, its size in bytes, and the commit and the `environment_ref` the job
  # read, which are compared and stored, never read. `failure_cause` (`failure_causes/0`),
  # `failure_reason` (a starter's release alone has one) and `failed_at` are the last
  # build that failed, which leaves the last good build as it was. `retired_at` is when the
  # collection's `environment_ref` went from a value to none: the image is retired for new
  # runs, and the record keeps the rest.
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
    field :image, :string
    field :size, :integer
    field :commit, :string
    field :built_at, :utc_datetime_usec
    field :reported_ref, :string
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
