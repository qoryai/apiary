defmodule Apiary.Repo.Migrations.AddTerminalSizeToRuns do
  use Ecto.Migration

  # Expand only. The size of the pseudo-terminal an interactive run runs on, as the record
  # last said it: `terminal` of `dev.qory.run.started`, then each `dev.qory.run.resized`,
  # folded by the projector. Null on a run on pipes, and on one recorded by a runner that
  # did not report the size. Nullable without a default: instant. Runs projected before
  # this are filled by `mix apiary.rebuild` (see Upgrading in the changelog).
  def change do
    alter table(:runs) do
      add :terminal_cols, :integer
      add :terminal_rows, :integer
    end
  end
end
