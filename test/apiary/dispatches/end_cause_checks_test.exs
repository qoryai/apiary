defmodule Apiary.Dispatches.EndCauseChecksTest do
  # The checks of `dispatch_runs` and `dispatches` that list end causes, read from the
  # database after every migration: each list equals the causes the code ends a run for.
  # A migration that rewrites a list and leaves out a cause fails here.
  use Apiary.DataCase, async: true

  alias Apiary.Dispatches.{DispatchRun, Handover}

  # The text of the check `name`, as the database stores it.
  defp definition(name) do
    %{rows: [[definition]]} =
      Repo.query!("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1", [
        name
      ])

    definition
  end

  # The causes the check `name` compares `end_cause` with, sorted.
  defp causes(name) do
    [list] =
      Regex.run(~r/end_cause = ANY \(ARRAY\[([^\]]*)\]/, definition(name),
        capture: :all_but_first
      )

    ~r/'([a-z_]+)'::text/
    |> Regex.scan(list, capture: :all_but_first)
    |> List.flatten()
    |> Enum.sort()
  end

  defp names(causes), do: causes |> Enum.map(&Atom.to_string/1) |> Enum.sort()

  test "the end-cause check of each table lists every end cause" do
    for table <- ~w(dispatch_runs dispatches) do
      assert causes("#{table}_end_cause_check") == names(DispatchRun.end_causes())
    end
  end

  test "the outcome checks list run_ended, build_failed, harness_unresolved and the causes of a handover that cannot form a run" do
    assert causes("dispatch_runs_result_outcome_check") ==
             names([:run_ended, :build_failed, :harness_unresolved | Handover.unformed()])

    assert causes("dispatch_runs_result_outcome_error_check") ==
             names([:build_failed, :harness_unresolved | Handover.unformed()])
  end

  test "the end_detail check lists run_refused and harness_unresolved" do
    assert causes("dispatch_runs_end_detail_check") == names([:run_refused, :harness_unresolved])
  end
end
