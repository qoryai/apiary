defmodule Apiary.Policy.RunConfiguration do
  @moduledoc """
  A run configuration as it was served: immutable. `document` is the exact bytes a
  runner is given, `digest` is `sha256=` and the hex of those bytes, the string of the
  `X-Qory-Run-Configuration` header. `version` counts from 1 per hive and target; the
  baseline's rows have no target. The current one is the highest version.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "run_configurations" do
    field :version, :integer
    field :document, :string
    field :digest, :string
    field :rendered_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    belongs_to :target, Apiary.Runs.Target
    belongs_to :changed_by, Apiary.Accounts.User
    belongs_to :policy_change, Apiary.Policy.Change
  end
end
