defmodule Apiary.Repo.Migrations.FixTheWorkspaceIdFunctionSSearchPath do
  use Ecto.Migration

  # `workspace_public_id()`, which 20261011100000 made, calls `gen_random_uuid()`,
  # `uuid_send()`, `encode()` and the string functions by their names alone, all built into
  # Postgres in `pg_catalog`. With its `search_path` set to `pg_catalog` it finds them there
  # and nowhere else, whatever the `search_path` of the session that calls it, the column's
  # default included. It changes no row.
  def up do
    execute("ALTER FUNCTION workspace_public_id() SET search_path = pg_catalog")
  end

  # Rolled back, the function runs under the caller's `search_path` again.
  def down do
    execute("ALTER FUNCTION workspace_public_id() RESET search_path")
  end
end
