defmodule Apiary.Repo.Migrations.KeepTheApplyItemsOfARunSFirstWorkCredential do
  use Ecto.Migration

  # The apply items of the first work credential an adapter issued for a run
  # (`Apiary.Runs.WorkCredential`): on its credential entry, `issued_apply`, a JSON array of
  # 1 to 16 objects, the items of that answer as Qory Apiary sealed them for the gateway,
  # written with the credential's Activity entry. A gateway refuses a renewal whose items
  # differ from those at the run's start, so a later answer with other items is refused
  # and its seal never sent. The items are not secret. NULL until the first credential is
  # sealed and recorded, and on every entry that is not `work`.
  #
  # NULL for every row there already, and adding a column with no default rewrites no row.
  # Rolled back, the column goes.
  def change do
    alter table(:run_credentials) do
      add :issued_apply, :jsonb
    end

    create constraint(:run_credentials, :run_credentials_issued_apply_check,
             check: """
             issued_apply IS NULL OR (
               purpose = 'work'
               AND jsonb_typeof(issued_apply) = 'array'
               AND jsonb_array_length(issued_apply) BETWEEN 1 AND 16
               AND NOT jsonb_path_exists(issued_apply, '$[*] ? (@.type() != "object")')
             )
             """
           )
  end
end
