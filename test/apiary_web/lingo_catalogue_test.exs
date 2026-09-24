defmodule ApiaryWeb.LingoCatalogueTest do
  @moduledoc """
  Engine English is never shown (docs/lingo.md). Source strings are written in the engine's
  words; a body's catalogue says them in the body's words. A source string that uses an
  engine word and has no translation in every body's catalogue would reach the page as it
  is, so it fails here.
  """
  use ExUnit.Case, async: true

  alias Expo.Message

  @priv Path.expand("../../priv/gettext", __DIR__)

  # The engine's surface words (decision 0065): the ones every body renames. Whole words
  # only, so "targeted", "systemd" or "archive" do not count. `organisation` is not here:
  # it is the same word in the engine and the software body.
  @engine_words ~r/\b(targets?|systems?|change[ -]requests?|appl(?:y|ies|ied|ying)|hives?)\b/i

  # The apiary skin's words (decision 0057), shown by no body. The skin is per user and
  # not built; when it is, it gets its own catalogue. `Qory Apiary` is the product's name.
  @apiary_words ~r/\b(apiary|apiaries|bees?|swarms?|flowers?|nectar|honey|jars?|beekeepers?|hivekeeping)\b/i

  # A source string whose engine word is the ordinary English word ("the operating system",
  # "apply the filters") says so with this context: pgettext("plain", "..."). The context
  # also keeps it apart from the engine term, which a body may translate differently.
  @plain_context "plain"

  defp pot_files, do: Path.wildcard(Path.join(@priv, "*.pot"))

  defp locales do
    @priv
    |> Path.join("*/LC_MESSAGES")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
  end

  defp domain(pot), do: Path.basename(pot, ".pot")

  defp po_file(locale, domain), do: Path.join([@priv, locale, "LC_MESSAGES", domain <> ".po"])

  defp messages(path), do: path |> Expo.PO.parse_file!() |> Map.fetch!(:messages)

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

  describe "the catalogues" do
    test "every locale is a body: a language with an @modifier, never plain engine English" do
      assert locales() != []

      for locale <- locales() do
        assert locale =~ ~r/\A[a-z]{2,3}(_[A-Z]{2})?@[a-z]+\z/,
               "priv/gettext/#{locale} is not a body's catalogue; name it like en@software"
      end
    end

    test "every body has a catalogue for every domain" do
      for pot <- pot_files(), locale <- locales() do
        assert File.exists?(po_file(locale, domain(pot))),
               "#{po_file(locale, domain(pot))} is missing: run mix gettext.extract --merge"
      end
    end

    test "a source string with an engine word is translated in every body" do
      failures =
        for pot <- pot_files(),
            locale <- locales(),
            key <- untranslated(messages(pot), messages(po_file(locale, domain(pot)))),
            do: "#{locale}/#{domain(pot)}: #{inspect(key)}"

      assert failures == [], """
      These source strings use an engine word and would be shown as they are. Translate
      them in each body's catalogue, or, where the word is the ordinary English one, use
      pgettext("#{@plain_context}", ...):

      #{Enum.join(failures, "\n")}
      """
    end

    test "no source string and no body's translation uses an apiary word" do
      failures =
        for pot <- pot_files(), message <- messages(pot) do
          {_ctx, msgid} = Message.key(message)

          text =
            message |> source_text() |> without_bindings() |> String.replace("Qory Apiary", "")

          if text =~ @apiary_words, do: "source: #{inspect(msgid)}"
        end ++
          for locale <- locales(),
              pot <- pot_files(),
              message <- messages(po_file(locale, domain(pot))),
              translation <- translations(message) do
            text = translation |> without_bindings() |> String.replace("Qory Apiary", "")

            # A body names the hive too: the software body says workplace.
            if text =~ @apiary_words or text =~ ~r/\bhives?\b/i,
              do: "#{locale}: #{inspect(translation)}"
          end

      assert Enum.reject(failures, &is_nil/1) == []
    end
  end

  describe "the check itself" do
    defp singular(msgid, msgstr \\ "", opts \\ []),
      do: %Message.Singular{
        msgid: [msgid],
        msgstr: [msgstr],
        msgctxt: opts[:msgctxt],
        flags: opts[:flags] || []
      }

    test "fails an engine word without a translation, and passes it with one" do
      source = [singular("Every target follows it.")]
      assert untranslated(source, []) == [{"", "Every target follows it."}]
      assert untranslated(source, [singular("Every target follows it.")]) != []

      assert untranslated(source, [
               singular("Every target follows it.", "Every repository follows it.")
             ]) == []
    end

    test "a fuzzy translation does not count" do
      source = [singular("Apply the change request")]
      po = [singular("Apply the change request", "Merge the pull request", flags: [["fuzzy"]])]
      assert untranslated(source, po) != []
    end

    test "every plural form must be translated" do
      source = [%Message.Plural{msgid: ["%{count} target"], msgid_plural: ["%{count} targets"]}]

      half = [
        %Message.Plural{
          msgid: ["%{count} target"],
          msgid_plural: ["%{count} targets"],
          msgstr: %{0 => ["%{count} repository"], 1 => [""]}
        }
      ]

      assert untranslated(source, half) != []
    end

    test "ignores bindings, other words that contain an engine word, and the plain context" do
      assert untranslated([singular("Renamed %{target}.")], []) == []
      assert untranslated([singular("A targeted archive under systemd")], []) == []
      assert untranslated([singular("The operating system", "", msgctxt: ["plain"])], []) == []
      assert untranslated([singular("The operating system")], []) != []
      assert untranslated([singular("Nothing on this Hive's systems")], []) != []
    end
  end
end
