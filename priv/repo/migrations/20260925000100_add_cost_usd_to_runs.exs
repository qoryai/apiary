defmodule Apiary.Repo.Migrations.AddCostUsdToRuns do
  use Ecto.Migration

  # Expand only. The cost a run reported, the sum of `cost_usd` over its session result
  # events, folded by the projector; null on a run that reported none, never zero.
  # Nullable without a default: instant. Runs projected before this are filled by
  # `mix apiary.rebuild` (see Upgrading in the changelog).
  def change do
    alter table(:runs) do
      add :cost_usd, :numeric
    end
  end
end
