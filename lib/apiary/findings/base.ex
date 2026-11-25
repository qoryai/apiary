defmodule Apiary.Findings.Base do
  @moduledoc false
  use Ecto.Schema

  # The base of a target in one take in of a work item (`Apiary.Findings`): the version
  # that the first run of the take in on the target started from, written once.

  @typedoc "A base."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "finding_bases" do
    field :take_in, :integer
    field :base, :string
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :target, Apiary.Runs.Target
  end
end
