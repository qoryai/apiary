defmodule Apiary.Repo.Migrations.RemoveCredentialsFromTheSecurityPolicy do
  use Ecto.Migration

  # The security policy no longer names credentials: a rule of `policy_rules` is a host
  # rule and nothing else. The credential rules are deleted, `name` and `argument` go, and
  # the checks and the unique index are the host's alone. `kind` stays, `'host'` its one
  # value. A run configuration already rendered keeps its bytes until the next change of
  # its policy, or `mix apiary.policy.rerender`.
  #
  # Down puts the columns, the checks and the index back as they were; the rules deleted
  # stay deleted.
  @nobody "'00000000-0000-0000-0000-000000000000'::uuid"

  def up do
    execute "DELETE FROM policy_rules WHERE kind <> 'host'"

    drop constraint(:policy_rules, :policy_rules_kind_check)
    drop constraint(:policy_rules, :policy_rules_subject_check)
    drop constraint(:policy_rules, :policy_rules_deny_has_no_paths_check)
    drop index(:policy_rules, [], name: :policy_rules_subject_index)

    alter table(:policy_rules) do
      remove :name
      remove :argument
    end

    create constraint(:policy_rules, :policy_rules_kind_check, check: "kind = 'host'")
    create constraint(:policy_rules, :policy_rules_subject_check, check: "host IS NOT NULL")

    create constraint(:policy_rules, :policy_rules_deny_has_no_paths_check,
             check: "action = 'allow' OR paths IS NULL"
           )

    create unique_index(
             :policy_rules,
             [:workspace_id, "COALESCE(target_id, #{@nobody})", :kind, :host],
             name: :policy_rules_subject_index
           )
  end

  def down do
    drop index(:policy_rules, [], name: :policy_rules_subject_index)
    drop constraint(:policy_rules, :policy_rules_deny_has_no_paths_check)
    drop constraint(:policy_rules, :policy_rules_subject_check)
    drop constraint(:policy_rules, :policy_rules_kind_check)

    alter table(:policy_rules) do
      add :name, :text
      add :argument, :text
    end

    create constraint(:policy_rules, :policy_rules_kind_check,
             check: "kind IN ('host', 'credential')"
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

    create unique_index(
             :policy_rules,
             [:workspace_id, "COALESCE(target_id, #{@nobody})", :kind, "COALESCE(host, name)"],
             name: :policy_rules_subject_index
           )
  end
end
