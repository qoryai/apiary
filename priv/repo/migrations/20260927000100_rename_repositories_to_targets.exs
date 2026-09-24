defmodule Apiary.Repo.Migrations.RenameRepositoriesToTargets do
  use Ecto.Migration

  # The engine's words (decision 0065): what a run changes is a target, in a system; a
  # body names them for a domain, and the software body calls them a repository on a
  # forge. `repositories` becomes `targets` (`forge` becomes `system`), every
  # `repository_id` becomes `target_id`, and a run's copies of its target's labels,
  # `forge` and `repository`, become `target_system` and `target_path`.
  #
  # Renames only: every row, key, foreign key and check stays as it is, and so does every
  # index, rebuilt nowhere. A renamed column is renamed inside the definitions that name
  # it (the composite foreign keys, `policy_rules_locked_is_the_hives_check`, the
  # COALESCE expressions of `policy_rules_subject_index` and
  # `run_configurations_version_index`), so only the names that spell the old words are
  # renamed here. Each statement changes the catalogue alone and takes its lock for an
  # instant; the whole runs in the migration's one transaction.
  #
  # One migration, not expand and contract: 0.1.0 has almost no installations, and the
  # release that carries this one says so (decision 0065, amended 2026-09-24).

  @tables_with_a_target ~w(runs policy_rules policy_changes run_configurations)

  # {old, new} names of the indexes and constraints that spell the old words.
  @indexes [
    {"repositories_pkey", "targets_pkey"},
    {"repositories_hive_id_forge_path_index", "targets_hive_id_system_path_index"},
    {"repositories_id_hive_id_index", "targets_id_hive_id_index"},
    {"repositories_organisation_id_hive_id_index", "targets_organisation_id_hive_id_index"},
    {"runs_hive_id_repository_id_index", "runs_hive_id_target_id_index"},
    {"policy_rules_repository_id_index", "policy_rules_target_id_index"},
    {"policy_changes_hive_id_repository_id_inserted_at_index",
     "policy_changes_hive_id_target_id_inserted_at_index"},
    {"run_configurations_repository_id_index", "run_configurations_target_id_index"}
  ]

  @constraints [
    {"targets", "repositories_organisation_id_fkey", "targets_organisation_id_fkey"},
    {"targets", "repositories_hive_id_fkey", "targets_hive_id_fkey"},
    {"targets", "repositories_egress_mode_check", "targets_egress_mode_check"},
    {"runs", "runs_repository_id_fkey", "runs_target_id_fkey"},
    {"policy_rules", "policy_rules_repository_id_fkey", "policy_rules_target_id_fkey"},
    {"policy_changes", "policy_changes_repository_id_fkey", "policy_changes_target_id_fkey"},
    {"run_configurations", "run_configurations_repository_id_fkey",
     "run_configurations_target_id_fkey"}
  ]

  def up do
    rename table(:repositories), to: table(:targets)
    rename table(:targets), :forge, to: :system

    for table <- @tables_with_a_target do
      rename table(table), :repository_id, to: :target_id
    end

    rename table(:runs), :forge, to: :target_system
    rename table(:runs), :repository, to: :target_path

    for {old, new} <- @indexes, do: execute("ALTER INDEX #{old} RENAME TO #{new}")

    for {table, old, new} <- @constraints,
        do: execute("ALTER TABLE #{table} RENAME CONSTRAINT #{old} TO #{new}")

    not_null_names("targets", "repositories", "targets")
  end

  def down do
    for {table, old, new} <- @constraints,
        do: execute("ALTER TABLE #{table} RENAME CONSTRAINT #{new} TO #{old}")

    for {old, new} <- @indexes, do: execute("ALTER INDEX #{new} RENAME TO #{old}")

    rename table(:runs), :target_path, to: :repository
    rename table(:runs), :target_system, to: :forge

    for table <- @tables_with_a_target do
      rename table(table), :target_id, to: :repository_id
    end

    rename table(:targets), :system, to: :forge
    rename table(:targets), to: table(:repositories)

    not_null_names("repositories", "targets", "repositories")
  end

  # Postgres 18 names each NOT NULL constraint `<table>_<column>_not_null` and keeps the
  # name through a rename of either; earlier versions keep none in the catalogue, and then
  # there is nothing to rename. Each is named again from its table and column as they are.
  defp not_null_names(table, from, to) do
    execute("""
    DO $$
    DECLARE c record;
    BEGIN
      FOR c IN
        SELECT con.conname, att.attname
        FROM pg_constraint con
        JOIN pg_attribute att
          ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
        WHERE con.conrelid = 'public.#{table}'::regclass
          AND con.contype = 'n'
          AND con.conname LIKE '#{from}\\_%'
      LOOP
        EXECUTE format('ALTER TABLE #{table} RENAME CONSTRAINT %I TO %I',
                       c.conname, '#{to}_' || c.attname || '_not_null');
      END LOOP;
    END
    $$
    """)
  end
end
