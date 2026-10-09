defmodule Apiary.Repo.Migrations.SayWhereARunCredentialCameFrom do
  use Ecto.Migration

  # A run says where its credential came from: `credential` of its `dev.qory.run.started`,
  # `issuer` or `none`, NULL until a start says it. It is folded from the events
  # (`Apiary.Runs.Fold`) like every other field. A run whose credential came from an issuer
  # is never closed by the workspace once its start says so (`Apiary.Runs.close_run/2`).
  def up do
    alter table(:runs) do
      add :credential_from, :text
    end

    create constraint(:runs, :runs_credential_from_check,
             check: "credential_from IN ('issuer', 'none')"
           )
  end

  def down do
    drop constraint(:runs, :runs_credential_from_check)

    alter table(:runs) do
      remove :credential_from
    end
  end
end
