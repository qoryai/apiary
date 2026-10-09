defmodule Apiary.Repo.Migrations.CreateTheSecurityPolicy do
  use Ecto.Migration

  # The security policy and what it renders (`Apiary.Policy`).
  #
  # `policy_rules`: a row with no target is a rule of the workspace's baseline, a row with
  # one is that target's, of the rule's workspace by the composite key. A rule names a host
  # (the contract's grammar, with the paths it is held to, NULL for every path) or a
  # credential of the machine's by name; it names a credential, it never holds one. The
  # checks say what a rule may be: a host rule has a host and no credential, a credential
  # rule the reverse; a deny removes the whole host, so only an allow is held to paths; only
  # a rule of the workspace locks. One rule per host or name, in the baseline and in each
  # target: the unique index reads a baseline rule's missing target as the nil UUID.
  #
  # `run_configurations`: the run configurations as served, immutable rows, one per version,
  # of the workspace's baseline or of a target. `document` is the exact bytes the gateway
  # was given and `digest` is `sha256=` and the hex of those bytes. The current one is the
  # highest version, read from the unique index newest first. `audit_entry_id` names the
  # audit entry of the policy change that rendered it, without a foreign key: the trail is
  # pruned by age, and a version outlives the entry of the change that made it.
  @nobody "'00000000-0000-0000-0000-000000000000'::uuid"

  def change do
    create table(:policy_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: :delete_all
          )

      add :kind, :text, null: false
      add :action, :text, null: false
      add :host, :text
      add :paths, {:array, :text}
      add :name, :text
      add :argument, :text
      add :locked, :boolean, null: false, default: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:policy_rules, :policy_rules_kind_check,
             check: "kind IN ('host', 'credential')"
           )

    create constraint(:policy_rules, :policy_rules_action_check,
             check: "action IN ('allow', 'deny')"
           )

    create constraint(:policy_rules, :policy_rules_subject_check,
             check: """
             (kind = 'host' AND host IS NOT NULL AND name IS NULL AND argument IS NULL)
             OR (kind = 'credential' AND name IS NOT NULL AND host IS NULL AND paths IS NULL)
             """
           )

    create constraint(:policy_rules, :policy_rules_deny_has_no_paths_check,
             check: "action = 'allow' OR (paths IS NULL AND argument IS NULL)"
           )

    create constraint(:policy_rules, :policy_rules_locked_is_the_workspaces_check,
             check: "NOT locked OR target_id IS NULL"
           )

    create unique_index(
             :policy_rules,
             [:workspace_id, "COALESCE(target_id, #{@nobody})", :kind, "COALESCE(host, name)"],
             name: :policy_rules_subject_index
           )

    create index(:policy_rules, [:organisation_id, :workspace_id])
    create index(:policy_rules, [:target_id])
    create index(:policy_rules, [:created_by_id])

    create table(:run_configurations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: :delete_all
          )

      add :version, :integer, null: false
      add :document, :text, null: false
      add :digest, :text, null: false
      add :rendered_at, :utc_datetime_usec, null: false
      add :changed_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :audit_entry_id, :binary_id
    end

    create constraint(:run_configurations, :run_configurations_version_check,
             check: "version >= 1"
           )

    create unique_index(
             :run_configurations,
             [:workspace_id, "COALESCE(target_id, #{@nobody})", :version],
             name: :run_configurations_version_index
           )

    create index(:run_configurations, [:workspace_id, :digest])
    create index(:run_configurations, [:organisation_id, :workspace_id])
    create index(:run_configurations, [:target_id])
    create index(:run_configurations, [:changed_by_id])
    create index(:run_configurations, [:audit_entry_id])
  end
end
