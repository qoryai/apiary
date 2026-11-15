defmodule Apiary.Runs.CancelTest do
  # A member's cancel of a running run (`Apiary.Runs.cancel/2`): the mark on the run, its
  # audit entry and when a cancel fails. What the mark changes for the run's
  # requests and its stage is tested beside each of them.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.{Audit, Runs}
  alias Apiary.Audit.Entry
  alias Apiary.Runs.{Outcome, Projector, Run}

  @moduletag needs: :observability

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, run: started_run(scope)}
  end

  defp entries(run),
    do: Repo.all(from e in Entry, where: e.subject_id == ^run.id and e.action == "run.cancel")

  test "marks a running run with when and who, and writes run.cancel", %{scope: scope, run: run} do
    assert run.state == "running"
    Runs.subscribe(scope, run)

    assert {:ok, %Run{} = cancelled} = Runs.cancel(scope, run)
    assert %DateTime{} = cancelled.cancel_requested_at
    assert cancelled.cancel_requested_by_id == scope.user.id
    assert Run.cancel_requested?(cancelled)
    assert Run.cancel_requested?(Repo.get!(Run, run.id))
    # The state still comes from the exit.
    assert cancelled.state == "running"

    assert [%Entry{details: %{"number" => number}}] = entries(run)
    assert number == run.number
    assert_receive {:run_changed, %Run{id: id}} when id == run.id

    # The Activity page shows it.
    [entry] = entries(run)

    assert ApiaryWeb.Activity.Describer.Core.sentence(Audit.action(entry), entry, %{}) ==
             "Cancelled run #{run.number}"

    # The Activity filter offers it by its label.
    assert ApiaryWeb.Activity.Describer.Core.label(:"run.cancel") == "Run cancelled"
  end

  test "a second press keeps the first mark and writes no second entry", %{
    scope: scope,
    run: run
  } do
    {:ok, first} = Runs.cancel(scope, run)
    {:ok, again} = Runs.cancel(scope, Repo.get!(Run, run.id))

    assert again.cancel_requested_at == first.cancel_requested_at
    assert length(entries(run)) == 1
  end

  test "a run with an exit, an outcome, or that is not alive is not running", %{scope: scope} do
    exited = started_run(scope, %{}, exit: %{"state" => "succeeded", "exit_code" => 0})
    assert {:error, :not_running} = Runs.cancel(scope, exited)

    for changes <- [
          [
            outcome_state: "succeeded",
            outcome_time: DateTime.utc_now(),
            outcome_received_at: DateTime.utc_now(),
            outcome_digest: :crypto.strong_rand_bytes(32)
          ],
          [state: "pending"],
          # Lost for good: past its backstop.
          [
            state: "lost",
            lost_at: DateTime.utc_now(),
            backstop_at: DateTime.add(DateTime.utc_now(), -1, :second)
          ],
          [state: "completed"]
        ] do
      run = started_run(scope)
      {1, _rows} = Repo.update_all(from(r in Run, where: r.id == ^run.id), set: changes)
      assert {:error, :not_running} = Runs.cancel(scope, Repo.get!(Run, run.id))
      refute Run.cancel_requested?(Repo.get!(Run, run.id))
    end

    assert Repo.all(from e in Entry, where: e.action == "run.cancel") == []
  end

  test "a lost run that may still attach again is cancelled; one lost for good is not", %{
    scope: scope,
    run: run
  } do
    now = DateTime.utc_now()

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [state: "lost", lost_at: now, backstop_at: DateTime.add(now, 3600, :second)]
      )

    assert {:ok, %Run{state: "lost"} = cancelled} = Runs.cancel(scope, Repo.get!(Run, run.id))
    assert Runs.Cancel.cancelling?(cancelled)
    assert [%Entry{details: %{"number" => number}}] = entries(run)
    assert number == run.number

    for changes <- [
          [backstop_at: DateTime.add(now, -1, :second)],
          [backstop_at: DateTime.add(now, 3600, :second), silenced_at: now],
          [exited_at: now],
          [events_pruned_at: now]
        ] do
      lost = started_run(scope)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^lost.id),
          set: [state: "lost", lost_at: now] ++ changes
        )

      assert {:error, :not_running} = Runs.cancel(scope, Repo.get!(Run, lost.id))
      refute Run.cancel_requested?(Repo.get!(Run, lost.id))
    end
  end

  test "a run of another workspace is out of reach of a person who is not a member there", %{
    run: run
  } do
    %{scope: other} = sign_up_fixture()

    assert {:error, _refused} = Runs.cancel(other, run)
    refute Run.cancel_requested?(Repo.get!(Run, run.id))
  end

  test "a rebuild of the run from its events keeps the mark", %{scope: scope, run: run} do
    {:ok, cancelled} = Runs.cancel(scope, run)

    assert {:ok, rebuilt} = Projector.rebuild(Repo.get!(Run, run.id))
    assert rebuilt.cancel_requested_at == cancelled.cancel_requested_at
    assert rebuilt.cancel_requested_by_id == scope.user.id
  end

  test "the reason cancelled_by_member is the cancel's: a starter's outcome drops it" do
    assert Run.cancel_reason() in Outcome.reserved_reasons()

    {:ok, outcome} =
      Outcome.parse(%{
        "version" => 1,
        "state" => "cancelled",
        "reason" => "cancelled_by_member",
        "time" => "2026-11-13T10:00:00Z"
      })

    assert %Outcome{state: "cancelled", reason: nil} = outcome
  end

  test "the canceller is named by the local part of their address, then Former member", %{
    scope: scope,
    run: run
  } do
    {:ok, cancelled} = Runs.cancel(scope, run)
    assert Runs.Cancel.canceller(cancelled) == hd(String.split(scope.user.email, "@"))

    assert Runs.Cancel.canceller(%{cancelled | cancel_requested_by_id: nil}) == "Former member"
    assert Runs.Cancel.canceller(run) == nil
  end

  test "the query of a cancelling run returns the runs cancelling?/2 is true of", %{
    scope: scope
  } do
    at = DateTime.utc_now()
    before = DateTime.add(at, -60, :second)
    later = DateTime.add(at, 3600, :second)
    mark = [cancel_requested_at: before]
    issued = DateTime.add(at, -120, :second)

    # A run that goes through a gateway: its registration and run key, the end of its
    # attach window `attach_by`.
    gateway = [
      registered_at: issued,
      registration_labels: %{},
      registration_about: %{},
      registration_digest: :crypto.hash(:sha256, "registration"),
      registration_interval_seconds: 30,
      registration_answer_digest: "answer",
      run_key_payload: "payload",
      run_key_issued_at: issued,
      attach_by: before
    ]

    attached = [
      attached_at: before,
      attach_interval_seconds: 30,
      attach_answer_digest: "answer"
    ]

    cases = [
      running: [state: "running"],
      marked_running: [state: "running"] ++ mark,
      marked_pending: [state: "pending"] ++ mark,
      marked_running_with_exit: [state: "running", exit_state: "cancelled"] ++ mark,
      marked_cancelled: [state: "cancelled", exit_state: "cancelled"] ++ mark,
      marked_failed: [state: "failed"] ++ mark,
      marked_paused: [state: "paused"] ++ mark,
      marked_lost_may_attach: [state: "lost", backstop_at: later] ++ mark,
      marked_lost_no_backstop: [state: "lost"] ++ mark,
      marked_lost_exited: [state: "lost", exited_at: before] ++ mark,
      marked_lost_silenced: [state: "lost", silenced_at: before] ++ mark,
      marked_lost_past_backstop: [state: "lost", backstop_at: before] ++ mark,
      marked_lost_attach_closed: [state: "lost"] ++ gateway ++ mark,
      marked_lost_attached: [state: "lost"] ++ gateway ++ attached ++ mark,
      # Retention pruned its events: no route serves it (`Apiary.Runs.Sender.live?/2`).
      marked_lost_pruned: [state: "lost", events_pruned_at: before] ++ mark,
      marked_running_pruned: [state: "running", events_pruned_at: before] ++ mark,
      lost_may_attach: [state: "lost", backstop_at: later]
    ]

    runs = for {name, attrs} <- cases, into: %{}, do: {name, run_fixture(scope, attrs)}
    ids = Enum.map(runs, fn {_name, run} -> run.id end)

    queried =
      Repo.all(
        from(r in Run,
          as: :run,
          where: r.id in ^ids,
          where: ^Apiary.Runs.Cancel.cancelling_condition(at),
          select: r.id
        )
      )

    expected = for {name, run} <- runs, Apiary.Runs.Cancel.cancelling?(run, at), do: name
    got = for {name, run} <- runs, run.id in queried, do: name

    assert Enum.sort(got) == Enum.sort(expected)

    assert Enum.sort(expected) ==
             Enum.sort([
               :marked_running,
               :marked_pending,
               :marked_lost_may_attach,
               :marked_lost_no_backstop,
               :marked_lost_attached
             ])
  end

  test "a run with an exit folded but not yet a state is not running", %{scope: scope} do
    run = started_run(scope)
    event_fixture(run, 50, "run.exited", %{"state" => "succeeded", "exit_code" => 0})
    {:ok, _projected} = Projector.project(run)

    assert {:error, :not_running} = Runs.cancel(scope, Repo.get!(Run, run.id))
  end
end
