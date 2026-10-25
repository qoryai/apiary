defmodule Apiary.Repo.Migrations.RecordAnAccessLevelOnAStack do
  use Ecto.Migration

  # A stack row with a workflow may record the access level of that workflow's runs
  # (`Apiary.Stacks.Stack`): `stacks.access`, text, `read` or `write`, NULL for none. A
  # recorded level only lowers the level the workflow declares in its stack; NULL lowers
  # nothing. The check `stacks_access_check` takes NULL, or a level on a row with a
  # workflow. Every row before this migration records none.
  #
  # Rolled back, the column goes with its check.
  def change do
    alter table(:stacks) do
      add :access, :text
    end

    create constraint(:stacks, :stacks_access_check,
             check: "access IS NULL OR (access IN ('read', 'write') AND workflow IS NOT NULL)"
           )
  end
end
