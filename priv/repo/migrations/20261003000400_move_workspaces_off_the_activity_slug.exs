defmodule Apiary.Repo.Migrations.MoveWorkspacesOffTheActivitySlug do
  use Ecto.Migration

  # `/:org/activity` is an organisation's page now, the Activity page, so `activity` is a
  # name no workspace slug may be (`ApiaryWeb.ReservedSlugs.workspace/0`). A workspace
  # that took it before is given the first free numbered slug in its organisation,
  # `activity-2` and on, as `Apiary.Organisations.Slug.pick/3` numbers one: its pages
  # move there, and its old path is the Activity page's. The name is not changed. One
  # statement over the workspaces that hold the slug, most likely none: instant.
  #
  # Rolling it back changes nothing: which of the numbered slugs were `activity` before is
  # not kept, and the previous release serves them where they are.
  def up do
    execute("""
    UPDATE workspaces w
    SET slug = (
      SELECT 'activity-' || n
      FROM generate_series(2, 10000) AS n
      WHERE NOT EXISTS (
        SELECT 1 FROM workspaces o
        WHERE o.organisation_id = w.organisation_id AND o.slug = 'activity-' || n
      )
      ORDER BY n
      LIMIT 1
    )
    WHERE w.slug = 'activity'
    """)
  end

  def down, do: :ok
end
