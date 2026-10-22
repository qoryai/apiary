defmodule Apiary.Repo.Migrations.KeepADispatchSMachineLog do
  use Ecto.Migration

  # The machine log a node pool's starter uploads for a dispatch, at most one per dispatch
  # (`Apiary.Dispatches.MachineLog`). The text is a file in the folder
  # APIARY_MACHINE_LOGS_DIR sets (`Apiary.Dispatches.MachineLogStore`); the row has:
  #
  # - `storage_key`, the file's name in that folder: the dispatch's public id;
  # - `byte_size`, the text's size in bytes as UTF-8;
  # - `truncated`, true when the starter cut the log to its last part;
  # - `uploaded_at`, when Qory Apiary stored it.
  #
  # The row goes with its dispatch (`ON DELETE CASCADE`); the retention job deletes a file
  # whose row is gone.
  #
  # And `instance_settings.machine_log_retention_days`, how many days a machine log is
  # kept, as MACHINE_LOG_RETENTION_DAYS sets it: 1 to 365, NULL until an instance admin
  # saves one, and NULL is the default.
  def change do
    create table(:dispatch_machine_logs, primary_key: false) do
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

      add :dispatch_id, references(:dispatches, type: :binary_id, on_delete: :delete_all),
        null: false

      add :storage_key, :text, null: false
      add :byte_size, :bigint, null: false
      add :truncated, :boolean, null: false, default: false
      add :uploaded_at, :utc_datetime_usec, null: false
    end

    create unique_index(:dispatch_machine_logs, [:dispatch_id])
    create unique_index(:dispatch_machine_logs, [:storage_key])
    create index(:dispatch_machine_logs, [:organisation_id, :workspace_id])
    create index(:dispatch_machine_logs, [:uploaded_at])

    create constraint(:dispatch_machine_logs, :dispatch_machine_logs_storage_key_check,
             check: "storage_key ~ '^dp_[0-9a-hjkmnp-tv-z]{16}$'"
           )

    create constraint(:dispatch_machine_logs, :dispatch_machine_logs_byte_size_check,
             check: "byte_size >= 0"
           )

    alter table(:instance_settings) do
      add :machine_log_retention_days, :integer
    end

    create constraint(:instance_settings, :instance_settings_machine_log_retention_days_check,
             check: "machine_log_retention_days BETWEEN 1 AND 365"
           )
  end
end
