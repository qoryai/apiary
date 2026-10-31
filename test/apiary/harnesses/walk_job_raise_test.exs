defmodule Apiary.Harnesses.WalkJobRaiseTest do
  # A harness walk's job whose write raises (`Apiary.Harnesses.WalkJob`): tried again,
  # and on its last attempt it fails the walk `walk_error` and ends its run
  # `harness_unresolved`, with `walk_error` as its detail, before it raises, so the run
  # does not wait for ever. The test adds a check to `run_harnesses` that refuses every
  # failure but `walk_error`, inside its transaction, which rolls it back; the check
  # locks the table, so the module is not async.
  use Apiary.DataCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Stacks}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.{RunHarness, WalkJob}

  @moduletag needs: :factory
  @moduletag :capture_log

  @setting "extends: {git: \"https://code.example.com/acme/harness\", ref: v1}\n"

  defp job(run, attempt) do
    perform_job(
      WalkJob,
      %{
        "organisation_id" => run.organisation_id,
        "workspace_id" => run.workspace_id,
        "dispatch_run_id" => run.id
      },
      attempt: attempt
    )
  end

  test "a write that raises leaves the run waiting, and on the last attempt ends it" do
    %{scope: scope} = sign_up_fixture()
    {:ok, _stack} = Stacks.put_stack(scope, {:workspace, scope.workspace, "explore"}, nil)

    {:ok, _choice} =
      Stacks.put_stack(scope, {:workspace, scope.workspace}, @setting, choice: :repository)

    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(scope), 1) end)

    # No adapter covers the harness, so the walk fails not_covered, whose write raises.
    Repo.query!("""
    ALTER TABLE run_harnesses ADD CONSTRAINT run_harnesses_test_check
      CHECK (state <> 'failed' OR failure = 'walk_error') NOT VALID
    """)

    assert_raise Ecto.ConstraintError, fn -> job(run, 1) end
    assert %RunHarness{state: :pending} = Repo.get_by!(RunHarness, dispatch_run_id: run.id)
    assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, run.id)

    assert_raise Ecto.ConstraintError, fn -> job(run, 3) end

    assert %RunHarness{state: :failed, failure: "walk_error", attempts: 3} =
             Repo.get_by!(RunHarness, dispatch_run_id: run.id)

    assert %DispatchRun{state: :ended, end_cause: :harness_unresolved, end_detail: "walk_error"} =
             Repo.get!(DispatchRun, run.id)
  end
end
