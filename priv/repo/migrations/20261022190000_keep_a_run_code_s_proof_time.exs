defmodule Apiary.Repo.Migrations.KeepARunCodeSProofTime do
  use Ecto.Migration

  # The timestamp of the proof of the newest accepted redemption of a run's code, the
  # first or a retry, in Unix seconds. A retry by the same public key is accepted only
  # with a newer one (`Apiary.Runs.RunCode`). Null until the first redemption, and for
  # every other run.
  def change do
    alter table(:runs) do
      add :run_code_proof_timestamp, :bigint
    end
  end
end
