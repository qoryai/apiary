defmodule Apiary.Runs.EventTypesMigrationTest do
  @moduledoc """
  The rename of the stored event types in `20260927000100`: every `ai.qory.*` event a
  0.1.0 installation holds becomes `dev.qory.*`, and the rollback names it back.
  """
  # Not async: the statement is the whole table's, not one run's, as the migration runs it.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Ecto.Query

  Code.require_file(
    "priv/repo/migrations/20260927000100_rename_repositories_to_targets.exs",
    File.cwd!()
  )

  alias Apiary.Repo
  alias Apiary.Repo.Migrations.RenameRepositoriesToTargets, as: Migration
  alias Apiary.Runs.Event

  defp types(run),
    do:
      Repo.all(from e in Event, where: e.run_id == ^run.id, order_by: e.sequence, select: e.type)

  test "up renames every ai.qory type, and only those; down names them back" do
    %{scope: scope} = sign_up_fixture()
    run = run_fixture(scope)

    # As 0.1.0 stored them, beside one already renamed and one of another namespace.
    stored = [
      "ai.qory.ping",
      "ai.qory.run.started",
      "ai.qory.session.subagent_finished",
      "dev.qory.run.heartbeat",
      "com.example.ai.qory.other"
    ]

    for {type, sequence} <- Enum.with_index(stored, 1) do
      event = event_fixture(run, sequence, "ping", %{})
      Repo.update_all(from(e in Event, where: e.id == ^event.id), set: [type: type])
    end

    Repo.query!(Migration.event_types_sql("ai.qory.", "dev.qory."))

    assert types(run) == [
             "dev.qory.ping",
             "dev.qory.run.started",
             "dev.qory.session.subagent_finished",
             "dev.qory.run.heartbeat",
             "com.example.ai.qory.other"
           ]

    Repo.query!(Migration.event_types_sql("dev.qory.", "ai.qory."))

    assert types(run) == [
             "ai.qory.ping",
             "ai.qory.run.started",
             "ai.qory.session.subagent_finished",
             "ai.qory.run.heartbeat",
             "com.example.ai.qory.other"
           ]
  end
end
