defmodule Apiary.Repo.Migrations.KeepTheAdapterARunCouldNotReach do
  use Ecto.Migration

  # The call to an adapter a run of the queue stopped at (`Apiary.Adapters.Calls`), on
  # its row of `dispatch_runs`: `adapter_failure_id`, the adapter; `adapter_failure`, the
  # cause (`Apiary.Adapters.CallFailure`); `adapter_failure_call`, the call's path,
  # `run-credential`, `resolve` or `read`; and `adapter_failure_code`, the code of the
  # adapter's refusal, for the cause `refused` alone, else NULL. The first three are set
  # together or not at all (`dispatch_runs_adapter_failure_check`).
  #
  # NULL for every row there already, and adding a column with no default rewrites no row.
  # The check is added NOT VALID, so adding it takes no scan of `dispatch_runs` under its
  # lock; the next migration validates it. The index serves the reference when a node is
  # deleted.
  def up do
    alter table(:dispatch_runs) do
      add :adapter_failure_id, references(:nodes, type: :binary_id, on_delete: :nothing)
      add :adapter_failure, :text
      add :adapter_failure_call, :text
      add :adapter_failure_code, :text
    end

    execute """
    ALTER TABLE dispatch_runs ADD CONSTRAINT dispatch_runs_adapter_failure_check CHECK (
      (adapter_failure_id IS NULL AND adapter_failure IS NULL AND
       adapter_failure_call IS NULL AND adapter_failure_code IS NULL) OR (
        adapter_failure_id IS NOT NULL AND
        adapter_failure IS NOT NULL AND
        adapter_failure_call IS NOT NULL AND
        adapter_failure IN ('no_address', 'not_allowed', 'unreachable', 'timeout',
                            'refused', 'invalid_answer', 'too_large') AND
        adapter_failure_call IN ('run-credential', 'resolve', 'read') AND
        (adapter_failure_code IS NULL OR
         (adapter_failure = 'refused' AND adapter_failure_code ~ '^[a-z_]{1,64}$'))
      )
    ) NOT VALID
    """

    create index(:dispatch_runs, [:adapter_failure_id], where: "adapter_failure_id IS NOT NULL")
  end

  def down do
    drop index(:dispatch_runs, [:adapter_failure_id], where: "adapter_failure_id IS NOT NULL")
    execute "ALTER TABLE dispatch_runs DROP CONSTRAINT dispatch_runs_adapter_failure_check"

    alter table(:dispatch_runs) do
      remove :adapter_failure_id
      remove :adapter_failure
      remove :adapter_failure_call
      remove :adapter_failure_code
    end
  end
end
