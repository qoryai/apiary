defmodule Apiary.Repo.Migrations.AddAuditEntryIdToRunConfigurations do
  use Ecto.Migration

  # The audit entry of the policy change that rendered a run configuration, in place of
  # `policy_change_id`, which is no longer written and goes with `policy_changes` in a
  # later release. No foreign key: the audit trail is pruned by age, and a version
  # outlives the entry of the change that made it. A nullable column without a default
  # and an index on a small table: instant, no row is rewritten. Reversible: rolling it
  # back drops both.
  def change do
    alter table(:run_configurations) do
      add :audit_entry_id, :binary_id
    end

    create index(:run_configurations, [:audit_entry_id])
  end
end
