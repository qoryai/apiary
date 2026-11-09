defmodule Apiary.Repo.Migrations.LetAStepBeACopy do
  use Ecto.Migration

  # One more kind of step on `run_steps`: `copy`, the host work that copies the run's work
  # back from the wall after its last agent session, which `qory run` sends around the
  # session that makes the copy.
  #
  # The check is added NOT VALID, so adding it takes no scan of the table under its lock;
  # the next migration validates it. Rows folded before this migration keep their kinds,
  # all of them in the wider list.
  def up do
    drop constraint(:run_steps, :run_steps_kind_check)

    create constraint(:run_steps, :run_steps_kind_check,
             check:
               "kind IN ('fetch', 'compose', 'image', 'build', 'setup', 'join', 'wall', 'push', 'machine', 'copy')",
             validate: false
           )
  end

  # Rolled back, a step of this kind has no kind, as the fold leaves any kind outside its
  # list.
  def down do
    drop constraint(:run_steps, :run_steps_kind_check)
    execute "UPDATE run_steps SET kind = NULL WHERE kind = 'copy'"

    create constraint(:run_steps, :run_steps_kind_check,
             check:
               "kind IN ('fetch', 'compose', 'image', 'build', 'setup', 'join', 'wall', 'push', 'machine')"
           )
  end
end
