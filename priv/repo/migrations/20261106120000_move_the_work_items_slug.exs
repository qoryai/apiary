defmodule Apiary.Repo.Migrations.MoveTheWorkItemsSlug do
  use Ecto.Migration

  # `work-items` is reserved as an organisation slug (`ApiaryWeb.ReservedSlugs`): a work
  # item's permanent address, `/work-items/<id>`, takes the path. An organisation with
  # that slug moves to the first of `work-items-2`, `work-items-3`, … that is free, as
  # `Apiary.Organisations.Slug.pick/3` picks a slug, among every organisation's
  # (`organisations_slug_index`), deleted and marked ones included. None of these names is
  # reserved, and each fits the 40 characters of a slug. A workspace's slug is not
  # reserved, and a workspace with the slug `work-items` keeps it.
  #
  # No other table contains a copy of the slug: everything else refers to an organisation
  # by its id. The audit trail keeps the slug an organisation had when it was renamed
  # (`organisation.rename`), as it was then.

  def up do
    execute """
    DO $$
    DECLARE
      held record;
      n integer;
    BEGIN
      FOR held IN SELECT id, slug FROM organisations WHERE slug = 'work-items' LOOP
        n := 2;
        WHILE EXISTS (SELECT 1 FROM organisations WHERE slug = held.slug || '-' || n) LOOP
          n := n + 1;
        END LOOP;

        UPDATE organisations SET slug = held.slug || '-' || n WHERE id = held.id;
      END LOOP;
    END
    $$
    """
  end

  # Rolled back, nothing moves back: the slug a holder had is not kept, and the name stays
  # reserved for as long as the code that reserves it runs.
  def down, do: :ok
end
