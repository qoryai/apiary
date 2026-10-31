defmodule Apiary.Repo.Migrations.CreateArtifacts do
  use Ecto.Migration

  # The artifacts of a work item (`Apiary.Artifacts`): the records and versions are kept
  # here, the content in a store (`Apiary.Artifacts.Store`).
  #
  # - `artifact_types`: a workspace's custom types. `public_id` is `at_` and sixteen
  #   lowercase Crockford base32 characters (`Apiary.PublicId`). `name` is lowercase
  #   letters and digits in groups joined by single hyphens, 1 to 64 bytes, unique in the
  #   workspace. `base_view` is `document`, `image`, `video`, `file` or `structured`.
  #   `size_limit` is the most bytes of all files of one version, 1 to 2 GiB.
  #   `max_files` is the most files of one version, 1 to 20, and exactly 1 for a structured
  #   type, which alone has a `json_schema`.
  # - `artifacts`: one row per work item, type and name. `public_id` is `af_`. `type` and
  #   `name` follow the rule of a type's name; `name` is `main` unless a push sets
  #   another. `stage_id` is the stage of the first version, NULL for none.
  # - `artifact_versions`: one row per version of an artifact. `public_id` is `av_`.
  #   `number` counts the versions of an artifact from 1, unique per artifact. `writer` is
  #   `run` or `person`: a run's version links to the run of the queue (`run_id`), a
  #   person's to the account (`user_id`); each link is set to NULL should its row go.
  #   `note` is at most 4,000 characters.
  # - `artifact_files`: one row per file of a version. `filename` is 1 to 255 bytes with
  #   no `/`, `\` or NUL, and neither `.` nor `..`, unique in the version. `sha256` is the
  #   content's digest in lowercase hex, and `store_key` the key the store keeps the
  #   content under.
  #
  # Each table is held to its organisation, and to its workspace by the composite key. An
  # artifact is held to its work item, a version to its artifact and a file to its version
  # by keys that follow the parent to another workspace (`ON UPDATE CASCADE`) and go with
  # it (`ON DELETE CASCADE`). The tables are new, and empty.

  @public_id "[0-9a-hjkmnp-tv-z]{16}"
  @name "^[a-z0-9]+(-[a-z0-9]+)*$"

  def up do
    create table(:artifact_types, primary_key: false) do
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

      add :public_id, :text, null: false
      add :name, :text, null: false
      add :base_view, :text, null: false
      add :size_limit, :bigint, null: false
      add :max_files, :integer, null: false
      add :json_schema, :map
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:artifact_types, [:public_id])
    create unique_index(:artifact_types, [:workspace_id, :name])
    create index(:artifact_types, [:organisation_id, :workspace_id])

    create constraint(:artifact_types, :artifact_types_public_id_check,
             check: "public_id ~ '^at_#{@public_id}$'"
           )

    create constraint(:artifact_types, :artifact_types_name_check,
             check: "name ~ '#{@name}' AND octet_length(name) <= 64"
           )

    create constraint(:artifact_types, :artifact_types_base_view_check,
             check: "base_view IN ('document', 'image', 'video', 'file', 'structured')"
           )

    create constraint(:artifact_types, :artifact_types_size_limit_check,
             check: "size_limit BETWEEN 1 AND 2147483648"
           )

    create constraint(:artifact_types, :artifact_types_max_files_check,
             check: "max_files BETWEEN 1 AND 20 AND (base_view <> 'structured' OR max_files = 1)"
           )

    create constraint(:artifact_types, :artifact_types_json_schema_check,
             check:
               "(base_view = 'structured') = (json_schema IS NOT NULL) AND " <>
                 "(json_schema IS NULL OR jsonb_typeof(json_schema) = 'object')"
           )

    create table(:artifacts, primary_key: false) do
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

      add :work_item_id, :binary_id, null: false
      add :public_id, :text, null: false
      add :type, :text, null: false
      add :name, :text, null: false, default: "main"
      add :stage_id, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    execute("""
    ALTER TABLE artifacts ADD CONSTRAINT artifacts_work_item_id_fkey
      FOREIGN KEY (work_item_id, workspace_id) REFERENCES work_items (id, workspace_id)
      MATCH FULL ON DELETE CASCADE ON UPDATE CASCADE
    """)

    create unique_index(:artifacts, [:public_id])
    create unique_index(:artifacts, [:work_item_id, :type, :name])
    create unique_index(:artifacts, [:id, :workspace_id])
    create index(:artifacts, [:organisation_id, :workspace_id])

    create constraint(:artifacts, :artifacts_public_id_check,
             check: "public_id ~ '^af_#{@public_id}$'"
           )

    create constraint(:artifacts, :artifacts_type_check,
             check: "type ~ '#{@name}' AND octet_length(type) <= 64"
           )

    create constraint(:artifacts, :artifacts_name_check,
             check: "name ~ '#{@name}' AND octet_length(name) <= 64"
           )

    create constraint(:artifacts, :artifacts_stage_id_check,
             check: "stage_id IS NULL OR octet_length(stage_id) BETWEEN 1 AND 64"
           )

    create table(:artifact_versions, primary_key: false) do
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

      add :artifact_id, :binary_id, null: false
      add :public_id, :text, null: false
      add :number, :integer, null: false
      add :writer, :text, null: false
      add :run_id, references(:dispatch_runs, type: :binary_id, on_delete: :nilify_all)
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :stage_id, :text
      add :note, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    execute("""
    ALTER TABLE artifact_versions ADD CONSTRAINT artifact_versions_artifact_id_fkey
      FOREIGN KEY (artifact_id, workspace_id) REFERENCES artifacts (id, workspace_id)
      MATCH FULL ON DELETE CASCADE ON UPDATE CASCADE
    """)

    create unique_index(:artifact_versions, [:public_id])
    create unique_index(:artifact_versions, [:artifact_id, :number])
    create unique_index(:artifact_versions, [:id, :workspace_id])
    create index(:artifact_versions, [:organisation_id, :workspace_id])
    create index(:artifact_versions, [:run_id])
    create index(:artifact_versions, [:user_id])

    create constraint(:artifact_versions, :artifact_versions_public_id_check,
             check: "public_id ~ '^av_#{@public_id}$'"
           )

    create constraint(:artifact_versions, :artifact_versions_number_check, check: "number >= 1")

    # A run's version has no account, a person's no run. Either link is NULL once its row
    # is gone.
    create constraint(:artifact_versions, :artifact_versions_writer_check,
             check:
               "(writer = 'run' AND user_id IS NULL) OR (writer = 'person' AND run_id IS NULL)"
           )

    create constraint(:artifact_versions, :artifact_versions_stage_id_check,
             check: "stage_id IS NULL OR octet_length(stage_id) BETWEEN 1 AND 64"
           )

    create constraint(:artifact_versions, :artifact_versions_note_check,
             check: "note IS NULL OR char_length(note) BETWEEN 1 AND 4000"
           )

    create table(:artifact_files, primary_key: false) do
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

      add :version_id, :binary_id, null: false
      add :filename, :text, null: false
      add :content_type, :text, null: false
      add :size, :bigint, null: false
      add :sha256, :text, null: false
      add :store_key, :text, null: false
    end

    execute("""
    ALTER TABLE artifact_files ADD CONSTRAINT artifact_files_version_id_fkey
      FOREIGN KEY (version_id, workspace_id) REFERENCES artifact_versions (id, workspace_id)
      MATCH FULL ON DELETE CASCADE ON UPDATE CASCADE
    """)

    create unique_index(:artifact_files, [:version_id, :filename])
    create index(:artifact_files, [:organisation_id, :workspace_id])
    create index(:artifact_files, [:sha256])

    create constraint(:artifact_files, :artifact_files_filename_check,
             check:
               "octet_length(filename) BETWEEN 1 AND 255 AND filename NOT IN ('.', '..') " <>
                 "AND strpos(filename, '/') = 0 AND strpos(filename, E'\\\\') = 0"
           )

    create constraint(:artifact_files, :artifact_files_size_check, check: "size >= 0")

    create constraint(:artifact_files, :artifact_files_sha256_check,
             check: "sha256 ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:artifact_files, :artifact_files_content_type_check,
             check: "octet_length(content_type) BETWEEN 1 AND 255"
           )

    create constraint(:artifact_files, :artifact_files_store_key_check,
             check: "octet_length(store_key) BETWEEN 1 AND 255"
           )
  end

  # Rolled back, the tables go, so the roll back refuses while an artifact or a custom type
  # is kept: it deletes none.
  @refusal "Qory Apiary keeps the artifacts of work items and the custom artifact types " <>
             "of workspaces, so this migration rolls back only while none is kept. Some are."

  def down do
    execute("LOCK TABLE artifact_types, artifacts IN SHARE MODE")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM artifacts) OR EXISTS (SELECT 1 FROM artifact_types) THEN
        RAISE EXCEPTION '#{@refusal}';
      END IF;
    END
    $$
    """)

    drop table(:artifact_files)
    drop table(:artifact_versions)
    drop table(:artifacts)
    drop table(:artifact_types)
  end
end
