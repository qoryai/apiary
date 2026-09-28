defmodule Apiary.Repo.Migrations.CreateObanTables do
  use Ecto.Migration

  # The durable job queue: Oban's `oban_jobs` and `oban_peers` tables, its types, indexes
  # and the rest of what its migrations create, in `public`. The version is pinned, so a
  # later Oban does not change what this migration did; an upgrade of Oban's tables is a
  # migration of its own. The tables carry no `organisation_id`: they are the instance's,
  # and a job names the organisation and the workspace it works for in its arguments
  # (`Apiary.Job`). Rolling it back drops everything Oban created.
  def up, do: Oban.Migration.up(version: 14)

  def down, do: Oban.Migration.down(version: 1)
end
