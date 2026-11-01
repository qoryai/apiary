defmodule Apiary.Repo.Migrations.NumberEveryRun do
  use Ecto.Migration

  # Every run gets a number, unique on the server: 1 for the first run, then one more for
  # each (`Apiary.Runs.Run`, `number`). The console addresses a run by it,
  # `/:org/:workspace/runs/:number`.
  #
  # The runs that are there already are numbered in the order they started, by
  # `coalesce(started_at, inserted_at)`, then `inserted_at` and `id` for a tie. The
  # sequence `runs_number_seq` then goes on from the highest number (from 1 on an empty
  # table), and is the column's default, so an insert that names no number takes the next.
  # A number an insert took is not given back when the insert rolls back or does nothing.
  #
  # All of it runs in the migration's one transaction, which first locks `runs` against
  # writes: code still serving during a deploy cannot insert a run without a number between
  # the numbering and NOT NULL.
  def up do
    execute "LOCK TABLE runs IN SHARE ROW EXCLUSIVE MODE"

    alter table(:runs) do
      add :number, :bigint
    end

    execute """
    UPDATE runs SET number = numbered.number
    FROM (
      SELECT id, row_number() OVER (
        ORDER BY coalesce(started_at, inserted_at), inserted_at, id
      ) AS number
      FROM runs
    ) AS numbered
    WHERE runs.id = numbered.id
    """

    execute "CREATE SEQUENCE runs_number_seq AS bigint START WITH 1 OWNED BY runs.number"

    execute """
    SELECT setval('runs_number_seq', coalesce(max(number), 1), max(number) IS NOT NULL)
    FROM runs
    """

    execute "ALTER TABLE runs ALTER COLUMN number SET DEFAULT nextval('runs_number_seq')"
    execute "ALTER TABLE runs ALTER COLUMN number SET NOT NULL"

    create unique_index(:runs, [:number])
  end

  def down do
    drop index(:runs, [:number])

    # The sequence is owned by the column and is dropped with it.
    alter table(:runs) do
      remove :number
    end
  end
end
