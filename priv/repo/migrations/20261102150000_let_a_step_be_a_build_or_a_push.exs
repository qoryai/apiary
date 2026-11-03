defmodule Apiary.Repo.Migrations.LetAStepBeABuildOrAPush do
  use Ecto.Migration

  # Two more kinds of step on `run_steps`: `build`, which Forager sends already and which
  # the fold left without a kind, and `push`, the host step after the last session and
  # before the run's exit.
  #
  # The check is added NOT VALID, so adding it takes no scan of the table under its lock;
  # the next migration validates it. Rows folded before this migration keep their kinds,
  # all of them in the wider list.
  def up do
    drop constraint(:run_steps, :run_steps_kind_check)

    create constraint(:run_steps, :run_steps_kind_check,
             check:
               "kind IN ('fetch', 'compose', 'image', 'build', 'setup', 'join', 'wall', 'push')",
             validate: false
           )
  end

  # Rolled back, a step of these two kinds has no kind, as the fold leaves a kind it does
  # not know.
  def down do
    drop constraint(:run_steps, :run_steps_kind_check)
    execute "UPDATE run_steps SET kind = NULL WHERE kind IN ('build', 'push')"

    create constraint(:run_steps, :run_steps_kind_check,
             check: "kind IN ('fetch', 'compose', 'image', 'setup', 'join', 'wall')"
           )
  end
end
