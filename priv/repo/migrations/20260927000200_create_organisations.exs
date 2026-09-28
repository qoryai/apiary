defmodule Apiary.Repo.Migrations.CreateOrganisations do
  use Ecto.Migration

  # An organisation. It is in the URL, `/:org/…`, by its slug, unique on the instance; the
  # check holds the slug to the rules of `Apiary.Organisations.Slug`: 1 to 40 of `a`–`z`,
  # `0`–`9` and hyphens, starting and ending with a letter or a digit.
  #
  # Deleting one marks it first and purges it after the instance's grace period
  # (`Apiary.Deletion`): `deletion_marked_at`, when it was marked; `deletion_marked_by_id`,
  # who (none for the instance); `purge_after`, from when it may be purged; `purge_trigger`,
  # why (`grace_period` for an owner's deletion, `erasure_request` for a purge at once, with
  # `purge_requested_by_id` the instance admin who asked); `purge_started_at`, when a purge
  # claimed it, after which the deletion can no longer be cancelled. All empty for one in
  # use. The check keeps the marks together, and an erasure's asker with an erasure; the
  # partial index is the sweep's: the few marked rows by when they are due.
  #
  # Nothing here limits the instance to one organisation. That is the core edition's rule,
  # not the schema's, so an edition may hold more.
  @slug_format "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"
  @slug_max_length 40

  def change do
    create table(:organisations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :deletion_marked_at, :utc_datetime_usec
      add :deletion_marked_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :purge_after, :utc_datetime_usec
      add :purge_trigger, :text
      add :purge_requested_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :purge_started_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:organisations, [:slug])

    create constraint(:organisations, :organisations_slug_format,
             check: "slug ~ '#{@slug_format}' AND char_length(slug) <= #{@slug_max_length}"
           )

    create constraint(:organisations, :organisations_deletion_mark_check,
             check:
               "(deletion_marked_at IS NULL) = (purge_after IS NULL) AND " <>
                 "(deletion_marked_at IS NULL) = (purge_trigger IS NULL) AND " <>
                 "(purge_started_at IS NULL OR deletion_marked_at IS NOT NULL) AND " <>
                 "(purge_requested_by_id IS NULL OR purge_trigger = 'erasure_request')"
           )

    create constraint(:organisations, :organisations_purge_trigger_check,
             check: "purge_trigger IN ('grace_period', 'erasure_request')"
           )

    create index(:organisations, [:purge_after],
             where: "deletion_marked_at IS NOT NULL",
             name: :organisations_marked_for_deletion_index
           )
  end
end
