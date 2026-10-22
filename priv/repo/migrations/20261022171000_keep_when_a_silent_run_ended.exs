defmodule Apiary.Repo.Migrations.KeepWhenASilentRunEnded do
  use Ecto.Migration

  # `runs.silenced_at`: when the lost-run check ended a handed-over run for 600 s without
  # a heartbeat and moved its `backstop_at` back to the end of that silence
  # (`Apiary.Dispatches.RunEnd`). The Overview reads it to tell a silence end apart from
  # an end at the deadline its attach set. Nil for every other run. Not folded: a
  # rebuild keeps it. Adding a column that may be empty, with no default, rewrites no row.
  def change do
    alter table(:runs) do
      add :silenced_at, :utc_datetime_usec
    end
  end
end
