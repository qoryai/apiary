defmodule Apiary.WorkItems.ExploreStatusTest do
  # Where Explore stands for a live work item, derived in SQL for a list
  # (`Apiary.WorkItems.Explore.with_status/1`, `statuses/1`), held to the status
  # `Apiary.WorkItems.Explore.status/2` gives over the same runs: every status, each way a
  # run comes to it, with what the runs of the queue keep stored as their writers store
  # it (`Apiary.Dispatches.Settle`).
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2, where: 3, select: 3]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Dispatches.{DispatchRun, Settle}
  alias Apiary.WorkItems.{Confirmation, Explore, WorkItem}

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  # A work item whose current take in has the runs `runs` gives, each `explore_run_fixture/2`
  # options, its last of attempt `attempt` when given; each run ended `run_ended` and
  # settled has what it gave stored. `confirmed: true` confirms the take in.
  defp work_item!(scope, runs, opts \\ []) do
    work_item = work_item_fixture(scope)

    for run_opts <- runs do
      %{dispatch_run: dispatch_run} = explore_run_fixture(work_item, run_opts)
      if Keyword.get(run_opts, :settle, true), do: Settle.settle(dispatch_run.id)
    end

    if Keyword.get(opts, :cleared), do: clear!(work_item)
    if Keyword.get(opts, :confirmed), do: confirm!(work_item)
    work_item
  end

  # The result of each of its runs cleared, as retention clears it.
  defp clear!(work_item) do
    Repo.update_all(from(d in DispatchRun, where: d.work_item_id == ^work_item.id),
      set: [result: nil]
    )
  end

  defp confirm!(work_item) do
    Repo.insert!(%Confirmation{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      take_in: work_item.take_in,
      attempt: 1,
      result: understood_result(),
      confirmed_at: DateTime.utc_now()
    })
  end

  # Two earlier runs that gave questions, and the run limit is 3.
  defp at_limit(last), do: [[result: questions_result()], [result: questions_result()], last]

  defp cases do
    unsettled = [
      run: %{exit_state: nil, exited_at: nil, outcome_received_at: DateTime.utc_now()},
      settle: false
    ]

    [
      {:queued, [], []},
      {:queued, [[state: :waiting]], []},
      {:queued, [[state: :claimed]], []},
      {:running, [[state: :handed_over]], []},
      {:running, [unsettled], []},
      {:confirm, [[result: understood_result()]], []},
      {:confirm, at_limit(result: understood_result()), []},
      {:confirm, [[result: understood_result(), run: %{state: "cancelled"}]], []},
      {:questions, [[result: questions_result()]], []},
      {:no_result, [[]], []},
      {:no_result, [[result: {:data, %{"is_error" => true, "result" => "{}"}}]], []},
      {:no_result, [[result: {:data, %{"is_error" => false, "result" => "not json"}}]], []},
      {:no_result, [[end_cause: :ticket_gone]], []},
      {:no_result, [[end_cause: :inputs_invalid]], []},
      {:no_result, [[result: understood_result()]], cleared: true},
      {:no_result, [[result: questions_result()]], cleared: true},
      {:lost, [[end_cause: :lost]], []},
      {:lost, [[run: %{state: "lost", lost_at: DateTime.utc_now()}]], []},
      {:cancelled, [[end_cause: :released]], []},
      {:cancelled, [[end_cause: :closed]], []},
      {:cancelled, [[end_cause: :undone]], []},
      {:cancelled, [[run: %{state: "cancelled"}]], []},
      {:used_up, at_limit(result: questions_result()), []},
      {:used_up, at_limit([]), []},
      {:used_up, at_limit(end_cause: :lost), []},
      {:used_up, at_limit(end_cause: :released), []},
      {:used_up, at_limit(end_cause: :variables_invalid), []},
      {:shape, [[result: understood_result()]], confirmed: true},
      {:shape, [], confirmed: true}
    ]
  end

  test "the status in SQL is the status Explore gives, for every status", %{scope: scope} do
    now = DateTime.utc_now()

    checked =
      for {expected, runs, opts} <- cases() do
        work_item = work_item!(scope, runs, opts)
        explore = Explore.current(work_item, now).status
        sql = Map.fetch!(Explore.statuses([work_item.id]), work_item.id)

        assert {expected, expected} == {explore, sql},
               "#{inspect(runs)} #{inspect(opts)}: Explore #{explore}, SQL #{sql}"

        expected
      end

    assert Enum.sort(Enum.uniq(checked)) ==
             Enum.sort([
               :queued,
               :running,
               :confirm,
               :questions,
               :no_result,
               :lost,
               :cancelled,
               :used_up,
               :shape
             ])
  end

  test "reads the current take in alone, its latest run", %{scope: scope} do
    work_item = work_item!(scope, [[result: understood_result()], []])
    assert Explore.statuses([work_item.id]) == %{work_item.id => :no_result}

    # A take in again: its runs are of take in 2, and the proposal of take in 1 counts no more.
    Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: [take_in: 2])
    assert Explore.statuses([work_item.id]) == %{work_item.id => :queued}

    explore_run_fixture(%{work_item | take_in: 2}, state: :handed_over)
    assert Explore.statuses([work_item.id]) == %{work_item.id => :running}
  end

  test "composes with a query of work items, to filter and count by status", %{scope: scope} do
    confirm = work_item!(scope, [[result: understood_result()]])
    questions = work_item!(scope, [[result: questions_result()]])
    _running = work_item!(scope, [[state: :handed_over]])

    waiting =
      from(w in WorkItem, as: :work_item, where: w.workspace_id == ^scope.workspace.id)
      |> Explore.with_status()
      |> where([explore_status: s], s.status in ^Explore.status_names([:confirm, :questions]))
      |> select([work_item: w, explore_status: s], {w.id, s.status})
      |> Repo.all()
      |> Map.new(fn {id, status} -> {id, Explore.status_of(status)} end)

    assert waiting == %{confirm.id => :confirm, questions.id => :questions}
    assert Explore.statuses([]) == %{}
  end
end
