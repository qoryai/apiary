defmodule ApiaryWeb.LingoCatalogueTest do
  @moduledoc """
  Engine English is never shown (docs/lingo.md): the core's catalogues, `priv/gettext`,
  are held to the rules of `ApiaryWeb.LingoCatalogueCase`, and so are the checks
  themselves, on made-up messages and on the fixtures of `test/support/gettext_fallback`,
  one that passes and copies of it that do not.
  """
  use ApiaryWeb.LingoCatalogueCase,
    async: true,
    priv: Path.expand("../../priv/gettext", __DIR__)

  alias Expo.Message

  @fixture Path.expand("../support/gettext_fallback", __DIR__)

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

    test "a language's sentence may come from the domain's catalogue or the language's" do
      source = [singular("Settings"), singular("Every target follows it.")]
      language = [singular("Settings", "Einstellungen")]
      domain = [singular("Every target follows it.", "Jedes Repository folgt ihr.")]

      assert missing(source, [domain, language]) == []
      assert missing(source, [domain]) == [{"", "Settings"}]

      assert missing(source, [[singular("Settings")], language]) == [
               {"", "Every target follows it."}
             ]
    end

    test "ignores bindings, other words that contain an engine word, and the plain context" do
      assert untranslated([singular("Renamed %{target}.")], []) == []
      assert untranslated([singular("A targeted archive under systemd")], []) == []
      assert untranslated([singular("The operating system", "", msgctxt: ["plain"])], []) == []
      assert untranslated([singular("The operating system")], []) != []
      assert untranslated([singular("Nothing on this Workspace's systems")], []) != []
    end

    test "a domain's translation of a sentence without an engine word is stray" do
      assert stray([singular("Every target follows it.", "Every repository follows it.")]) == []
      assert stray([singular("Settings")]) == []
      assert stray([singular("Settings", "Settings")]) == [{"", "Settings"}]

      plain = singular("Apply filters", "Apply filters", msgctxt: ["plain"])
      assert stray([plain]) == [{"plain", "Apply filters"}]
    end

    test "finds a fuzzy entry, whether or not it is translated" do
      assert fuzzy([singular("Settings", "Einstellungen")]) == []
      assert fuzzy([singular("Settings", "", flags: [["fuzzy"]])]) == [{"", "Settings"}]
    end
  end

  describe "the check, on the catalogues of test/support/gettext_fallback" do
    @describetag :tmp_dir

    test "passes a language's catalogue and a domain's that holds only its own sentences" do
      assert missing_in(@fixture) == []
      assert stray_in(@fixture) == []
      assert fuzzy_in(@fixture) == []
    end

    test "fails a sentence neither the domain nor the language translates", %{tmp_dir: dir} do
      File.cp_r!(@fixture, dir)
      edit(dir, "de", &String.replace(&1, ~s(msgid "Settings"\nmsgstr "Einstellungen"\n), ""))

      assert missing_in(dir) == [~s(de@software/default: {"", "Settings"})]
    end

    test "fails a domain's translation of a sentence of the language", %{tmp_dir: dir} do
      File.cp_r!(@fixture, dir)
      edit(dir, "de@software", &(&1 <> ~s(\nmsgid "Settings"\nmsgstr "Einstellungen"\n)))

      assert stray_in(dir) == [~s(de@software/default: {"", "Settings"})]
    end

    test "fails a fuzzy entry", %{tmp_dir: dir} do
      File.cp_r!(@fixture, dir)
      edit(dir, "de", &String.replace(&1, ~s(msgid "Settings"), ~s(#, fuzzy\nmsgid "Settings")))

      assert fuzzy_in(dir) == [~s(de/LC_MESSAGES/default.po: {"", "Settings"})]
    end

    defp edit(dir, locale, fun) do
      path = po_file(dir, locale, "default")
      File.write!(path, path |> File.read!() |> fun.())
    end
  end
end
