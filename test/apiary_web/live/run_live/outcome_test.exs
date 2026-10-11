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

  test "a session's run keeps the runtime's clause in every state" do
    exited = %{exit_state: "lost", exited_at: DateTime.utc_now()}

    for {outcome, state, word} <- [
          {"succeeded", "completed", "Succeeded"},
          {"failed", "failed", "Failed"},
          {"cancelled", "cancelled", "Cancelled"}
        ] do
      run = Map.merge(exited, %{state: state, outcome_state: outcome})

      assert RunComponents.outcome_sentence(Map.merge(run, %{signal: "SIGTERM"})) ==
               "#{word}, as its starter said; the runtime ended with SIGTERM"

      assert RunComponents.outcome_sentence(Map.merge(run, %{signal: nil, exit_code: 1})) ==
               "#{word}, as its starter said; the runtime exited 1"

      assert RunComponents.outcome_sentence(Map.merge(run, %{signal: nil, exit_code: -1})) ==
               "#{word}, as its starter said; the runtime's exit was not recorded"

      assert RunComponents.outcome_sentence(Map.put(run, :exited_at, nil)) ==
               "#{word}, as its starter said; the runtime has not exited yet"
    end
  end

  test "a run refused at its start says the starter's state alone, in every state" do
    for {outcome, state, word} <- [
          {"succeeded", "completed", "Succeeded"},
          {"failed", "failed", "Failed"},
          {"cancelled", "cancelled", "Cancelled"}
        ] do
      run = %{
        state: state,
        outcome_state: outcome,
        exited_at: nil,
        refused_at: DateTime.utc_now()
      }

      assert RunComponents.outcome_sentence(run) == "#{word}, as its starter said"
    end
  end

  test "the header of a refused run given an outcome says the starter's state alone", %{
    conn: conn,
    scope: scope
  } do
    for {outcome, word} <- [
          {"succeeded", "Succeeded"},
          {"failed", "Failed"},
          {"cancelled", "Cancelled"}
        ] do
      run =
        projected(scope, [{2, "run.refused", %{"code" => "image_unknown"}}], given(outcome))

      assert %DateTime{} = run.refused_at

      {:ok, lv, _html} = page(conn, scope, run)
      assert render(element(lv, "#run-meta #run-outcome")) =~ ">#{word}, as its starter said<"
      refute has_element?(lv, "#run-meta", "the runtime")
    end
  end

  test "an outcome sent with no state says no sentence, only the starter gave no outcome", %{
    conn: conn,
    scope: scope
  } do
    session = {1, "run.started", started_data()}

    for events <- [
          [session],
          [session, {2, "run.exited", %{"state" => "failed", "exit_code" => 1}}],
          [session, {2, "run.exited", %{"state" => "succeeded", "exit_code" => 0}}],
          [session, {2, "run.exited", %{"state" => "failed", "signal" => "SIGKILL"}}],
          [session, {2, "run.exited", %{"state" => "cancelled", "reason" => "stopped"}}],
          [session, {2, "run.exited", %{"reason" => "quiet", "quiet_seconds" => 60}}],
          [{2, "run.refused", %{"code" => "image_unknown"}}]
        ] do
      run = projected(scope, events, given("cancelled", "stopped"))
      assert %Run{state: "cancelled", reason: "stopped"} = run
      assert RunComponents.outcome_sentence(run) == nil
      assert RunComponents.reason_words(run) == "the starter gave no outcome"

      alive = render_component(&RunComponents.alive/1, state: run.state, run: run)
      refute alive =~ "as its starter said"
      assert alive =~ "Cancelled"

      {:ok, lv, html} = page(conn, scope, run)
      refute html =~ "as its starter said"
      refute has_element?(lv, "#run-outcome")
      assert has_element?(lv, "#run-meta #run-state", "Cancelled")
      assert has_element?(lv, "#run-reason", "the starter gave no outcome")
      assert has_element?(lv, "#rail-reason", "the starter gave no outcome")
    end
  end

  test "an outcome sent with no state is announced as a cancelled run", %{
    conn: conn,
    scope: scope
  } do
    run = projected(scope, [{1, "run.started", started_data()}], %{})
    assert %Run{state: "running"} = run
    {:ok, lv, _html} = page(conn, scope, run)

    run =
      run
      |> Ecto.Changeset.change(
        Map.merge(given("cancelled", "stopped"), %{state: "cancelled", reason: "stopped"})
      )
      |> Apiary.Repo.update!()

    Apiary.Runs.broadcast_changed(run)
    html = render(lv)

    assert render(element(lv, "#run-announcer")) =~
             "Run cancelled: the starter gave no outcome."

    refute html =~ "as its starter said"
    assert has_element?(lv, "#run-reason", "the starter gave no outcome")
  end

  test "every other outcome keeps its sentence" do
    exited = %{exit_state: "lost", exited_at: DateTime.utc_now()}

    for {outcome, reason, state, word} <- [
          {"succeeded", nil, "completed", "Succeeded"},
          {"failed", "checks_failed", "failed", "Failed"},
          {"cancelled", nil, "cancelled", "Cancelled"},
          {"cancelled", "no_longer_needed", "cancelled", "Cancelled"}
        ] do
      run =
        Map.merge(exited, %{
          state: state,
          outcome_state: outcome,
          outcome_reason: reason,
          exit_code: 1
        })

      assert RunComponents.outcome_sentence(run) ==
               "#{word}, as its starter said; the runtime exited 1"
    end
  end

  test "the starter's end with no outcome still reads stopped, no outcome given", %{
    conn: conn,
    scope: scope
  } do
    started = {1, "run.started", started_data()}

    for exit <- [
          %{"state" => "cancelled", "reason" => "stopped"},
          %{"reason" => "stopped"},
          %{"state" => "failed", "reason" => "run_ended_at_issuer"},
          %{"reason" => "run_ended_at_issuer"}
        ] do
      run = projected(scope, [started, {2, "run.exited", exit}], %{})
      assert %Run{state: "cancelled", outcome_state: nil} = run
      assert RunComponents.reason_words(run) == "stopped, no outcome given"

      {:ok, lv, _html} = page(conn, scope, run)
      assert has_element?(lv, "#run-reason", "stopped, no outcome given")
      refute has_element?(lv, "#run-meta", "the starter gave no outcome")
    end
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
