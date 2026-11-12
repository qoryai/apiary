defmodule ApiaryWeb.OverviewComponentsTest do
  @moduledoc """
  What a row of the overview calls a run (`ApiaryWeb.OverviewComponents.row_title/1`), and
  the Paused part of the fourteen-day chart (`ApiaryWeb.OverviewComponents.days_chart/1`).
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ApiaryWeb.OverviewComponents

  @public_id "rn_7f3e9b205b1d4c7e"

  test "a row calls a run by its title, else its command line, else Run and its number" do
    run = %{
      public_id: @public_id,
      number: 14,
      about_title: "Fix the login redirect",
      labels: %{"task" => "fix-login"},
      command: "claude",
      args: ["-p", "fix the login redirect"]
    }

    assert OverviewComponents.row_title(run) == "Fix the login redirect"

    # A task is an ordinary label, never the title.
    untitled = %{run | about_title: nil}
    assert OverviewComponents.row_title(untitled) == "claude -p fix the login redirect"

    long = %{untitled | args: ["-p", String.duplicate("a", 60)]}
    assert String.length(OverviewComponents.row_title(long)) == 40
    assert OverviewComponents.row_title(long) =~ ~r/…\z/

    assert OverviewComponents.row_title(%{untitled | command: nil}) == "Run 14"
  end

  test "a row's title is shown as a text Forager sent is: no invisible character, no control" do
    run = %{
      public_id: @public_id,
      number: 14,
      about_title: "Fix the#{<<0x202E::utf8>>} login",
      labels: %{},
      command: "claude",
      args: ["-p", "fix\u0085it"]
    }

    assert OverviewComponents.row_title(run) == "Fix the login"
    assert OverviewComponents.row_title(%{run | about_title: nil}) == "claude -p fix\u{FFFD}it"
  end

  test "a title with nothing left to show is no title: the command line, else Run and its number" do
    run = %{
      public_id: @public_id,
      number: 14,
      about_title: "#{<<0x202E::utf8>>}#{<<0x200B::utf8>>}",
      labels: %{},
      command: "claude",
      args: ["-p", "fix it"]
    }

    assert OverviewComponents.row_title(run) == "claude -p fix it"
    assert OverviewComponents.row_title(%{run | command: nil}) == "Run 14"
  end

  test "a command line with nothing left to show is none: Run and its number" do
    run = %{
      public_id: @public_id,
      number: 14,
      about_title: nil,
      labels: %{},
      command: "#{<<0x202E::utf8>>}#{<<0x200B::utf8>>}",
      args: []
    }

    assert OverviewComponents.row_title(run) == "Run 14"
  end

  @today ~D[2026-11-12]
  # The runs plot's baseline: its top margin and its height (`days_chart/1`).
  @base 22 + 104

  # Fourteen days ending today, the last ones `{runs, paused}` as given, the rest empty.
  defp days(last) do
    counts = List.duplicate({0, 0}, 14 - length(last)) ++ last

    counts
    |> Enum.with_index()
    |> Enum.map(fn {{runs, paused}, i} ->
      %{
        day: Date.add(@today, i - 13),
        runs: runs,
        alive: 0,
        ended_well: runs - paused,
        cancelled: 0,
        paused: paused,
        ended_badly: 0,
        denied: 0
      }
    end)
  end

  defp chart(days, width \\ 640) do
    render_component(&OverviewComponents.days_chart/1,
      id: "days",
      days: days,
      today: @today,
      scope: %{organisation: "northwind", workspace: "checkout"},
      width: width
    )
    |> LazyHTML.from_fragment()
  end

  defp slot(doc, offset),
    do: LazyHTML.query(doc, "a[data-day='#{Date.add(@today, offset)}']")

  defp d(doc, offset, class),
    do: doc |> slot(offset) |> LazyHTML.query("path.#{class}") |> LazyHTML.attribute("d")

  describe "the Paused part of each day's runs column" do
    test "a day with paused runs has a part as high as its share of the column; one without has none" do
      doc = chart(days([{6, 1}, {3, 3}, {2, 0}]))

      # 6 runs, the most, fill the 104 px plot; 1 of them paused is 17 px from the base.
      assert [part] = d(doc, -2, "q-col-paused")
      assert part =~ ~r/\AM[0-9.]+ #{@base}V#{@base - 17}h26V#{@base}z\z/

      # Every run of the day paused: the part is the whole column, rounded top included.
      assert d(doc, -1, "q-col-paused") == d(doc, -1, "q-col-runs")

      assert d(doc, 0, "q-col-paused") == []
      assert [_column] = d(doc, 0, "q-col-runs")
      assert doc |> LazyHTML.query("path.q-col-paused") |> Enum.count() == 2
    end

    test "a part that reaches into the rounded top follows the column's outline" do
      doc = chart(days([{50, 49}]))

      # 49 of 50 is 102 px of 104: 2 px into the 4 px corners, each 0.54 px in from the side.
      assert [part] = d(doc, 0, "q-col-paused")
      assert part =~ "V#{@base - 104 + 4}a4 4 0 0 1 0.54 -2h24.93a4 4 0 0 1 0.54 2V#{@base}z"
    end

    test "a day's tooltip says its paused runs, and only a day that has some" do
      doc = chart(days([{6, 1}, {1, 0}]))

      assert doc |> slot(-1) |> LazyHTML.attribute("data-runs") == ["6 runs, 1 paused"]
      assert doc |> slot(0) |> LazyHTML.attribute("data-runs") == ["1 run"]
    end

    test "the key shows only while a day of the fourteen has a paused run" do
      doc = chart(days([{6, 0}, {2, 0}]))
      assert doc |> LazyHTML.query(".q-key-paused") |> Enum.count() == 0
      assert doc |> LazyHTML.query("text.q-key") |> Enum.count() == 0

      doc = chart(days([{6, 1}]))
      assert doc |> LazyHTML.query("rect.q-key-paused[aria-hidden=true]") |> Enum.count() == 1
      assert doc |> LazyHTML.query("text.q-key") |> LazyHTML.text() == "paused"
    end

    test "at the narrowest width the key ends well before the day's maximum" do
      # The width the overview draws at least (`chart_size`), with a five-digit maximum.
      doc = chart(days([{12_345, 1}]), 280)

      [x] = doc |> LazyHTML.query("text.q-key") |> LazyHTML.attribute("x")
      [max] = doc |> LazyHTML.query("text.q-max") |> Enum.map(&LazyHTML.text/1) |> Enum.take(1)
      assert String.trim(max) == "max 12,345"

      # At most 7 px a character at 11 px, both words measured generously.
      key_end = String.to_integer(x) + 7 * String.length("paused")
      max_start = 280 - 7 * String.length(String.trim(max))
      assert key_end < max_start
    end
  end
end
