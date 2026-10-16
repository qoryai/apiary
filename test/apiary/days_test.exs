defmodule Apiary.DaysTest do
  use Apiary.DataCase, async: true

  import Apiary.Days, only: [sql_day: 2]

  alias Apiary.Accounts.Preferences
  alias Apiary.Days

  doctest Apiary.Days

  describe "a day in a zone" do
    test "today turns at the zone's midnight, not at UTC's" do
      # 07:00 UTC is midnight in Los Angeles (PDT, UTC-7) on 17 October 2026.
      assert Days.today("America/Los_Angeles", ~U[2026-10-17 06:59:59Z]) == ~D[2026-10-16]
      assert Days.today("America/Los_Angeles", ~U[2026-10-17 07:00:00Z]) == ~D[2026-10-17]

      # 11:00 UTC is midnight in Auckland (NZDT, UTC+13): a day ahead of UTC.
      assert Days.today("Pacific/Auckland", ~U[2026-10-16 10:59:59Z]) == ~D[2026-10-16]
      assert Days.today("Pacific/Auckland", ~U[2026-10-16 11:00:00Z]) == ~D[2026-10-17]

      assert Days.today("Etc/UTC", ~U[2026-10-16 23:59:59Z]) == ~D[2026-10-16]
      assert Days.day_of(~N[2026-10-17 06:59:59], "America/Los_Angeles") == ~D[2026-10-16]
    end

    test "a day spans from its midnight to the next, in UTC" do
      assert Days.range(~D[2026-10-16], "America/Los_Angeles") ==
               {~U[2026-10-16 07:00:00.000000Z], ~U[2026-10-17 07:00:00.000000Z]}

      assert Days.range(~D[2026-10-17], "Pacific/Auckland") ==
               {~U[2026-10-16 11:00:00.000000Z], ~U[2026-10-17 11:00:00.000000Z]}
    end

    test "a day the clocks go forward at midnight starts after the gap, and is 23 hours long" do
      # Chile's summer time starts at midnight on 6 September 2026: 00:00 to 01:00 is skipped.
      assert {from, to} = Days.range(~D[2026-09-06], "America/Santiago")
      assert from == ~U[2026-09-06 04:00:00.000000Z]
      assert DateTime.shift_zone!(from, "America/Santiago").hour == 1
      assert DateTime.diff(to, from, :hour) == 23

      # The day before ends where this one starts.
      assert {_from, ^from} = Days.range(~D[2026-09-05], "America/Santiago")
    end

    test "a day whose midnight comes twice starts at the first, and is 25 hours long" do
      # Cuba's summer time ends at 01:00 on 1 November 2026, back to 00:00.
      assert {from, to} = Days.range(~D[2026-11-01], "America/Havana")
      assert from == ~U[2026-11-01 04:00:00.000000Z]
      assert DateTime.diff(to, from, :hour) == 25
      assert {_from, ^from} = Days.range(~D[2026-10-31], "America/Havana")
    end

    test "a window is the last days up to today, and the moments they span" do
      now = ~U[2026-10-17 03:00:00Z]

      assert {days, {from, to}} = Days.window(3, "America/Los_Angeles", now)
      assert days == [~D[2026-10-14], ~D[2026-10-15], ~D[2026-10-16]]
      assert from == ~U[2026-10-14 07:00:00.000000Z]
      assert to == ~U[2026-10-17 07:00:00.000000Z]
    end

    test "buckets count each day of a list, 0 for a day without a count" do
      days = [~D[2026-10-15], ~D[2026-10-16], ~D[2026-10-17]]
      assert Days.buckets(days, %{~D[2026-10-16] => 4}) == [0, 4, 0]
    end
  end

  describe "the database's day" do
    test "every zone a person chooses from is one the database knows, and cuts the same day" do
      zones = Preferences.time_zones()

      for at <- [~U[2026-10-17 11:30:00.000000Z], ~U[2026-03-29 00:30:00.000000Z]] do
        stored = DateTime.to_naive(at)

        days =
          Repo.all(
            from z in fragment("SELECT unnest(?::text[]) AS name", ^zones),
              select: {z.name, sql_day(type(^stored, :naive_datetime_usec), z.name)}
          )

        assert length(days) == length(zones)

        for {zone, day} <- days do
          assert day == Days.day_of(at, zone), "#{zone} at #{at}"
        end
      end
    end
  end
end
