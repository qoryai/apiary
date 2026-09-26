defmodule ApiaryWeb.Cldr do
  @moduledoc """
  The CLDR backend: how each language the console speaks writes dates, times and numbers,
  from the Unicode Common Locale Data Repository, compiled into the release.

  Pages never call it; they call `ApiaryWeb.Format`, which picks the locale and the time
  zone for them. English is `en-GB`, because the product writes British English: the day
  before the month and a 24-hour clock ("26 Sept 2026, 14:03").

  **Offline.** A locale's data is read at compile time and never at runtime. `ex_cldr`
  ships `en` and `und` itself; every other locale in `:locales` is a JSON file committed
  under `priv/cldr/locales`, so a build finds it there and downloads nothing. `ex_cldr`
  downloads a missing or stale file at compile time, and a test fails when a configured
  locale's file is not in the repository at the library's CLDR version
  (`docs/lingo.md`, Dates and numbers).
  """

  use Cldr,
    otp_app: :apiary,
    data_dir: "./priv/cldr",
    locales: ["en", "en-GB"],
    default_locale: "en-GB",
    providers: [Cldr.Number, Cldr.Calendar, Cldr.DateTime]
end
