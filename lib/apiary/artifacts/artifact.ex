defmodule Apiary.Artifacts.Artifact do
  # An artifact: one result of a work item, by type and name, with its versions
  # (`Apiary.Artifacts.Version`).
  #
  # `public_id` is `af_` and sixteen lowercase Crockford base32 characters
  # (`Apiary.PublicId`). `type` is a type's name, standard or custom
  # (`Apiary.Artifacts.Type`), and `name` is what differs between two artifacts of one type on
  # one work item, `main` unless a push sets another; both follow the rule of a type's name
  # (`Apiary.Artifacts.Type.name?/1`), and a work item has one artifact per type and
  # name. `stage_id` is the stage its first version was made in, nil for none. The
  # artifact is of its work item's workspace, held to it by the composite key, and follows
  # it to another workspace.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false
  use Ecto.Schema

  @typedoc "An artifact of a work item."
  @type t :: %__MODULE__{}

  @prefix "af"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "artifacts" do
    field :public_id, :string
    field :type, :string
    field :name, :string, default: "main"
    field :stage_id, :string
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    has_many :versions, Apiary.Artifacts.Version
  end

  # prefix/0 is the prefix of an artifact's public id, `af`.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix
end
