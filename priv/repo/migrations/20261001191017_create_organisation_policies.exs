defmodule Apiary.Repo.Migrations.CreateOrganisationPolicies do
  use Ecto.Migration

  # The organisation's policy, the level above its workspaces' security policy
  # (`Apiary.Policy.Above`), and its feature.
  #
  # `organisation_policies`: one row per organisation at most, written when its policy is
  # first changed: `enforce_everywhere`, the mode floor (on, no workspace or target may
  # observe), and `own_allows`, the switch (off, only the organisation's allows grant a
  # host). `created_by_id` is the person who began it, kept when their account is deleted,
  # as the audit trail keeps its actor.
  #
  # `organisation_policy_rules`: the organisation's host rules, one per host, allow or
  # deny, an allow held to `paths` or on every path (`paths` empty). A deny has no paths,
  # by the check. No `kind`: every rule is a host's. No `workspace_id`: the rows
  # are the organisation's own, and reach every workspace through the resolution.
  #
  # The feature `organisation_policy` joins the check of `feature_grants`, which lists the
  # features there are. Down, its grants go with the check that no longer names it.
  def up do
    create table(:organisation_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :enforce_everywhere, :boolean, null: false, default: false
      add :own_allows, :boolean, null: false, default: true
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:organisation_policies, [:organisation_id])
    create index(:organisation_policies, [:created_by_id], where: "created_by_id IS NOT NULL")

    create table(:organisation_policy_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :action, :text, null: false
      add :host, :text, null: false
      add :paths, {:array, :text}
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:organisation_policy_rules, [:organisation_id, :host],
             name: :organisation_policy_rules_host_index
           )

    create index(:organisation_policy_rules, [:created_by_id], where: "created_by_id IS NOT NULL")

    create constraint(:organisation_policy_rules, :organisation_policy_rules_action_check,
             check: "action IN ('allow', 'deny')"
           )

    create constraint(:organisation_policy_rules, :organisation_policy_rules_deny_paths_check,
             check: "action <> 'deny' OR paths IS NULL"
           )

    drop constraint(:feature_grants, :feature_grants_feature_check)

    create constraint(:feature_grants, :feature_grants_feature_check,
             check:
               "feature IN ('observability', 'security', 'managed_organisations', 'factory', 'organisation_policy')"
           )
  end

  def down do
    execute "DELETE FROM feature_grants WHERE feature = 'organisation_policy'"
    drop constraint(:feature_grants, :feature_grants_feature_check)

    create constraint(:feature_grants, :feature_grants_feature_check,
             check: "feature IN ('observability', 'security', 'managed_organisations', 'factory')"
           )

    drop table(:organisation_policy_rules)
    drop table(:organisation_policies)
  end
end
