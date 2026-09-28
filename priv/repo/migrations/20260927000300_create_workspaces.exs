defmodule Apiary.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  # A workspace of an organisation. `(organisation_id, id)` is unique: it is what every
  # workspace-owned table references with its `(organisation_id, workspace_id)`, so no row
  # can name a workspace of another organisation, and a key an edition's table may
  # reference too. The name and the slug are unique within the organisation; the slug is in
  # the URL, `/:org/:workspace/…`, held by the check to the rules of
  # `Apiary.Organisations.Slug`, as an organisation's is.
  #
  # `domain` is chosen when the workspace is created and checked by the application
  # (`Apiary.Lingo.Domain`): a new domain is a release, never a migration. `egress_mode` is
  # the mode of the workspace's security policy, `observe` (denies nothing) or `enforce`.
  # The retention days are how long the workspace keeps a run's events and a run's log
  # bytes, each on its own; NULL is unlimited.
  #
  # The deletion marks are the organisation's (`Apiary.Deletion`), with the same checks and
  # the sweep's partial index.
  @slug_format "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"
  @slug_max_length 40

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :domain, :string, null: false, default: "software"
      add :egress_mode, :text, null: false, default: "observe"
      add :events_retention_days, :integer
      add :log_retention_days, :integer
      add :deletion_marked_at, :utc_datetime_usec
      add :deletion_marked_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :purge_after, :utc_datetime_usec
      add :purge_trigger, :text
      add :purge_requested_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :purge_started_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspaces, [:organisation_id, :id])
    create unique_index(:workspaces, [:organisation_id, :name])
    create unique_index(:workspaces, [:organisation_id, :slug])

    create constraint(:workspaces, :workspaces_slug_format,
             check: "slug ~ '#{@slug_format}' AND char_length(slug) <= #{@slug_max_length}"
           )

    create constraint(:workspaces, :workspaces_egress_mode_check,
             check: "egress_mode IN ('observe', 'enforce')"
           )

    create constraint(:workspaces, :workspaces_events_retention_days_check,
             check: "events_retention_days BETWEEN 1 AND 3650"
           )

    create constraint(:workspaces, :workspaces_log_retention_days_check,
             check: "log_retention_days BETWEEN 1 AND 3650"
           )

    create constraint(:workspaces, :workspaces_deletion_mark_check,
             check:
               "(deletion_marked_at IS NULL) = (purge_after IS NULL) AND " <>
                 "(deletion_marked_at IS NULL) = (purge_trigger IS NULL) AND " <>
                 "(purge_started_at IS NULL OR deletion_marked_at IS NOT NULL) AND " <>
                 "(purge_requested_by_id IS NULL OR purge_trigger = 'erasure_request')"
           )

    create constraint(:workspaces, :workspaces_purge_trigger_check,
             check: "purge_trigger IN ('grace_period', 'erasure_request')"
           )

    create index(:workspaces, [:purge_after],
             where: "deletion_marked_at IS NOT NULL",
             name: :workspaces_marked_for_deletion_index
           )
  end
end
