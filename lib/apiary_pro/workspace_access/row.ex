defmodule ApiaryPro.WorkspaceAccess.Row do
  @moduledoc """
  A person's access to one workspace of an organisation they are a member of: one row per
  person and workspace. A membership is the organisation's and carries the level; which
  workspaces a member reaches is these rows. A level that reaches every workspace
  (`Apiary.Access.reaches_every_workspace?/1`) needs none, and a row it has changes
  nothing while it holds that level.

  Workspace data: it carries `organisation_id` and `workspace_id` under the composite key
  against `workspaces`, and goes with its workspace. The person is named by
  `(organisation_id, user_id)` against their membership, so removing the member removes
  their rows. Added and removed through `ApiaryPro.WorkspaceAccess.add/3` and
  `ApiaryPro.WorkspaceAccess.remove/3`, and by accepting an invitation, which
  grants the workspace it was sent from.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workspace_access" do
    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :user, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @typedoc "A person's access to one workspace."
  @type t :: %__MODULE__{}
end
