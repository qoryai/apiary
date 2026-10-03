defmodule Apiary.Secrets.Value do
  @moduledoc """
  One value of a stored secret: its value id, a lowercase slug unique in the secret, or
  none for a secret's one value, and the value itself, only ever stored encrypted
  (`Apiary.Secrets.Cipher`): `nonce` and `ciphertext`, under the workspace's data key
  (`data_key_id`).

  The value is write-only. The virtual `value` carries a plaintext only into a changeset,
  and `Apiary.Secrets` takes it out before the row is written: no struct it returns holds
  one. The plaintext, the nonce and the ciphertext are redacted from `inspect/2` and are
  not encoded to JSON.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @typedoc "A value of a stored secret."
  @type t :: %__MODULE__{}

  @value_id ~r/\A[a-z0-9][a-z0-9_.-]{0,63}\z/
  @value_max 16_384

  @derive {Jason.Encoder, only: [:value_id, :inserted_at, :updated_at]}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "secret_values" do
    field :value_id, :string
    field :value, :string, virtual: true, redact: true
    field :nonce, :binary, redact: true
    field :ciphertext, :binary, redact: true

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :secret, Apiary.Secrets.Secret
    belongs_to :data_key, Apiary.Secrets.DataKey
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :updated_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The most bytes a value has."
  @spec value_max() :: pos_integer
  def value_max, do: @value_max

  @doc "The rule a value id keeps: `^[a-z0-9][a-z0-9_.-]{0,63}$`."
  @spec value_id_format() :: Regex.t()
  def value_id_format, do: @value_id

  @doc """
  The fields a listing loads: every field but the nonce and the ciphertext, which stay in
  the database for everything but sealing.
  """
  @spec public_fields() :: [atom]
  def public_fields, do: __schema__(:fields) -- [:nonce, :ciphertext]

  @doc """
  The changeset of a value: `value`, the plaintext, required, UTF-8 text of 1 to
  #{@value_max} bytes with no NUL; and `value_id`, required when `opts[:value_id]` is
  `:required`, optional otherwise.
  """
  @spec changeset(t, map, keyword) :: Ecto.Changeset.t()
  def changeset(value, attrs, opts \\ []) do
    value
    |> cast(attrs, [:value, :value_id], empty_values: [nil])
    |> validate_value()
    |> value_id_changeset(opts[:value_id] || :optional)
  end

  @doc "The changeset of a value's value id alone, as a rename takes it."
  @spec value_id_changeset(t | Ecto.Changeset.t(), :required | :optional) ::
          Ecto.Changeset.t()
  def value_id_changeset(value_or_changeset, rule)

  def value_id_changeset(%__MODULE__{} = value, rule),
    do: value |> change() |> value_id_changeset(rule)

  def value_id_changeset(%Ecto.Changeset{} = changeset, rule) do
    changeset
    |> update_change(:value_id, &blank_to_nil/1)
    |> value_id_rule(rule)
    |> validate_format(:value_id, @value_id,
      message:
        dgettext_noop(
          "errors",
          "must be lowercase letters, digits, ., _ and -, starting with a letter or digit, at most 64"
        )
    )
    |> unique_constraint(:value_id,
      name: :secret_values_value_id_index,
      message: dgettext_noop("errors", "is already a value ID of this secret")
    )
  end

  defp value_id_rule(changeset, :required), do: validate_required(changeset, [:value_id])

  defp value_id_rule(changeset, :optional), do: changeset

  # The checks never put the value in a message.
  defp validate_value(changeset) do
    changeset = validate_required(changeset, [:value])

    case get_change(changeset, :value) do
      value when is_binary(value) ->
        cond do
          value == "" ->
            add_error(changeset, :value, dgettext_noop("errors", "can't be blank"),
              validation: :required
            )

          byte_size(value) > @value_max ->
            add_error(
              changeset,
              :value,
              dgettext_noop("errors", "must be at most %{count} bytes"), count: @value_max)

          not String.valid?(value) ->
            add_error(changeset, :value, dgettext_noop("errors", "must be UTF-8 text"))

          String.contains?(value, <<0>>) ->
            add_error(changeset, :value, dgettext_noop("errors", "must not contain a NUL byte"))

          true ->
            changeset
        end

      _ ->
        changeset
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
