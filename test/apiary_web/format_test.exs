defmodule ApiaryWeb.FormatTest do
  use ExUnit.Case, async: true

  alias ApiaryWeb.Format

  doctest ApiaryWeb.Format

  @at ~U[2026-09-26 14:03:11.123456Z]

  describe "the reader's locale" do
    test "is the language of the Gettext locale, the domain dropped" do
      assert Format.locale_for("en@software") == "en-GB"
      assert Format.locale_for("en") == "en-GB"
      assert Format.locale_for("en_GB@software") == "en-GB"
    end

    test "is English for a language the backend was not built with" do
      assert Format.locale_for("xx@software") == "en-GB"
      assert Format.locale_for("tlh") == "en-GB"
    end

    test "follows the process's Gettext locale" do
      assert Gettext.with_locale(ApiaryWeb.Gettext, "en@software", &Format.locale/0) == "en-GB"
    end

    test "every language with a Gettext catalogue has CLDR data" do
      for locale <- Gettext.known_locales(ApiaryWeb.Gettext) do
        language = locale |> String.split(["@", "_"]) |> hd()
        cldr = Format.locale_for(locale)

        assert String.starts_with?(cldr, language),
               "#{locale} is formatted as #{cldr}: add #{language} to ApiaryWeb.Cldr's locales"
      end
    end

    test "every locale the backend is built with is in the repository, at the library's CLDR version" do
      for locale <- ApiaryWeb.Cldr.known_locale_names() do
        file = "#{locale}.json"

        path =
          Enum.find(
            [
              Path.join("priv/cldr/locales", file),
              Path.join([Cldr.Config.cldr_data_dir(), "locales", file])
            ],
            &File.exists?/1
          )

        assert path, "no CLDR data for #{locale}: compile once online and commit priv/cldr"
        version = path |> File.read!() |> Jason.decode!() |> Map.fetch!("version")
        assert version == to_string(Cldr.version()), "#{path} is CLDR #{version}"
      end
    end
  end

  describe "numbers" do
    test "are grouped as the language groups them" do
      assert Format.number(0) == "0"
      assert Format.number(999) == "999"
      assert Format.number(1240) == "1,240"
      assert Format.number(1_234_567) == "1,234,567"
      assert Format.number(-1240) == "-1,240"
      assert Format.number(nil) == nil
    end

    test "show a fraction with the digits asked for" do
      assert Format.number(3.456, digits: 1) == "3.5"
      assert Format.number(12.0, digits: 1) == "12.0"
      assert Format.number(0.0123, digits: 4) == "0.0123"
      assert Format.number(1234.5, digits: 2) == "1,234.50"
    end

    test "round a half up, as people expect" do
      assert Format.number(1.25, digits: 1) == "1.3"
      assert Format.number(0.125, digits: 2) == "0.13"
      assert Format.number(2.5, digits: 0) == "3"
    end

    test "sizes are in decimal units, moving to the next one after rounding" do
      assert Format.bytes(0) == "0 B"
      assert Format.bytes(812) == "812 B"
      assert Format.bytes(1250) == "1.3 kB"
      assert Format.bytes(16_384) == "16.4 kB"
      assert Format.bytes(999_949) == "999.9 kB"
      assert Format.bytes(999_950) == "1.0 MB"
      assert Format.bytes(1_400_000) == "1.4 MB"
      assert Format.bytes(999_950_000) == "1.0 GB"
      assert Format.bytes(2_000_000_000_000) == "2,000.0 GB"
      assert Format.bytes(nil) == nil
    end
  end

  describe "dates and times in UTC" do
    test "each kind of value" do
      assert Format.date(@at) == "26 Sept 2026"
      assert Format.short_date(@at) == "26 Sept"
      assert Format.time(@at) == "14:03"
      assert Format.time(@at, seconds: true) == "14:03:11"
      assert Format.datetime(@at) == "26 Sept 2026, 14:03"
      assert Format.datetime(@at, year: false) == "26 Sept, 14:03"
      assert Format.datetime(@at, zone: true) == "26 Sept 2026, 14:03 UTC"
      assert Format.datetime(@at, seconds: true, zone: true) == "26 Sept 2026, 14:03:11 UTC"

      assert Format.datetime(@at, milliseconds: true, zone: true) ==
               "26 Sept 2026, 14:03:11.123 UTC"

      assert Format.datetime(~U[2026-09-26 14:03:11Z], milliseconds: true) ==
               "26 Sept 2026, 14:03:11.000"
    end

    test "nil stays nil" do
      for fun <- [&Format.date/1, &Format.short_date/1, &Format.time/1, &Format.datetime/1] do
        assert fun.(nil) == nil
      end
    end

    test "a naive time is taken as UTC, and a calendar day is not shifted" do
      assert Format.put_time_zone("America/Lima") == :ok
      assert Format.datetime(~N[2026-09-26 14:03:00]) == "26 Sept 2026, 09:03"
      assert Format.date(~D[2026-09-26]) == "26 Sept 2026"
      assert Format.date(~U[2026-09-26 02:00:00Z]) == "25 Sept 2026"
    end

    test "a date leaves out the year of the current one" do
      now = ~U[2026-12-01 12:00:00Z]
      assert Format.day(~U[2026-09-16 10:00:00Z], now) == "16 Sept"
      assert Format.day(~U[2025-09-16 10:00:00Z], now) == "16 Sept 2025"
    end
  end

  describe "the reader's time zone" do
    test "is UTC until one is set" do
      assert Format.time_zone() == "Etc/UTC"
      assert Format.put_time_zone("Europe/Berlin") == :ok
      assert Format.time_zone() == "Europe/Berlin"
      assert Format.put_time_zone(nil) == :ok
      assert Format.time_zone() == "Etc/UTC"
    end

    test "an unknown zone is refused and the zone stays" do
      Format.put_time_zone("Europe/Berlin")
      assert Format.put_time_zone("Nowhere/Else") == {:error, :unknown_time_zone}
      assert Format.time_zone() == "Europe/Berlin"
    end

    test "is shifted into at the last step, across a change of summer time" do
      Format.put_time_zone("Europe/Berlin")

      # Summer time ends at 01:00 UTC on 25 October 2026: 02:30 comes twice.
      assert Format.datetime(~U[2026-10-25 00:30:00Z], zone: true) == "25 Oct 2026, 02:30 CEST"
      assert Format.datetime(~U[2026-10-25 01:30:00Z], zone: true) == "25 Oct 2026, 02:30 CET"
      assert Format.zone(~U[2026-07-01 00:00:00Z]) == "CEST"
      assert Format.zone(~U[2026-12-01 00:00:00Z]) == "CET"
    end

    test "a zone without an abbreviation is named by its offset" do
      Format.put_time_zone("America/Lima")
      assert Format.datetime(@at, zone: true) == "26 Sept 2026, 09:03 GMT-05:00"
    end

    test "with_time_zone/2 restores the zone before it" do
      Format.put_time_zone("Europe/Berlin")

      assert Format.with_time_zone("Asia/Kolkata", fn -> Format.time(@at) end) == "19:33"
      assert Format.time_zone() == "Europe/Berlin"

      assert_raise RuntimeError, fn ->
        Format.with_time_zone("Asia/Kolkata", fn -> raise "boom" end)
      end

      assert Format.time_zone() == "Europe/Berlin"
    end

    test "with_time_zone/2 renders an unknown zone in UTC, not in the caller's" do
      Format.put_time_zone("Europe/Berlin")

      assert Format.with_time_zone("Nowhere/Else", fn -> Format.time_zone() end) == "Etc/UTC"
      assert Format.with_time_zone(nil, fn -> Format.time(@at) end) == "14:03"
      assert Format.time_zone() == "Europe/Berlin"

      Format.put_time_zone(nil)
      assert Format.with_time_zone("Europe/Berlin", &Format.time_zone/0) == "Europe/Berlin"
      assert Format.time_zone() == "Etc/UTC"
    end
  end

  describe "relative times" do
    @now ~U[2026-09-20 14:04:00Z]

    test "count back in CLDR's words" do
      assert Format.ago(1, :second) == "1 second ago"
      assert Format.ago(3, :minute) == "3 minutes ago"
      assert Format.ago(1, :hour) == "1 hour ago"
      assert Format.ago(2, :day) == "2 days ago"
    end

    test "a time across runs" do
      assert Format.relative(~U[2026-09-20 14:03:58Z], @now) == "Just now"
      assert Format.relative(~U[2026-09-20 14:03:20Z], @now) == "40 seconds ago"
      assert Format.relative(~U[2026-09-20 14:02:00Z], @now) == "2 minutes ago"
      assert Format.relative(~U[2026-09-19 16:40:03Z], @now) == "Yesterday, 16:40"
      assert Format.relative(~U[2026-09-17 09:30:00Z], @now) == "17 Sept, 09:30"
      assert Format.relative(~U[2025-09-17 09:30:00Z], @now) == "17 Sept 2025, 09:30"
    end

    test "a clock to the second" do
      assert Format.clock(~U[2026-09-20 14:02:11Z], @now) == "Today, 14:02:11"
      assert Format.clock(~U[2026-09-19 14:02:11Z], @now) == "Yesterday, 14:02:11"
      assert Format.clock(~U[2026-09-18 14:02:11Z], @now) == "18 Sept 2026, 14:02:11"
    end

    test "days turn at the reader's midnight" do
      # 23:30 UTC on the 19th is already the 20th in Berlin, and still the 19th in Lima.
      at = ~U[2026-09-19 23:30:00Z]
      now = ~U[2026-09-20 21:00:00Z]

      Format.put_time_zone("Europe/Berlin")
      assert Format.clock(at, now) == "Today, 01:30:00"
      assert Format.day_heading(at, now) == "Today"

      Format.put_time_zone("America/Lima")
      assert Format.clock(at, now) == "Yesterday, 18:30:00"
      assert Format.day_heading(at, now) == "Yesterday"

      Format.put_time_zone("Asia/Kolkata")
      assert Format.day_heading(at, ~U[2026-09-22 12:00:00Z]) == "20 Sept 2026"
    end
  end
end
