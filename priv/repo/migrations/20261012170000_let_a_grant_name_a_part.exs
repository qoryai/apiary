defmodule Apiary.Repo.Migrations.LetAGrantNameAPart do
  use Ecto.Migration

  # A grant may name a part of a feature (`Apiary.Features.parts/0`) as well as a feature:
  # the run's Terminal, `observability.terminal`, which a row hides (`granted` false) from
  # the people of an organisation and of the clients below it. The check of
  # `feature_grants`, which lists the names there are, gains the part; every other name
  # stays.
  #
  # It runs again harmlessly: the check is dropped where it is there and made again.
  #
  # Rolling back deletes the rows that name the part, so the check without it holds again,
  # and the part is shown wherever its feature is.
  @features "'observability', 'security', 'managed_organisations', 'organisation_policy', " <>
              "'organisation_variables'"

  def up do
    execute "ALTER TABLE feature_grants DROP CONSTRAINT IF EXISTS feature_grants_feature_check"

    create constraint(:feature_grants, :feature_grants_feature_check,
             check: "feature IN (#{@features}, 'observability.terminal')"
           )
  end

  def down do
    execute "DELETE FROM feature_grants WHERE feature = 'observability.terminal'"
    execute "ALTER TABLE feature_grants DROP CONSTRAINT IF EXISTS feature_grants_feature_check"

    create constraint(:feature_grants, :feature_grants_feature_check,
             check: "feature IN (#{@features})"
           )
  end
end
