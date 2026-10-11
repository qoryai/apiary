defmodule ApiaryWeb.RunLive.OutcomeTest do
  # A run whose state its starter's outcome set, unlike what its exit said: the run page
  # says both, "Succeeded, as its starter said; the runtime exited 1".
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.{Projector, Run}
  alias ApiaryWeb.RunComponents

  setup :register_and_log_in_user

  defp given(state, reason \\ nil) do
    %{
      outcome_state: state,
      outcome_reason: reason,
      outcome_time: DateTime.utc_now(),
      outcome_received_at: DateTime.utc_now(),
      outcome_digest: :crypto.hash(:sha256, "outcome #{state}")
    }
  end

  defp projected(scope, events, attrs) do
    run = run_fixture(scope, attrs)
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    run
  end

  defp page(conn, scope, run),
    do: live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

  test "the header says the starter's state and the runtime's exit", %{conn: conn, scope: scope} do
    run =
      projected(
        scope,
        [
          {1, "run.started", started_data()},
          {2, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1200}}
        ],
        given("succeeded")
      )

    assert %Run{state: "completed", exit_state: "failed", exit_code: 1} = run

    {:ok, lv, _html} = page(conn, scope, run)

    assert has_element?(
             lv,
             "#run-meta #run-state.q-sdot-completed #run-outcome",
             "Succeeded, as its starter said; the runtime exited 1"
           )

    # The exit is said in the sentence, not again after it.
    refute has_element?(lv, "#run-meta", "exit 1")
  end

  test "an outcome that agrees with the exit reads as today", %{conn: conn, scope: scope} do
    run =
      projected(
        scope,
        [
          {1, "run.started", started_data()},
          {2, "run.exited", %{"state" => "succeeded", "exit_code" => 0}}
        ],
        given("succeeded")
      )

    {:ok, lv, _html} = page(conn, scope, run)
    assert has_element?(lv, "#run-meta #run-state.q-sdot-completed", "Completed")
    refute has_element?(lv, "#run-outcome")
  end

  test "the sentence's variants: a signal, no exit yet, an exit not recorded" do
    base = %{state: "failed", outcome_state: "failed", exit_state: "completed"}
    exited = Map.put(base, :exited_at, DateTime.utc_now())

    assert RunComponents.outcome_sentence(Map.merge(exited, %{signal: "SIGKILL", exit_code: nil})) ==
             "Failed, as its starter said; the runtime ended with SIGKILL"

    assert RunComponents.outcome_sentence(Map.merge(exited, %{signal: nil, exit_code: 1})) ==
             "Failed, as its starter said; the runtime exited 1"

    assert RunComponents.outcome_sentence(Map.merge(exited, %{signal: nil, exit_code: -1})) ==
             "Failed, as its starter said; the runtime's exit was not recorded"

    assert RunComponents.outcome_sentence(
             Map.merge(base, %{state: "cancelled", outcome_state: "cancelled", exited_at: nil})
           ) == "Cancelled, as its starter said; the runtime has not exited yet"

    # No outcome, or one the exit agrees with: nothing new is said.
    assert RunComponents.outcome_sentence(%{state: "failed", outcome_state: nil}) == nil

    assert RunComponents.outcome_sentence(
             Map.merge(exited, %{exit_state: "failed", exit_code: 1})
           ) ==
             nil
  end

  test "an exit folded before its state was kept reads as the exit alone", %{
    conn: conn,
    scope: scope
  } do
    # Exited 0, completed, with no exit_state, as a run folded before the column was;
    # then given an outcome that agrees.
    run =
      projected(
        scope,
        [
          {1, "run.started", started_data()},
          {2, "run.exited", %{"state" => "succeeded", "exit_code" => 0}}
        ],
        given("succeeded")
      )

    run = run |> Ecto.Changeset.change(exit_state: nil, exit_reason: nil) |> Apiary.Repo.update!()

    assert %Run{state: "completed", exit_state: nil, exit_code: 0} = run
    refute Run.outcome_differs?(run)
    assert RunComponents.outcome_sentence(run) == nil

    {:ok, lv, _html} = page(conn, scope, run)
    assert has_element?(lv, "#run-meta #run-state.q-sdot-completed", "Completed")
    refute has_element?(lv, "#run-outcome")
  end
end
