defmodule Apiary.Repo.Migrations.KeepAWorkspaceSType do
  use Ecto.Migration

  # The workspace type a workspace was made from, by the key of its definition
  # (`Apiary.Lingo.Domain.definition/1`): `workspaces.type`, beside `domain`. The
  # application sets it when it creates a workspace (`Apiary.Organisations.Workspace`).
  # No check limits its values, as none limits `domain`'s, so a later type adds no
  # migration.
  #
  # A workspace there already gets the key of the type its domain reads as
  # (`Apiary.Lingo.Domain.for_workspace/1`): `qory.general` for `general`, and
  # `qory.software` for `software` and for any name no domain has, which reads as the
  # default, the software domain.
  def up do
    alter table(:workspaces) do
      add :type, :string
    end

    execute """
    UPDATE workspaces
    SET type = CASE domain WHEN 'general' THEN 'qory.general' ELSE 'qory.software' END
    """

    alter table(:workspaces) do
      modify :type, :string, null: false
    end
  end

  def down do
    alter table(:workspaces) do
      remove :type
    end
  end
end
