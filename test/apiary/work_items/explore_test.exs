defmodule Apiary.WorkItems.ExploreTest do
  # Where a run of a take in stands, and where Explore stands for a live work item, from
  # the runs of the queue, what each kept (`result_outcome`), and their registered runs,
  # with no database.
  use ExUnit.Case, async: true

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.Explore

  @now ~U[2026-10-18 12:00:00.000000Z]

  defp dispatch_run(state, cause \\ nil, outcome \\ nil),
    do: %DispatchRun{
      state: state,
      end_cause: cause,
      result_outcome: outcome,
      take_in: 1,
      attempt: 1,
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

  defp place(dispatch_run, run \\ nil),
    do: Explore.step(dispatch_run, run) |> Map.take([:place, :outcome])

  describe "step/2" do
    test "a run waiting or claimed is queued, and one handed over running" do
      assert place(dispatch_run(:waiting)) == %{place: :queued, outcome: nil}
      assert place(dispatch_run(:claimed)) == %{place: :queued, outcome: nil}

      assert place(dispatch_run(:handed_over), run(state: "running")) == %{
               place: :running,
               outcome: nil
             }
    end

    test "what the run kept decides: a proposal, or questions, whatever its run's state" do
      for outcome <- [:proposal, :questions], state <- ["completed", "failed", "cancelled"] do
        assert place(dispatch_run(:ended, :run_ended, outcome), run(state: state)) ==
                 %{place: outcome, outcome: outcome}
      end
    end

    test "ended with nothing kept yet: running, until its settle stores what it gave" do
      assert place(dispatch_run(:ended, :run_ended), run()) == %{place: :running, outcome: nil}
    end

    test "none or an error kept: no result, or cancelled or lost as its run reads" do
      for outcome <- [:none, :error, :refused] do
        assert place(dispatch_run(:ended, :run_ended, outcome), run()) ==
                 %{place: :no_result, outcome: outcome}
      end

      assert place(dispatch_run(:ended, :run_ended, :none), run(state: "cancelled")) ==
               %{place: :cancelled, outcome: nil}

      assert place(dispatch_run(:ended, :run_ended, :error), run(state: "lost", lost_at: @now)) ==
               %{place: :lost, outcome: nil}
    end

    test "a run ended lost is lost, unless it left questions open" do
      assert place(dispatch_run(:ended, :lost), run()) == %{place: :lost, outcome: nil}

      assert place(dispatch_run(:ended, :lost, :questions), run()) ==
               %{place: :questions, outcome: :questions}
    end

    test "a run released, closed or undone is cancelled" do
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

    test "at the run limit, a run without a result is used up; questions still wait" do
      for place <- [:no_result, :lost, :cancelled],
          do: assert(Explore.status([step(place, 3)], false) == :used_up)

      assert Explore.status([step(:questions, 3)], false) == :questions

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
