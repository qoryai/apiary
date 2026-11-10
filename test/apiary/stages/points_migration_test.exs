defmodule Apiary.Stages.PointsMigrationTest do
  # The migration that replaces an escalation's gaps with its points, run down and up
  # again inside the test's transaction, which rolls it all back. It changes the table
  # under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: [:factory, :workflow_model]

  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures

  alias Apiary.Stages.Escalation

  @version 20_261_109_100_001
  @migration Apiary.Repo.Migrations.KeepAnEscalationSPoints
  @options [log: false, migration_lock: false]

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_an_escalation_s_points.exs")
      |> Code.require_file()
    end

    :ok
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{work_item: taken_in_fixture(scope)}
  end

  # Inserts an escalation of the work item for `cause` with `points`, resolved unless
  # `open`, as at most one escalation of a work item is open.
  defp escalation!(work_item, cause, points, open \\ false) do
    now = DateTime.utc_now()

    Repo.insert!(%Escalation{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      process_version_id: work_item.process_version_id,
      stage_id: "st_6ns22c4pav",
      round: 1,
      cause: cause,
      points: points,
      resolution: if(open, do: nil, else: :close),
      resolved_at: if(open, do: nil, else: now),
      inserted_at: now
    })
  end

  defp run_again(text), do: %{"text" => text, "action" => "run_again"}

  defp column(name, id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{name} FROM escalations WHERE id = $1", [Ecto.UUID.dump!(id)])

    value
  end

  defp set_gaps!(id, gaps),
    do: Repo.query!("UPDATE escalations SET gaps = $2 WHERE id = $1", [Ecto.UUID.dump!(id), gaps])

  test "down writes an escalate's point texts as its gaps, one per line", %{
    work_item: work_item
  } do
    escalate =
      escalation!(work_item, :escalate, [run_again("No test."), run_again("No docs.")], true)

    stopped = escalation!(work_item, :run_stopped, [run_again("The run stopped.")])
    none = escalation!(work_item, :escalate, [])

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)

    assert column("gaps", escalate.id) == "No test.\nNo docs."
    assert column("gaps", stopped.id) == nil
    assert column("gaps", none.id) == nil
  end

  test "up writes each non-empty line of an escalate's gaps as a point, at most 20", %{
    work_item: work_item
  } do
    escalate = escalation!(work_item, :escalate, [], true)
    long = escalation!(work_item, :escalate, [])
    round_limit = escalation!(work_item, :round_limit, [])
    none = escalation!(work_item, :escalate, [])

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)

    set_gaps!(escalate.id, "  No test for the empty basket.\r\n\n\t\nThe docs are out of date.\n")
    set_gaps!(long.id, Enum.map_join(1..21, "\n", &"Gap #{&1}."))
    set_gaps!(round_limit.id, "The checkout is slow.")

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)

    assert column("points", escalate.id) == [
             run_again("No test for the empty basket."),
             run_again("The docs are out of date.")
           ]

    assert column("points", long.id) == Enum.map(1..20, &run_again("Gap #{&1}."))
    assert column("points", round_limit.id) == []
    assert column("points", none.id) == []

    refute Repo.exists?(
             from c in "columns",
               prefix: "information_schema",
               where: c.table_name == "escalations" and c.column_name == "gaps"
           )
  end
end
