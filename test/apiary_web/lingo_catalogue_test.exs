defmodule ApiaryWeb.LingoCatalogueTest do
  @moduledoc """
  Engine English is never shown (docs/lingo.md): the core's catalogues, `priv/gettext`,
  are held to the rules of `ApiaryWeb.LingoCatalogueCase`, and so are the checks
  themselves, on made-up messages and on the fixtures of `test/support/gettext_fallback`,
  one that passes and copies of it that do not.
  """
  # The sentences a software workspace says in its words, with no engine word in them: the
  # policy file's place, outside the checkout, and the harness choice's repository and its
  # branch, tag or commit, the version's name among them, and why a read of the Qory
  # harness failed.
  @software_sentences [
    "%{contact_support} to correct the version of %{source}: a version name has 1 to 255 letters, digits, dots, underscores, slashes and hyphens, and no spaces.",
    "%{contact_support}. Reading the harness from %{url} failed: the source has no version %{ref}.",
    "%{person}, updated from harness version %{commit}, %{date}",
    "%{source} has no version named %{ref}. %{contact_support} to correct the version of this harness source.",
    "%{source} has no version named %{ref}. Correct the version.",
    "%{source} has no version yet. Add a version with a qory.yaml or harness.yaml at its root that lists the stack under exports.",
    "A file outside the folder the runs work in, given with: %{command}",
    "A harness source",
    "A run uses the harness version its process version came from. Keep the process at the latest moves that harness version at each new version of the harness. A fixed version uses that version.",
    "Always the latest: a run uses the newest version. On the Qory harness, that is the version when a machine claims the run. On a harness source, it is the version when the run is queued. A fixed version uses that version.",
    "At each new harness version on %{branch}, Qory Apiary saves it as a new version of the stages. Edits saved on the Workflows page stop it.",
    "Choose a harness with a process for this type of workspace. The harness has no template of this workspace's type at this version.",
    "Compare version %{number} of the stages with the process at harness version %{commit}, then save it as a new version.",
    "Correct the version: a version name has 1 to 255 letters, digits, dots, underscores, slashes and hyphens, and no spaces.",
    "Correct the version: give a version name, refs/heads/<name>, refs/tags/<name> or a full version id. People without write access can change other refs, such as a change request's.",
    "Harness version",
    "Harness version in use: %{commit}, process version %{number}",
    "Harness: %{harness}, version %{commit}",
    "Keep a policy file outside the folder the runs work in.",
    {"plain",
     "Keep one template of this workspace's type in the harness, or choose another harness. At this commit the harness has more than one."},
    "Press Update from harness again. The harness choice changed after you opened this difference.",
    "Set a version that exists in the workspace's harness settings. %{url} has no %{ref}.",
    "Set a version that exists. %{url} has no tag or version %{ref}.",
    "Set a version that exists. %{url} has no version %{ref}.",
    "The Qory harness is the harness at %{url}.",
    "Update from harness version %{commit}",
    "Updated from harness version %{commit}, %{date}",
    "Version %{commit}",
    "tag or version",
    "the host does not have the version",
    "the host returned something other than a git source over HTTPS",
    "the host serves nothing public at that address",
    "the source is larger than 16 MiB, or a harness file is larger than 0.25 MiB"
  ]

  use ApiaryWeb.LingoCatalogueCase,
    async: true,
    priv: Path.expand("../../priv/gettext", __DIR__),
    sentences: %{"en@software" => @software_sentences}

  # The form that adds an integration from a repository on a forge, which reads the same in
  # every domain: the integration's code lives there.
  @integration_release_form [
    "Repository",
    "is not on a forge Qory Apiary adds integrations from",
    "must be a repository's path: Qory Apiary adds no integration from an address",
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
