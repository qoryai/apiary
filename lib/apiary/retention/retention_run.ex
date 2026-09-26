defmodule Apiary.Retention.RetentionRun do
  @moduledoc """
  What one run of the retention job did to one workspace: the settings and cut-offs it ran
  under, and how many runs it pruned, events, log chunks, log bytes and deliveries it
  deleted. `trigger` is `schedule` for the nightly job and `manual` for `mix apiary.prune`.
  `complete` is false when the job stopped before it was through the workspace, by its
  bound on the runs of one night or by a failure; the next night goes on from there.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "retention_runs" do
    field :trigger, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :events_retention_days, :integer
    field :log_retention_days, :integer
    field :events_cutoff, :utc_datetime_usec
    field :log_cutoff, :utc_datetime_usec
    field :runs_pruned, :integer, default: 0
    field :events_deleted, :integer, default: 0
    field :log_chunks_deleted, :integer, default: 0
    field :log_bytes_deleted, :integer, default: 0
    field :deliveries_deleted, :integer, default: 0
    field :complete, :boolean, default: true

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
  end
end
