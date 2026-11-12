defmodule Apiary.Repo.Migrations.NarrowTheFeaturesAGrantMayName do
  use Ecto.Migration

  # The editions no longer have the feature `factory`: no organisation is granted it or
  # has it taken away. Its grants are deleted, and the check of `feature_grants`, which
  # lists the features there are, no longer names it; every other feature stays.
  #
  # Rolling back gives the check `factory` again; the grants deleted do not come back.
  def up do
    execute "DELETE FROM feature_grants WHERE feature = 'factory'"
    drop constraint(:feature_grants, :feature_grants_feature_check)

    create constraint(:feature_grants, :feature_grants_feature_check,
             check:
               "feature IN ('observability', 'security', 'managed_organisations', 'organisation_policy', 'organisation_variables')"
           )
  end

  def down do
    drop constraint(:feature_grants, :feature_grants_feature_check)

    create constraint(:feature_grants, :feature_grants_feature_check,
             check:
               "feature IN ('observability', 'security', 'managed_organisations', 'factory', 'organisation_policy', 'organisation_variables')"
           )
  end
end
