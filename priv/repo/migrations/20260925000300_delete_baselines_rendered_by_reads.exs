defmodule Apiary.Repo.Migrations.DeleteBaselinesRenderedByReads do
  use Ecto.Migration

  # A one-off repair of data, idempotent. Until this release a page's read of a hive
  # nobody had changed rendered and stored a baseline, version 1 with no change and no
  # author, so the hive's first real change became version 2 and the console's "version 1
  # is rendered by the first change" was false. Nothing is persisted by a read any more.
  #
  # The rows a read stored are the ones with no change behind them. Each is deleted when
  # either the hive has no change yet, so nothing is served from it, or a later version of
  # the same baseline exists, so it is superseded; and where one is deleted, the versions
  # after it and the `version_after` of the changes that made them move down by one, so
  # the first change's version is 1 again. A row that is the only version of a managed
  # baseline (its first change rendered the same bytes) is kept: it is what is served.
  # The versions are moved by way of a large offset, since the unique index on the version
  # is checked row by row.
  def up do
    for sql <- repair_sql(), do: execute(sql)
  end

  def down, do: :ok

  @offset 1_000_000

  @doc "The statements of the repair, in order; each idempotent, all in one transaction."
  def repair_sql do
    [
      "DROP TABLE IF EXISTS orphan_baselines",
      """
      CREATE TEMP TABLE orphan_baselines ON COMMIT DROP AS
      SELECT c.id, c.hive_id, c.version
      FROM run_configurations c
      WHERE c.policy_change_id IS NULL AND c.changed_by_id IS NULL AND c.repository_id IS NULL
        AND (NOT EXISTS (SELECT 1 FROM policy_changes p WHERE p.hive_id = c.hive_id)
             OR EXISTS (SELECT 1 FROM run_configurations n
                        WHERE n.hive_id = c.hive_id AND n.repository_id IS NULL AND n.version > c.version))
      """,
      "DELETE FROM run_configurations WHERE id IN (SELECT id FROM orphan_baselines)",
      """
      UPDATE run_configurations c SET version = c.version + #{@offset}
      FROM orphan_baselines o
      WHERE c.hive_id = o.hive_id AND c.repository_id IS NULL AND c.version > o.version
      """,
      """
      UPDATE run_configurations SET version = version - #{@offset + 1}
      WHERE version > #{@offset}
      """,
      """
      UPDATE policy_changes p SET version_after = p.version_after - 1
      FROM orphan_baselines o
      WHERE p.hive_id = o.hive_id AND p.repository_id IS NULL AND p.version_after > o.version
      """
    ]
  end
end
