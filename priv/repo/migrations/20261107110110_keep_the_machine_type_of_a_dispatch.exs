defmodule Apiary.Repo.Migrations.KeepTheMachineTypeOfADispatch do
  use Ecto.Migration

  # `dispatches.machine_type` and `dispatches.machine_spec`: the machine type and its spec
  # that the claim answer of the dispatch had; null for an answer to a claim with no
  # offers, which has neither. The claim writes both or neither
  # (`claim_run/6` in lib/apiary/dispatches.ex). The database has no check that the two
  # are both set or both null.
  #
  # Adding columns that may be empty, with no default, rewrites no row. One table per
  # migration: 20261107110100 has the reason.
  def change do
    alter table(:dispatches) do
      add :machine_type, :text
      add :machine_spec, :jsonb
    end
  end
end
