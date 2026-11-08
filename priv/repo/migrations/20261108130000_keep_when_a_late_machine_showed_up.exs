defmodule Apiary.Repo.Migrations.KeepWhenALateMachineShowedUp do
  use Ecto.Migration

  # When a machine last showed up for a dispatch that takes none any more
  # (`Apiary.Dispatches.Slots`):
  #
  # - `dispatches.late_machine_at`: the time of the last `dispatched` refused for the
  #   dispatch, or of the last redemption of its run code refused because the dispatch
  #   was stale or ended; nil until one. The dispatch then holds its slot of its pool's
  #   instance limit until its machine is reported `gone`.
  #
  # Adding a column that may be empty, with no default, rewrites no row.
  def change do
    alter table(:dispatches) do
      add :late_machine_at, :utc_datetime_usec
    end
  end
end
