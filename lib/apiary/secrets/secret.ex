defmodule Apiary.Secrets.Secret do
  @moduledoc """
  A stored secret of a workspace: a name, unique in the workspace whatever its case, a
  public id (`sec_` and 16 lowercase Crockford base32 characters, `Apiary.PublicId`),
  a note on what it is used for, and its values (`Apiary.Secrets.Value`): one without a
  value id, or several, each with its own.

  The row holds no value, and the values a listing loads hold no ciphertext. Changed only
  through `Apiary.Secrets`.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @typedoc "A stored secret of a workspace."
  @type t :: %__MODULE__{}

  @name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  @note_max 500

  @derive {Jason.Encoder, only: [:public_id, :name, :note, :values, :inserted_at, :updated_at]}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "secrets" do
    field :public_id, :string
    field :name, :string
    field :note, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :updated_by, Apiary.Accounts.User
    has_many :values, Apiary.Secrets.Value, preload_order: [asc: :value_id]

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The rule a secret's name keeps: a variable's, `^[A-Za-z_][A-Za-z0-9_]{0,127}$`."
  @spec name_format() :: Regex.t()
  def name_format, do: @name

  @doc "The most characters a note has."
  @spec note_max() :: pos_integer
  def note_max, do: @note_max

  @doc "The changeset of a secret's name and note."
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:name, :note], empty_values: [nil])
    |> update_change(:name, &trim/1)
    |> update_change(:note, &blank_to_nil/1)
    |> validate_required([:name])
    |> validate_format(:name, @name,
      message:
        dgettext_noop(
          "errors",
          "must start with a letter or _ and hold only letters, digits and _, at most 128"
        )
    )
    # Counted as the database counts it (`char_length`), in code points.
    |> validate_length(:note, max: @note_max, count: :codepoints)
    |> validate_format(:note, ~r/\A[^[:cntrl:]]*\z/u,
      message: dgettext_noop("errors", "must not contain control characters")
    )
    |> check_constraint(:note,
      name: :secrets_note_length,
      message: dgettext_noop("errors", "is too long")
    )
    |> unique_constraint(:name,
      name: :secrets_name_index,
      message:
        dgettext_noop(
          "errors",
          "is already the name of a secret in this workspace, compared without case"
        )
    )
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
