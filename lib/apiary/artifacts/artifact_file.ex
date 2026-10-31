defmodule Apiary.Artifacts.ArtifactFile do
  # A file of a version of an artifact (`Apiary.Artifacts.Version`).
  #
  # `filename` is a base name, 1 to 255 bytes, with no `/`, `\`, NUL or other control
  # character, neither `.` nor `..`, unique in its version
  # (`Apiary.Artifacts.Filename`). `content_type` is what the file's bytes are, as the
  # format check read them (`Apiary.Artifacts.Format`), never what the writer said.
  # `size` is its bytes, `sha256` its digest in lowercase hex, and `store_key` the key
  # the store keeps its content under (`Apiary.Artifacts.Store`): files of the same
  # content share one stored copy.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A file of a version of an artifact."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "artifact_files" do
    field :filename, :string
    field :content_type, :string
    field :size, :integer
    field :sha256, :string
    field :store_key, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :version, Apiary.Artifacts.Version
  end
end
