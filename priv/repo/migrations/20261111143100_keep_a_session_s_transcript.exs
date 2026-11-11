defmodule Apiary.Repo.Migrations.KeepASessionSTranscript do
  use Ecto.Migration

  # The chunks of the transcript of a run's runtime session, one row per
  # `dev.qory.session.transcript` event, keyed by the event's sequence
  # (`Apiary.Runs.Transcript`): the session's number, the runtime's session id, the
  # file's path, the chunk's offset in the file and its bytes, decoded. A continuation of
  # a paused run reads them. Log retention leaves them; the daily retention job deletes
  # a run's chunks once its work item is closed or undone (`Apiary.Retention`). They go
  # with the run.
  #
  # `transcript_paths` has one row per run and path with chunks: how many chunks the run
  # keeps of the path and their bytes, the sequence up to which the chunks were checked
  # for a gap, the offset at which the next chunk has to start, and whether a gap was
  # found (`Apiary.Runs.TranscriptPath`). Each pass of the projection checks only the
  # chunks after that sequence, by the index on the run, the path and the sequence, which
  # a restore reads the file by too.
  #
  # Nothing exists to fill: the chunks of events stored before are not read again.
  def change do
    create table(:session_chunks, primary_key: false) do
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

      add :run_id,
          references(:runs,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :sequence, :bigint, null: false
      add :session, :integer, null: false
      add :session_id, :text, null: false
      add :path, :text, null: false
      add :offset, :bigint, null: false
      add :bytes, :binary, null: false
    end

    create unique_index(:session_chunks, [:run_id, :sequence])
    create index(:session_chunks, [:run_id, :path, :sequence])
    create index(:session_chunks, [:organisation_id, :workspace_id])

    create constraint(:session_chunks, :session_chunks_shape_check,
             check:
               "session >= 1 AND length(session_id) BETWEEN 1 AND 128 AND " <>
                 "length(path) BETWEEN 1 AND 1024 AND \"offset\" >= 0 AND " <>
                 "octet_length(bytes) BETWEEN 1 AND 32768"
           )

    create table(:transcript_paths, primary_key: false) do
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

      add :run_id,
          references(:runs,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false,
          primary_key: true

      add :path, :text, null: false, primary_key: true
      add :chunks, :integer, null: false
      add :bytes, :bigint, null: false
      add :checked_sequence, :bigint, null: false
      add :next_offset, :bigint, null: false
      add :gap, :boolean, null: false
    end

    create index(:transcript_paths, [:organisation_id, :workspace_id])

    create constraint(:transcript_paths, :transcript_paths_shape_check,
             check:
               "length(path) BETWEEN 1 AND 1024 AND chunks >= 0 AND bytes >= 0 AND " <>
                 "checked_sequence >= 0 AND next_offset >= 0"
           )
  end
end
