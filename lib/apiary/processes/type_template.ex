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
  - `name`, `summary` and `description`: the type's name, its one or two sentences on
    New workspace, and its "How it works" text, at most `limits/0` characters each, and
    the description at most `word_limit/0` words. Nil
    shows the text the release ships in code, translated (`Apiary.Processes.type_texts/1`).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # The most characters of each text, as the table's check has them.
  @limits %{name: 60, summary: 200, description: 1200}

  # The most words of the description, which the type's page shows beside its stages.
  @word_limit 80

  @typedoc "A version of a workspace type's default process."
  @type t :: %__MODULE__{}

  @typedoc "One of a version's texts: its name, its summary or its description."
  @type text :: :name | :summary | :description

  schema "type_template_versions" do
    field :type, :string
    field :number, :integer
    field :document, :map
    field :release, :integer
    field :based_on, :integer
    field :name, :string
    field :summary, :string
    field :description, :string

    belongs_to :author, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc "limits/0 is the most characters of each text: name 60, summary 200, description 1200."
  @spec limits() :: %{text => pos_integer}
  def limits, do: @limits

  @doc "word_limit/0 is the most words of the description: 80."
  @spec word_limit() :: pos_integer
  def word_limit, do: @word_limit
end
