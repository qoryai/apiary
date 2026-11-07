defmodule Apiary.Repo.Migrations.KeepTheQoryHarnessFilesByCommit do
  use Ecto.Migration

  # The files of the Qory harness that Qory Apiary reads, by commit
  # (`Apiary.Harnesses.Qory`), and the commit each branch or tag was last read at. The
  # pages read these rows only; a run's start and a new workspace read the repository.
  #
  #   * `qory_harness_files`: one row per file, by the repository's address (`git`), a
  #     full commit id and the file's path. `content` is the file's text, NULL for a file
  #     the commit does not have. A commit's rows are written in one insert, and never
  #     changed after.
  #   * `qory_harness_heads`: one row per branch or tag, by the repository's address and
  #     its name (`ref`): the commit it was at when it was last read, and when.
  #
  # Neither table has an organisation: the rows are the instance's.
  def change do
    create table(:qory_harness_files, primary_key: false) do
      add :git, :text, null: false, primary_key: true
      add :commit, :text, null: false, primary_key: true
      add :path, :text, null: false, primary_key: true
      add :content, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:qory_harness_files, :qory_harness_files_commit_check,
             check: "commit ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'"
           )

    create table(:qory_harness_heads, primary_key: false) do
      add :git, :text, null: false, primary_key: true
      add :ref, :text, null: false, primary_key: true
      add :commit, :text, null: false
      add :read_at, :utc_datetime_usec, null: false
    end

    create constraint(:qory_harness_heads, :qory_harness_heads_commit_check,
             check: "commit ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'"
           )
  end
end
