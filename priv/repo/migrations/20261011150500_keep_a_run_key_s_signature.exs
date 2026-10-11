defmodule Apiary.Repo.Migrations.KeepARunKeySSignature do
  use Ecto.Migration

  # The signature of a run's run key, 64 bytes of Ed25519, beside its payload
  # (`run_key_payload`): a repeat of the registration is given the run key it was given
  # first, byte for byte, whatever signing key the instance holds by then. NULL for every
  # existing row; a run that has one has a payload too (`runs_run_key_signature_check`,
  # added NOT VALID, so it scans no row under a lock that blocks writes; the next migration
  # validates it).
  def up do
    alter table(:runs) do
      add :run_key_signature, :binary
    end

    execute """
    ALTER TABLE runs ADD CONSTRAINT runs_run_key_signature_check CHECK (
      run_key_signature IS NULL OR
      (octet_length(run_key_signature) = 64 AND run_key_payload IS NOT NULL)
    ) NOT VALID
    """
  end

  def down do
    drop constraint(:runs, :runs_run_key_signature_check)

    alter table(:runs) do
      remove :run_key_signature
    end
  end
end
