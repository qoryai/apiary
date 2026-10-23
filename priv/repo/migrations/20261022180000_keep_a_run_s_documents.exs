defmodule Apiary.Repo.Migrations.KeepARunSDocuments do
  use Ecto.Migration

  # The documents of a run registered at its claim, encoded once at the claim, which the
  # redemption of its run code answers byte for byte, to a retry too
  # (`Apiary.Runs.RunCode`). Null for every other run.
  def change do
    alter table(:runs) do
      add :run_documents, :binary
    end
  end
end
