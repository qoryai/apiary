defmodule Apiary.Repo.Migrations.AddDeniedCountAndLastMode do
  use Ecto.Migration

  # Expand only. `runs.denied_count` lets the runs list show a run's denials without a
  # join; the four `connections.last_*` columns carry what the reason of a connection is
  # built from (the egress event's `mode`, `path_rule`, `credential`, `request_method`).
  #
  # The count is backfilled here, in one statement: it is a sum of what is already
  # projected, so it is exactly what the projector would have counted. The four columns are
  # not: what they hold is what the fold reads from an event (strings only, cut by bytes on
  # a character boundary), and only the fold says that the same way twice. Rows projected
  # before this migration keep them null, which the console reads as "not recorded", until
  # `mix apiary.rebuild` (`Apiary.Release.rebuild/0` in a release) projects those runs again.
  # The indexes the new pages read by are in the next migration, outside a transaction.
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

    execute denied_count_sql()
  end

  def down do
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

  @doc "A run's denied connections, from its `connections`: what the projector counts."
  def denied_count_sql do
    """
    UPDATE runs r
    SET denied_count = s.denied
    FROM (SELECT run_id, SUM(denied)::integer AS denied FROM connections GROUP BY run_id) s
    WHERE s.run_id = r.id AND s.denied > 0
    """
  end
end
