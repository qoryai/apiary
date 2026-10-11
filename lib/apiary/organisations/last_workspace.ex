defmodule Apiary.Organisations.LastWorkspace do
  @moduledoc """
  The workspace a person last used in an organisation: one per person and organisation,
  written by every workspace page they open, a live navigation's too
  (`Apiary.Organisations.remember_workspace/1`). An organisation's page and the
  switcher's link to the organisation open it while the person reaches it
  (`Apiary.Organisations.resolve_scope/4`). It is keyed by the person, not a membership,
  so it holds for every way of reaching an organisation, and goes with the person, the
  organisation and the workspace.
  """
  use Ecto.Schema

  @typedoc "The workspace a person last used in an organisation."
  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id
  schema "last_workspaces" do
    belongs_to :user, Apiary.Accounts.User, primary_key: true
    belongs_to :organisation, Apiary.Organisations.Organisation, primary_key: true
    belongs_to :workspace, Apiary.Organisations.Workspace

    timestamps(type: :utc_datetime_usec, inserted_at: false)
  end
end
