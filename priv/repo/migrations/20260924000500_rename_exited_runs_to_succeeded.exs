defmodule Apiary.Repo.Migrations.RenameExitedRunsToSucceeded do
  use Ecto.Migration

  # The run state `exited` becomes `succeeded`, the runner's own word for it and the
  # counterpart of `failed`.
  #
  # `runs` may be large, so nothing here holds a long lock or one long transaction. Every
  # statement commits on its own (no DDL transaction); the migration lock is kept, so two
  # instances booting at once do not both run it. The steps are idempotent, so a boot that
  # fails halfway is simply run again:
  #
  # 1. The `CHECK` on `state` is swapped for one that accepts both words, `NOT VALID`:
  #    instant, no scan, and every write is still checked.
  # 2. The rows are rewritten in batches of 5000, walked by primary key, one commit a
  #    batch, so the receiver's writes to other rows are never blocked for long. A pass
  #    walks the whole key once; passes repeat until one finds nothing, which catches a
  #    row written with the old word while a pass was under way.
  # 3. The `CHECK` is swapped for the narrow one, `NOT VALID` again, and then validated,
  #    which scans the table under a lock that lets reads and writes through.
  #
  # `down` does the same the other way. A row written by the new release after that (a
  # `succeeded` state) is renamed back to `exited` by it, and the previous release reads it.
  @disable_ddl_transaction true

  @constraint "runs_state_check"
  @batch 5000

  @states ~w(pending running failed timed_out lost closed)

  def up, do: rename_state("exited", "succeeded")
  def down, do: rename_state("succeeded", "exited")

  defp rename_state(from, to) do
    swap_check([from, to | @states], validate: false)
    rewrite(from, to)
    swap_check([to | @states], validate: true)
  end

  defp swap_check(states, validate: validate?) do
    list = states |> Enum.map(&"'#{&1}'") |> Enum.join(", ")

    repo().query!("ALTER TABLE runs DROP CONSTRAINT IF EXISTS #{@constraint}", [])

    repo().query!(
      "ALTER TABLE runs ADD CONSTRAINT #{@constraint} CHECK (state IN (#{list})) NOT VALID",
      []
    )

    if validate?, do: repo().query!("ALTER TABLE runs VALIDATE CONSTRAINT #{@constraint}", [])
  end

  # Batches by primary key, `from` to `to`, until a whole pass renames nothing.
  defp rewrite(from, to) do
    case pass(from, to, nil, 0) do
      0 -> :ok
      _renamed -> rewrite(from, to)
    end
  end

  defp pass(from, to, after_id, renamed) do
    %{rows: rows} =
      repo().query!(
        """
        UPDATE runs SET state = $2
        WHERE id IN (
          SELECT id FROM runs
          WHERE state = $1 AND ($3::uuid IS NULL OR id > $3::uuid)
          ORDER BY id LIMIT #{@batch}
        )
        RETURNING id
        """,
        [from, to, after_id]
      )

    case rows do
      [] -> renamed
      ids -> pass(from, to, ids |> Enum.map(&hd/1) |> Enum.max(), renamed + length(ids))
    end
  end
end
