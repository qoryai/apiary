defmodule Apiary.Repo.Migrations.KeepTheCommitsARunPushed do
  use Ecto.Migration

  # `run_pushed_commits`: the commits a run reported it pushed to its targets
  # (`Apiary.Runs.PushedCommit`), one row per commit and place, in the order the run
  # reported them:
  #
  # - `sequence` is the position in the run's list, from 1, in the order Qory Apiary stored
  #   the rows;
  # - `system` and `path` are the place the commit went to, as the run sent them;
  # - `commit` is the full commit id, 40 or 64 lowercase hex characters;
  # - `at` is when Qory Apiary stored the row.
  #
  # A repeat of a commit for the same run, system and path is one row (the unique index on
  # the four), so a run that sends its report again stores nothing new. Not an event
  # projection: nothing rebuilds the rows, and the retention of a run's events leaves them.
  #
  # A new table: no row of another table is written again, and its keys and its check are
  # part of its creation.
  def change do
    create table(:run_pushed_commits, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :run_id,
          references(:runs,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :sequence, :bigint, null: false
      add :system, :text, null: false
      add :path, :text, null: false
      add :commit, :text, null: false
      add :at, :utc_datetime_usec, null: false
    end

    create unique_index(:run_pushed_commits, [:run_id, :sequence])
    create unique_index(:run_pushed_commits, [:run_id, :system, :path, :commit])
    create index(:run_pushed_commits, [:organisation_id, :workspace_id])

    create constraint(:run_pushed_commits, :run_pushed_commits_commit_check,
             check: "commit ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'"
           )

    create constraint(:run_pushed_commits, :run_pushed_commits_sequence_check,
             check: "sequence >= 1"
           )
  end
end
