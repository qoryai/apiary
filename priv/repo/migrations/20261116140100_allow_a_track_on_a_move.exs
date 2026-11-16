defmodule Apiary.Repo.Migrations.AllowATrackOnAMove do
  use Ecto.Migration

  # A person's move forward past a gate that offers tracks records a track as an approval
  # does (`Apiary.Stages.move/5`), so `gate_decisions.track` may be set on a `move` too.
  # The check `gate_decisions_track_check` of `20261116120050` becomes `track IS NULL OR
  # kind IN ('approve', 'move')`.
  #
  # The new check is added NOT VALID, so adding it takes no scan of the table under its
  # lock; `20261116140200` validates it. No stored row breaks it: a row with a track is an
  # approval.
  def up do
    drop constraint(:gate_decisions, :gate_decisions_track_check)

    create constraint(:gate_decisions, :gate_decisions_track_check,
             check: "track IS NULL OR kind IN ('approve', 'move')",
             validate: false
           )
  end

  # Rolled back, the tracks that moves recorded are removed, so the earlier check holds: the
  # work item's track is then the one of its newest approval.
  def down do
    drop constraint(:gate_decisions, :gate_decisions_track_check)
    execute "UPDATE gate_decisions SET track = NULL WHERE kind <> 'approve'"

    create constraint(:gate_decisions, :gate_decisions_track_check,
             check: "track IS NULL OR kind = 'approve'",
             validate: false
           )
  end
end
