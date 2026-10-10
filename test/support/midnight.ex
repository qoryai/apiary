defmodule Apiary.Midnight do
  @moduledoc """
  Helpers for the tests that read a day from the clock: "today", "yesterday", today's
  date or today's column. A page reads its day from the clock when it renders, and what
  a test wrote before it was dated by the clock, or by the database's time (the time
  the test's transaction began, under the SQL sandbox), when it was written: a test that
  writes before midnight and reads after it reads yesterday. Each helper keeps the write
  and the read on one day.

    * `reader_at_noon/1` and `noon_zone/0`, where the day is the reader's, turning at
      midnight in their time zone: the reader's clock reads between 12:00 and 13:00, so
      the write and the read lie in one of the reader's days for any test shorter than
      eleven hours, whatever the hour in UTC. Nothing waits.
    * `clear_of_midnight/1`, where the day is UTC's, as the overview's chart is: within
      `seconds` of midnight UTC it waits until the day has turned.

  Where the test controls the time it writes, it pins it instead.
  """

  alias Apiary.Accounts
  alias Apiary.Accounts.User

  @doc """
  A time zone whose clock reads between 12:00 and 13:00 now: an `Etc/GMT` zone, whose
  names count the other way (`Etc/GMT-12` is twelve hours ahead of UTC).
  """
  @spec noon_zone() :: String.t()
  def noon_zone do
    hours = 12 - DateTime.utc_now().hour
    if hours > 0, do: "Etc/GMT-#{hours}", else: "Etc/GMT+#{-hours}"
  end

  @doc """
  Gives `user` the time zone of `noon_zone/0`, which the pages they open read their days
  in; returns the zone, for a test that formats its own expectation in it.
  """
  @spec reader_at_noon(User.t()) :: String.t()
  def reader_at_noon(%User{} = user) do
    zone = noon_zone()
    {:ok, _} = Accounts.update_user_preferences(user, %{time_zone: zone})
    zone
  end

  @doc """
  Waits until midnight UTC has passed when it is less than `seconds` away, and returns
  the UTC day: a test that starts its runs after it, and reads them on a page that dates
  by UTC days, has `seconds` before the day turns.
  """
  @spec clear_of_midnight(pos_integer) :: Date.t()
  def clear_of_midnight(seconds \\ 20) do
    now = DateTime.utc_now()
    midnight = DateTime.new!(Date.add(DateTime.to_date(now), 1), ~T[00:00:00], "Etc/UTC")
    left = DateTime.diff(midnight, now, :millisecond)
    if left < seconds * 1000, do: Process.sleep(left + 1)
    Date.utc_today()
  end
end
