defmodule Apiary.Processes.TypeTemplate do
  @moduledoc """
  A version of a workspace type's default process (`Apiary.Processes.TypeTemplates`): its
  document, as `priv/schemas/process/v1.schema.json` describes it, numbered 1, 2, …
  within the type. Each save makes a new row; nothing changes a row's document after.

  - `type`: the key of the type's definition (`Apiary.Lingo.Domain.Definition`), such as
    `qory.software`.
  - `author_id`: the instance admin who saved it; nil for a copy of the default the
    release ships.
  - `release`: the version of the release's default this row copies; nil for an instance
    admin's save.
  - `based_on`: the number of the version the save started from; nil for a copy of the
    release's default.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @typedoc "A version of a workspace type's default process."
  @type t :: %__MODULE__{}

  schema "type_template_versions" do
    field :type, :string
    field :number, :integer
    field :document, :map
    field :release, :integer
    field :based_on, :integer

    belongs_to :author, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end
end
