defmodule Apiary.Repo.Migrations.KeepTheRunsAContinuationContinues do
  use Ecto.Migration

  # The paused runs a continuation continues (`Apiary.Runs.Transcript.resume_at_claim/1`):
  # `runs.resume` may have `runs`, 1 to 256 strings, the ids of the paused runs found
  # through each run's continuation, oldest first, as its claim found them, beside
  # `run_id`, `session_id` and `path`.
  #
  # The check is added NOT VALID, so adding it takes no scan of the table under its lock;
  # the next migration validates it. It changes no row: a continuation claimed before has
  # no `runs`, and so no `resume.runs` in its run configuration.
  def up do
    drop constraint(:runs, :runs_resume_check)

    create constraint(:runs, :runs_resume_check,
             check: check(~w(run_id session_id path runs), runs()),
             validate: false
           )
  end

  # Rolled back, a run keeps no `runs`: they are removed from every run that has them.
  def down do
    drop constraint(:runs, :runs_resume_check)

    execute "UPDATE runs SET resume = resume - 'runs' WHERE resume ? 'runs'"

    create constraint(:runs, :runs_resume_check, check: check(~w(run_id session_id path), ""))
  end

  defp check(members, runs) do
    "resume IS NULL OR (jsonb_typeof(resume) = 'object' " <>
      "AND resume ?& ARRAY['run_id', 'session_id', 'path'] " <>
      "AND (resume - ARRAY[#{Enum.map_join(members, ", ", &"'#{&1}'")}]) = '{}'::jsonb " <>
      "AND jsonb_typeof(resume -> 'run_id') = 'string' " <>
      "AND jsonb_typeof(resume -> 'session_id') = 'string' " <>
      "AND jsonb_typeof(resume -> 'path') = 'string'#{runs})"
  end

  # Each CASE branch runs only when the one before it does not hold, so the length of
  # `runs` is read only for an array. The path is strict: a lax path unwraps an array
  # inside `runs`, so `[["a"]]` would pass.
  defp runs do
    " AND CASE WHEN NOT resume ? 'runs' THEN true " <>
      "WHEN jsonb_typeof(resume -> 'runs') <> 'array' THEN false " <>
      "ELSE jsonb_array_length(resume -> 'runs') BETWEEN 1 AND 256 " <>
      "AND NOT jsonb_path_exists(resume, 'strict $.runs[*] ? (@.type() != \"string\")') END"
  end
end
