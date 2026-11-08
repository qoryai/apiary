defmodule Apiary.Repo.Migrations.KeepAPoolSOffers do
  use Ecto.Migration

  # `nodes.offers`: the machines a node pool offered in its latest claim, as the claim
  # had them; null for a pool whose latest claim had no offers, or that has not claimed.
  #
  # Adding a column that may be empty, with no default, rewrites no row. One table per
  # migration: 20261107110100 has the reason.
  def change do
    alter table(:nodes) do
      add :offers, :jsonb
    end
  end
end
