defmodule Apiary.Days do
  @moduledoc """
  Calendar days in a time zone: which day a moment falls on, and the moments a day spans.

  Times are stored in UTC. A day a person reads, today, yesterday or a column of a chart,
  is a day in that person's zone (`Apiary.Accounts.Scope.time_zone/1`), which this module
  takes as an argument and never reads from the process. A day starts at midnight in the
  zone; on a day the clocks change, a midnight that does not exist starts the day at the
  first moment after the gap, and a midnight that happens twice starts it at the first.

  `sql_day/2` is the same day, read by the database: a column of `timestamp without time
  zone` holding UTC, taken to the zone and cut to its date.
  """

  @utc "Etc/UTC"

  @typedoc "A moment: a `DateTime`, or a `NaiveDateTime` taken as UTC."
  @type moment :: DateTime.t() | NaiveDateTime.t()

  @typedoc "A span of moments in UTC: from `from`, included, to `to`, excluded."
  @type range :: {DateTime.t(), DateTime.t()}

  @doc """
  The day it is in `zone` at `now`.

      iex> Apiary.Days.today("Pacific/Auckland", ~U[2026-10-16 12:30:00Z])
      ~D[2026-10-17]
  """
  @spec today(String.t(), DateTime.t()) :: Date.t()
  def today(zone, now \\ DateTime.utc_now()), do: day_of(now, zone)

  @doc """
  The day `at` falls on in `zone`.

      iex> Apiary.Days.day_of(~U[2026-10-17 05:00:00Z], "America/Los_Angeles")
      ~D[2026-10-16]
  """
  @spec day_of(moment(), String.t()) :: Date.t()
  def day_of(%DateTime{} = at, zone), do: at |> DateTime.shift_zone!(zone) |> DateTime.to_date()
  def day_of(%NaiveDateTime{} = at, zone), do: at |> DateTime.from_naive!(@utc) |> day_of(zone)

  @doc """
  The moment `day` starts in `zone`, in UTC.

      iex> Apiary.Days.start_of(~D[2026-10-16], "America/Los_Angeles")
      ~U[2026-10-16 07:00:00.000000Z]
  """
  @spec start_of(Date.t(), String.t()) :: DateTime.t()
  def start_of(%Date{} = day, zone) do
    local =
      case DateTime.new(day, ~T[00:00:00.000000], zone) do
        {:ok, at} -> at
        {:gap, _before, after_gap} -> after_gap
        {:ambiguous, first, _second} -> first
      end

    # The moment after a gap comes from the zone database with no fraction of a second.
    %{DateTime.shift_zone!(local, @utc) | microsecond: {0, 6}}
  end

  @doc """
  The moments `day` spans in `zone`, in UTC: from its start, included, to the next day's,
  excluded. A day the clocks change is 23 or 25 hours long.
  """
  @spec range(Date.t(), String.t()) :: range()
  def range(%Date{} = day, zone), do: {start_of(day, zone), start_of(Date.add(day, 1), zone)}

  @doc """
  The last `count` days in `zone` up to the day of `now`, oldest first and today last, and
  the moments they span in UTC.

      iex> {days, {from, to}} = Apiary.Days.window(2, "Etc/UTC", ~U[2026-10-17 09:00:00Z])
      iex> {days, from, to}
      {[~D[2026-10-16], ~D[2026-10-17]], ~U[2026-10-16 00:00:00.000000Z],
       ~U[2026-10-18 00:00:00.000000Z]}
  """
  @spec window(pos_integer(), String.t(), DateTime.t()) :: {[Date.t()], range()}
  def window(count, zone, now \\ DateTime.utc_now()) when is_integer(count) and count > 0 do
    last = today(zone, now)
    first = Date.add(last, 1 - count)
    days = Enum.to_list(Date.range(first, last))
    {days, {start_of(first, zone), start_of(Date.add(last, 1), zone)}}
  end

  @doc """
  A count for each of `days`, in their order: `counts` maps a day to its count, and a day
  it does not hold counts 0.
  """
  @spec buckets([Date.t()], %{optional(Date.t()) => number()}) :: [number()]
  def buckets(days, counts) when is_list(days) and is_map(counts),
    do: for(day <- days, do: Map.get(counts, day, 0))

  @doc """
  The day a stored UTC moment falls on in a zone, as an Ecto query expression: `at` is a
  `timestamp without time zone` holding UTC, `zone` an IANA name, pinned (`^zone`).

      from r in Run, group_by: sql_day(r.started_at, ^zone)
  """
  defmacro sql_day(at, zone) do
    quote do
      fragment("((? AT TIME ZONE 'UTC') AT TIME ZONE ?)::date", unquote(at), unquote(zone))
    end
  end
end
