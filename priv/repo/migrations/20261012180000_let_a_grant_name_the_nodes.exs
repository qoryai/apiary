defmodule Apiary.Repo.Migrations.LetAGrantNameTheNodes do
  use Ecto.Migration

  # A grant may name the nodes (`Apiary.Features.parts/0`), `nodes`, a part of no feature:
  # the nodes, the node pools, their access keys and the gateways, which a client's row
  # hides (`granted` false) from the client's people. The check of `feature_grants`,
  # which lists the names there are, gains it; every other name stays.
  #
  # It runs again harmlessly: the check is dropped where it is there and made again.
  #
  # Rolling back deletes the rows that name the nodes, so the check without them holds
  # again, as it was, and the nodes are shown to everyone who reads them.
  @names "'observability', 'security', 'managed_organisations', 'organisation_policy', " <>
           "'organisation_variables', 'observability.terminal'"

  def up do
    execute "ALTER TABLE feature_grants DROP CONSTRAINT IF EXISTS feature_grants_feature_check"

    create constraint(:feature_grants, :feature_grants_feature_check,
             check: "feature IN (#{@names}, 'nodes')"
           )
  end

  def down do
    execute "DELETE FROM feature_grants WHERE feature = 'nodes'"
    execute "ALTER TABLE feature_grants DROP CONSTRAINT IF EXISTS feature_grants_feature_check"

    create constraint(:feature_grants, :feature_grants_feature_check,
             check: "feature IN (#{@names})"
           )
  end
end
