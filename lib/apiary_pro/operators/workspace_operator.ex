defmodule ApiaryPro.Operators.WorkspaceOperator do
  @moduledoc """
  The operator of a workspace, one row per operated workspace, keyed by its
  `workspace_id`: the workspace's `organisation_id`, and `operator_id`, the operator that
  manages the workspace, since `since`. A workspace without a row has no operator. No
  code in the product writes the rows.

  The database keeps the rules (the table's migration lists them): at most one operator
  per workspace; an operator of the kind `operator`, never of the workspace's
  organisation. `operator_kind`, generated, is the other half of the key to the operator,
  and is not read here. No field is cast from a form.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Apiary.Organisations.{Organisation, Workspace}

  @primary_key false
  @foreign_key_type :binary_id
  schema "workspace_operators" do
    belongs_to :workspace, Workspace, primary_key: true
    belongs_to :organisation, Organisation
    belongs_to :operator, Organisation
    field :since, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "The operator of one workspace."
  @type t :: %__MODULE__{}

  @doc """
  create_changeset/3 is the changeset of the operator `operator_id` of `workspace` from
  `since`. A constraint violation in the database comes back as an error: on
  `:workspace_id` for a workspace that has an operator already, and on `:operator_id` for
  an operator that is not of the kind `operator` or is the workspace's organisation.
  """
  @spec create_changeset(%Workspace{}, Ecto.UUID.t(), DateTime.t()) :: Ecto.Changeset.t()
  def create_changeset(%Workspace{} = workspace, operator_id, %DateTime{} = since) do
    %__MODULE__{
      workspace_id: workspace.id,
      organisation_id: workspace.organisation_id,
      operator_id: operator_id,
      since: since
    }
    |> change()
    |> validate_required([:workspace_id, :organisation_id, :operator_id, :since])
    |> unique_constraint(:workspace_id, name: :workspace_operators_pkey)
    |> foreign_key_constraint(:workspace_id, name: :workspace_operators_workspace_id_fkey)
    |> foreign_key_constraint(:operator_id, name: :workspace_operators_operator_fkey)
    |> check_constraint(:operator_id, name: :workspace_operators_not_its_organisation)
  end
end
