# Words on the page

The engine behind Qory Apiary is generic: a work item enters, a run does it, and the result
is a **change request** that is **applied** to a **target** in a **system**, in a
**workspace** of an **organisation**. A **domain** (`Apiary.Lingo.Domain`) names the
engine for one kind of work. The software domain says repository, forge, pull request and
merge. Engine English is never shown. Every page is written in a domain's words.

This is done with Gettext, not with a list of word swaps:

- Every visible string goes through Gettext. The source text (the msgid) is written in
  **engine words**: `gettext("Every target follows it.")`.
- A **domain is a Gettext locale**, written in GNU's `language@modifier` form:
  `priv/gettext/en@software/` is English in the software domain's words. A later
  `de@software` is German for the same domain, and `en@marketing` is another domain. The
  language and the domain stay separate. (A Gettext domain, such as `errors`, is another
  thing: one catalogue file of a locale.)
- **A domain's catalogue holds only its own sentences.** A message the locale's catalogue
  lacks is looked up in the next locale of the chain (`ApiaryWeb.Gettext.Fallback`):
  `de@software`, then `de_AT` for `de_AT@software`, then `de`, and at the end the source
  text. So German is one full catalogue, `priv/gettext/de/`, shared by every domain, and
  `de@software` and `de@marketing` hold only the sentences that name a target, a system, a
  change request or applying one. English has no catalogue of its own: the source text is
  English, and `en@software` translates every sentence with an engine word.
- **The locale is built from the person and the workspace**, `language@domain`
  (`ApiaryWeb.Lingo.locale_for/1`). The language is the person's preference
  (`users.language`, one of `Apiary.Accounts.Preferences.languages/0`: English, and the
  language of every catalogue under `priv/gettext`). The domain is the workspace's
  (`workspaces.domain`, chosen when the workspace is created), read through the registry
  of domains (`Apiary.Lingo.Domain.domains/0`, `for_workspace/1`); software is the only
  one and the default. Every page of a signed-in member has a workspace in its scope, the
  person's own settings included, and reads that workspace's domain. A scope without a
  workspace (a person with no membership, on `/users/organisations`) reads the person's
  language in the default domain; a page without a person (log-in, registration) reads
  the default locale, `en@software`. A stored language that has no catalogue any more
  reads English. `de@software` without a catalogue of its own goes down the chain above.
- `ApiaryWeb.Lingo` sets that locale: a plug in the `:browser` pipeline, and an
  `on_mount` hook that every LiveView runs. The default locale of the backend is
  `en@software`, so a render outside a request (an error page) never falls back to engine
  English.
- **A mail is written for its recipient**: `ApiaryWeb.Lingo.with_locale(scope, user, fun)`
  renders in the recipient's language and the domain of the scope's workspace (the default
  domain with no scope). The log-in and email-change mails use it; an invitation goes to
  an address that may have no account, and is written in the inviter's locale.
- The person's **time zone** (`users.time_zone`, an IANA name the compiled `tz` database
  knows) is how times are shown; every time is stored in UTC.
  `Apiary.Accounts.Scope.time_zone/1` reads it, and `ApiaryWeb.Lingo` sets it for
  `ApiaryWeb.Format` beside the locale, from the same scope. The **skin** (`users.skin`) is stored
  too, with one value, `standard`, the domain's own words, until the apiary skin is
  built; its catalogue will go in front of the domain's in the chain.
- `test/apiary_web/lingo_catalogue_test.exs` fails when a source string contains an engine
  word and a domain's catalogue has no translation for it, and, for a language other than
  English, when a sentence has a translation neither in the domain's catalogue nor in the
  language's. It also fails when a catalogue shows a word of the apiary skin.

## The words

| Engine (msgid) | Software domain (`en@software`) |
|---|---|
| target, targets | repository, repositories |
| system, systems | forge, forges |
| change request | pull request |
| apply, applied | merge, merged |
| organisation | organisation |
| workspace, workspaces | workspace, workspaces |

Everything else (run, task, work item, gate, evidence, member, access key, policy) is the
same word in the engine and in the software domain. Qory Apiary is the product's name and
stays as it is. Organisation and workspace are the same word in the software domain, so
their msgids need no translation there. Without the apiary skin, no page says apiary,
hive, bee, flower, nectar, honey or jar: the skin, a per-user setting that is not built
yet, calls an organisation an apiary and a workspace a hive. The `<.term>` hover component
is for words that need a standard term on hover. It is not a way to show hive or apiary.

Contracts, wire bodies, JSON errors for machines, the schema, code and logs use engine words
and do not go through Gettext.

## Writing a string

- **Whole sentences.** One msgid per sentence or label. Never build a sentence out of pieces
  (`"Pruned " <> Enum.join(parts, ", ")`). Write each variant as its own sentence.
- **Interpolate with bindings**, never with `#{}`:
  `gettext("Workspace renamed to %{name}.", name: workspace.name)`. Bindings are names,
  and the test ignores the words in them, so `%{target}` is fine.
- **A binding may carry a translated, self-contained phrase**, such as a quantity,
  `days: ngettext("%{number} day", "%{number} days", n, number: Format.number(n))`, in
  `gettext("Events are pruned after %{days}.", days: days)`. It may never carry a piece
  of grammar.
- **Counts use `ngettext`**, which chooses the plural form by `n`. Its `%{count}` is the
  raw number and never shown: a count on the page is its own binding, formatted,
  `ngettext("%{number} event", "%{number} events", n, number: Format.number(n))`
  (Dates and numbers, below).
- **`pgettext` contexts** keep apart two meanings of the same English text. Use context
  `"plain"` when an engine word appears in its ordinary English sense, such as
  `pgettext("plain", "Apply filters")` or `pgettext("plain", "Operating system")`. The test
  skips these strings, and no domain renames them.

## Sentences with markup

A sentence with a bold count, a host in mono, a link or a clock in it is still one msgid.
`ApiaryWeb.RichText` translates it and keeps the markup out of the catalogue: the marked-up
parts are bindings, and `<.rich>` renders the result.

```heex
<.rich text={rich_gettext("Invitation sent to %{email}.", email: {:b, invitation.email})} />
<.rich text={rich_ngettext("%{number} run", "%{number} runs", n, number: {:b, Format.number(n)})} />
```

- `rich_gettext/2`, `rich_pgettext/3` and `rich_ngettext/4` take the same arguments as
  their Gettext twins. The bindings are a keyword list literal, and each may be a string or
  rich text. They return rich text, a list that `<.rich text={...} />` renders. Every view
  imports them through `use ApiaryWeb`.
- Rich text is a string, a list, or `{:b, rich}`, `{:m, text}`, `{:code, text}`,
  `{:bad, rich}`, `{:link, path, rich}`, `{:href, url, rich}` or `{:term, word, standard}`.
  Add a CSS class as the last element when the page needs its own look, for example
  `{:b, name, "font-medium text-base-content"}`. A rendered component or `{:safe, iodata}`
  is also rich text and goes in as it is.
- When a template writes the markup, bind `{:part, name}` and give the `:part` slot of that
  name: `<.rich text={rich_gettext("%{time} by a member", time: {:part, :time})}>` followed
  by `<:part name={:time}><.clock at={@at} /></:part>`.
- A phrase of its own can be a binding, as with plain Gettext:
  `rich_gettext("%{runs} in %{targets}", runs: rich_ngettext(...), targets: rich_ngettext(...))`.
- Everything is escaped. The bindings never go into the sentence as text, so a host or a
  task that contains `%{...}` stays as it is. Never put markup in a msgid, such as
  backticks, asterisks or HTML, and never use `raw/1` on a translation.

## Where strings live

- **HEEx text:** `{gettext("Settings")}`. **Attributes:** `label={gettext("Name")}`,
  `aria-label={gettext("Switch organisation, current: %{name}", name: @organisation.name)}`.
- **Page titles, flashes, assigns:** call Gettext where the string is made:
  `assign(page_title: gettext("Settings"))`, `put_flash(:info, gettext("..."))`. The
  process already has the domain's locale.
- **Module attributes and other compile-time lists** are evaluated before any request runs.
  Mark the string with `gettext_noop("Overview")` and translate it at render with
  `Gettext.gettext(ApiaryWeb.Gettext, msgid)`. `ApiaryWeb.Layouts` does this for the
  navigation.
- **Scripts** under `assets/js` hold no words. The server hands them their words in the
  domain's language, as a data attribute of the hook's element or of the page's `<body>`:
  `RunComponents.clock_words/0` for the ticking clocks, `RunPageComponents.terminal_words/0`
  for the log, and `data-copied-words` for the copy button. A template with bindings is
  made with the bindings standing for themselves, `gettext("Today, %{time}", time: "%{time}")`,
  and the script fills it in. A count that the script cannot know ahead of time is passed as
  `[one, other]`, and the script takes `one` for 1. That is the plural rule of English. A
  bounded count, such as the seconds of "N seconds ago", is passed with one string for every
  value, so the language's own rule chooses the form. A script formats a date, a time or a
  number with `Intl`, in the locale and the time zone on the `<body>` (`data-locale`,
  `data-time-zone`), never the browser's own (Dates and numbers, below).
- **Changeset errors** are in the `errors` Gettext domain. `translate_error/1` translates
  them at render. A custom message is marked where it is written:
  `message: dgettext_noop("errors", "is already the name of a workspace in this organisation")`
  (`use Gettext, backend: ApiaryWeb.Gettext` in the schema). Messages that interpolate at
  compile time (`"must be between #{first} and #{last} days"`) cannot be extracted. Use
  `%{...}` keys that Ecto puts in the error's options instead.
- **Mail** is rendered for its recipient: `Apiary.Accounts.UserNotifier` wraps a mail to a
  user in `ApiaryWeb.Lingo.with_locale(scope, user, fn -> ... end)`, whichever process
  sends it. A mail about a workspace passes a scope of that workspace, for its domain.

## Dates and numbers

Never format a date, a time or a number by hand: no `Calendar.strftime/2`, no pattern, no
`Integer.to_string/1` or `:erlang.float_to_binary/2` for something a person reads, and no
"UTC" written after a time. `ApiaryWeb.Format` is the one place that does it, from the
Unicode CLDR (`ApiaryWeb.Cldr`), and every view has it as `Format`:

- **A count or a number:** `Format.number(n)` is "1,240"; `Format.number(x, digits: 1)` is
  "3.4", a half rounded up.
- **A size:** `Format.bytes(n)` is "48.2 kB", in decimal units: 1 kB is 1,000 bytes, and a
  size that rounds to a thousand of a unit is shown in the next one.
- **A date:** `Format.date(at)` is "26 Sept 2026"; `Format.short_date(at)` leaves out the
  year, "26 Sept"; `Format.day(at)` leaves it out only in the current year.
- **A time:** `Format.time(at)` is "14:03", with `seconds: true` "14:03:11".
- **A date and a time:** `Format.datetime(at)` is "26 Sept 2026, 14:03", with the options
  `year: false`, `seconds: true` and `milliseconds: true`; `zone: true` names the zone,
  "26 Sept 2026, 14:03 UTC".
- **A time back from now:** `Format.time_ago(at)` ("3 minutes ago"), `Format.relative(at)`
  ("Yesterday, 16:40") and `Format.clock(at)` ("Today, 14:02:11"); `Format.day_heading/2`
  heads a list of days.

- **The reader comes from the process.** The CLDR locale is the language of the Gettext
  locale (`en@software` is English), and the time zone is the one
  `Format.put_time_zone/1` set, UTC until then: `ApiaryWeb.Lingo` sets the person's zone
  with the locale, for a request, a LiveView and `Lingo.with_locale/2,3`, so a mail is
  rendered in its recipient's zone. A page passes the value only.
- **English is `en-GB`**: the product writes British English, so a date is day, month,
  year ("26 Sept 2026") and the clock has 24 hours.
- **Stored in UTC, shown in the reader's zone.** The shift happens in `ApiaryWeb.Format`
  and nowhere else. "Today" and "Yesterday" are the reader's days. A list grouped by day
  groups by the reader's day, `DateTime.to_date(Format.local(at))`.
- **Counted days are still UTC days.** What the database counts per day, the overview's
  chart and its fourteen days, and the From and To dates of the runs and connections
  filters, are UTC days. A page that shows such days says so, as the overview's note does,
  until they move to the reader's zone.
- **A sentence binds a formatted value**, as it binds any phrase:
  `gettext("Revoked %{date}", date: Format.date(key.revoked_at))`,
  `gettext("Yesterday, %{time}", time: Format.time(at))`.
- **What a machine reads is not formatted**: a `datetime` attribute, the data attribute a
  hook reads, the contract, the API and the logs keep ISO 8601 in UTC and plain integers.

**Adding a language** is two steps, the catalogue (above) and its CLDR data: add the
language to `locales` in `ApiaryWeb.Cldr` (and to the map at the top of `ApiaryWeb.Format`
when it is written as a regional variant, as English is `en-GB`), compile once online,
and commit the file `ex_cldr` downloads into `priv/cldr/locales/`. A build reads it from
there and never downloads it again, so a self-hosted instance builds offline. `ex_cldr`
ships `en` itself. When an upgrade of `ex_cldr` moves to a new CLDR version, the next
compile downloads every committed file again: commit them with the upgrade.
`test/apiary_web/format_test.exs` fails when a language with a catalogue has no CLDR data,
or when a file is not at the library's CLDR version.

## Updating the catalogues

```sh
mix gettext.extract --merge         # new strings into priv/gettext/*.pot and every domain's .po
```

Then open `priv/gettext/en@software/LC_MESSAGES/*.po`. Fill in `msgstr` for every new
message that has an engine word, in the software domain's words. A message without an
engine word may keep an empty `msgstr`, because the source text is already the software
domain's English. Clear any `fuzzy` flag that a merge sets after you check the
translation. A fuzzy translation does not count.

The catalogues have no line numbers and are sorted by msgid, so moving code does not change
them. CI runs `mix gettext.extract --check-up-to-date`, and so does `mix precommit`. A string
that was not extracted fails there. A string with an engine word that was not translated
fails the test.

A new domain is a new locale: `mix gettext.merge priv/gettext --locale en@marketing`. A
new language is a language's catalogue with every sentence,
`mix gettext.merge priv/gettext --locale de`, and a catalogue per domain with the domain's
sentences only: `--locale de@software`. A domain's catalogue leaves every other `msgstr`
empty. `ApiaryWeb.Gettext.Plural` takes the plural rules from the language part of the
locale.
