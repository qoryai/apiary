defmodule Apiary.Repo.Migrations.CloseEveryDeclinedWorkItem do
  use Ecto.Migration

  # A person closes a work item they do not want, so `declined` goes as a state of a work
  # item and as a kind of event, and `decline` as the resolution of an escalation.
  #
  # - A declined work item becomes closed: `closed_at` and `closed_by_id` take the values
  #   of `declined_at` and `declined_by_id`, and both columns go.
  # - A `declined` event becomes `closed`. Its `data` stays, with the stage it ended at.
  # - A `taken_in` event whose `before` has the state `declined` gets the state `closed`,
  #   so an undo of that take in again goes back to closed.
  # - An escalation resolved with `decline` reads `close`.
  # - The audit trail stays as it is, as its entries record what happened.
  #
  # Rolled back, the columns and the checks come back with no declined row: a work item
  # closed here stays closed, as no row records that it was declined.
  @states ~w(exploring closed undone)
  @kinds ~w(taken_in closed undone answered confirmed explore_again)
  @resolutions ~w(accept another_round move_back close)

  def up do
    execute("LOCK TABLE work_items, work_item_events, escalations IN ACCESS EXCLUSIVE MODE")

    drop constraint(:work_items, :work_items_declined_check)
    drop constraint(:work_items, :work_items_state_check)

    execute("""
    UPDATE work_items
    SET state = 'closed', closed_at = declined_at, closed_by_id = declined_by_id
    WHERE state = 'declined'
    """)

    create constraint(:work_items, :work_items_state_check,
             check: "state IN (#{quoted(@states)})"
           )

    drop index(:work_items, [:declined_by_id])

    alter table(:work_items) do
      remove :declined_at
      remove :declined_by_id
    end

    drop constraint(:work_item_events, :work_item_events_kind_check)

    execute("UPDATE work_item_events SET kind = 'closed' WHERE kind = 'declined'")

    execute("""
    UPDATE work_item_events
    SET data = jsonb_set(data, '{before,state}', '"closed"')
    WHERE kind = 'taken_in' AND data #>> '{before,state}' = 'declined'
    """)

    create constraint(:work_item_events, :work_item_events_kind_check,
             check: "kind IN (#{quoted(@kinds)})"
           )

    drop constraint(:escalations, :escalations_resolution_check)

    execute("UPDATE escalations SET resolution = 'close' WHERE resolution = 'decline'")

    create constraint(:escalations, :escalations_resolution_check, check: resolved(@resolutions))
  end

  def down do
    drop constraint(:escalations, :escalations_resolution_check)

    create constraint(:escalations, :escalations_resolution_check,
             check: resolved(@resolutions ++ ["decline"])
           )

    drop constraint(:work_item_events, :work_item_events_kind_check)

    create constraint(:work_item_events, :work_item_events_kind_check,
             check: "kind IN (#{quoted(@kinds ++ ["declined"])})"
           )

    alter table(:work_items) do
      add :declined_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :declined_at, :utc_datetime_usec
    end

    create index(:work_items, [:declined_by_id])

    drop constraint(:work_items, :work_items_state_check)

    create constraint(:work_items, :work_items_state_check,
             check: "state IN (#{quoted(@states ++ ["declined"])})"
           )

    create constraint(:work_items, :work_items_declined_check,
             check:
               "(state = 'declined') = (declined_at IS NOT NULL) AND " <>
                 "(declined_by_id IS NULL OR declined_at IS NOT NULL)"
           )
  end

  defp resolved(resolutions) do
    "(resolved_at IS NULL AND resolution IS NULL) OR " <>
      "(resolved_at IS NOT NULL AND resolution IN (#{quoted(resolutions)}))"
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
