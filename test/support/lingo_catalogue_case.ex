defmodule ApiaryWeb.LingoCatalogueCase do
  @moduledoc """
  The rules of `docs/lingo.md` held to a backend's catalogues. Engine English is never
  shown: source strings are written in the engine's words, and a domain's catalogue says
  them in the domain's words. A source string that uses an engine word and has no
  translation in every domain's catalogue would reach the page as it is, so it fails here.

  A language other than English has a catalogue of its own (`de`), which every domain of
  that language falls back to (`ApiaryWeb.Gettext.Fallback`). English has none: the source
  text is English already. A domain's catalogue holds only the sentences it says in its
  own words, no catalogue holds a fuzzy entry, which Gettext would serve as it is, and
  none says a word of the apiary skin.

  Each backend has catalogues of its own, the core's in `priv/gettext` and an edition's in
  its own folder, and each is held to the rules. A test module uses this one with the
  folder, and gets the tests:

      use ApiaryWeb.LingoCatalogueCase,
        async: true,
        priv: Path.expand("../../priv/gettext", __DIR__)

  The checks are functions of a folder of catalogues too, so a test can run them against
  fixtures (`ApiaryWeb.LingoCatalogueTest`).
  """

  use ExUnit.CaseTemplate

  alias Expo.Message

  # The engine's surface words: the ones every domain renames. Whole words only, so
  # "targeted" or "systemd" do not count. `organisation` is not here: it is the same word
  # in the engine and the software domain. Nor is `workspace`: organisation and workspace
  # are the same words in every domain.
  @engine_words ~r/\b(targets?|systems?|change[ -]requests?|appl(?:y|ies|ied|ying))\b/i

  # The apiary skin's words, shown by no domain. The skin is per user and not built; when
  # it is, it gets its own catalogue. A hive is the skin's word for a workspace, and an
  # apiary its word for an organisation. `Qory Apiary` is the product's name.
  @apiary_words ~r/\b(apiary|apiaries|hives?|bees?|swarms?|flowers?|nectar|honey|jars?|beekeepers?|hivekeeping)\b/i

  # A source string whose engine word is the ordinary English word ("the operating system",
  # "apply the filters") says so with this context: pgettext("plain", "..."). The context
  # also keeps it apart from the engine term, which a domain may translate differently.
  @plain_context "plain"

  @doc false
  def plain_context, do: @plain_context

  @doc false
  def pot_files(priv), do: Path.wildcard(Path.join(priv, "*.pot"))

  @doc false
  def locales(priv) do
    priv
    |> Path.join("*/LC_MESSAGES")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
    |> Enum.sort()
  end

  @doc false
  def domain_locales(priv), do: Enum.filter(locales(priv), &String.contains?(&1, "@"))

  defp language(locale), do: locale |> String.split("@", parts: 2) |> hd()

  @doc false
  def english?(locale), do: language(locale) =~ ~r/\Aen(_[A-Z]{2})?\z/

  @doc false
  def plain_english?(locale), do: english?(locale) and locale == language(locale)

  @doc false
  def domain(pot), do: Path.basename(pot, ".pot")

  @doc false
  def po_file(priv, locale, domain),
    do: Path.join([priv, locale, "LC_MESSAGES", domain <> ".po"])

  @doc false
  def messages(path), do: path |> Expo.PO.parse_file!() |> Map.fetch!(:messages)

  # Source text as a reader would see it: bindings (%{target}) are names, not words.
  defp source_text(%Message.Singular{msgid: msgid}), do: IO.iodata_to_binary(msgid)

  defp source_text(%Message.Plural{msgid: msgid, msgid_plural: plural}),
    do: IO.iodata_to_binary([msgid, "\n", plural])

  defp without_bindings(text), do: String.replace(text, ~r/%\{\w+\}/, "")

  defp translations(%Message.Singular{msgstr: msgstr}), do: [IO.iodata_to_binary(msgstr)]

  defp translations(%Message.Plural{msgstr: msgstr}),
    do: msgstr |> Enum.sort() |> Enum.map(fn {_n, s} -> IO.iodata_to_binary(s) end)

  defp translated?(nil), do: false

  defp translated?(message) do
    not message.obsolete and not Message.has_flag?(message, "fuzzy") and
      Enum.all?(translations(message), &(&1 != ""))
  end

  @doc false
  def engine_word?(message) do
    {msgctxt, _msgid} = Message.key(message)
    msgctxt != @plain_context and message |> source_text() |> without_bindings() =~ @engine_words
  end

  @doc false
  def untranslated(pot_messages, po_messages) do
    by_key = Map.new(po_messages, &{Message.key(&1), &1})

    for message <- pot_messages,
        engine_word?(message),
        not translated?(by_key[Message.key(message)]),
        do: Message.key(message)
  end

  @doc false
  def missing(pot_messages, chain_po_messages) do
    found =
      for messages <- chain_po_messages,
          message <- messages,
          translated?(message),
          into: MapSet.new(),
          do: Message.key(message)

    for message <- pot_messages,
        not MapSet.member?(found, Message.key(message)),
        do: Message.key(message)
  end

  @doc false
  def stray(po_messages) do
    for message <- po_messages,
        not message.obsolete,
        not engine_word?(message),
        Enum.any?(translations(message), &(&1 != "")),
        do: Message.key(message)
  end

  @doc false
  def fuzzy(messages), do: for(m <- messages, Message.has_flag?(m, "fuzzy"), do: Message.key(m))

  # Each check over a folder of catalogues lists its failures as "locale/domain: key".

  @doc false
  def untranslated_in(priv) do
    for pot <- pot_files(priv),
        locale <- domain_locales(priv),
        key <- untranslated(messages(pot), messages(po_file(priv, locale, domain(pot)))),
        do: "#{locale}/#{domain(pot)}: #{inspect(key)}"
  end

  @doc false
  def missing_in(priv) do
    for locale <- domain_locales(priv),
        not english?(locale),
        pot <- pot_files(priv),
        chain = [locale | ApiaryWeb.Gettext.Fallback.chain(locale)],
        pos =
          for(
            l <- chain,
            File.exists?(po_file(priv, l, domain(pot))),
            do: messages(po_file(priv, l, domain(pot)))
          ),
        key <- missing(messages(pot), pos),
        do: "#{locale}/#{domain(pot)}: #{inspect(key)}"
  end

  @doc false
  def stray_in(priv) do
    for locale <- domain_locales(priv),
        pot <- pot_files(priv),
        key <- stray(messages(po_file(priv, locale, domain(pot)))),
        do: "#{locale}/#{domain(pot)}: #{inspect(key)}"
  end

  @doc false
  def fuzzy_in(priv) do
    for path <- Path.wildcard(Path.join(priv, "**/*.{po,pot}")),
        key <- fuzzy(messages(path)),
        do: "#{Path.relative_to(path, priv)}: #{inspect(key)}"
  end

  @doc false
  def apiary_words_in(priv) do
    sources =
      for pot <- pot_files(priv), message <- messages(pot) do
        {_ctx, msgid} = Message.key(message)

        text =
          message |> source_text() |> without_bindings() |> String.replace("Qory Apiary", "")

        if text =~ @apiary_words, do: "source: #{inspect(msgid)}"
      end

    translated =
      for locale <- locales(priv),
          pot <- pot_files(priv),
          message <- messages(po_file(priv, locale, domain(pot))),
          translation <- translations(message) do
        text = translation |> without_bindings() |> String.replace("Qory Apiary", "")

        if text =~ @apiary_words, do: "#{locale}: #{inspect(translation)}"
      end

    Enum.reject(sources ++ translated, &is_nil/1)
  end

  using opts do
    priv = Keyword.fetch!(opts, :priv)

    quote do
      import ApiaryWeb.LingoCatalogueCase

      @priv unquote(priv)

      describe "the catalogues" do
        test "every locale is a domain's catalogue or a language's, never plain English" do
          assert domain_locales(@priv) != []

          for locale <- locales(@priv) do
            assert locale =~ ~r/\A[a-z]{2,3}(_[A-Z]{2})?(@[a-z]+)?\z/,
                   "#{@priv}/#{locale}: name a domain's catalogue like en@software, a language's like de"

            refute plain_english?(locale),
                   "#{@priv}/#{locale}: English needs no catalogue of its own, the source text is English"
          end
        end

        test "every locale has a catalogue for every Gettext domain" do
          for pot <- pot_files(@priv), locale <- locales(@priv) do
            path = po_file(@priv, locale, domain(pot))
            assert File.exists?(path), "#{path} is missing: run mix gettext.extract --merge"
          end
        end

        test "a source string with an engine word is translated in every domain" do
          failures = untranslated_in(@priv)

          assert failures == [], """
          These source strings use an engine word and would be shown as they are. Translate
          them in each domain's catalogue, or, where the word is the ordinary English one, use
          pgettext("#{plain_context()}", ...):

          #{Enum.join(failures, "\n")}
          """
        end

        test "every sentence is translated in a language other than English, by the domain or the language" do
          failures = missing_in(@priv)

          assert failures == [], """
          These source strings would be shown in English. Translate them in the language's
          catalogue, or in the domain's where the domain says them in its own words:

          #{Enum.join(failures, "\n")}
          """
        end

        test "a domain's catalogue translates only the sentences with an engine word" do
          failures = stray_in(@priv)

          assert failures == [], """
          A domain's catalogue holds only its own sentences; the rest comes from the language's
          catalogue, or, in English, from the source text. Empty these msgstrs:

          #{Enum.join(failures, "\n")}
          """
        end

        test "no catalogue has a fuzzy entry" do
          failures = fuzzy_in(@priv)

          assert failures == [], """
          Gettext serves a fuzzy translation as it is. Check each one, then remove the flag:

          #{Enum.join(failures, "\n")}
          """
        end

        test "no source string and no translation uses an apiary word" do
          assert apiary_words_in(@priv) == []
        end
      end
    end
  end
end
