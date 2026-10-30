defmodule ApiaryWeb.LingoCatalogueTest do
  @moduledoc """
  Engine English is never shown (docs/lingo.md): the core's catalogues, `priv/gettext`,
  are held to the rules of `ApiaryWeb.LingoCatalogueCase`, and so are the checks
  themselves, on made-up messages and on the fixtures of `test/support/gettext_fallback`,
  one that passes and copies of it that do not.
  """
  # The sentences a software workspace says in its words, with no engine word in them: the
  # Explore texts, which read the code and propose how to build it, the policy file's
  # place, outside the checkout, and the harness choice's repository and its branch, tag or
  # commit, the version's name among them.
  @software_sentences [
    "%{source} has no version named %{ref}. An instance admin corrects the version of this harness source.",
    "%{source} has no version named %{ref}. Correct the version.",
    "%{source} has no version yet. Add a version with a qory.yaml or harness.yaml at its root that lists the stack under exports.",
    "A file outside the folder the runs work in, given with: %{command}",
    "A harness source",
    "A work item starts when someone takes in one of the Backlog's %{items}. Qory then explores it and proposes what to do.",
    "Always the latest: each run uses the newest version when it starts. A fixed version uses that version.",
    "Correct the version: a version name has 1 to 255 letters, digits, dots, underscores, slashes and hyphens, and no spaces.",
    "Correct the version: give a version name, refs/heads/<name>, refs/tags/<name> or a full version id. People without write access can change other refs, such as a change request's.",
    "Harness version",
    "Keep a policy file outside the folder the runs work in.",
    "Proposed what to do",
    "Qory asked %{number} question before it can propose what to do.",
    "Qory asked %{number} question before it can propose what to do. Answer it, and Qory explores again with your answer. Or decline the work item.",
    "Qory is exploring again, with %{name}'s answers. It reads the %{item} and proposes what to do.",
    "Qory is exploring again, with the answers of this take in. It reads the %{item} and proposes what to do.",
    "Qory is exploring again, with your answers. It reads the %{item} and proposes what to do.",
    "Qory is exploring. It reads the %{item} and proposes what to do.",
    "Qory proposed what to do, after %{duration}.",
    "Qory proposed what to do, after %{duration}. It waits for %{name} to confirm",
    "Qory proposed what to do, after %{duration}. It waits for you to confirm",
    "Qory proposed what to do. Confirm it, change it first, or decline the work item.",
    "Qory reads the %{item}",
    "Qory reads the %{item} and %{name}'s answers when the run starts, and proposes what to do.",
    "Qory reads the %{item} and the answers of this take in when the run starts, and proposes what to do.",
    "Qory reads the %{item} and your answers when the run starts, and proposes what to do.",
    "Qory reads the %{item} when the run starts, and proposes what to do.",
    "Qory starts run %{attempt} of %{of} when the workspace's node pool takes it. It reads the %{item} and proposes what to do, or asks what it needs to know.",
    "Run %{attempt} of %{of} reads the %{item} and these answers, from the start. It proposes what to do, or asks what it still needs to know.",
    "Run %{attempt} of %{of} reads the %{item}. It proposes what to do, or asks what it needs to know.",
    "Run %{attempt} of %{of} starts when the workspace's node pool takes it. It reads the %{item} and these answers, from the start.",
    "tag or version"
  ]

  use ApiaryWeb.LingoCatalogueCase,
    async: true,
    priv: Path.expand("../../priv/gettext", __DIR__),
    sentences: %{"en@software" => @software_sentences}

  # The form that adds an integration from a repository on a forge, which reads the same in
  # every domain: the integration's code lives there.
  @integration_release_form [
    "Repository",
    "is not on a forge this instance adds integrations from",
    "must be a repository's path: this instance adds no integration from an address",
    "must be a repository's path or an https address of a description.json"
  ]

  alias Expo.Message

  @fixture Path.expand("../support/gettext_fallback", __DIR__)

  describe "the software words" do
    test "no source string says one, but in the plain context, a workspace type's line or the integration release form" do
      failures = software_words_in(@priv, @integration_release_form)

      assert failures == [], """
      These source strings use a software word, which a workspace of any other domain
      would show. Write them in the engine's words, and say them in the software
      domain's words in its catalogue:

      #{Enum.join(failures, "\n")}
      """
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

    test "a collection is an engine word, said in a domain's words" do
      source = [
        singular("Find a collection"),
        %Message.Plural{msgid: ["%{count} collection"], msgid_plural: ["%{count} collections"]}
      ]

      assert untranslated(source, []) == [
               {"", "Find a collection"},
               {"", "%{count} collection"}
             ]

      assert untranslated(source, [
               singular("Find a collection", "Find a repository"),
               %Message.Plural{
                 msgid: ["%{count} collection"],
                 msgid_plural: ["%{count} collections"],
                 msgstr: %{0 => ["%{count} repository"], 1 => ["%{count} repositories"]}
               }
             ]) == []

      assert untranslated([singular("Renamed %{collection}.")], []) == []
      assert untranslated([singular("Nothing collected")], []) == []
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

    test "a domain's listed sentence is no stray, and must be translated" do
      translated = singular("Proposed what to do", "Proposed how to build it")
      assert stray([translated]) == [{"", "Proposed what to do"}]
      assert stray([translated], ["Proposed what to do"]) == []
      assert stray([translated], [{"", "Proposed what to do"}]) == []
    end

    test "a software word is one of a software workspace's words, whole" do
      for text <- [
            "Open the repository",
            "%{count} repositories",
            "On the forge",
            "Open a pull request",
            "Pull-requests",
            "The branch",
            "Every commit",
            "Outside the checkout",
            "Qory reads the code"
          ] do
        assert software_word?(singular(text)), text
      end

      for text <- [
            "Renamed %{repository}.",
            "from %{commit}",
            "A one-time code",
            "Claude Code",
            "Its integrity code",
            "Branched off",
            "Committed to it"
          ] do
        refute software_word?(singular(text)), text
      end

      refute software_word?(singular("In a checkout, run it", "", msgctxt: ["plain"]))

      refute software_word?(
               singular("Each ticket needs a repository", "", msgctxt: ["workspace type"])
             )
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
