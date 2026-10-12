defmodule Apiary.Repo.Migrations.MoveTheSlugsKeptBack do
  use Ecto.Migration

  # `admin`, `api` and `new` are reserved as organisation slugs, and `api` and `new` as
  # workspace slugs (`ApiaryWeb.ReservedSlugs`). An organisation or a workspace that holds
  # one moves to the first of `<slug>-2`, `<slug>-3`, … that is free, as
  # `Apiary.Organisations.Slug.pick/3` picks a slug: an organisation's among every
  # organisation's (`organisations_slug_index`), a workspace's among the workspaces of its
  # organisation (`workspaces_organisation_id_slug_index`), deleted and marked ones
  # included. None of these names is reserved, and each fits the 40 characters of a slug.
  #
  # Nothing else holds a copy to change: everything else refers to an organisation or a
  # workspace by its id. The audit trail keeps the slug a workspace had when it was made
  # (`workspace.create`), as it was then.

  def up do
    execute """
    DO $$
    DECLARE
      held record;
      n integer;
    BEGIN
      FOR held IN
        SELECT id, slug FROM organisations WHERE slug IN ('admin', 'api', 'new') ORDER BY slug
      LOOP
        n := 2;
        WHILE EXISTS (SELECT 1 FROM organisations WHERE slug = held.slug || '-' || n) LOOP
          n := n + 1;
        END LOOP;

        UPDATE organisations SET slug = held.slug || '-' || n WHERE id = held.id;
      END LOOP;

      FOR held IN
        SELECT id, organisation_id, slug FROM workspaces WHERE slug IN ('api', 'new')
        ORDER BY organisation_id, slug
      LOOP
        n := 2;
        WHILE EXISTS (
          SELECT 1 FROM workspaces
          WHERE organisation_id = held.organisation_id AND slug = held.slug || '-' || n
        ) LOOP
          n := n + 1;
        END LOOP;

        UPDATE workspaces SET slug = held.slug || '-' || n WHERE id = held.id;
      END LOOP;
    END
    $$
    """
  end

  # Rolled back, nothing moves back: the slug a holder had is not kept, and the names stay
  # reserved for as long as the code that reserves them runs.
  def down, do: :ok
end
