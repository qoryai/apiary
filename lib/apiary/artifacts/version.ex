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
  # characters.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A version of an artifact."
  @type t :: %__MODULE__{}

  @prefix "av"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "artifact_versions" do
    field :public_id, :string
    field :number, :integer
    field :writer, Ecto.Enum, values: [:run, :person]
    field :stage_id, :string
    field :note, :string
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :artifact, Apiary.Artifacts.Artifact
    belongs_to :run, Apiary.Dispatches.DispatchRun
    belongs_to :user, Apiary.Accounts.User
    has_many :files, Apiary.Artifacts.ArtifactFile, foreign_key: :version_id
  end

  # prefix/0 is the prefix of a version's public id, `av`.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix
end
