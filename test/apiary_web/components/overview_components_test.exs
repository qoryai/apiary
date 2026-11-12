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

  # The left edge of the column of the day `offset` from today, at 640 px, 26 px wide, plus
  # `dx`, as the chart writes it.
  defp left(offset, dx \\ 0),
    do: :erlang.float_to_binary((13 + offset + 0.5) * (640 / 14) - 13 + dx, decimals: 2)

  describe "the Paused part of each day's runs column" do
    test "a day with paused runs has a part as high as its share of the column; one without has none" do
      doc = chart(days([{6, 1}, {3, 3}, {2, 0}]))

      # 6 runs, the most, fill the 104 px plot; 1 of them paused is 17 px from the base, of
      # which the top pixel is the gap between the two parts.
      assert d(doc, -2, "q-col-paused") == [
               "M#{left(-2)} #{@base}V#{@base - 16}H#{left(-2, 26)}V#{@base}z"
             ]

      # The rest of the column starts above the gap, from 17 px to the rounded top: no runs
      # part under the Paused part.
      assert d(doc, -2, "q-col-runs") == [
               "M#{left(-2)} #{@base - 17}V#{@base - 100}A4 4 0 0 1 #{left(-2, 4)} #{@base - 104}" <>
                 "H#{left(-2, 22)}A4 4 0 0 1 #{left(-2, 26)} #{@base - 100}V#{@base - 17}z"
             ]

      # Every run of the day paused: the part is the whole column, rounded top included.
      assert [whole] = d(doc, -1, "q-col-paused")

      assert whole =~
               ~r/\AM#{left(-1)} #{@base}V#{@base - 52 + 4}a4 4 0 0 1 4 -4h18a4 4 0 0 1 4 4V#{@base}z\z/

      assert d(doc, -1, "q-col-runs") == []

      assert d(doc, 0, "q-col-paused") == []
      assert [_column] = d(doc, 0, "q-col-runs")
      assert doc |> LazyHTML.query("path.q-col-paused") |> Enum.count() == 2
    end

    test "a part is the whole column only when every run paused" do
      # At a maximum of 200, 2 runs are a 2 px column and 20 runs a 10 px one.
      doc = chart(days([{200, 0}, {2, 1}, {20, 19}]))

      # 1 of 2 is 1 px, not the 2 px least, so the column keeps 1 px of its runs part. A
      # 2 px column has no room for a gap: the two parts meet at 1 px.
      i1 = 2 - :math.sqrt(3)

      assert d(doc, -1, "q-col-paused") == [
               "M#{left(-1)} #{@base}A2 2 0 0 1 #{left(-1, i1)} #{@base - 1}" <>
                 "H#{left(-1, 26 - i1)}A2 2 0 0 1 #{left(-1, 26)} #{@base}z"
             ]

      assert d(doc, -1, "q-col-runs") == [
               "M#{left(-1, i1)} #{@base - 1}A2 2 0 0 1 #{left(-1, 2)} #{@base - 2}" <>
                 "H#{left(-1, 24)}A2 2 0 0 1 #{left(-1, 26 - i1)} #{@base - 1}z"
             ]

      # 19 of 20 rounds up to the whole 10 px; the rest starts at 9 px, and the part stops
      # at 8 px, under the 1 px gap.
      i8 = 4 - :math.sqrt(12)
      i9 = 4 - :math.sqrt(7)

      assert d(doc, 0, "q-col-paused") == [
               "M#{left(0)} #{@base}V#{@base - 6}A4 4 0 0 1 #{left(0, i8)} #{@base - 8}" <>
                 "H#{left(0, 26 - i8)}A4 4 0 0 1 #{left(0, 26)} #{@base - 6}V#{@base}z"
             ]

      assert d(doc, 0, "q-col-runs") == [
               "M#{left(0, i9)} #{@base - 9}A4 4 0 0 1 #{left(0, 4)} #{@base - 10}" <>
                 "H#{left(0, 22)}A4 4 0 0 1 #{left(0, 26 - i9)} #{@base - 9}z"
             ]
    end

    test "a 3 px column has 1 px of each part and the 1 px gap between them" do
      # At a maximum of 104, 3 runs are a 3 px column; 1 of them paused is 1 px, raised to
      # the 2 px least, whose top pixel is the gap.
      doc = chart(days([{104, 0}, {3, 1}]))
      i1 = 3 - :math.sqrt(8)
      i2 = 3 - :math.sqrt(5)

      assert d(doc, 0, "q-col-paused") == [
               "M#{left(0)} #{@base}A3 3 0 0 1 #{left(0, i1)} #{@base - 1}" <>
                 "H#{left(0, 26 - i1)}A3 3 0 0 1 #{left(0, 26)} #{@base}z"
             ]

      assert d(doc, 0, "q-col-runs") == [
               "M#{left(0, i2)} #{@base - 2}A3 3 0 0 1 #{left(0, 3)} #{@base - 3}" <>
                 "H#{left(0, 23)}A3 3 0 0 1 #{left(0, 26 - i2)} #{@base - 2}z"
             ]
    end

    test "a part that reaches into the rounded top follows the column's outline" do
      doc = chart(days([{50, 49}]))

      # 49 of 50 is 102 px of 104: the rest starts 2 px into the 4 px corners, each side
      # 0.54 px in there, and the part stops 1 px below it, each side 0.13 px in.
      inset = 4 - :math.sqrt(12)
      i101 = 4 - :math.sqrt(15)

      assert d(doc, 0, "q-col-paused") == [
               "M#{left(0)} #{@base}V#{@base - 100}A4 4 0 0 1 #{left(0, i101)} #{@base - 101}" <>
                 "H#{left(0, 26 - i101)}A4 4 0 0 1 #{left(0, 26)} #{@base - 100}V#{@base}z"
             ]

      assert d(doc, 0, "q-col-runs") == [
               "M#{left(0, inset)} #{@base - 102}A4 4 0 0 1 #{left(0, 4)} #{@base - 104}" <>
                 "H#{left(0, 22)}A4 4 0 0 1 #{left(0, 26 - inset)} #{@base - 102}z"
             ]
    end

    test "a day's tooltip reads its paused runs, and only a day that has some" do
      doc = chart(days([{6, 1}, {1, 0}]))

      assert doc |> slot(-1) |> LazyHTML.attribute("data-runs") == ["6 runs, 1 paused"]
      assert doc |> slot(0) |> LazyHTML.attribute("data-runs") == ["1 run"]
    end

    test "the legend shows only while a day of the fourteen has a paused run" do
      doc = chart(days([{6, 0}, {2, 0}]))
      assert doc |> LazyHTML.query(".q-legend-paused, .q-legend") |> Enum.count() == 0

      # The legend is part of the title's line, so the browser places it after the title.
      doc = chart(days([{6, 1}]))
      title = LazyHTML.query(doc, "text.q-ttl") |> Enum.take(1) |> hd()

      assert title |> LazyHTML.query("tspan.q-legend-paused[aria-hidden=true]") |> LazyHTML.text() ==
               "■"

      assert title |> LazyHTML.query("tspan.q-legend[aria-hidden=true]") |> LazyHTML.text() ==
               "paused"
    end

    test "at the narrowest width the title and its legend end well before the day's maximum" do
      # The width the overview draws at least (`chart_size`), with a five-digit maximum.
      doc = chart(days([{12_345, 1}]), 280)

      [title, _denied] = doc |> LazyHTML.query("text.q-ttl") |> Enum.map(&LazyHTML.text/1)
      assert title == "Runs per day■paused"
      [max | _] = doc |> LazyHTML.query("text.q-max") |> Enum.map(&LazyHTML.text/1)
      assert String.trim(max) == "max 12,345"

      # At most 7 px a character, measured generously, and the legend's 8 and 4 px gaps.
      line_end = 7 * String.length(title) + 8 + 4
      max_start = 280 - 7 * String.length(String.trim(max))
      assert line_end < max_start
    end
  end
end
