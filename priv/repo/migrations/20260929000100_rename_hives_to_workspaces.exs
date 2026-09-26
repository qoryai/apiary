defmodule Apiary.Repo.Migrations.RenameHivesToWorkspaces do
  use Ecto.Migration

  # The engine's word for the unit of use inside an organisation is a workspace; a hive is
  # the apiary skin's word for it, and the skin is not built. `hives` becomes
  # `workspaces`, every `hive_id` becomes `workspace_id`, and every index and
  # constraint whose name spells hive is named again, so the schema says hive nowhere.
  #
  # Renames only: every row, key, foreign key and check stays as it is, and so does every
  # index, rebuilt nowhere. A renamed column is renamed inside the definitions that name
  # it (the composite foreign keys, the partial and expression indexes, the unique indexes
  # scoped by organisation), so only the names that spell the old word are renamed here.
  # Each statement changes the catalogue alone and takes its lock for an instant; the
  # whole runs in the migration's one transaction. No stored value names a hive: events,
  # policy changes, run configurations and labels hold no `hive` key or word.

  @tables_with_a_workspace ~w(access_keys connections deliveries events invitations log_chunks
                              memberships policy_changes policy_rules retention_runs
                              run_configurations runs targets)

  # {old, new} names of the indexes that spell the old word; `hives_pkey` renames its
  # primary key constraint with it.
  @indexes [
    {"access_keys_organisation_id_hive_id_index",
     "access_keys_organisation_id_workspace_id_index"},
    {"connections_hive_id_last_seen_at_index", "connections_workspace_id_last_seen_at_index"},
    {"connections_organisation_id_hive_id_index",
     "connections_organisation_id_workspace_id_index"},
    {"deliveries_hive_id_run_id_index", "deliveries_workspace_id_run_id_index"},
    {"deliveries_organisation_id_hive_id_index", "deliveries_organisation_id_workspace_id_index"},
    {"events_hive_id_event_id_index", "events_workspace_id_event_id_index"},
    {"events_organisation_id_hive_id_index", "events_organisation_id_workspace_id_index"},
    {"hives_organisation_id_id_index", "workspaces_organisation_id_id_index"},
    {"hives_organisation_id_name_index", "workspaces_organisation_id_name_index"},
    {"hives_pkey", "workspaces_pkey"},
    {"invitations_organisation_id_hive_id_index",
     "invitations_organisation_id_workspace_id_index"},
    {"log_chunks_organisation_id_hive_id_index", "log_chunks_organisation_id_workspace_id_index"},
    {"memberships_organisation_id_hive_id_index",
     "memberships_organisation_id_workspace_id_index"},
    {"policy_changes_hive_id_inserted_at_index", "policy_changes_workspace_id_inserted_at_index"},
    {"policy_changes_hive_id_target_id_inserted_at_index",
     "policy_changes_workspace_id_target_id_inserted_at_index"},
    {"policy_changes_organisation_id_hive_id_index",
     "policy_changes_organisation_id_workspace_id_index"},
    {"policy_rules_organisation_id_hive_id_index",
     "policy_rules_organisation_id_workspace_id_index"},
    {"retention_runs_hive_id_started_at_index", "retention_runs_workspace_id_started_at_index"},
    {"retention_runs_organisation_id_hive_id_index",
     "retention_runs_organisation_id_workspace_id_index"},
    {"run_configurations_hive_id_digest_index", "run_configurations_workspace_id_digest_index"},
    {"run_configurations_organisation_id_hive_id_index",
     "run_configurations_organisation_id_workspace_id_index"},
    {"runs_hive_id_access_key_id_started_index", "runs_workspace_id_access_key_id_started_index"},
    {"runs_hive_id_inserted_at_index", "runs_workspace_id_inserted_at_index"},
    {"runs_hive_id_run_id_index", "runs_workspace_id_run_id_index"},
    {"runs_hive_id_started_or_first_heard_index",
     "runs_workspace_id_started_or_first_heard_index"},
    {"runs_hive_id_state_index", "runs_workspace_id_state_index"},
    {"runs_hive_id_target_id_index", "runs_workspace_id_target_id_index"},
    {"runs_id_hive_id_index", "runs_id_workspace_id_index"},
    {"runs_organisation_id_hive_id_index", "runs_organisation_id_workspace_id_index"},
    {"targets_hive_id_system_path_index", "targets_workspace_id_system_path_index"},
    {"targets_id_hive_id_index", "targets_id_workspace_id_index"},
    {"targets_organisation_id_hive_id_index", "targets_organisation_id_workspace_id_index"}
  ]

  # {table, old, new}: the checks and the foreign keys that spell the old word.
  @constraints [
    {"workspaces", "hives_egress_mode_check", "workspaces_egress_mode_check"},
    {"workspaces", "hives_events_retention_days_check", "workspaces_events_retention_days_check"},
    {"workspaces", "hives_log_retention_days_check", "workspaces_log_retention_days_check"},
    {"policy_rules", "policy_rules_locked_is_the_hives_check",
     "policy_rules_locked_is_the_workspaces_check"},
    {"workspaces", "hives_organisation_id_fkey", "workspaces_organisation_id_fkey"},
    {"memberships", "memberships_hive_id_fkey", "memberships_workspace_id_fkey"},
    {"invitations", "invitations_hive_id_fkey", "invitations_workspace_id_fkey"},
    {"access_keys", "access_keys_hive_id_fkey", "access_keys_workspace_id_fkey"},
    {"targets", "targets_hive_id_fkey", "targets_workspace_id_fkey"},
    {"runs", "runs_hive_id_fkey", "runs_workspace_id_fkey"},
    {"events", "events_hive_id_fkey", "events_workspace_id_fkey"},
    {"log_chunks", "log_chunks_hive_id_fkey", "log_chunks_workspace_id_fkey"},
    {"connections", "connections_hive_id_fkey", "connections_workspace_id_fkey"},
    {"deliveries", "deliveries_hive_id_fkey", "deliveries_workspace_id_fkey"},
    {"policy_rules", "policy_rules_hive_id_fkey", "policy_rules_workspace_id_fkey"},
    {"policy_changes", "policy_changes_hive_id_fkey", "policy_changes_workspace_id_fkey"},
    {"run_configurations", "run_configurations_hive_id_fkey",
     "run_configurations_workspace_id_fkey"},
    {"retention_runs", "retention_runs_hive_id_fkey", "retention_runs_workspace_id_fkey"}
  ]

  def up do
    rename table(:hives), to: table(:workspaces)

    for table <- @tables_with_a_workspace do
      rename table(table), :hive_id, to: :workspace_id
    end

    for {old, new} <- @indexes, do: execute("ALTER INDEX #{old} RENAME TO #{new}")

    for {table, old, new} <- @constraints,
        do: execute("ALTER TABLE #{table} RENAME CONSTRAINT #{old} TO #{new}")

    for table <- ["workspaces" | @tables_with_a_workspace], do: not_null_names(table, "hive")
  end

  def down do
    for {table, old, new} <- @constraints,
        do: execute("ALTER TABLE #{table} RENAME CONSTRAINT #{new} TO #{old}")

    for {old, new} <- @indexes, do: execute("ALTER INDEX #{new} RENAME TO #{old}")

    for table <- @tables_with_a_workspace do
      rename table(table), :workspace_id, to: :hive_id
    end

    rename table(:workspaces), to: table(:hives)

    for table <- ["hives" | @tables_with_a_workspace], do: not_null_names(table, "workspace")
  end

  # Postgres 18 names each NOT NULL constraint `<table>_<column>_not_null` and keeps the
  # name through a rename of either; earlier versions keep none in the catalogue, and then
  # there is nothing to rename. Each one of `table` whose name holds `word` is named again
  # from its table and column as they are.
  defp not_null_names(table, word) do
    execute("""
    DO $$
    DECLARE c record;
    BEGIN
      FOR c IN
        SELECT con.conname, att.attname
        FROM pg_constraint con
        JOIN pg_attribute att
          ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
        WHERE con.conrelid = '#{table}'::regclass
          AND con.contype = 'n'
          AND con.conname LIKE '%#{word}%'
      LOOP
        EXECUTE format('ALTER TABLE #{table} RENAME CONSTRAINT %I TO %I',
                       c.conname, '#{table}_' || c.attname || '_not_null');
      END LOOP;
    END
    $$
    """)
  end
end
