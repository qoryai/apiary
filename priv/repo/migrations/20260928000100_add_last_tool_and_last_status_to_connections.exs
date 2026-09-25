defmodule Apiary.Repo.Migrations.AddLastToolAndLastStatusToConnections do
  use Ecto.Migration

  # Expand only. Contract v1 revision 2 names, on an egress event, the tool a request was
  # handed to (`tool`) and the status the host or the tool answered (`status`); the two
  # columns carry them for the last attempt, as the other `last_*` columns do.
  #
  # Nullable and without a default, so the statement changes the catalogue and rewrites no
  # row. Nothing is backfilled here: what the columns hold is what the fold reads from an
  # event, and only the fold says that the same way twice. Rows projected before this
  # migration keep them null, which the console reads as a connection that is no tool
  # invocation and whose answer was not recorded, until `mix apiary.rebuild`
  # (`Apiary.Release.rebuild/0` in a release) projects those runs again.
  def change do
    alter table(:connections) do
      add :last_tool, :text
      add :last_status, :integer
    end
  end
end
