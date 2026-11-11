defmodule Apiary.Repo.Migrations.KeepAContinuationSResume do
  use Ecto.Migration

  # The `resume` member of a continuation's run configuration (`Apiary.Runs.Transcript`):
  # `runs.resume`, the paused run's id and the session id and path of its transcript, as
  # its claim found them, a JSON object with exactly `run_id`, `session_id` and `path`,
  # each a string; nil for every other run. Written once with the registration, so each
  # run configuration of the run has the same `resume`.
  #
  # Nothing exists to fill: a continuation registered before reads no `resume`, and
  # starts a new session.
  def change do
    alter table(:runs) do
      add :resume, :jsonb
    end

    create constraint(:runs, :runs_resume_check,
             check: """
             resume IS NULL OR (jsonb_typeof(resume) = 'object'
               AND resume - 'run_id' - 'session_id' - 'path' = '{}'::jsonb
               AND jsonb_typeof(resume -> 'run_id') = 'string'
               AND jsonb_typeof(resume -> 'session_id') = 'string'
               AND jsonb_typeof(resume -> 'path') = 'string')
             """
           )
  end
end
