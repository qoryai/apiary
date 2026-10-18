defmodule Apiary.WorkItems.ExploreTest do
  # Where a run of a take in stands, and where Explore stands for a live work item, from
  # the runs, their registered runs and their result events, with no database.
  use ExUnit.Case, async: true

  import Apiary.WorkItemsFixtures,
    only: [understood_result: 0, questions_result: 0, questions_result: 1]

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.{Event, Run}
  alias Apiary.WorkItems.Explore

  @now ~U[2026-10-18 12:00:00.000000Z]

  defp dispatch_run(state, cause \\ nil, attempt \\ 1),
    do: %DispatchRun{
      state: state,
      end_cause: cause,
      take_in: 1,
      attempt: attempt,
      of: 3,
      updated_at: @now
    }

  # A registered run whose exit is folded, unless `attrs` say otherwise.
  defp run(attrs \\ []) do
    struct!(
      %Run{
        id: Ecto.UUID.generate(),
        state: "completed",
        exit_state: "completed",
        outcome_received_at: DateTime.add(@now, -60, :second)
      },
      attrs
    )
  end

  defp event(data), do: %Event{type: "dev.qory.session.result", sequence: 9, data: data}

  defp result_event(document),
    do: event(%{"is_error" => false, "result" => Jason.encode!(document)})

  defp place(dispatch_run, run \\ nil, event \\ nil),
    do: Explore.step(dispatch_run, run, event, @now) |> Map.take([:place, :outcome])

  describe "step/4" do
    test "a run waiting or claimed is queued, and one handed over running" do
      assert place(dispatch_run(:waiting)) == %{place: :queued, outcome: nil}
      assert place(dispatch_run(:claimed)) == %{place: :queued, outcome: nil}

      assert place(dispatch_run(:handed_over), run(state: "running")) == %{
               place: :running,
               outcome: nil
             }
    end

    test "a run's result decides: a proposal, or questions" do
      step =
        Explore.step(
          dispatch_run(:ended, :run_ended),
          run(),
          result_event(understood_result()),
          @now
        )

      assert %{place: :proposal, outcome: :proposal, result: %{"verdict" => "understood"}} = step

      step =
        Explore.step(
          dispatch_run(:ended, :run_ended),
          run(),
          result_event(questions_result()),
          @now
        )

      assert %{place: :questions, outcome: :questions, result: %{"questions" => [_, _]}} = step
    end

    test "a result counts even when the run failed or was cancelled by its outcome" do
      for state <- ["failed", "cancelled"] do
        assert place(
                 dispatch_run(:ended, :run_ended),
                 run(state: state),
                 result_event(understood_result())
               ) ==
                 %{place: :proposal, outcome: :proposal}
      end
    end

    test "without a result: none, an error, or one the check refuses" do
      ended = dispatch_run(:ended, :run_ended)
      assert place(ended, run(), nil) == %{place: :no_result, outcome: :none}

      assert place(ended, run(), event(%{"is_error" => false})) == %{
               place: :no_result,
               outcome: :none
             }

      assert place(ended, run(), event(%{"is_error" => true, "result" => "{}"})) ==
               %{place: :no_result, outcome: :error}

      assert place(ended, run(), event(%{"result" => "{}"})) == %{
               place: :no_result,
               outcome: :error
             }

      assert place(ended, run(), event(%{"is_error" => false, "result" => "not json"})) ==
               %{place: :no_result, outcome: :refused}

      wrong = Map.put(understood_result(), "verdict", "maybe")
      assert place(ended, run(), result_event(wrong)) == %{place: :no_result, outcome: :refused}
    end

    test "a run without a result that reads as cancelled or lost is so" do
      ended = dispatch_run(:ended, :run_ended)
      assert place(ended, run(state: "cancelled")) == %{place: :cancelled, outcome: nil}
      assert place(ended, run(state: "lost", lost_at: @now)) == %{place: :lost, outcome: nil}
    end

    test "a run ended lost, or released, is lost or cancelled, whatever its result" do
      assert place(dispatch_run(:ended, :lost), run(), result_event(understood_result())) ==
               %{place: :lost, outcome: nil}

      assert place(dispatch_run(:ended, :released), run()) == %{place: :cancelled, outcome: nil}
      assert place(dispatch_run(:ended, :released)) == %{place: :cancelled, outcome: nil}
      assert place(dispatch_run(:ended, :closed)) == %{place: :cancelled, outcome: nil}
      assert place(dispatch_run(:ended, :undone)) == %{place: :cancelled, outcome: nil}
    end

    test "a run its handover could not form has no result: an error" do
      for cause <- [:variables_invalid, :ticket_gone, :inputs_invalid] do
        assert place(dispatch_run(:ended, cause)) == %{place: :no_result, outcome: :error}
      end
    end

    test "a run ended by its outcome with no result yet reads as running for 10 minutes" do
      ended = dispatch_run(:ended, :run_ended)
      waiting = run(exit_state: nil, outcome_received_at: DateTime.add(@now, -599, :second))
      assert place(ended, waiting) == %{place: :running, outcome: nil}

      late = %{waiting | outcome_received_at: DateTime.add(@now, -600, :second)}
      assert place(ended, late) == %{place: :no_result, outcome: :none}

      # Its exit folded, every event before it is stored; lost or pruned, none comes.
      assert place(ended, %{waiting | exit_state: "completed"}) == %{
               place: :no_result,
               outcome: :none
             }

      assert place(ended, %{waiting | state: "lost", lost_at: @now}) == %{
               place: :lost,
               outcome: nil
             }

      assert place(ended, %{waiting | events_pruned_at: @now}) == %{
               place: :no_result,
               outcome: :none
             }

      # A result that comes in the window counts at once.
      assert place(ended, waiting, result_event(understood_result())) ==
               %{place: :proposal, outcome: :proposal}
    end
  end

  describe "step/4 with what the run of the queue keeps" do
    defp stored(outcome, result \\ nil),
      do: %{dispatch_run(:ended, :run_ended) | result_outcome: outcome, result: result}

    test "the stored outcome wins over the result event" do
      kept = questions_result(["Which shelf?"])

      step =
        Explore.step(stored(:questions, kept), run(), result_event(understood_result()), @now)

      assert %{place: :questions, outcome: :questions, result: ^kept} = step

      for outcome <- [:none, :error, :refused] do
        assert place(stored(outcome), run(), result_event(understood_result())) ==
                 %{place: :no_result, outcome: outcome}
      end
    end

    test "a stored proposal or questions reads from the row, its events pruned" do
      pruned = run(events_pruned_at: @now)

      assert %{place: :proposal, outcome: :proposal, result: %{"verdict" => "understood"}} =
               Explore.step(stored(:proposal, understood_result()), pruned, nil, @now)

      assert %{place: :questions, result: %{"questions" => [_, _]}} =
               Explore.step(stored(:questions, questions_result()), pruned, nil, @now)
    end

    test "a stored proposal or questions whose result was cleared reads as a pruned run" do
      for outcome <- [:proposal, :questions] do
        assert %{place: :no_result, outcome: :none, result: nil} =
                 Explore.step(stored(outcome), run(events_pruned_at: @now), nil, @now)

        assert place(stored(outcome), run(state: "cancelled")) ==
                 %{place: :cancelled, outcome: nil}

        assert place(stored(outcome), run(state: "lost", lost_at: @now)) ==
                 %{place: :lost, outcome: nil}
      end
    end

    test "a stored outcome without a result reads as cancelled or lost as its run does" do
      assert place(stored(:none), run(state: "cancelled")) == %{place: :cancelled, outcome: nil}

      assert place(stored(:error), run(state: "lost", lost_at: @now)) ==
               %{place: :lost, outcome: nil}
    end

    test "none stored falls back to the result event, and to the window before it" do
      waiting = run(exit_state: nil, outcome_received_at: DateTime.add(@now, -599, :second))
      assert place(stored(nil), waiting) == %{place: :running, outcome: nil}

      assert place(stored(nil), waiting, result_event(understood_result())) ==
               %{place: :proposal, outcome: :proposal}

      assert place(stored(nil), run(), nil) == %{place: :no_result, outcome: :none}
    end
  end

  describe "status/2" do
    defp step(place, attempt), do: %{place: place, attempt: attempt, of: 3}

    test "the latest run's place, a proposal waiting for Confirm" do
      assert Explore.status([], false) == :queued
      assert Explore.status([step(:queued, 1)], false) == :queued
      assert Explore.status([step(:running, 1)], false) == :running
      assert Explore.status([step(:questions, 1), step(:proposal, 2)], false) == :confirm

      for place <- [:questions, :no_result, :lost, :cancelled],
          do: assert(Explore.status([step(place, 2)], false) == place)
    end

    test "at the run limit, a run without a proposal is used up" do
      for place <- [:questions, :no_result, :lost, :cancelled],
          do: assert(Explore.status([step(place, 3)], false) == :used_up)

      assert Explore.status([step(:proposal, 3)], false) == :confirm
      assert Explore.status([step(:running, 3)], false) == :running
    end

    test "a confirmed take in waits for Shape" do
      assert Explore.status([step(:proposal, 1)], true) == :shape
    end

    test "the stages" do
      assert Explore.stage(:shape) == :shape
      assert Explore.stage(:confirm) == :confirm

      for status <- [:queued, :running, :questions, :no_result, :lost, :cancelled, :used_up],
          do: assert(Explore.stage(status) == :explore)
    end
  end
end
