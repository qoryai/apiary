defmodule Mix.Tasks.Apiary.PruneTest do
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Retention
  alias Apiary.Runs.{Event, Projector, Run}
  alias Mix.Tasks.Apiary.Prune

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    scope = scope_fixture()
    run = run_fixture(scope)
    events_fixture(run, record())
    {:ok, _run} = Projector.project(run)
    long_ago = DateTime.add(DateTime.utc_now(), -50 * 86_400, :second)
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [last_event_at: long_ago])

    %{scope: scope, run: run}
  end

  defp events(run), do: Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count)

  test "without a setting there is nothing to prune", %{run: run} do
    Prune.run([])
    assert_received {:mix_shell, :info, ["No hive has a retention setting: nothing to prune."]}
    assert events(run) == 14
  end

  test "--dry-run counts and deletes nothing; without it the job prunes and records", %{
    scope: scope,
    run: run
  } do
    {:ok, hive} = Retention.update_retention(scope, %{events_retention_days: 10})

    Prune.run(["--dry-run"])
    assert_received {:mix_shell, :info, [line]}
    assert line =~ "hive #{hive.id}: would prune 1 runs: 14 events, 2 log chunks (12 bytes)"
    assert events(run) == 14
    assert Retention.list_retention_runs(scope) == []

    Prune.run(["--batch", "5"])
    assert_received {:mix_shell, :info, [line]}
    assert line =~ "hive #{hive.id}: pruned 1 runs: 14 events"
    assert events(run) == 0
    assert [%{trigger: "manual", events_deleted: 14}] = Retention.list_retention_runs(scope)
  end
end
