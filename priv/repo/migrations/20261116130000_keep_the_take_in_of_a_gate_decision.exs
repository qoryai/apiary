defmodule Apiary.Repo.Migrations.KeepTheTakeInOfAGateDecision do
  use Ecto.Migration

  # `gate_decisions.take_in` is the take in of the work item that a decision was made in
  # (`Apiary.Stages`). The track a work item is on is the track of its newest approval in
  # the current take in, so a work item taken in again starts with no track.
  #
  # A nullable column with no default rewrites no row. A decision stored before has none, and
  # none of them has a track.
  def up do
    alter table(:gate_decisions) do
      add :take_in, :integer
    end
  end

  def down do
    alter table(:gate_decisions) do
      remove :take_in
    end
  end
end
