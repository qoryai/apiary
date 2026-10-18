defmodule Apiary.Repo.Migrations.KeepACollectionSEnvironmentRef do
  use Ecto.Migration

  # A collection's `environment_ref` (`Apiary.Adapters.Collection`), as the latest listing
  # that names the collection gives it (`source-collections.schema.json`): the adapter's id
  # of the collection's environment definition, 1 to 200 characters, which the core
  # compares and stores and never reads meaning into. Empty when that listing named the
  # collection without one: the collection has none. Adding a column that may be empty,
  # with no default, rewrites no row, and every row passes the check.
  def change do
    alter table(:source_collections) do
      add :environment_ref, :text
    end

    create constraint(:source_collections, :source_collections_environment_ref_check,
             check: "environment_ref IS NULL OR char_length(environment_ref) BETWEEN 1 AND 200"
           )
  end
end
