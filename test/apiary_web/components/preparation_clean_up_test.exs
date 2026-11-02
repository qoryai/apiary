defmodule ApiaryWeb.PreparationCleanUpTest do
  # The Clean up row of the Prepare machine section (`ApiaryWeb.PreparationComponents`):
  # what it shows for each report of the pool's starter, and with no report before and
  # after the 15 minutes from the run's end, for a run on a permanent machine, and when it
  # is not shown; when it stops waiting; and its words and time as rendered.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ApiaryWeb.PreparationComponents

  @ended ~U[2026-10-15 12:00:00.000000Z]
  @report_at ~U[2026-10-15 12:03:04.000000Z]

  defp machine(changes \\ %{}) do
    Map.merge(
      %{
        dispatch_id: "dp_0123456789abcdef",
        pool: %{id: "np_0123456789abcdef", name: "build-pool", place: :workspace, operator: nil},
        machine_type: nil,
        requested_at: DateTime.add(@ended, -600, :second),
        requested_ms: 1_000,
        release_reason: nil,
        handed_over_at: DateTime.add(@ended, -590, :second),
        ended_at: @ended,
        end: nil,
        started: %{
          state: "succeeded",
          started_at: DateTime.add(@ended, -599, :second),
          ended_at: DateTime.add(@ended, -590, :second),
          duration_ms: 9_000
        }
      },
      changes
    )
  end

  defp preparation(machine) do
    %{machine: machine, steps: [], log_pruned_at: nil, session_started_at: nil, stopped: nil}
  end

  defp run(state, node \\ nil), do: %{state: state, node: node}

  defp minutes(minutes), do: DateTime.add(@ended, minutes * 60, :second)

  describe "clean_up/3" do
    test "a report shows its state and time, whether the run is alive or not" do
      for state <- [:deleting, :gone, :delete_failed], run_state <- ["running", "failed"] do
        preparation = preparation(machine(%{end: %{state: state, at: @report_at}, ended_at: nil}))

        assert PreparationComponents.clean_up(preparation, run(run_state), minutes(1)) ==
                 {:report, state, @report_at}
      end
    end

    test "with no report, a run that ended waits 15 minutes from its end, then has none" do
      preparation = preparation(machine())
      due = minutes(15)

      assert PreparationComponents.clean_up(preparation, run("failed"), minutes(0)) ==
               {:waiting, due}

      assert PreparationComponents.clean_up(preparation, run("completed"), minutes(14)) ==
               {:waiting, due}

      assert PreparationComponents.clean_up(preparation, run("failed"), due) == :no_report
      assert PreparationComponents.clean_up(preparation, run("lost"), minutes(60)) == :no_report

      assert PreparationComponents.clean_up_due(preparation, run("failed"), minutes(3)) == due
      assert PreparationComponents.clean_up_due(preparation, run("failed"), due) == nil
    end

    test "no row while the run goes on with no report, or for a dispatch never handed over" do
      assert PreparationComponents.clean_up(
               preparation(machine(%{ended_at: nil})),
               run("running"),
               minutes(1)
             ) == nil

      assert PreparationComponents.clean_up(
               preparation(machine()),
               run("pending"),
               minutes(1)
             ) == nil

      assert PreparationComponents.clean_up(
               preparation(machine(%{handed_over_at: nil})),
               run("failed"),
               minutes(1)
             ) == nil

      assert PreparationComponents.clean_up_due(
               preparation(machine(%{handed_over_at: nil})),
               run("failed"),
               minutes(1)
             ) == nil
    end

    test "a run on a permanent machine keeps it once the run ended; no other run has a row" do
      preparation = preparation(nil)

      assert PreparationComponents.clean_up(preparation, run("completed", %{kind: :node}), @ended) ==
               :stays

      assert PreparationComponents.clean_up(preparation, run("running", %{kind: :node}), @ended) ==
               nil

      assert PreparationComponents.clean_up(preparation, run("failed", %{kind: :gateway}), @ended) ==
               nil

      assert PreparationComponents.clean_up(preparation, run("failed", nil), @ended) == nil
      assert PreparationComponents.clean_up(nil, run("failed", %{kind: :node}), @ended) == nil
    end
  end

  describe "the row" do
    defp row(clean_up) do
      html =
        render_component(&PreparationComponents.prepare_machine/1,
          preparation: preparation(machine()),
          alive: false,
          clean_up: clean_up
        )

      row = html |> LazyHTML.from_fragment() |> LazyHTML.query("#prepare-machine-clean-up")
      assert Enum.count(row) == 1
      row
    end

    defp text(row), do: row |> LazyHTML.text() |> String.split() |> Enum.join(" ")

    test "is the last row, with its words, and the report's time for a report" do
      for {clean_up, words, timed?} <- [
            {{:report, :gone, @report_at}, "Machine removed", true},
            {{:report, :deleting, @report_at}, "Machine removal requested", true},
            {{:report, :delete_failed, @report_at}, "Removal failed: the machine still exists",
             true},
            {{:waiting, minutes(15)}, "Waiting for a report", false},
            {:no_report, "No removal report", false},
            {:stays, "Machine stays registered", false}
          ] do
        row = row(clean_up)
        assert text(row) =~ "Clean up " <> words

        times = LazyHTML.query(row, "time")
        assert Enum.count(times) == if(timed?, do: 1, else: 0), words

        if timed?,
          do: assert(LazyHTML.attribute(times, "datetime") == [DateTime.to_iso8601(@report_at)])
      end
    end

    test "comes after every other row, and is not there without a clean up" do
      html =
        render_component(&PreparationComponents.prepare_machine/1,
          preparation: preparation(machine()),
          alive: false,
          clean_up: :no_report
        )

      ids =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".q-prep-steps > li > [id]")
        |> LazyHTML.attribute("id")

      assert List.last(ids) == "prepare-machine-clean-up"

      html =
        render_component(&PreparationComponents.prepare_machine/1,
          preparation: preparation(machine()),
          alive: false
        )

      refute html =~ "prepare-machine-clean-up"
    end
  end
end
