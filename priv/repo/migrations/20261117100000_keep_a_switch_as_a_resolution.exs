defmodule Apiary.Repo.Migrations.KeepASwitchAsAResolution do
  use Ecto.Migration

  # A person resolves an escalation by switching the work item to another track of the gate
  # that recorded its track (`Apiary.Stages.resolve_escalation/5`), so
  # `escalations.resolution` may be `switch`. The check `escalations_resolution_check`
  # becomes: open with no resolution, or resolved with one of `accept`, `another_round`,
  # `move_back`, `switch` and `close`.
  #
  # The new check is added NOT VALID, so adding it takes no scan of the table under its
  # lock; `20261117100100` validates it. No stored row breaks it: each resolution of a row
  # is in the earlier list.
  @resolutions ~w(accept another_round move_back close)

  def up do
    drop constraint(:escalations, :escalations_resolution_check)

    create constraint(:escalations, :escalations_resolution_check,
             check: resolved(["switch" | @resolutions]),
             validate: false
           )
  end

  # Rolled back, the escalations resolved with `switch` are deleted, as the earlier check
  # allows no such resolution. The work item stays where the switch put it, with the track
  # that the switch recorded on its gate decision and the entry in the audit trail.
  def down do
    drop constraint(:escalations, :escalations_resolution_check)
    execute "DELETE FROM escalations WHERE resolution = 'switch'"

    create constraint(:escalations, :escalations_resolution_check,
             check: resolved(@resolutions),
             validate: false
           )
  end

  defp resolved(resolutions) do
    "(resolved_at IS NULL AND resolution IS NULL) OR " <>
      "(resolved_at IS NOT NULL AND resolution IN (#{quoted(resolutions)}))"
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
