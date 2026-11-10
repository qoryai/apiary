defmodule Apiary.Repo.Migrations.LetAStepBeAMachine do
  use Ecto.Migration

  # One more kind of step on `run_steps`: `machine`, the start of the run's machine, which
  # `qory run` sends after the redemption of the run's code, one log line per part of the
  # start.
  #
  # The check is added NOT VALID, so adding it takes no scan of the table under its lock;
  # the next migration validates it. Rows folded before this migration keep their kinds,
  # all of them in the wider list.
  def up do
    drop constraint(:run_steps, :run_steps_kind_check)

    create constraint(:run_steps, :run_steps_kind_check,
             check:
               "kind IN ('fetch', 'compose', 'image', 'build', 'setup', 'join', 'wall', 'push', 'machine')",
             validate: false
           )
  end

  # Rolled back, a step of this kind has no kind, as the fold leaves any kind outside its
  # list.
  def down do
    drop constraint(:run_steps, :run_steps_kind_check)
    execute "UPDATE run_steps SET kind = NULL WHERE kind = 'machine'"

    create constraint(:run_steps, :run_steps_kind_check,
             check:
               "kind IN ('fetch', 'compose', 'image', 'build', 'setup', 'join', 'wall', 'push')"
           )
  end
end
