defmodule ApiaryWeb.Format do
  @moduledoc """
  Every date, time and number a person reads, formatted as the reader's language writes it
  and in the reader's time zone. Nothing else in the console formats one for display
  (`docs/lingo.md`, Dates and numbers).

  The formats are CLDR's (`ApiaryWeb.Cldr`): a page asks for a kind of value, a date, a
  time, a count, and never writes a pattern. The reader is taken from the process, the way
  Gettext takes its locale, so a page passes only the value:

    * **The locale** is the language of the current Gettext locale: `en@software` is
      English. English is `en-GB`, because the product writes British English. A language
      the CLDR backend was not built with reads English.
    * **The time zone** is the one `put_time_zone/1` set for the process, `Etc/UTC` until
      then. Times are stored in UTC and shifted into it here, at the last step, and
      nowhere else. Where a time names its zone, it shows the zone's abbreviation (`UTC`,
      `CEST`), or CLDR's `GMT-05:00` for a zone that has none.

  Machine-readable output is not formatted here: a `datetime` attribute, a hook's data
  attribute, the contract and the API keep ISO 8601 in UTC.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  alias ApiaryWeb.Cldr, as: Backend

  @time_zone_key {__MODULE__, :time_zone}
  @default_time_zone "Etc/UTC"

  # The CLDR locale of a language, where it is not the language itself.
  @locales %{"en" => "en-GB"}
  @default_locale "en-GB"
  @known Enum.map(Backend.known_locale_names(), &Atom.to_string/1)

  @typedoc "A moment: stored in UTC, a naive one taken as UTC."
  @type moment :: DateTime.t() | NaiveDateTime.t()

  ## The reader

  @doc """
  The CLDR locale the calling process formats in, from its Gettext locale.

      iex> Gettext.with_locale(ApiaryWeb.Gettext, "en", &ApiaryWeb.Format.locale/0)
      "en-GB"
  """
  @spec locale() :: String.t()
  def locale, do: ApiaryWeb.Gettext |> Gettext.get_locale() |> locale_for()

  @doc """
  The CLDR locale for a Gettext locale: the domain is dropped, a language's territory is
  kept when CLDR has it (`de_AT@software` is `de-AT`), and a language the backend was not
  built with reads English.

      iex> ApiaryWeb.Format.locale_for("en@software")
      "en-GB"
      iex> ApiaryWeb.Format.locale_for("xx")
      "en-GB"
  """
  @spec locale_for(String.t()) :: String.t()
  def locale_for(gettext_locale) when is_binary(gettext_locale) do
    tag = gettext_locale |> String.split("@", parts: 2) |> hd() |> String.replace("_", "-")
    language = tag |> String.split("-", parts: 2) |> hd()
    Enum.find([tag, language], @default_locale, &(&1 in @known)) |> cldr_locale()
  end

  defp cldr_locale(name), do: Map.get(@locales, name, name)

  @doc """
  Sets the time zone the calling process shows times in, an IANA name such as
  `Europe/Berlin`; `nil` resets it to UTC. An unknown zone leaves the zone as it was.
  """
  @spec put_time_zone(String.t() | nil) :: :ok | {:error, :unknown_time_zone}
  def put_time_zone(nil) do
    Process.delete(@time_zone_key)
    :ok
  end

  def put_time_zone(zone) when is_binary(zone) do
    if known_time_zone?(zone) do
      Process.put(@time_zone_key, zone)
      :ok
    else
      {:error, :unknown_time_zone}
    end
  end

  @doc "The time zone the calling process shows times in; `Etc/UTC` until one is set."
  @spec time_zone() :: String.t()
  def time_zone, do: Process.get(@time_zone_key, @default_time_zone)

  @doc """
  Runs `fun` with `zone` as the time zone and restores the previous one: for a render
  outside a request or a LiveView, such as a mail to one reader. An unknown zone, or
  `nil`, renders in UTC.
  """
  @spec with_time_zone(String.t() | nil, (-> result)) :: result when result: var
  def with_time_zone(zone, fun) when is_function(fun, 0) do
    previous = Process.get(@time_zone_key)

    with {:error, :unknown_time_zone} <- put_time_zone(zone),
         do: Process.delete(@time_zone_key)

    try do
      fun.()
    after
      if previous, do: Process.put(@time_zone_key, previous), else: Process.delete(@time_zone_key)
    end
  end

  @doc "Whether `zone` is a time zone the time zone database knows."
  @spec known_time_zone?(String.t()) :: boolean()
  def known_time_zone?(zone) when is_binary(zone),
    do: match?({:ok, _}, DateTime.shift_zone(~U[2000-01-01 00:00:00Z], zone))

  @doc "A moment in the reader's time zone."
  @spec local(moment()) :: DateTime.t()
  def local(%DateTime{} = at), do: DateTime.shift_zone!(at, time_zone())
  def local(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> local()

  ## Numbers

  @doc """
  A number with the language's grouping and decimal marks: 1240 as "1,240". With
  `digits: n`, a fraction is shown with exactly `n` decimals, a half rounded up: "3.4",
  and 1.25 as "1.3".
  """
  @spec number(number() | Decimal.t() | nil, keyword()) :: String.t() | nil
  def number(n, opts \\ [])
  def number(nil, _opts), do: nil

  def number(n, opts) do
    options = [backend: Backend, locale: locale(), rounding_mode: :half_up]

    options =
      case Keyword.get(opts, :digits) do
        nil -> options
        digits -> Keyword.put(options, :fractional_digits, digits)
      end

    Cldr.Number.to_string!(n, options)
  end

  @doc """
  A size in decimal units, 1 kB being 1,000 bytes: "812 B", "48.2 kB", "1.4 MB", "2.0 GB".
  A size that rounds up to a thousand of its unit is shown in the next one: 999,950 bytes
  is "1.0 MB".
  """
  @spec bytes(non_neg_integer() | nil) :: String.t() | nil
  def bytes(nil), do: nil
  def bytes(n) when is_integer(n) and n < 1000, do: gettext("%{number} B", number: number(n))

  def bytes(n) when is_integer(n),
    do: bytes(n, [{1000, :kb}, {1_000_000, :mb}, {1_000_000_000, :gb}])

  defp bytes(n, [{size, unit} | larger]) do
    # Tenths of the unit, a half rounded up.
    tenths = div(n * 10 + div(size, 2), size)

    if tenths >= 10_000 and larger != [] do
      bytes(n, larger)
    else
      value = number(tenths / 10, digits: 1)

      case unit do
        :kb -> gettext("%{number} kB", number: value)
        :mb -> gettext("%{number} MB", number: value)
        :gb -> gettext("%{number} GB", number: value)
      end
    end
  end

  ## Dates and times

  @doc """
  A date with its year: "26 Sept 2026". A moment is shown on the reader's day; a `Date`
  is a calendar day and is not shifted.
  """
  @spec date(Date.t() | moment() | nil) :: String.t() | nil
  def date(nil), do: nil
  def date(%Date{} = day), do: format_date(day, :medium)
  def date(at), do: at |> local() |> format_date(:medium)

  @doc "A date without its year, for a date in the current year: \"26 Sept\"."
  @spec short_date(Date.t() | moment() | nil) :: String.t() | nil
  def short_date(nil), do: nil
  def short_date(%Date{} = day), do: format_date(day, :MMMd)
  def short_date(at), do: at |> local() |> format_date(:MMMd)

  @doc """
  A date that leaves out the year when it is the current one: "16 Sept", and
  "16 Sept 2025" a year earlier.
  """
  @spec day(moment() | nil, moment()) :: String.t() | nil
  def day(at, now \\ DateTime.utc_now())
  def day(nil, _now), do: nil

  def day(at, now) do
    if this_year?(at, now), do: short_date(at), else: date(at)
  end

  @doc "A time of day: \"14:03\", or \"14:03:11\" with `seconds: true`."
  @spec time(moment() | nil, keyword()) :: String.t() | nil
  def time(at, opts \\ [])
  def time(nil, _opts), do: nil

  def time(at, opts) do
    style = if opts[:seconds], do: :medium, else: :short
    Cldr.Time.to_string!(local(at), backend: Backend, locale: locale(), format: style)
  end

  @doc """
  A date and a time: "26 Sept 2026, 14:03".

  Options:

    * `year: false` leaves the year out: "26 Sept, 14:03";
    * `seconds: true` adds the seconds, `milliseconds: true` their fraction too:
      "26 Sept 2026, 14:03:11.123";
    * `zone: true` names the time zone: "26 Sept 2026, 14:03 UTC".
  """
  @spec datetime(moment() | nil, keyword()) :: String.t() | nil
  def datetime(at, opts \\ [])
  def datetime(nil, _opts), do: nil

  def datetime(at, opts) do
    # A whole second has no fraction to show and CLDR's formatter would fail on it: every
    # moment is given microsecond precision.
    %DateTime{microsecond: {us, _precision}} = local = local(at)
    local = %{local | microsecond: {us, 6}}
    locale = locale()
    date_format = if Keyword.get(opts, :year, true), do: :medium, else: :MMMd

    time_format =
      cond do
        opts[:milliseconds] -> milliseconds_pattern(locale)
        opts[:seconds] -> :medium
        true -> :short
      end

    text =
      Cldr.DateTime.to_string!(local,
        backend: Backend,
        locale: locale,
        date_format: date_format,
        time_format: time_format
      )

    if opts[:zone], do: with_zone(text, local), else: text
  end

  @doc """
  The reader's time zone as a time names it, at the moment `at`: "UTC", "CEST", or
  "GMT-05:00" for a zone without an abbreviation.
  """
  @spec zone(moment()) :: String.t()
  def zone(at), do: at |> local() |> zone_mark()

  ## Relative times

  @doc """
  A count of units back from now, in CLDR's words: `ago(3, :minute)` is "3 minutes ago".
  `unit` is `:second`, `:minute`, `:hour` or `:day`.
  """
  @spec ago(non_neg_integer(), :second | :minute | :hour | :day) :: String.t()
  def ago(count, unit) when is_integer(count) and unit in [:second, :minute, :hour, :day],
    do: Cldr.DateTime.Relative.to_string!(-count, backend: Backend, locale: locale(), unit: unit)

  @doc """
  A timestamp as people say it, up to seven days back ("2 minutes ago", "Yesterday,
  17:20", "3 days ago"), then its date.
  """
  @spec time_ago(moment(), DateTime.t()) :: String.t()
  def time_ago(at, now \\ DateTime.utc_now()) do
    seconds = max(DateTime.diff(now, utc(at), :second), 0)
    days = days_back(at, now)

    cond do
      seconds < 60 -> gettext("Just now")
      seconds < 3600 -> ago(div(seconds, 60), :minute)
      days <= 0 -> ago(div(seconds, 3600), :hour)
      days == 1 -> gettext("Yesterday, %{time}", time: time(at))
      days <= 7 -> ago(days, :day)
      true -> date(at)
    end
  end

  @doc """
  A time across runs, as the browser's clocks tick it (`assets/js/hooks/ticker.js`):
  relative up to yesterday ("40 seconds ago", "Yesterday, 16:40"), then "17 Sept, 09:30",
  with the year when it is not the current one.
  """
  @spec relative(moment(), DateTime.t()) :: String.t()
  def relative(at, now \\ DateTime.utc_now()) do
    seconds = max(DateTime.diff(now, utc(at), :second), 0)
    days = days_back(at, now)

    cond do
      seconds < 5 -> gettext("Just now")
      seconds < 60 -> ago(seconds, :second)
      seconds < 3600 -> ago(div(seconds, 60), :minute)
      days <= 0 -> ago(div(seconds, 3600), :hour)
      days == 1 -> gettext("Yesterday, %{time}", time: time(at))
      true -> datetime(at, year: not this_year?(at, now))
    end
  end

  @doc """
  A clock to the second, with the day in words when it is today or yesterday:
  "Today, 14:02:11", "Yesterday, 14:02:11", "18 Sept 2026, 14:02:11".
  """
  @spec clock(moment(), DateTime.t()) :: String.t()
  def clock(at, now \\ DateTime.utc_now()) do
    case days_back(at, now) do
      0 -> gettext("Today, %{time}", time: time(at, seconds: true))
      1 -> gettext("Yesterday, %{time}", time: time(at, seconds: true))
      _ -> datetime(at, seconds: true)
    end
  end

  @doc """
  Today or yesterday in words, else the date: a day's heading in a list of days.
  """
  @spec day_heading(moment(), DateTime.t()) :: String.t()
  def day_heading(at, now \\ DateTime.utc_now()) do
    case days_back(at, now) do
      0 -> gettext("Today")
      1 -> gettext("Yesterday")
      _ -> date(at)
    end
  end

  @doc """
  How many of the reader's days `at` lies before `now`: 0 today, 1 yesterday. Days turn at
  midnight in the reader's time zone.
  """
  @spec days_back(moment(), moment()) :: integer()
  def days_back(at, now),
    do: Date.diff(DateTime.to_date(local(now)), DateTime.to_date(local(at)))

  ## Helpers

  defp format_date(value, format),
    do: Cldr.Date.to_string!(value, backend: Backend, locale: locale(), format: format)

  defp this_year?(at, now), do: local(at).year == local(now).year

  defp utc(%DateTime{} = at), do: at
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  # CLDR has no skeleton for fractions of a second; TR35 appends them to the seconds
  # field with the language's decimal mark, so the medium time's pattern is extended.
  defp milliseconds_pattern(locale) do
    {:ok, %{medium: id}} = Cldr.DateTime.Format.time_formats(locale, :gregorian, Backend)
    {:ok, formats} = Cldr.DateTime.Format.date_time_available_formats(locale, :gregorian, Backend)
    {:ok, %{latn: symbols}} = Cldr.Number.Symbol.number_symbols_for(locale, Backend)

    case Map.fetch(formats, id) do
      {:ok, %{unicode: pattern}} -> with_fraction(pattern, symbols)
      {:ok, pattern} when is_binary(pattern) -> with_fraction(pattern, symbols)
      _other -> :medium
    end
  end

  defp with_fraction(pattern, symbols) do
    String.replace(pattern, "ss", "ss" <> symbols.decimal.standard <> "SSS", global: false)
  end

  defp with_zone(text, local) do
    gettext_comment("A time and the abbreviation of its time zone: 14:03 UTC.")
    gettext("%{time} %{zone}", time: text, zone: zone_mark(local))
  end

  # The zone's abbreviation where it has one; CLDR's localised GMT offset for a zone the
  # database knows only by its offset ("-05").
  defp zone_mark(%DateTime{zone_abbr: abbr} = local) do
    if abbr =~ ~r/^[A-Z]{2,6}$/,
      do: abbr,
      else: Cldr.DateTime.Formatter.zone_gmt(local, 1, locale(), Backend, %{})
  end
end
