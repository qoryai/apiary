defmodule Apiary.Repo.Migrations.KeepEnvironments do
  use Ecto.Migration

  # The environment record of a collection for a node pool (`Apiary.Environments.Record`),
  # one per pool and collection: what the last prebuild of the collection's target built
  # for that pool, and what was asked of it. The table holds the rows; nothing here queues
  # or records a build.
  #
  # - `queued_ref` and `queued_at`: the collection's `environment_ref` the last prebuild
  #   for the pool was queued for, and when. A record is made when a prebuild is first
  #   queued for it, so both are always set.
  # - `image`, `size`, `commit`, `built_at` and `reported_ref`: the last good build, set
  #   together or not at all. `image` is pinned by its digest, as the provisioner
  #   contract's `$defs/image` has it (`NAME@sha256:` and 64 lower-case hexadecimal
  #   digits, NAME at most 255 characters); `size` is in bytes, from 1 to 2^53 - 1;
  #   `commit` and `reported_ref`, the commit and the `environment_ref` the job read, are
  #   1 to 200 characters, compared and stored, never read.
  # - `failure_cause`, `failure_reason` and `failed_at`: the last build that failed, if
  #   any, which leaves the last good build as it was. `failure_cause` is `released` (the
  #   starter gave the run back, with its `failure_reason`, 1 to 200 characters, the
  #   release's reason), `lost` or `timed_out`, which have no reason.
  # - `retired_at`: when the collection's `environment_ref` went from a value to none, which
  #   retires the image for new runs; the record keeps the rest.
  #
  # A record is held to the pool's workspace and the collection's organisation by the
  # composite keys. It goes with the pool's workspace (`ON DELETE CASCADE`); the node pool
  # and the collection are NO ACTION, as a dispatch's pool is: a pool is deleted softly,
  # and the purge deletes these rows before the pools and the collections.
  @ref_check "BETWEEN 1 AND 200"
  # The provisioner contract's `$defs/image`.
  @image "^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*" <>
           "(?::[0-9]{1,5})?/)?[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*" <>
           "(?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*@sha256:[0-9a-f]{64}$"

  def change do
    create table(:environments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :pool_id,
          references(:nodes,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :source_collection_id,
          references(:source_collections,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :queued_ref, :text, null: false
      add :queued_at, :utc_datetime_usec, null: false
      add :image, :text
      add :size, :bigint
      add :commit, :text
      add :built_at, :utc_datetime_usec
      add :reported_ref, :text
      add :failure_cause, :text
      add :failure_reason, :text
      add :failed_at, :utc_datetime_usec
      add :retired_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:environments, [:pool_id, :source_collection_id])
    create index(:environments, [:source_collection_id])
    create index(:environments, [:organisation_id, :workspace_id])

    create constraint(:environments, :environments_queued_ref_check,
             check: "char_length(queued_ref) #{@ref_check}"
           )

    create constraint(:environments, :environments_built_check,
             check:
               "(image IS NULL AND size IS NULL AND commit IS NULL AND built_at IS NULL AND " <>
                 "reported_ref IS NULL) OR (image IS NOT NULL AND size IS NOT NULL AND " <>
                 "commit IS NOT NULL AND built_at IS NOT NULL AND reported_ref IS NOT NULL)"
           )

    create constraint(:environments, :environments_image_check,
             check: "image IS NULL OR (char_length(image) <= 327 AND image ~ '#{@image}')"
           )

    create constraint(:environments, :environments_size_check,
             check: "size IS NULL OR size BETWEEN 1 AND 9007199254740991"
           )

    create constraint(:environments, :environments_commit_check,
             check: "commit IS NULL OR char_length(commit) #{@ref_check}"
           )

    create constraint(:environments, :environments_reported_ref_check,
             check: "reported_ref IS NULL OR char_length(reported_ref) #{@ref_check}"
           )

    create constraint(:environments, :environments_failure_check,
             check:
               "(failure_cause IS NULL AND failure_reason IS NULL AND failed_at IS NULL) OR " <>
                 "(failure_cause IS NOT NULL AND failed_at IS NOT NULL AND (" <>
                 "(failure_cause = 'released' AND failure_reason IS NOT NULL AND " <>
                 "char_length(failure_reason) #{@ref_check}) OR " <>
                 "(failure_cause IN ('lost', 'timed_out') AND failure_reason IS NULL)))"
           )
  end
end
