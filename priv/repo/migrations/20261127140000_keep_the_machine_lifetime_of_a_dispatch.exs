defmodule Apiary.Repo.Migrations.KeepTheMachineLifetimeOfADispatch do
  use Ecto.Migration

  # `machine_lifetime_minutes` of `dispatches`: the minutes its claim answer let the
  # machine live (`max_lifetime_minutes`), which the claim computes from the run's time
  # limits (`Apiary.Dispatches.RunEnd.lifetime_minutes/2`). A dispatch claimed before this
  # column stays nil, and its step's lifetime applies to it
  # (`Apiary.Dispatches.DispatchRun.machine_lifetime_minutes/1`).
  def change do
    alter table(:dispatches) do
      add :machine_lifetime_minutes, :integer
    end
  end
end
