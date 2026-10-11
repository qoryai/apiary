defmodule Apiary.Repo.Migrations.LetARunGoThroughAGateway do
  use Ecto.Migration

  # A run that goes through a gateway (`Apiary.Runs.Registration`, `Apiary.Runs.Attach`), on
  # its own row of `runs`:
  #
  # - `gateway_id`, the gateway the registering node's choice resolved to: a plain reference
  #   to the gateway's own row, set NULL should that row go with a purge;
  # - `run_key_payload`, the exact bytes of the run key's payload the server signed, at
  #   most 2048 bytes; `run_key_issued_at`, when the run key was made; `attach_by`, the end
  #   of its attach window;
  # - `attached_at`, when the gateway attached the run; `attach_time`, the attach's `time`,
  #   on the gateway's clock; `attach_interval_seconds`, the heartbeat interval the attach
  #   announced, which the run is held to; `attach_answer_digest`, the digest of the run
  #   configuration the attach was given, which a repeat of the attach is given again.
  #
  # All NULL for a direct run, every existing row among them. A run that went through a
  # gateway holds the run key's three from its registration, and the attach's four once
  # attached. `runs_registration_check` is relaxed as far as such a run needs: its
  # registration carries no heartbeat interval and is given no run configuration, so those
  # two columns are NULL on it, and set on every direct registration as before.
  #
  # The checks and the reference are added NOT VALID, so adding them takes no scan of the
  # table under its lock; the next migration validates them.
  @registration_columns ~w(registered_at registration_labels registration_about
                            registration_digest)

  def up do
    alter table(:runs) do
      add :gateway_id,
          references(:nodes, type: :binary_id, on_delete: :nilify_all, validate: false)

      add :run_key_payload, :binary
      add :run_key_issued_at, :utc_datetime_usec
      add :attach_by, :utc_datetime_usec
      add :attached_at, :utc_datetime_usec
      add :attach_time, :utc_datetime_usec
      add :attach_interval_seconds, :integer
      add :attach_answer_digest, :text
    end

    drop constraint(:runs, :runs_registration_check)

    create constraint(:runs, :runs_registration_check,
             check:
               "(#{all_null(@registration_columns)} AND registration_interval_seconds IS NULL " <>
                 "AND registration_answer_digest IS NULL) OR " <>
                 "(#{all_set(@registration_columns)} AND " <>
                 "((registration_interval_seconds IS NOT NULL AND " <>
                 "registration_answer_digest IS NOT NULL) OR " <>
                 "(run_key_payload IS NOT NULL AND registration_interval_seconds IS NULL AND " <>
                 "registration_answer_digest IS NULL)))",
             validate: false
           )

    create constraint(:runs, :runs_run_key_check,
             check:
               "(run_key_payload IS NULL AND run_key_issued_at IS NULL AND attach_by IS NULL " <>
                 "AND gateway_id IS NULL) OR " <>
                 "(octet_length(run_key_payload) BETWEEN 1 AND 2048 AND " <>
                 "run_key_issued_at IS NOT NULL AND attach_by > run_key_issued_at AND " <>
                 "registered_at IS NOT NULL)",
             validate: false
           )

    create constraint(:runs, :runs_attach_check,
             check:
               "(attached_at IS NULL AND attach_time IS NULL AND " <>
                 "attach_interval_seconds IS NULL AND attach_answer_digest IS NULL) OR " <>
                 "(attached_at IS NOT NULL AND attach_time IS NOT NULL AND " <>
                 "attach_interval_seconds BETWEEN 1 AND 300 AND " <>
                 "attach_answer_digest IS NOT NULL AND run_key_payload IS NOT NULL)",
             validate: false
           )
  end

  # Rolled back, a run that went through a gateway could not be held: refused while any is
  # there.
  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM runs WHERE run_key_payload IS NOT NULL) THEN
        RAISE EXCEPTION 'runs holds runs that went through a gateway: delete them before rolling this back';
      END IF;
    END
    $$
    """)

    drop constraint(:runs, :runs_attach_check)
    drop constraint(:runs, :runs_run_key_check)
    drop constraint(:runs, :runs_registration_check)

    alter table(:runs) do
      remove :attach_answer_digest
      remove :attach_interval_seconds
      remove :attach_time
      remove :attached_at
      remove :attach_by
      remove :run_key_issued_at
      remove :run_key_payload
      remove :gateway_id
    end

    create constraint(:runs, :runs_registration_check,
             check:
               "(#{all_null(@registration_columns)} AND registration_interval_seconds IS NULL " <>
                 "AND registration_answer_digest IS NULL) OR " <>
                 "(#{all_set(@registration_columns)} AND " <>
                 "registration_interval_seconds IS NOT NULL AND " <>
                 "registration_answer_digest IS NOT NULL)"
           )
  end

  defp all_null(columns), do: Enum.map_join(columns, " AND ", &"#{&1} IS NULL")
  defp all_set(columns), do: Enum.map_join(columns, " AND ", &"#{&1} IS NOT NULL")
end
