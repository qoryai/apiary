defmodule Apiary.Repo.Migrations.KeepTheSessionWhereARunPaused do
  use Ecto.Migration

  # `runs.paused_session`: the number of the session of the run that paused at the limit
  # of its model keys, from that session's `dev.qory.session.exited`. Folded
  # (`Apiary.Runs.Fold`), so a rebuild sets it again; null while no session paused. The
  # run that continues a paused run resumes this session's transcript
  # (`Apiary.Runs.Transcript`). Adding a column that may be empty, with no default,
  # rewrites no row.
  def change do
    alter table(:runs) do
      add :paused_session, :integer
    end
  end
end
