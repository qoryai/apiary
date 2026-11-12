defmodule Apiary.Repo.Migrations.AddModelChainToTenants do
  use Ecto.Migration

  # Which model providers the runs of a client use: `organisation`, the client's
  # providers, or `operator`, its operator's. Every organisation starts on
  # `organisation`. The database keeps the rules:
  #
  # - Only those two values.
  # - `operator` only on a row that has an operator, so an organisation with no operator,
  #   and a client parted from its operator, is on `organisation`.
  def change do
    alter table(:tenants) do
      add :model_chain, :text, null: false, default: "organisation"
    end

    create constraint(:tenants, :tenants_model_chain_check,
             check: "model_chain IN ('organisation', 'operator')"
           )

    create constraint(:tenants, :tenants_model_chain_operator_check,
             check: "model_chain = 'organisation' OR operator_id IS NOT NULL"
           )
  end
end
