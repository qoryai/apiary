defmodule ApiaryWeb.PreparationCleanUpTest do
  # The Machine removed row of the Run list (`ApiaryWeb.PreparationComponents`): what it
  # shows for each report of the pool's starter, and with no report before and after the
  # 15 minutes from the run's end, and when it is not shown; when it stops waiting; its
  # start, its duration, its cause and the machine's time alive; Machine stays registered
  # for a run on a permanent machine.
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
        queued_at: nil,
        requested_ms: 1_000,
        started_as: nil,
        release_reason: nil,
        handed_over_at: DateTime.add(@ended, -590, :second),
        ended_at: @ended,
        end: nil,
        removal_cause: :run_ended,
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
    defp list(clean_up, machine \\ machine()) do
      render_component(&PreparationComponents.run_list/1,
        preparation: preparation(machine),
        alive: false,
        clean_up: clean_up
      )
      |> LazyHTML.from_fragment()
    end

    defp row(clean_up, machine \\ machine()) do
      row = clean_up |> list(machine) |> LazyHTML.query("#prepare-machine-removed")
      assert Enum.count(row) == 1
      row
    end

    defp text(row), do: row |> LazyHTML.text() |> String.split() |> Enum.join(" ")

    defp head(row), do: row |> LazyHTML.query(".q-prep-row") |> text()

    defp facts(row) do
      terms = row |> LazyHTML.query("dt") |> Enum.map(&text/1)
      values = row |> LazyHTML.query("dd") |> Enum.map(&text/1)
      Enum.zip(terms, values)
    end

    test "a gone report: from the run's end to the report, opening to Cause and Alive" do
      row = row({:report, :gone, @report_at})

      assert head(row) =~ ~r/^Machine removed\b/
      refute head(row) =~ "Waiting"

      assert row |> LazyHTML.query(".q-tc1 time") |> LazyHTML.attribute("datetime") ==
               [DateTime.to_iso8601(@ended)]

      # From the run's end at 12:00:00 to the report at 12:03:04.
      assert text(LazyHTML.query(row, ".q-tc2")) == "3 m 04 s"

      # The machine was started 599 s before the run's end, 783 s before the report.
      assert facts(row) == [{"Cause", "Run ended"}, {"Alive", "13 m 03 s"}]
      assert row |> LazyHTML.attribute("data-clean-up") == ["gone"]

      assert LazyHTML.query(list({:report, :gone, @report_at}), "details#prepare-machine-removed")
             |> Enum.count() == 1
    end

    test "Cause is Keep-alive lost for a lost run, and is left out for any other run" do
      row = row({:report, :gone, @report_at}, machine(%{removal_cause: :keep_alive_lost}))
      assert {"Cause", "Keep-alive lost"} in facts(row)

      row = row({:report, :gone, @report_at}, machine(%{removal_cause: nil}))
      assert facts(row) == [{"Alive", "13 m 03 s"}]
    end

    test "waiting for a report, then none: the words, the run's end, and no duration" do
      for {clean_up, words} <- [
            {{:waiting, minutes(15)}, "Waiting for a report"},
            {:no_report, "No removal report"}
          ] do
        row = row(clean_up)

        assert head(row) ==
                 "Machine removed " <> words <> " " <> text(LazyHTML.query(row, ".q-tc1"))

        assert text(LazyHTML.query(row, ".q-tc2")) == "", words

        assert row |> LazyHTML.query(".q-tc1 time") |> LazyHTML.attribute("datetime") ==
                 [DateTime.to_iso8601(@ended)]

        # No time alive without the gone report: the row opens to the cause alone.
        assert facts(row) == [{"Cause", "Run ended"}], words
      end
    end

    test "with neither a cause nor a time alive, the row does not open" do
      html = list(:no_report, machine(%{removal_cause: nil}))
      assert html |> LazyHTML.query("div#prepare-machine-removed") |> Enum.count() == 1
      assert html |> LazyHTML.query("details#prepare-machine-removed") |> Enum.count() == 0
    end

    test "a report other than gone has its words beside the name, and no duration" do
      for {state, words} <- [
            {:deleting, "Machine removal requested"},
            {:delete_failed, "Removal failed: the machine still exists"}
          ] do
        row = row({:report, state, @report_at})
        assert head(row) =~ "Machine removed " <> words
        assert text(LazyHTML.query(row, ".q-tc2")) == "", words
      end
    end

    test "comes after every other row, and is not there without a clean up" do
      ids =
        :no_report
        |> list()
        |> LazyHTML.query("#prepare-machine > .q-prep-steps > li > [id]")
        |> LazyHTML.attribute("id")

      assert List.last(ids) == "prepare-machine-removed"

      html =
        render_component(&PreparationComponents.run_list/1,
          preparation: preparation(machine()),
          alive: false
        )

      refute html =~ "prepare-machine-removed"
    end
  end
end
