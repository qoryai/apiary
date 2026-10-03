defmodule Apiary.Variables.Variable do
  @moduledoc """
  A variable: a name and a value a run's process is given, at a level: the workspace's
  (no `target_id`) or a repository's (a target's, `target_id`). A workspace's variable may
  be `locked`, and then no repository sets its own value for the name.

  A name keeps a variable's rule, `^[A-Za-z_][A-Za-z0-9_]{0,127}$`, and is compared
  without case: one level holds a name once, whatever its case. A value is UTF-8 text of
  at most #{4096} bytes, with no NUL, carriage return or line feed; it may be empty.

  The same struct carries a variable of a level above the workspace, which the edition
  materialises (`Apiary.Policy.Above`, its `variables`) and which is no row: only its
  `name`, `value` and `locked` are read. Rows change only through `Apiary.Variables`.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @typedoc "A variable of a workspace or a repository, or of the level above."
  @type t :: %__MODULE__{}

  @name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  @value_max 4096

  @derive {Jason.Encoder, only: [:name, :value, :locked, :inserted_at, :updated_at]}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "variables" do
    field :name, :string
    field :value, :string
    field :locked, :boolean, default: false

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :target, Apiary.Runs.Target
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :updated_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The rule a name keeps: `^[A-Za-z_][A-Za-z0-9_]{0,127}$`."
  @spec name_format() :: Regex.t()
  def name_format, do: @name

  @doc "The most bytes a value has."
  @spec value_max() :: pos_integer
  def value_max, do: @value_max

  @doc """
  The changeset of a variable's name, value and lock. The lock is cast only for a
  workspace's variable: a repository's is never locked.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(variable, attrs) do
    fields =
      if is_nil(variable.target_id), do: [:name, :value, :locked], else: [:name, :value]

    variable
    |> cast(attrs, fields, empty_values: [nil])
    |> update_change(:name, &trim/1)
    |> validate_required([:name, :value])
    |> validate_format(:name, @name,
      message:
        dgettext_noop(
          "errors",
          "must start with a letter or _ and hold only letters, digits and _, at most 128"
        )
    )
    |> validate_value()
    |> unique_constraint(:name,
      name: :variables_name_index,
      message: dgettext_noop("errors", "is already set here, compared without case")
    )
  end

  defp validate_value(changeset) do
    case get_change(changeset, :value) do
      value when is_binary(value) ->
        cond do
          byte_size(value) > @value_max ->
            add_error(
              changeset,
              :value,
              dgettext_noop("errors", "must be at most %{count} bytes"),
              count: @value_max
            )

          not String.valid?(value) ->
            add_error(changeset, :value, dgettext_noop("errors", "must be UTF-8 text"))

          String.contains?(value, [<<0>>, "\r", "\n"]) ->
            add_error(
              changeset,
              :value,
              dgettext_noop("errors", "must be one line, with no NUL byte")
            )

          true ->
            changeset
        end

      _ ->
        changeset
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
