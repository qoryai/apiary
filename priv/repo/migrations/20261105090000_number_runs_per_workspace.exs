defmodule Apiary.Repo.Migrations.NumberRunsPerWorkspace do
  use Ecto.Migration

  # Each workspace counts its runs from 1: a run's number is unique in its workspace, not
  # on the server (`Apiary.Runs.Run`, `number`), and comes from a counter of the
  # workspace's runs (`Apiary.Runs.Number`), apart from the counter of its work items.
  #
  # - `run_counters`: one row per workspace, made with its first run, with the last number
  #   given. A number is taken by an upsert that adds one, inside the transaction that
  #   writes the run, so the row stays locked until it commits and a rolled back run returns
  #   its number to the counter. `last_number` is 0 where the only number taken went back.
  #
  # The runs that are there get new numbers, in the order they were created: by
  # `inserted_at`, then by the old number for a tie, which is unique. Each counter goes on
  # from the highest number of its workspace. An old address `/runs/<number>` then shows
  # another run of the workspace, or not found. The sequence `runs_number_seq` and the
  # column's default go.
  #
  # A work item moves between workspaces and its runs stay where they ran. Each counter
  # also goes past the highest number of the runs of the work items now in its workspace,
  # those in other workspaces included, so the next run of such a work item has a number
  # none of its runs has. Runs of a work item moved before this migration may still repeat
  # a number, because the renumbering counts each workspace apart. A move that the previous
  # release makes on this schema can repeat a number too, as it does not raise the counter.
  #
  # The previous release sets no number on an insert, and runs on this schema
  # (`guides/upgrading.md`, Expand, then contract). The trigger `runs_number_from_counter`
  # takes a number from the same counter for an insert with none. This release sets the
  # number on every insert (`Apiary.Runs.Number`), so the trigger does not fire for it.
  #
  # All of it runs in the migration's one transaction, and every lock stays until it ends:
  #
  # - `LOCK TABLE` blocks writes to `runs` first, so no run is inserted between the
  #   renumbering and the counters.
  # - The foreign keys of `run_counters` take `ShareRowExclusiveLock` on `workspaces` and
  #   `organisations`, which blocks writes to both.
  # - `DROP DEFAULT` takes `AccessExclusiveLock` on `runs`, which blocks reads of `runs` too,
  #   through the renumbering, which updates every row. The lock lasted 128 s on 1,000,000
  #   runs with 23 indexes, on a machine that was not idle.
  def up do
    execute "LOCK TABLE runs IN SHARE ROW EXCLUSIVE MODE"

    create table(:run_counters, primary_key: false) do
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
          primary_key: true

      add :last_number, :bigint, null: false
    end

    create index(:run_counters, [:organisation_id])

    create constraint(:run_counters, :run_counters_last_number_check, check: "last_number >= 0")

    execute "ALTER TABLE runs ALTER COLUMN number DROP DEFAULT"
    execute "DROP SEQUENCE runs_number_seq"
    drop index(:runs, [:number])

    execute """
    UPDATE runs SET number = numbered.number
    FROM (
      SELECT id, row_number() OVER (
        PARTITION BY workspace_id ORDER BY inserted_at, number
      ) AS number
      FROM runs
    ) AS numbered
    WHERE runs.id = numbered.id
    """

    create unique_index(:runs, [:workspace_id, :number])

    execute """
    INSERT INTO run_counters (organisation_id, workspace_id, last_number)
    SELECT organisation_id, workspace_id, max(number)
    FROM runs
    GROUP BY organisation_id, workspace_id
    """

    execute """
    INSERT INTO run_counters (organisation_id, workspace_id, last_number)
    SELECT w.organisation_id, w.workspace_id, max(r.number)
    FROM runs r
    JOIN dispatch_runs d ON d.id = r.dispatch_run_id
    JOIN work_items w ON w.id = d.work_item_id
    GROUP BY w.organisation_id, w.workspace_id
    ON CONFLICT (workspace_id) DO UPDATE
    SET last_number = GREATEST(run_counters.last_number, EXCLUDED.last_number)
    """

    execute """
    CREATE FUNCTION runs_number_from_counter() RETURNS trigger AS $$
    BEGIN
      INSERT INTO run_counters (organisation_id, workspace_id, last_number)
      VALUES (NEW.organisation_id, NEW.workspace_id, 1)
      ON CONFLICT (workspace_id) DO UPDATE SET last_number = run_counters.last_number + 1
      RETURNING last_number INTO NEW.number;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER runs_number_from_counter BEFORE INSERT ON runs
    FOR EACH ROW WHEN (NEW.number IS NULL)
    EXECUTE FUNCTION runs_number_from_counter()
    """
  end

  # Back to one count on the server, in the order the runs were created, with the id for a
  # tie. The numbers the runs had before `up` are not kept, so `down` does not restore
  # them.
  def down do
    execute "LOCK TABLE runs IN SHARE ROW EXCLUSIVE MODE"

    execute "DROP TRIGGER runs_number_from_counter ON runs"
    execute "DROP FUNCTION runs_number_from_counter()"

    drop index(:runs, [:workspace_id, :number])

    execute """
    UPDATE runs SET number = numbered.number
    FROM (
      SELECT id, row_number() OVER (ORDER BY inserted_at, id) AS number
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

    create unique_index(:runs, [:number])

    drop table(:run_counters)
  end
end
