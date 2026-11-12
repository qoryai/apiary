defmodule ApiaryPro.OrganisationVariables.Variable do
  @moduledoc """
  One variable of the organisation (`organisation_variables`): a name and a value every
  workspace of the organisation inherits, and whether the organisation **locks** the name,
  so no workspace or repository sets it. One name per organisation, compared without case.

  A name and a value keep the core's rules (`Apiary.Variables.Variable`), with its
  sentences: a name `^[A-Za-z_][A-Za-z0-9_]{0,127}$`, a value of UTF-8 text of at most
  #{4096} bytes, with no NUL, carriage return or line feed, which may be empty.

  The core resolves it as an `Apiary.Variables.Variable` of the level above the workspace
  (`to_core_variable/1`): the same name, value and lock, unpersisted, never a row of
  `variables`. Rows change only through `ApiaryPro.OrganisationVariables`.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryProWeb.Gettext

  import Ecto.Changeset

  alias Apiary.Variables.Variable, as: Core

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organisation_variables" do
    field :name, :string
    field :value, :string
    field :locked, :boolean, default: false

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :updated_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  changeset/2 checks a variable's name, value and lock as the core checks a workspace's
  (`Apiary.Variables.Variable.changeset/2`), with the same sentences: the name's rule, the
  value's size and lines, and one name per organisation whatever its case.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(variable, attrs) do
    variable
    |> cast(attrs, [:name, :value, :locked], empty_values: [nil])
    |> update_change(:name, &trim/1)
    |> validate_required([:name, :value])
    |> validate_format(:name, Core.name_format(),
      message:
        dgettext_noop(
          "errors",
          "must start with a letter or _ and hold only letters, digits and _, at most 128"
        )
    )
    |> validate_value()
    |> unique_constraint(:name,
      name: :organisation_variables_name_index,
      message: dgettext_noop("errors", "is already set here, compared without case")
    )
  end

  defp validate_value(changeset) do
    case get_change(changeset, :value) do
      value when is_binary(value) ->
        cond do
          byte_size(value) > Core.value_max() ->
            add_error(
              changeset,
              :value,
              dgettext_noop("errors", "must be at most %{count} bytes"),
              count: Core.value_max()
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

  @doc """
  to_core_variable/1 is the variable as the core resolves it at the level above the
  workspace: an `Apiary.Variables.Variable` with its name, value and lock, the
  organisation's id, its authors and its times, and the row's id, which a page names
  it by; no workspace and no target.
  """
  @spec to_core_variable(t) :: Core.t()
  def to_core_variable(%__MODULE__{} = variable) do
    %Core{
      id: variable.id,
      name: variable.name,
      value: variable.value,
      locked: variable.locked,
      organisation_id: variable.organisation_id,
      workspace_id: nil,
      target_id: nil,
      created_by_id: variable.created_by_id,
      updated_by_id: variable.updated_by_id,
      inserted_at: variable.inserted_at,
      updated_at: variable.updated_at
    }
  end
end
