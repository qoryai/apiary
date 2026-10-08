defmodule Apiary.Repo.Migrations.RemoveThePublisherAndWays do
  use Ecto.Migration

  # An integration's description names no publisher, and a connection is not used in ways:
  # a release no longer records a publisher (`publisher_name`, `publisher_url`, and the
  # ready check's clause that required one), and a connection's target no longer carries
  # ways (`connection_targets.ways` and its check).
  #
  # A release's integrity code covered its publisher (`Apiary.Integrations.Release`,
  # version 1). A release that recorded none, one that was pending or failed, still
  # verifies: version 1 codes its publisher as none. A ready release recorded one, so
  # without the columns its code no longer verifies, and SQL cannot write a new one, since
  # the key it is made under is not the database's. So every ready release is deleted,
  # with the integration connections added from it, whose foreign key would refuse the
  # deletion (`on_delete: :nothing`), and their targets (`on_delete: :delete_all`); an
  # audit entry names a connection by id, without a foreign key, and stays as it is.
  # Workspaces add their programs again.
  def up do
    delete_releases("state = 'ready'")

    drop constraint(:integration_releases, :integration_releases_ready_check)

    create constraint(:integration_releases, :integration_releases_ready_check,
             check:
               "state <> 'ready' OR (description IS NOT NULL AND description_sha256 IS NOT NULL " <>
                 "AND name IS NOT NULL AND version IS NOT NULL)"
           )

    alter table(:integration_releases) do
      remove :publisher_name
      remove :publisher_url
    end

    drop constraint(:connection_targets, :connection_targets_ways_check)

    alter table(:connection_targets) do
      remove :ways
    end
  end

  # Rolling back gives the tables their columns and checks again, empty: the releases,
  # connections and targets deleted do not come back. A release made since carries an
  # integrity code of version 2, which the code before this migration does not verify,
  # and a ready one names no publisher, which the check before it refuses: every one is
  # deleted, with its connections, as `up` deletes, for the same reason.
  def down do
    delete_releases("integrity_version = 2")

    alter table(:connection_targets) do
      add :ways, {:array, :text}
    end

    create constraint(:connection_targets, :connection_targets_ways_check,
             check:
               "ways IS NULL OR (cardinality(ways) BETWEEN 1 AND 2 " <>
                 "AND ways <@ ARRAY['credential', 'tool']::text[])"
           )

    alter table(:integration_releases) do
      add :publisher_name, :text
      add :publisher_url, :text
    end

    drop constraint(:integration_releases, :integration_releases_ready_check)

    create constraint(:integration_releases, :integration_releases_ready_check,
             check:
               "state <> 'ready' OR (description IS NOT NULL AND description_sha256 IS NOT NULL " <>
                 "AND name IS NOT NULL AND version IS NOT NULL AND publisher_name IS NOT NULL)"
           )
  end

  defp delete_releases(where) do
    execute("""
    DELETE FROM workspace_connections
    WHERE release_id IN (SELECT id FROM integration_releases WHERE #{where})
    """)

    execute("DELETE FROM integration_releases WHERE #{where}")
  end
end
