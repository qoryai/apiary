defmodule Apiary.TimeLimits.TimeLimit do
  # A time limit for the runs of one workflow, set at a place of a workspace: the whole
  # `minutes`, 15 to 1440, that a run of the workflow `workflow` may take. The place is
  # the workspace, or a target of it (`target_id`). `workflow` is a workflow name, as a
  # stack row has one (`Apiary.Stacks.Stack`).
  #
  # Changed only through `Apiary.TimeLimits`.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A time limit at the workspace or at a target."
  @type t :: %__MODULE__{}

  @typedoc "The place of a time limit: a target of the workspace, or the workspace."
  @type level :: :target | :workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "time_limits" do
    field :workflow, :string
    field :minutes, :integer

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :target, Apiary.Runs.Target
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :updated_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  # level/1 is the place of `limit`: `:target` for a row with a target, else `:workspace`.
  @spec level(t) :: level
  def level(%__MODULE__{target_id: nil}), do: :workspace
  def level(%__MODULE__{}), do: :target
end
