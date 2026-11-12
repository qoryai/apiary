defmodule Apiary.Repo.Migrations.CreateOrganisationVariables do
  use Ecto.Migration

  # The organisation's variables, the level above its workspaces' variables
  # (`Apiary.Policy.Above`, its `variables`), and their feature.
  #
  # `organisation_variables`: a name and a value every workspace of the organisation
  # inherits, and whether the organisation locks the name against its workspaces and their
  # repositories. Names keep a variable's rule and are unique in an organisation whatever
  # their case; a value is at most 4096 bytes, with no carriage return or line feed: the
  # core's checks of `variables`, copied. No `workspace_id`: the rows are the
  # organisation's own, and reach every workspace through the resolution. `created_by_id`
  # and `updated_by_id` are kept when an account is deleted, as the core's variables keep
  # theirs.
  #
  # The feature `organisation_variables` joins the check of `feature_grants`, which lists
  # the features there are. Down, its grants go with the check that no longer names it.
  def up do
    create table(:organisation_variables, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :text, null: false
      add :value, :text, null: false
      add :locked, :boolean, null: false, default: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:organisation_variables, :organisation_variables_name_format,
             check: "name ~ '^[A-Za-z_][A-Za-z0-9_]{0,127}$'"
           )

    create constraint(:organisation_variables, :organisation_variables_value_check,
             check: "octet_length(value) <= 4096 AND value !~ '[\\r\\n]'"
           )

    create unique_index(:organisation_variables, [:organisation_id, "lower(name)"],
             name: :organisation_variables_name_index
           )

    create index(:organisation_variables, [:created_by_id], where: "created_by_id IS NOT NULL")
    create index(:organisation_variables, [:updated_by_id], where: "updated_by_id IS NOT NULL")

    drop constraint(:feature_grants, :feature_grants_feature_check)

    create constraint(:feature_grants, :feature_grants_feature_check,
             check:
               "feature IN ('observability', 'security', 'managed_organisations', 'factory', 'organisation_policy', 'organisation_variables')"
           )
  end

  def down do
    execute "DELETE FROM feature_grants WHERE feature = 'organisation_variables'"
    drop constraint(:feature_grants, :feature_grants_feature_check)

    create constraint(:feature_grants, :feature_grants_feature_check,
             check:
               "feature IN ('observability', 'security', 'managed_organisations', 'factory', 'organisation_policy')"
           )

    drop table(:organisation_variables)
  end
end
