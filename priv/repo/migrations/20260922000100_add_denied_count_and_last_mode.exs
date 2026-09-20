defmodule Apiary.Repo.Migrations.AddDeniedCountAndLastMode do
  use Ecto.Migration

  # Expand only. `runs.denied_count` lets the runs list show a run's denials without a
  # join; the four `connections.last_*` columns carry what the reason of a connection is
  # built from (the egress event's `mode`, `path_rule`, `credential`, `request_method`).
  #
  # The backfill is two statements over what is already stored: the count is the sum of the
  # run's connections, and the `last_*` values are read from the one event each row names
  # with `last_sequence`, through the unique index on (run_id, sequence). No run is rebuilt.
  def up do
    alter table(:runs) do
      add :denied_count, :integer, null: false, default: 0
    end

    alter table(:connections) do
      add :last_mode, :text
      add :last_path_rule, :text
      add :last_credential, :text
      add :last_request_method, :text
    end

    # The runs list: a hive's runs by start, and a repository's.
    create index(:runs, [:hive_id, :started_at])
    create index(:runs, [:hive_id, :repository_id, :started_at])
    # The hive's connections in a range.
    create index(:connections, [:hive_id, :last_seen_at])

    execute """
    UPDATE runs r
    SET denied_count = s.denied
    FROM (SELECT run_id, SUM(denied)::integer AS denied FROM connections GROUP BY run_id) s
    WHERE s.run_id = r.id AND s.denied > 0
    """

    execute """
    UPDATE connections c
    SET last_mode = LEFT(e.data->>'mode', 64),
        last_path_rule = LEFT(e.data->>'path_rule', 1024),
        last_credential = LEFT(e.data->>'credential', 1024),
        last_request_method = LEFT(e.data->>'request_method', 64)
    FROM events e
    WHERE e.run_id = c.run_id
      AND e.sequence = c.last_sequence
      AND e.type = 'ai.qory.run.egress'
      AND jsonb_typeof(e.data) = 'object'
    """
  end

  def down do
    drop index(:connections, [:hive_id, :last_seen_at])
    drop index(:runs, [:hive_id, :repository_id, :started_at])
    drop index(:runs, [:hive_id, :started_at])

    alter table(:connections) do
      remove :last_request_method
      remove :last_credential
      remove :last_path_rule
      remove :last_mode
    end

    alter table(:runs) do
      remove :denied_count
    end
  end
end
