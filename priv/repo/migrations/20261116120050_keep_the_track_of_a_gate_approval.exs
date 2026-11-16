defmodule Apiary.Repo.Migrations.KeepTheTrackOfAGateApproval do
  use Ecto.Migration

  # A process declares tracks, and the gate of a stage offers some of them
  # (`Apiary.Processes`). `gate_decisions.track` is the id of the track a person chose with
  # an approval, nil for no track; only an approval has one. `stage_skips` records which
  # condition passed a stage or an entry over: `input` (the input type of a condition
  # `{input: T}`) or `track` (the track id of a condition `{track: ID}`), exactly one of
  # them, and `negated`, true where the condition was an `unless` that held. The column
  # `input` drops its NOT NULL.
  #
  # Each new column is nullable or has a constant default, so adding it rewrites no row.
  # The checks are added NOT VALID, so adding them takes no scan of the table under its
  # lock; `20261116120100` validates them. No stored row breaks them: no decision has a
  # track, and each skip has an input.
  def up do
    alter table(:gate_decisions) do
      add :track, :text
    end

    create constraint(:gate_decisions, :gate_decisions_track_check,
             check: "track IS NULL OR kind = 'approve'",
             validate: false
           )

    alter table(:stage_skips) do
      modify :input, :text, null: true, from: {:text, null: false}
      add :track, :text
      add :negated, :boolean, null: false, default: false
    end

    create constraint(:stage_skips, :stage_skips_condition_check,
             check: "num_nonnulls(input, track) = 1",
             validate: false
           )
  end

  # Rolled back, the skips that a track condition wrote are deleted: they have no input,
  # which the column needs again. The approvals stay, with no track.
  def down do
    drop constraint(:stage_skips, :stage_skips_condition_check)
    execute "DELETE FROM stage_skips WHERE input IS NULL"

    alter table(:stage_skips) do
      remove :negated
      remove :track
      modify :input, :text, null: false, from: {:text, null: true}
    end

    drop constraint(:gate_decisions, :gate_decisions_track_check)

    alter table(:gate_decisions) do
      remove :track
    end
  end
end
