defmodule Apiary.Artifacts.Version do
  # A version of an artifact (`Apiary.Artifacts.Artifact`): its files
  # (`Apiary.Artifacts.ArtifactFile`), stored as one unit, and who made it.
  #
  # `public_id` is `av_` and sixteen lowercase Crockford base32 characters
  # (`Apiary.PublicId`). `number` counts the versions of its artifact from 1, with no gap
  # (`Apiary.Artifacts.push/5`). `writer` is `:run` for a version a run of the queue made,
  # `run_id` (`Apiary.Dispatches.DispatchRun`), or `:person` for one a person made,
  # `user_id`; each link is nil once its row is gone. `stage_id` is the stage it was made
  # in, nil for none, and `note` what the writer added, nil for nothing, at most 4,000
  # characters. `withdrawn` is true for a withdrawal, a run's version with no files that
  # withdraws its artifact's name (`Apiary.Artifacts.withdraw/4`), false for every other.
  # `decision_id` is the id of the person's note that asked for the version, `gd_…` or
  # `es_…` (`Apiary.Stages.Notes`), nil for none (vault 0261, 624 (a)).
  #
  # `delivery`, `delivery_reply`, `delivery_failure` and `delivery_at` store where the
  # delivery of the version to an adapter stands (`Apiary.Artifacts.Delivery`): `delivery`
  # is `:sent`, `:delivered` or `:failed`, nil for a version with no delivery;
  # `delivery_reply` is the adapter's reply, nil until one is stored; `delivery_failure`
  # is a reason in `delivery_failures/0`, nil until a failure is stored; `delivery_detail`
  # is what failed, 1 to 1000 characters on one line, nil for none; `delivery_at` is when the
  # last of them was stored, nil until one is; `delivery_target_id` is the workspace's
  # target the entry went to, nil until it is sent and once the target is gone.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A version of an artifact."
  @type t :: %__MODULE__{}

  @prefix "av"

  # The reasons of `changes-failed.schema.json` for a change request, and two of Qory
  # Apiary, each with nothing sent (`Apiary.Artifacts.Delivery`): `invalid`, the entry
  # failed its check against `changes.schema.json`, its members are longer as jsonb text
  # than the feed's check takes (`#/data`), or the version's `target.collection` is not
  # the run's (`#/target`); and `target_removed`, when the entry was to be sent, the
  # adapter was gone, the adapter's collection with the target was ended or assigned to
  # no workspace or another, its connection was not connected, or the workspace had no row
  # of the target.
  @delivery_failures [
    :not_permitted,
    :unreachable,
    :target_gone,
    :too_long,
    :refused,
    :invalid,
    :target_removed
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "artifact_versions" do
    field :public_id, :string
    field :number, :integer
    field :writer, Ecto.Enum, values: [:run, :person]
    field :stage_id, :string
    field :note, :string
    field :withdrawn, :boolean, default: false
    field :decision_id, :string
    field :delivery, Ecto.Enum, values: [:sent, :delivered, :failed]
    field :delivery_reply, :map
    field :delivery_failure, Ecto.Enum, values: @delivery_failures
    field :delivery_detail, :string
    field :delivery_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :artifact, Apiary.Artifacts.Artifact
    belongs_to :run, Apiary.Dispatches.DispatchRun
    belongs_to :user, Apiary.Accounts.User
    belongs_to :delivery_target, Apiary.Runs.Target
    has_many :files, Apiary.Artifacts.ArtifactFile, foreign_key: :version_id
  end

  # delivery_failures/0 is the values of `delivery_failure`.
  @doc false
  @spec delivery_failures() :: [atom]
  def delivery_failures, do: @delivery_failures

  # prefix/0 is the prefix of a version's public id, `av`.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix
end
