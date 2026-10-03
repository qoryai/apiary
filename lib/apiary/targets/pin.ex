defmodule Apiary.Targets.Pin do
  @moduledoc """
  A target a person pinned in a workspace: the sidebar lists a person's pins in the order
  they were pinned (`Apiary.Targets.list_pins/1`). One per person and target; it goes with
  its target and with its workspace. Written only through `Apiary.Targets.pin/2`.
  """
  use Ecto.Schema

  @typedoc "A person's pin of a target."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "target_pins" do
    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :user, Apiary.Accounts.User
    belongs_to :target, Apiary.Runs.Target

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
