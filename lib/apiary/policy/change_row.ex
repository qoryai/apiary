defmodule Apiary.Policy.ChangeRow do
  @moduledoc """
  A row of `policy_changes`, the history of the security policy as the release before the
  audit trail kept it. Written, never read: every change of the policy still writes one,
  under the id of its audit entry, so that the release before can run against this
  schema after a rollback and see the whole history and which workspaces are managed.
  The history this release shows is the audit trail's (`Apiary.Policy.Change`).

  A later release stops writing it and drops the table, after running the copy into the
  trail again (the migration `20261003000300`, which copies nothing twice) for the rows a
  rolled-back release wrote meanwhile.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @foreign_key_type :binary_id
  schema "policy_changes" do
    field :action, :string
    field :subject, :string
    field :before, :map
    field :after, :map
    field :version_after, :integer
    field :inserted_at, :utc_datetime_usec
    field :organisation_id, Ecto.UUID
    field :workspace_id, Ecto.UUID
    field :target_id, Ecto.UUID
    field :changed_by_id, Ecto.UUID
  end
end
