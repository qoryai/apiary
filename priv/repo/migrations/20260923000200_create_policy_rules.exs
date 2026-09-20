defmodule Apiary.Repo.Migrations.CreatePolicyRules do
  use Ecto.Migration

  @nobody "'00000000-0000-0000-0000-000000000000'::uuid"

  # The rules of the security policy. A row with no repository is a rule of the hive's
  # baseline; a row with one is that repository's. A rule names a host (the contract's
  # grammar, with the paths it is held to, null for every path) or a credential of the
  # machine's by name. It names a credential; it never holds one.
  def change do
    create table(:policy_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :hive_id,
          references(:hives,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      # Of the rule's hive, by the composite key; null for the baseline.
      add :repository_id,
          references(:repositories,
            type: :binary_id,
            with: [hive_id: :hive_id],
            on_delete: :delete_all
          )

      add :kind, :text, null: false
      add :action, :text, null: false
      add :host, :text
      add :paths, {:array, :text}
      add :name, :text
      add :argument, :text
      add :locked, :boolean, null: false, default: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:policy_rules, :policy_rules_kind_check,
             check: "kind IN ('host', 'credential')"
           )

    create constraint(:policy_rules, :policy_rules_action_check,
             check: "action IN ('allow', 'deny')"
           )

    # A host rule has a host and no credential; a credential rule the reverse.
    create constraint(:policy_rules, :policy_rules_subject_check,
             check: """
             (kind = 'host' AND host IS NOT NULL AND name IS NULL AND argument IS NULL)
             OR (kind = 'credential' AND name IS NOT NULL AND host IS NULL AND paths IS NULL)
             """
           )

    # A deny removes the whole host; only an allow is held to paths.
    create constraint(:policy_rules, :policy_rules_deny_has_no_paths_check,
             check: "action = 'allow' OR (paths IS NULL AND argument IS NULL)"
           )

    # Only a rule of the hive locks.
    create constraint(:policy_rules, :policy_rules_locked_is_the_hives_check,
             check: "NOT locked OR repository_id IS NULL"
           )

    # One rule per host or name, in the baseline and in each repository.
    create unique_index(
             :policy_rules,
             [:hive_id, "COALESCE(repository_id, #{@nobody})", :kind, "COALESCE(host, name)"],
             name: :policy_rules_subject_index
           )

    create index(:policy_rules, [:organisation_id, :hive_id])
    create index(:policy_rules, [:repository_id])
    create index(:policy_rules, [:created_by_id])
  end
end
