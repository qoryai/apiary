defmodule Apiary.Repo.Migrations.NameANodeSIdsAsTheNodeS do
  use Ecto.Migration

  # Every id a node gives is kept in a column whose name says it is the node's, an
  # external id, beside the ids Qory gives (`id`, and a run's `public_id`):
  #
  # - `runs.run_id` is `node_run_id`, the run's id as its node gave it, the subject of its
  #   events in the server contract; `runs.instance_id` is `node_instance_id`, the instance
  #   id the request that created the run claimed; `runs.attach_instance_id` is
  #   `gateway_instance_id`, the instance id of the gateway that attached the run.
  # - `events.event_id` is `node_event_id` and `events.instance_id` is `node_instance_id`.
  #   `events.run_id` is the run's row, Qory's id, and keeps its name.
  # - `deliveries.delivery_id`, `deliveries.run_id` and `deliveries.instance_id` are
  #   `node_delivery_id`, `node_run_id` and `node_instance_id`. `node_delivery_id` is the
  #   node's delivery id for the batch, or null when the batch gave none or gave one that is
  #   not a UUID: it holds only what the node gave, so it is no longer NOT NULL. A null
  #   never conflicts in the unique index on (`access_key_id`, `node_delivery_id`), so such
  #   a batch is deduplicated by its events' ids alone, as before.
  # - `node_instances.instance_id` is `node_instance_id`.
  #
  # The server contract's words stay as they are: a body, a path, a header and a signed
  # subject still say `run_id`, `instance_id`, `event_id` and `delivery_id`. The indexes
  # and the constraints named after a column are renamed with it, so each name still says
  # what it holds. Postgres 18 names a column's NOT NULL constraint after it; one that is
  # there is renamed too. Renames change the catalogue alone and rewrite no row. Rolled
  # back, `delivery_id` is NOT NULL again, and a delivery stored with none is given a
  # fresh UUID first, as the server made one up before.
  #
  # `runs_public_id_pattern_index` is a btree on `public_id` with `text_pattern_ops`, so a
  # search for a prefix of a run's `rn_` id (`LIKE 'rn_…%'`) can use an index whatever the
  # database's collation; the unique index on `public_id` stays.
  @columns [
    {"runs", "run_id", "node_run_id"},
    {"runs", "instance_id", "node_instance_id"},
    {"runs", "attach_instance_id", "gateway_instance_id"},
    {"events", "event_id", "node_event_id"},
    {"events", "instance_id", "node_instance_id"},
    {"deliveries", "delivery_id", "node_delivery_id"},
    {"deliveries", "run_id", "node_run_id"},
    {"deliveries", "instance_id", "node_instance_id"},
    {"node_instances", "instance_id", "node_instance_id"}
  ]

  @indexes [
    {"runs_workspace_id_run_id_index", "runs_workspace_id_node_run_id_index"},
    {"runs_gateway_id_run_id_index", "runs_gateway_id_node_run_id_index"},
    {"runs_node_id_instance_id_alive_index", "runs_node_id_node_instance_id_alive_index"},
    {"events_workspace_id_event_id_index", "events_workspace_id_node_event_id_index"},
    {"deliveries_access_key_id_delivery_id_index",
     "deliveries_access_key_id_node_delivery_id_index"},
    {"deliveries_workspace_id_run_id_index", "deliveries_workspace_id_node_run_id_index"},
    {"node_instances_node_id_instance_id_index", "node_instances_node_id_node_instance_id_index"}
  ]

  @checks [
    {"runs", "runs_instance_id_check", "runs_node_instance_id_check"},
    {"runs", "runs_attach_instance_id_check", "runs_gateway_instance_id_check"},
    {"events", "events_instance_id_check", "events_node_instance_id_check"},
    {"deliveries", "deliveries_instance_id_check", "deliveries_node_instance_id_check"},
    {"node_instances", "node_instances_instance_id_check",
     "node_instances_node_instance_id_check"}
  ]

  @not_nulls [
    {"runs", "runs_run_id_not_null", "runs_node_run_id_not_null"},
    {"events", "events_event_id_not_null", "events_node_event_id_not_null"},
    {"deliveries", "deliveries_run_id_not_null", "deliveries_node_run_id_not_null"},
    {"node_instances", "node_instances_instance_id_not_null",
     "node_instances_node_instance_id_not_null"}
  ]

  def up do
    for {table, from, to} <- @columns, do: rename_column(table, from, to)
    for {from, to} <- @indexes, do: rename_index(from, to)
    for {table, from, to} <- @checks, do: rename_constraint(table, from, to)
    for {table, from, to} <- @not_nulls, do: rename_not_null(table, from, to)

    execute("ALTER TABLE deliveries ALTER COLUMN node_delivery_id DROP NOT NULL")
    execute("CREATE INDEX runs_public_id_pattern_index ON runs (public_id text_pattern_ops)")
  end

  def down do
    execute("DROP INDEX runs_public_id_pattern_index")

    for {table, from, to} <- Enum.reverse(@not_nulls), do: rename_not_null(table, to, from)
    for {table, from, to} <- Enum.reverse(@checks), do: rename_constraint(table, to, from)
    for {from, to} <- Enum.reverse(@indexes), do: rename_index(to, from)
    for {table, from, to} <- Enum.reverse(@columns), do: rename_column(table, to, from)

    # After the rename, so that Postgres 18 names the constraint after `delivery_id`.
    execute("UPDATE deliveries SET delivery_id = gen_random_uuid() WHERE delivery_id IS NULL")
    execute("ALTER TABLE deliveries ALTER COLUMN delivery_id SET NOT NULL")
  end

  defp rename_column(table, from, to),
    do: execute("ALTER TABLE #{table} RENAME COLUMN #{from} TO #{to}")

  defp rename_index(from, to), do: execute("ALTER INDEX #{from} RENAME TO #{to}")

  defp rename_constraint(table, from, to),
    do: execute("ALTER TABLE #{table} RENAME CONSTRAINT #{from} TO #{to}")

  # A NOT NULL constraint has a name from Postgres 18 on; before, there is none to rename.
  defp rename_not_null(table, from, to) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = '#{table}'::regclass AND conname = '#{from}'
      ) THEN
        ALTER TABLE #{table} RENAME CONSTRAINT #{from} TO #{to};
      END IF;
    END
    $$
    """)
  end
end
