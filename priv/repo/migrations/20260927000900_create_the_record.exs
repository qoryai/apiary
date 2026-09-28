defmodule Apiary.Repo.Migrations.CreateTheRecord do
  use Ecto.Migration

  # The record of a run, as the runners deliver it (`Apiary.Runs.Ingest`):
  #
  # - `events`: each event a run reported, once, by its sequence in the run and by its id
  #   in the workspace. `projected_at` is set when the projector has folded it in; the
  #   partial index is the projector's queue. The projector also ranks the events of one
  #   type in a run by sequence.
  # - `log_chunks`: the bytes of a run's terminal or pipes, by sequence.
  # - `connections`: what the projector folds from a run's egress events, one row per host,
  #   port and path, with the counts and what the last attempt said. `last_sequence` is the
  #   sequence of the last event folded in: what "last" means, not the clock.
  # - `deliveries`: one row per batch an access key delivered, unique by its delivery id,
  #   so a batch sent again is recognised.
  #
  # The first three are held to their run's workspace by the composite key on
  # `(run_id, workspace_id)`, and go with the run. A delivery names its run by the runner's
  # id, not a foreign key: a delivery for a closed run is recorded too, and the record
  # outlives the run. A key is revoked, never deleted, and what it delivered is not to
  # vanish with it: no action on its key, which still lets a workspace go with everything
  # in it.
  def change do
    create table(:events, primary_key: false) do
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
      add :event_id, :uuid, null: false
      add :type, :text, null: false
      add :time, :utc_datetime_usec, null: false
      add :data, :map, null: false, default: %{}
      add :received_at, :utc_datetime_usec, null: false
      add :projected_at, :utc_datetime_usec
    end

    create unique_index(:events, [:run_id, :sequence])
    create unique_index(:events, [:workspace_id, :event_id])
    create index(:events, [:organisation_id, :workspace_id])
    create index(:events, [:run_id, :type, :sequence])

    create index(:events, [:run_id, :projected_at],
             where: "projected_at IS NULL",
             name: :events_unprojected_index
           )

    create table(:log_chunks, primary_key: false) do
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
      add :stream, :text, null: false
      add :bytes, :binary, null: false
    end

    create unique_index(:log_chunks, [:run_id, :sequence])
    create index(:log_chunks, [:organisation_id, :workspace_id])

    create table(:connections, primary_key: false) do
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

      add :host, :text, null: false
      add :port, :integer, null: false
      add :path, :text, null: false, default: ""
      add :method, :text
      add :attempts, :integer, null: false, default: 0
      add :allowed, :integer, null: false, default: 0
      add :denied, :integer, null: false, default: 0
      add :last_decision, :text
      add :last_rule, :text
      add :last_outcome, :text
      add :last_mode, :text
      add :last_path_rule, :text
      add :last_credential, :text
      add :last_request_method, :text
      add :last_tool, :text
      add :last_status, :integer
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :last_sequence, :bigint, null: false, default: 0
    end

    create unique_index(:connections, [:run_id, :host, :port, :path])
    create index(:connections, [:organisation_id, :workspace_id])
    create index(:connections, [:workspace_id, :last_seen_at])

    create table(:deliveries, primary_key: false) do
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

      add :access_key_id, references(:access_keys, type: :binary_id, on_delete: :nothing),
        null: false

      add :delivery_id, :uuid, null: false
      add :run_id, :uuid, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :event_count, :integer, null: false, default: 0
      add :inserted_count, :integer, null: false, default: 0
      add :status, :integer, null: false
      add :run_configuration_digest, :text
    end

    create unique_index(:deliveries, [:access_key_id, :delivery_id])
    create index(:deliveries, [:organisation_id, :workspace_id])
    create index(:deliveries, [:workspace_id, :run_id])
  end
end
