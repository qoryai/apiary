defmodule Apiary.Dispatches.RunEndBatchTest do
  # The lost-run check's batch (`Apiary.Dispatches.RunEnd.lose/1`): a run of the queue
  # whose end raises is logged and left for the next check, and the rest of the batch
  # still ends. Not async: the end is made to raise by a trigger, created inside the
  # test's transaction and rolled back with it, which locks `dispatch_runs` meanwhile.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Dispatches.{Dispatch, DispatchRun, RunEnd}

  @moduletag needs: :factory

  test "one end that raises is logged; the rest of the batch still ends" do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)

    [failing, other] =
      [handed_over_fixture(scope, key), handed_over_fixture(scope, key)]
      |> Enum.sort_by(& &1.dispatch_run.id)

    Repo.query!("""
    CREATE FUNCTION refuse_run_end_for_test() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'refused'; END $$
    """)

    Repo.query!("""
    CREATE TRIGGER refuse_run_end BEFORE UPDATE ON dispatch_runs FOR EACH ROW
    WHEN (OLD.id = '#{failing.dispatch_run.id}') EXECUTE FUNCTION refuse_run_end_for_test()
    """)

    past = DateTime.add(other.run.backstop_at, 1, :second)

    log =
      capture_log(fn ->
        assert RunEnd.lose(past) == [scope.workspace.id]
      end)

    assert log =~ "run end failed dispatch_run=#{failing.dispatch_run.id} error=Postgrex.Error"

    assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, failing.dispatch_run.id)
    assert %Dispatch{ended_at: nil} = Repo.get!(Dispatch, failing.dispatch.id)

    assert %DispatchRun{state: :ended, end_cause: :lost} =
             Repo.get!(DispatchRun, other.dispatch_run.id)

    assert %Dispatch{end_cause: :lost, slot_freed_at: %DateTime{}} =
             Repo.get!(Dispatch, other.dispatch.id)
  end
end
