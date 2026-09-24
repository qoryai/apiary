# Words on the page

The engine behind Qory Apiary is generic: a work item enters, a run does it, and the result
is a **change request** that is **applied** to a **target** in a **system**. A **body** names
the engine for one kind of factory. The software body says repository, forge, pull request
and merge. Engine English is never shown. Every page is written in a body's words.

This is done with Gettext, not with a list of word swaps:

- Every visible string goes through Gettext. The source text (the msgid) is written in
  **engine words**: `gettext("Every target follows it.")`.
- A **body is a Gettext locale**, written in GNU's `language@modifier` form:
  `priv/gettext/en@software/` is English in the software body's words. A later
  `de@software` is German for the same body, and `en@marketing` is another body. The
  language and the body stay separate.
- `ApiaryWeb.Lingo` sets the locale from the scope: a plug in the `:browser` pipeline, and
  an `on_mount` hook that every LiveView runs. The default locale is `en@software`, so a
  render outside a request (a mail sent from a job, an error page) never falls back to
  engine English. Every hive is of the software body for now.
- `test/apiary_web/lingo_catalogue_test.exs` fails when a source string contains an engine
  word and a body's catalogue has no translation for it. It also fails when a body shows an
  apiary word.

## The words

| Engine (msgid) | Software body (`en@software`) |
|---|---|
| target, targets | repository, repositories |
| system, systems | forge, forges |
| change request | pull request |
| apply, applied | merge, merged |
| hive, hives | workplace, workplaces |
| organisation | organisation |

Everything else (run, task, work item, gate, evidence, member, access key, policy) is the
same word in the engine and in the software body. Qory Apiary is the product's name and
stays as it is. Without the apiary skin, no page says apiary, hive, bee, flower, nectar,
honey or jar. The skin is a per-user setting that is not built yet. The `<.term>` hover
component is for words that need a standard term on hover. It is not a way to show hive or
apiary.

Contracts, wire bodies, JSON errors for machines, the schema, code and logs use engine words
and do not go through Gettext.

## Writing a string

- **Whole sentences.** One msgid per sentence or label. Never build a sentence out of pieces
  (`"Pruned " <> Enum.join(parts, ", ")`). Write each variant as its own sentence.
- **Interpolate with bindings**, never with `#{}`:
  `gettext("Workplace renamed to %{name}.", name: hive.name)`. Bindings are names, and the
  test ignores the words in them, so `%{target}` is fine.
- **A binding may carry a translated, self-contained phrase**, such as a quantity:
  `gettext("Events are pruned after %{days}.", days: ngettext("%{count} day", "%{count} days", n))`. It
  may never carry a piece of grammar.
- **Counts use `ngettext`**, which chooses the plural form. `%{count}` is the raw number. To
  show a formatted number, pass it as its own binding:
  `ngettext("%{number} event", "%{number} events", n, number: delimited(n))`.
- **`pgettext` contexts** keep apart two meanings of the same English text. Use context
  `"plain"` when an engine word appears in its ordinary English sense, such as
  `pgettext("plain", "Apply filters")` or `pgettext("plain", "Operating system")`. The test
  skips these strings, and no body renames them.

## Sentences with markup

A sentence with a bold count, a host in mono, a link or a clock in it is still one msgid.
`ApiaryWeb.RichText` translates it and keeps the markup out of the catalogue: the marked-up
parts are bindings, and `<.rich>` renders the result.

```heex
<.rich text={rich_gettext("Invitation sent to %{email}.", email: {:b, invitation.email})} />
<.rich text={rich_ngettext("%{number} run", "%{number} runs", n, number: {:b, delimited(n)})} />
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
  process already has the body's locale.
- **Module attributes and other compile-time lists** are evaluated before any request runs.
  Mark the string with `gettext_noop("Overview")` and translate it at render with
  `Gettext.gettext(ApiaryWeb.Gettext, msgid)`. `ApiaryWeb.Layouts` does this for the
  navigation.
- **Scripts** under `assets/js` hold no words. The server hands them their words in the
  body's language, as a data attribute of the hook's element or of the body:
  `RunComponents.clock_words/0` for the ticking clocks, `RunPageComponents.terminal_words/0`
  for the log, and `data-copied-words` for the copy button. A template with bindings is
  made with the bindings standing for themselves, `gettext("Today, %{time}", time: "%{time}")`,
  and the script fills it in. A count that the script cannot know ahead of time is passed as
  `[one, other]`, and the script takes `one` for 1. That is the plural rule of English. A
  bounded count, such as the seconds of "N seconds ago", is passed with one string for every
  value, so the language's own rule chooses the form.
- **Changeset errors** are in the `errors` domain. `translate_error/1` translates them at
  render. A custom message is marked where it is written:
  `message: dgettext_noop("errors", "is already the name of a hive in this organisation")`
  (`use Gettext, backend: ApiaryWeb.Gettext` in the schema). Messages that interpolate at
  compile time (`"must be between #{first} and #{last} days"`) cannot be extracted. Use
  `%{...}` keys that Ecto puts in the error's options instead.
- **Mail** is rendered in the process that sends it: a LiveView or a request already has
  the locale. A mail sent from a job about a hive wraps its rendering in
  `ApiaryWeb.Lingo.with_locale(scope, fn -> ... end)`.

## Updating the catalogues

```sh
mix gettext.extract --merge         # new strings into priv/gettext/*.pot and every body's .po
```

Then open `priv/gettext/en@software/LC_MESSAGES/*.po`. Fill in `msgstr` for every new
message that has an engine word, in the software body's words. A message without an engine
word may keep an empty `msgstr`, because the source text is already the software body's
English. Clear any `fuzzy` flag that a merge sets after you check the translation. A fuzzy
translation does not count.

The catalogues have no line numbers and are sorted by msgid, so moving code does not change
them. CI runs `mix gettext.extract --check-up-to-date`, and so does `mix precommit`. A string
that was not extracted fails there. A string with an engine word that was not translated
fails the test.

A new body is a new locale: `mix gettext.merge priv/gettext --locale en@marketing`.
`ApiaryWeb.Gettext.Plural` takes the plural rules from the language part of the locale.
