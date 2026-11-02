defmodule Apiary.Harnesses.QoryCopyTest do
  # The copy of the Qory harness in priv/harness/qory/ (`mix apiary.harness.update`):
  # the commit it was copied from is in `.harness-ref`, and its files are the bytes of
  # that commit.
  use ExUnit.Case, async: true

  alias Apiary.Artifacts.TemplateTypes
  alias Apiary.Harnesses.{QoryCopy, Reader}
  alias Apiary.Lingo.Domain.Definition
  alias Apiary.Processes
  alias Mix.Tasks.Apiary.Harness.Update

  @root Path.expand("../../..", __DIR__)
  @dir Path.join(@root, "priv/harness/qory")
  @texts Path.join(@root, "lib/apiary/harnesses/qory_copy/texts.ex")

  # The files copied from qoryai/harness at the commit in `.harness-ref`, by their SHA-256
  # there.
  @harness_ref "e49953e4f254ad7627ba4839930e239df6fb9f4d"
  @copied_sha256 %{
    "qory.yaml" => "0d43ac5ebe9ebdbb2087f42b14a56a8dea3db95516b7d514d1093cfea8a62f6e",
    "modules/software-factory/process.yaml" =>
      "392309098e8be0dccc99a08330eca602104ef97336815effb753c223b884faa7",
    "stacks/core/qory-stack.yaml" =>
      "1189e86746a88f25db585913250a830849107c3a18107bc6cef9f24c022b012f",
    "stacks/software/qory-stack.yaml" =>
      "e21a31b7e8a1bc55a36c991f7d780e0b885c7654e444c12542bd46bdb96e6e53"
  }

  test "the copy is of the commit Definition pins as the newest Qory harness" do
    assert File.read!(Path.join(@dir, ".harness-ref")) == @harness_ref <> "\n"
    assert QoryCopy.ref() == @harness_ref
    assert Definition.qory_harness().latest == @harness_ref
  end

  test "the copied files are the bytes of the pinned commit" do
    copied =
      for path <- Path.wildcard(Path.join(@dir, "**/*"), match_dot: true),
          File.regular?(path),
          do: Path.relative_to(path, @dir)

    assert Enum.sort(copied) == Enum.sort([".harness-ref" | Map.keys(@copied_sha256)])
    assert Enum.sort(Update.files()) == Enum.sort(Map.keys(@copied_sha256))
    assert QoryCopy.paths() == Enum.sort(Map.keys(@copied_sha256))

    for {path, sha256} <- @copied_sha256 do
      bytes = File.read!(Path.join(@dir, path))
      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha256, path
      assert QoryCopy.file(path) == bytes, path
    end

    assert QoryCopy.file("missing.yaml") == nil
  end

  test "Definition keeps stack core and lists the stacks the copy exports" do
    harness = Definition.qory_harness()
    assert harness.stack == "core"
    assert harness.stacks == ["core", "software"]
    assert Definition.qory("qory.software").harness["stack"] == "core"

    {:ok, exports} = Reader.exports(QoryCopy.file("qory.yaml"))
    assert exports.stacks == harness.stacks
  end

  describe "the copied template" do
    test "is the software type's, and the process passes the process rules" do
      template = QoryCopy.template()

      assert template.type == "qory.software"
      assert Processes.validate(template.process) == :ok
    end

    test "keeps today's stage ids, which the migrated work items keep" do
      assert Enum.map(QoryCopy.template().process["stages"], &{&1["id"], &1["name"]}) == [
               {"st_r79kph11eg", "Explore"},
               {"st_p9w5cvh311", "Shape"},
               {"st_6ns22c4pav", "Build"},
               {"st_m1mqbeywdg", "Verify"},
               {"st_k9kpv17xmy", "Release"}
             ]
    end

    test "has the texts of its module" do
      assert QoryCopy.texts() == QoryCopy.Texts.texts("software-factory")
    end
  end

  describe "the copied stacks' workflows" do
    test "are the names each stack lists: software lists explore-a-ticket, core none" do
      assert QoryCopy.workflows("software") == ["explore-a-ticket"]
      assert QoryCopy.workflows("core") == []
    end

    test "a stack the copy does not have raises" do
      assert_raise FunctionClauseError, fn -> QoryCopy.workflows("missing") end
    end
  end

  test "the template passes the check of its artifact types" do
    assert TemplateTypes.check(QoryCopy.template()) == :ok
  end

  describe "the template's texts" do
    setup do
      texts =
        for template <- Update.templates() do
          {:ok, process} = Reader.parse(QoryCopy.file("modules/#{template}/process.yaml"))

          {template,
           %{
             name: process["name"],
             summary: process["summary"],
             description: process["description"]
           }}
        end

      %{texts: texts}
    end

    test "the generated module is what the task writes from the copy", %{texts: texts} do
      assert File.read!(@texts) == Update.texts_module(texts)

      for {template, text} <- texts,
          do: assert(QoryCopy.Texts.texts(template) == text)

      assert QoryCopy.Texts.texts("core") == nil
    end

    test "are in default.pot in the workspace type context", %{texts: texts} do
      pot = Expo.PO.parse_file!(Path.join(@root, "priv/gettext/default.pot"))
      reference = Path.relative_to(@texts, @root)

      kept =
        for message <- pot.messages,
            message.msgctxt == ["workspace type"],
            reference in List.flatten(message.references),
            do: IO.iodata_to_binary(message.msgid)

      for {_template, text} <- texts,
          value <- [text.name, text.summary, text.description],
          do: assert(value in kept, value)
    end
  end
end
