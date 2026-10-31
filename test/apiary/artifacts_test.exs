defmodule Apiary.ArtifactsTest do
  # Not async: the store's root is the application's setting.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Artifacts
  alias Apiary.Artifacts.{Artifact, ArtifactFile, Store, Type, Version}
  alias Apiary.Audit.Entry

  @moduletag :tmp_dir
  @moduletag needs: :workflow_model

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "store")
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, root)
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    scope = scope_fixture()
    work_item = work_item_fixture(scope)
    %{dispatch_run: run} = explore_run_fixture(work_item)
    %{root: root, scope: scope, work_item: work_item, run: run}
  end

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>
  @gif "GIF89a" <> <<1, 0, 1, 0, 0, 0, 0>>
  @mp4 <<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0, "isomiso2">>
  @webm <<0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x42, 0x82, 0x84, "webm">>
  @svg ~s(<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1"/></svg>)

  defp file(filename, bytes, content_type \\ "application/octet-stream"),
    do: %{filename: filename, content_type: content_type, binary: bytes}

  defp doc(filename \\ "notes.md", text \\ "# Notes\n\nThe gift card field."),
    do: file(filename, text, "text/markdown")

  defp json(filename, value), do: file(filename, Jason.encode!(value), "application/json")

  defp proposal do
    %{
      "complexity" => %{"level" => "standard", "reason" => "Two pages change."},
      "understanding" => "Add gift cards to the checkout of the Web shop.",
      "scope" => %{"in" => ["Checkout page"], "out" => ["Refunds"]},
      "approach" => %{"summary" => "A field on the payment step.", "alternatives" => []}
    }
  end

  defp stored_paths(root) do
    case File.ls(root) do
      {:ok, _names} -> Path.wildcard(Path.join(root, "*/*/*"))
      {:error, :enoent} -> []
    end
  end

  defp staging_files(root), do: Path.wildcard(Path.join(root, ".staging-*"), match_dot: true)

  defp count(schema), do: Repo.aggregate(schema, :count)

  describe "types/1 and type/2" do
    test "list the ten standard types first, then the workspace's custom types by name", %{
      scope: scope
    } do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "demo-findings",
          "base_view" => "document"
        })

      names = Enum.map(Artifacts.types(scope.workspace), & &1.name)

      assert names ==
               ~w(acceptance-criteria explainer decision-record mockup screenshot demo-video
                  change proposal questions verdict demo-findings)
    end

    test "have the base views and dedicated views of the workflow model", %{scope: scope} do
      types = Map.new(Artifacts.types(scope.workspace), &{&1.name, &1})

      for name <- ~w(acceptance-criteria explainer decision-record),
          do: assert(types[name].base_view == :document)

      assert types["mockup"].base_view == :image
      assert types["screenshot"].base_view == :image
      assert types["demo-video"].base_view == :video

      for name <- ~w(change proposal questions verdict) do
        assert types[name].base_view == :structured
        assert types[name].view == String.to_existing_atom(name)
        assert types[name].max_files == 1
      end

      assert Enum.all?(Type.standard(), & &1.standard)
    end

    test "find a type by name, and nothing for a name no type has", %{scope: scope} do
      assert %Type{name: "verdict", standard: true} = Artifacts.type(scope.workspace, "verdict")
      assert Artifacts.type(scope.workspace, "demo-findings") == nil
      assert Artifacts.type(scope.workspace, "Not A Name") == nil
      assert Artifacts.type(scope.workspace, 12) == nil
    end

    test "never return a custom type of another organisation's workspace", %{scope: scope} do
      other = scope_fixture()

      {:ok, _type} =
        Artifacts.create_type(other, other.workspace, %{"name" => "bids", "base_view" => "file"})

      assert Artifacts.type(scope.workspace, "bids") == nil
      refute "bids" in Enum.map(Artifacts.types(scope.workspace), & &1.name)
    end
  end

  describe "create_type/3" do
    test "makes a custom type with the base view's defaults and an audit entry", %{scope: scope} do
      assert {:ok, %Type{} = type} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "demo-findings",
                 "base_view" => "document"
               })

      assert type.public_id =~ ~r/\Aat_[0-9a-hjkmnp-tv-z]{16}\z/
      assert type.size_limit == 1_048_576
      assert type.max_files == 1
      refute type.standard

      assert [%Entry{details: %{"change" => "create", "type" => "demo-findings"}}] =
               Repo.all(from e in Entry, where: e.action == "artifact_type.edit")
    end

    test "takes a structured type's schema as a map or as JSON text", %{scope: scope} do
      schema = %{"type" => "object", "properties" => %{"bid" => %{"type" => "number"}}}

      assert {:ok, %Type{json_schema: ^schema}} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "bids",
                 "base_view" => "structured",
                 "json_schema" => schema
               })

      assert {:ok, %Type{json_schema: ^schema}} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "bids-two",
                 "base_view" => "structured",
                 "json_schema" => Jason.encode!(schema)
               })
    end

    test "refuses a member, who may not edit the types", %{scope: scope} do
      member = member_fixture(scope)

      assert {:error, :forbidden} =
               Artifacts.create_type(member.scope, scope.workspace, %{
                 "name" => "bids",
                 "base_view" => "file"
               })
    end

    test "refuses another organisation's workspace", %{scope: scope} do
      other = scope_fixture()

      assert {:error, :not_found} =
               Artifacts.create_type(scope, other.workspace, %{
                 "name" => "bids",
                 "base_view" => "file"
               })
    end

    test "refuses a standard name, a name of the wrong form and a name twice", %{scope: scope} do
      for name <- [
            "verdict",
            "Bids",
            "bids_2",
            "-bids",
            "bids-",
            "a--b",
            String.duplicate("a", 65)
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Artifacts.create_type(scope, scope.workspace, %{
                   "name" => name,
                   "base_view" => "file"
                 })

        assert changeset.errors[:name], "#{inspect(name)} is taken"
      end

      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{"name" => "bids", "base_view" => "file"})

      assert {:error, %Ecto.Changeset{errors: [name: _error]}} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "bids",
                 "base_view" => "file"
               })
    end

    test "refuses limits past the base view's bounds", %{scope: scope} do
      attrs = %{"name" => "bids", "base_view" => "document"}

      assert {:error, %{errors: [size_limit: _error]}} =
               Artifacts.create_type(
                 scope,
                 scope.workspace,
                 Map.put(attrs, "size_limit", 10_485_761)
               )

      assert {:error, %{errors: [max_files: _error]}} =
               Artifacts.create_type(scope, scope.workspace, Map.put(attrs, "max_files", 21))

      assert {:error, %{errors: [max_files: _error]}} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "bids",
                 "base_view" => "structured",
                 "json_schema" => %{"type" => "object"},
                 "max_files" => 2
               })
    end

    test "keeps a schema for a structured type alone", %{scope: scope} do
      assert {:error, %{errors: [json_schema: _error]}} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "bids",
                 "base_view" => "structured"
               })

      assert {:error, %{errors: [json_schema: _error]}} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "bids",
                 "base_view" => "file",
                 "json_schema" => %{"type" => "object"}
               })
    end

    test "refuses a schema JSV cannot build, or that is over the bounds", %{scope: scope} do
      for schema <- [
            %{"type" => 5},
            %{"pattern" => "("},
            %{"enum" => Enum.to_list(1..1025)},
            "not JSON",
            [1, 2]
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Artifacts.create_type(scope, scope.workspace, %{
                   "name" => "bids",
                   "base_view" => "structured",
                   "json_schema" => schema
                 })

        assert changeset.errors[:json_schema], "#{inspect(schema)} is taken"
      end
    end
  end

  describe "update_type/3 and delete_type/2" do
    setup %{scope: scope} do
      {:ok, type} =
        Artifacts.create_type(scope, scope.workspace, %{"name" => "bids", "base_view" => "file"})

      %{type: type}
    end

    test "change the limits and keep the name and base view", %{scope: scope, type: type} do
      assert {:ok, updated} =
               Artifacts.update_type(scope, type, %{
                 "size_limit" => 2048,
                 "max_files" => 3,
                 "name" => "other",
                 "base_view" => "image"
               })

      assert {updated.size_limit, updated.max_files, updated.name, updated.base_view} ==
               {2048, 3, "bids", :file}
    end

    test "refuse a member", %{scope: scope, type: type} do
      member = member_fixture(scope)
      assert {:error, :forbidden} = Artifacts.update_type(member.scope, type, %{"max_files" => 2})
      assert {:error, :forbidden} = Artifacts.delete_type(member.scope, type)
    end

    test "delete a type no artifact has", %{scope: scope, type: type} do
      assert {:ok, _deleted} = Artifacts.delete_type(scope, type)
      assert Artifacts.type(scope.workspace, "bids") == nil
      assert {:error, :not_found} = Artifacts.delete_type(scope, type)
    end

    test "refuse to delete a type an artifact has",
         %{scope: scope, type: type, run: run} = context do
      {:ok, _version} =
        Artifacts.push({:run, run}, context.work_item, "bids", [file("bids.csv", "a,b")])

      assert {:error, :in_use} = Artifacts.delete_type(scope, type)
    end
  end

  describe "push/5 by a run" do
    test "stores version 1 with the content type the bytes show",
         %{run: run, root: root} = context do
      assert {:ok, %Version{} = version} =
               Artifacts.push({:run, run}, context.work_item, "screenshot", [
                 file("checkout.png", @gif, "image/png")
               ])

      assert version.number == 1
      assert version.writer == :run
      assert version.run_id == run.id
      assert version.user_id == nil
      assert version.public_id =~ ~r/\Aav_[0-9a-hjkmnp-tv-z]{16}\z/
      assert %Artifact{type: "screenshot", name: "main"} = version.artifact
      assert version.artifact.public_id =~ ~r/\Aaf_[0-9a-hjkmnp-tv-z]{16}\z/

      sha256 = Base.encode16(:crypto.hash(:sha256, @gif), case: :lower)

      assert [
               %ArtifactFile{
                 filename: "checkout.png",
                 content_type: "image/gif",
                 size: 13,
                 sha256: ^sha256,
                 store_key: ^sha256
               }
             ] = version.files

      <<a::binary-size(2), b::binary-size(2), _rest::binary>> = sha256
      assert stored_paths(root) == [Path.join([root, a, b, sha256])]
      assert File.read!(Path.join([root, a, b, sha256])) == @gif
      assert staging_files(root) == []
    end

    test "numbers the versions of an artifact 1, 2, 3 and keeps names apart", context do
      %{run: run, work_item: work_item} = context

      for n <- 1..3 do
        assert {:ok, %Version{number: ^n}} =
                 Artifacts.push({:run, run}, work_item, "explainer", [doc("v#{n}.md")])
      end

      assert {:ok, %Version{number: 1}} =
               Artifacts.push({:run, run}, work_item, "explainer", [doc()], name: "design")

      assert %Version{number: 3, files: [%{filename: "v3.md"}]} =
               Artifacts.newest(work_item, "explainer")

      assert %Version{number: 1} = Artifacts.newest(work_item, "explainer", "design")
      assert Artifacts.newest(work_item, "mockup") == nil

      assert [%Artifact{name: "design"}, %Artifact{name: "main", versions: versions} = main] =
               Artifacts.list(work_item)

      assert Enum.map(versions, & &1.number) == [3, 2, 1]
      assert Enum.map(Artifacts.versions(main), & &1.number) == [3, 2, 1]
    end

    test "keeps the same content once in the store", %{run: run, root: root} = context do
      {:ok, one} = Artifacts.push({:run, run}, context.work_item, "explainer", [doc("a.md")])

      {:ok, two} =
        Artifacts.push({:run, run}, context.work_item, "decision-record", [doc("b.md")])

      assert hd(one.files).store_key == hd(two.files).store_key
      assert length(stored_paths(root)) == 1
    end

    test "stores the stage and the note, the note trimmed", %{run: run} = context do
      assert {:ok, version} =
               Artifacts.push(
                 {:run, run},
                 context.work_item,
                 "verdict",
                 [json("verdict.json", %{"verdict" => "passed"})],
                 stage_id: "st_0123456789",
                 note: "  Round 2\r\nof 3  "
               )

      assert {version.stage_id, version.note, version.artifact.stage_id} ==
               {"st_0123456789", "Round 2\nof 3", "st_0123456789"}

      assert {:ok, %Version{note: nil}} =
               Artifacts.push(
                 {:run, run},
                 context.work_item,
                 "verdict",
                 [json("v.json", %{"verdict" => "passed"})],
                 note: " "
               )
    end

    test "writes no audit entry", %{run: run} = context do
      {:ok, _version} = Artifacts.push({:run, run}, context.work_item, "explainer", [doc()])
      assert Repo.all(from e in Entry, where: e.action == "artifact.write") == []
    end

    test "refuses a run of another work item", %{scope: scope, run: run} do
      other = work_item_fixture(scope, %{external_ref: "acme/shop#13"})
      assert {:error, :not_found} = Artifacts.push({:run, run}, other, "explainer", [doc()])
      assert count(Artifact) == 0
    end

    test "writes only the types the workflow may write, and verdict and questions", context do
      %{run: run, work_item: work_item} = context
      writes = [writes: ["explainer"]]

      assert {:ok, _version} =
               Artifacts.push({:run, run}, work_item, "explainer", [doc()], writes)

      assert {:error, {:not_writable, "mockup"}} =
               Artifacts.push({:run, run}, work_item, "mockup", [file("a.png", @png)], writes)

      assert {:ok, _version} =
               Artifacts.push(
                 {:run, run},
                 work_item,
                 "verdict",
                 [json("v.json", %{"verdict" => "escalate", "gaps" => "No demo."})],
                 writes
               )

      assert {:ok, _version} =
               Artifacts.push(
                 {:run, run},
                 work_item,
                 "questions",
                 [json("q.json", %{"questions" => ["Which basket?"]})],
                 writes
               )

      assert {:error, {:not_writable, "explainer"}} =
               Artifacts.push({:run, run}, work_item, "explainer", [doc()], writes: [])
    end

    test "refuses an unknown type and a type name of the wrong form", %{run: run} = context do
      assert {:error, {:unknown_type, "demo-findings"}} =
               Artifacts.push({:run, run}, context.work_item, "demo-findings", [doc()])

      assert {:error, {:invalid, :type}} =
               Artifacts.push({:run, run}, context.work_item, "../x", [doc()])

      assert {:error, {:invalid, :type}} =
               Artifacts.push({:run, run}, context.work_item, nil, [doc()])
    end

    test "refuses a name, a stage or a note of the wrong form", %{run: run} = context do
      push = &Artifacts.push({:run, run}, context.work_item, "explainer", [doc()], &1)

      assert {:error, {:invalid, :name}} = push.(name: "Main")
      assert {:error, {:invalid, :name}} = push.(name: "")
      assert {:error, {:invalid, :stage_id}} = push.(stage_id: "st x")
      assert {:error, {:invalid, :stage_id}} = push.(stage_id: String.duplicate("s", 65))
      assert {:error, {:invalid, :note}} = push.(note: "a\u0000b")
      assert {:error, {:invalid, :note}} = push.(note: "a\u202Eb")
      assert {:error, {:invalid, :note}} = push.(note: String.duplicate("n", 4001))
      assert {:error, {:invalid, :note}} = push.(note: <<0xFF>>)
      assert count(Artifact) == 0
    end

    test "counts a note's length in code points, as the database does", %{run: run} = context do
      push = &Artifacts.push({:run, run}, context.work_item, "explainer", [doc()], &1)

      # "e" and U+0301: one grapheme, two code points.
      accent = "e\u0301"
      assert {:error, {:invalid, :note}} = push.(note: String.duplicate(accent, 4000))
      assert {:ok, %Version{note: note}} = push.(note: String.duplicate(accent, 2000))
      assert String.length(note) == 2000
    end

    test "refuses no files, too many files and a file of the wrong shape",
         %{run: run} = context do
      push = &Artifacts.push({:run, run}, context.work_item, &1, &2)

      assert {:error, {:invalid, :no_files}} = push.("explainer", [])
      assert {:error, {:too_many_files, 1}} = push.("explainer", [doc("a.md"), doc("b.md")])

      assert {:error, {:too_many_files, 10}} =
               push.("screenshot", for(n <- 1..11, do: file("#{n}.png", @png)))

      assert {:error, {:invalid, {:file, 0}}} = push.("explainer", [%{filename: "a.md"}])

      assert {:error, {:invalid, {:file, 0}}} =
               push.("explainer", [%{"filename" => "a.md", "binary" => "x"}])
    end

    test "refuses a filename that is not a base name, or that is there twice",
         %{run: run} = context do
      push = &Artifacts.push({:run, run}, context.work_item, "screenshot", &1)

      for name <- [
            "",
            ".",
            "..",
            "a/b.png",
            "../b.png",
            "a\\b.png",
            "a\u0000.png",
            "a\n.png",
            "gnp.\u202Eexe",
            <<0xFF, ".png">>,
            String.duplicate("a", 252) <> ".png",
            7
          ] do
        assert {:error, {:invalid, {:filename, 1}}} =
                 push.([file("ok.png", @png), file(name, @png)]),
               "#{inspect(name)} is taken"
      end

      assert {:error, {:invalid, {:duplicate_filename, 1}}} =
               push.([file("a.png", @png), file("a.png", @gif)])

      assert {:ok, _version} = push.([file(String.duplicate("a", 251) <> ".png", @png)])
    end

    test "refuses a version over the size limit, and keeps nothing of it",
         %{scope: scope, run: run, root: root} = context do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "bids",
          "base_view" => "file",
          "size_limit" => 100,
          "max_files" => 2
        })

      push = &Artifacts.push({:run, run}, context.work_item, "bids", &1)
      assert {:error, {:too_large, 100}} = push.([file("a.bin", :binary.copy("a", 101))])

      assert {:error, {:too_large, 100}} =
               push.([file("a.bin", :binary.copy("a", 60)), file("b.bin", :binary.copy("b", 41))])

      assert {:ok, _version} =
               push.([file("a.bin", :binary.copy("a", 60)), file("b.bin", :binary.copy("b", 40))])

      assert length(stored_paths(root)) == 2
      assert staging_files(root) == []
      assert count(Version) == 1
    end

    test "reads a file from a path, stops past the limit, and refuses a path it cannot read",
         context do
      %{scope: scope, run: run, root: root, tmp_dir: tmp_dir} = context

      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "bids",
          "base_view" => "file",
          "size_limit" => 200_000
        })

      small = Path.join(tmp_dir, "small.bin")
      File.write!(small, :binary.copy("s", 200_000))
      large = Path.join(tmp_dir, "large.bin")
      File.write!(large, :binary.copy("l", 200_001))

      push =
        &Artifacts.push({:run, run}, context.work_item, "bids", [%{filename: "f.bin", path: &1}])

      assert {:error, {:too_large, 200_000}} = push.(large)
      assert staging_files(root) == []
      assert {:error, {:invalid, {:unreadable, 0}}} = push.(Path.join(tmp_dir, "missing.bin"))
      assert {:ok, %Version{files: [%{size: 200_000}]}} = push.(small)
    end

    test "checks each file against its base view, and writes nothing on a refusal",
         %{run: run, root: root} = context do
      push = &Artifacts.push({:run, run}, context.work_item, &1, &2)

      assert {:error, {:invalid, {:extension, 0}}} = push.("explainer", [doc("notes.txt")])

      assert {:error, {:invalid, {:format, 0}}} =
               push.("explainer", [doc("notes.md", <<0xFF, 0xFE>>)])

      assert {:error, {:invalid, {:format, 0}}} =
               push.("explainer", [doc("notes.md", "a\u0000b")])

      assert {:error, {:invalid, {:format, 1}}} =
               push.("screenshot", [file("a.png", @png), file("b.png", "<html></html>")])

      assert {:error, {:invalid, {:format, 0}}} = push.("demo-video", [file("demo.mp4", @png)])

      assert {:error, {:invalid, :no_video}} =
               push.("demo-video", [file("en.vtt", "WEBVTT\n"), file("de.vtt", "WEBVTT\n")])

      assert {:error, {:invalid, {:schema, 0}}} =
               push.("verdict", [json("v.json", %{"verdict" => "done"})])

      assert {:error, {:invalid, {:format, 0}}} = push.("verdict", [file("v.json", "{not json")])

      assert count(Artifact) == 0
      assert count(Version) == 0
      assert stored_paths(root) == []
      assert staging_files(root) == []
    end

    test "keeps the content type of each base view", %{run: run} = context do
      push = fn type, files ->
        {:ok, version} = Artifacts.push({:run, run}, context.work_item, type, files)
        Enum.map(version.files, & &1.content_type)
      end

      assert push.("explainer", [doc("Notes.MD")]) == ["text/markdown; charset=utf-8"]

      assert push.("mockup", [file("a.png", @png), file("b.svg", @svg), file("c.gif", @gif)]) ==
               ["image/png", "image/svg+xml", "image/gif"]

      assert push.("demo-video", [file("demo.mp4", @mp4)]) == ["video/mp4"]
      assert push.("demo-video", [file("demo.webm", @webm, "video/mp4")]) == ["video/webm"]

      assert push.("demo-video", [file("demo.mp4", @mp4), file("en.vtt", "WEBVTT\n")]) ==
               ["video/mp4", "text/vtt; charset=utf-8"]

      assert push.("proposal", [json("proposal.json", proposal())]) == ["application/json"]
    end

    test "takes the standard structured types' documents their schemas allow",
         %{run: run} = context do
      push = &Artifacts.push({:run, run}, context.work_item, &1, [json("a.json", &2)])

      assert {:ok, _version} =
               push.("change", %{
                 "url" => "https://forge.example.com/acme/shop/pull/4",
                 "title" => "Gift cards"
               })

      assert {:ok, _version} = push.("change", %{"url" => "http://localhost:8080/changes/4"})

      for url <- [
            "ftp://forge.example.com/4",
            "javascript:alert(1)",
            "https://user@forge.example.com/",
            "https://",
            "https://forge.example.com/a b"
          ] do
        assert {:error, {:invalid, {:schema, 0}}} = push.("change", %{"url" => url}),
               "#{url} is taken"
      end

      assert {:error, {:invalid, {:schema, 0}}} =
               push.("change", %{"url" => "https://a.example", "extra" => 1})

      assert {:ok, _version} = push.("proposal", proposal())

      assert {:error, {:invalid, {:schema, 0}}} =
               push.("proposal", Map.delete(proposal(), "scope"))

      assert {:ok, _version} =
               push.("questions", %{
                 "questions" => ["Which basket?"],
                 "understanding" => "A checkout change."
               })

      assert {:error, {:invalid, {:schema, 0}}} = push.("questions", %{"questions" => []})

      assert {:ok, _version} =
               push.("verdict", %{
                 "verdict" => "changes-requested",
                 "gaps" => "The demo has no second card."
               })

      assert {:error, {:invalid, {:schema, 0}}} =
               push.("verdict", %{"verdict" => "passed", "gaps" => ""})
    end

    test "validates a custom structured type's document against its schema",
         %{scope: scope, run: run} = context do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "bids",
          "base_view" => "structured",
          "json_schema" => %{
            "type" => "object",
            "required" => ["bids"],
            "properties" => %{"bids" => %{"type" => "array", "items" => %{"type" => "number"}}}
          }
        })

      push = &Artifacts.push({:run, run}, context.work_item, "bids", [json("bids.json", &1)])
      assert {:ok, _version} = push.(%{"bids" => [1.5, 2]})
      assert {:error, {:invalid, {:schema, 0}}} = push.(%{"bids" => ["high"]})
      assert {:error, {:invalid, {:schema, 0}}} = push.(%{"bids" => Enum.to_list(1..10_001)})
    end
  end

  describe "push/5 by a person" do
    test "stores the person's version and an audit entry", %{scope: scope} = context do
      member = member_fixture(scope)

      assert {:ok, %Version{writer: :person, user_id: user_id, run_id: nil}} =
               Artifacts.push(
                 {:person, member.scope},
                 context.work_item,
                 "proposal",
                 [json("p.json", proposal())],
                 note: "Scope edited"
               )

      assert user_id == member.user.id

      assert [%Entry{subject_id: subject_id, details: %{"type" => "proposal", "number" => 1}}] =
               Repo.all(from e in Entry, where: e.action == "artifact.write")

      assert subject_id == context.work_item.id
    end

    test "is not found for a person of another organisation", context do
      other = scope_fixture()

      assert {:error, :not_found} =
               Artifacts.push({:person, other}, context.work_item, "explainer", [doc()])
    end

    test "is not bound by a workflow's writes", %{scope: scope} = context do
      assert {:ok, _version} =
               Artifacts.push(
                 {:person, scope},
                 context.work_item,
                 "mockup",
                 [file("a.png", @png)],
                 writes: []
               )
    end
  end

  describe "get_version!/1 and open_file/1" do
    test "find a version by its public id and open its stored copy", %{run: run} = context do
      {:ok, pushed} =
        Artifacts.push({:run, run}, context.work_item, "screenshot", [file("a.png", @png)])

      version = Artifacts.get_version!(pushed.public_id)
      assert version.id == pushed.id
      assert %Artifact{type: "screenshot"} = version.artifact
      assert [stored] = version.files
      assert {:ok, path} = Artifacts.open_file(stored)
      assert File.read!(path) == @png
    end

    test "raise for an id of no version" do
      assert_raise Ecto.NoResultsError, fn -> Artifacts.get_version!("av_0000000000000000") end
      assert_raise Ecto.NoResultsError, fn -> Artifacts.get_version!("../etc") end
    end

    test "refuse a store key that is not a digest" do
      assert {:error, :invalid_key} =
               Artifacts.open_file(%ArtifactFile{store_key: "../../etc/passwd"})

      assert {:error, :not_found} =
               Artifacts.open_file(%ArtifactFile{store_key: String.duplicate("a", 64)})
    end
  end

  describe "exists?/3" do
    test "is true for a version of the type made in the stage whose files pass",
         %{run: run} = context do
      %{work_item: work_item} = context
      refute Artifacts.exists?(work_item, "st_build", "demo-video")

      {:ok, _version} =
        Artifacts.push({:run, run}, work_item, "demo-video", [file("d.mp4", @mp4)],
          stage_id: "st_build",
          name: "first"
        )

      assert Artifacts.exists?(work_item, "st_build", "demo-video")
      refute Artifacts.exists?(work_item, "st_verify", "demo-video")
      refute Artifacts.exists?(work_item, "st_build", "mockup")
      refute Artifacts.exists?(work_item, "st_build", "demo-findings")
    end

    test "reads the content types kept at the push, and no stored file",
         %{run: run, root: root} = context do
      {:ok, version} =
        Artifacts.push({:run, run}, context.work_item, "demo-video", [file("d.mp4", @mp4)],
          stage_id: "st_build"
        )

      {:ok, path} = Store.Volume.path(hd(version.files).store_key)
      assert String.starts_with?(path, root)
      File.rm!(path)
      assert Artifacts.exists?(context.work_item, "st_build", "demo-video")

      Repo.update_all(from(f in ArtifactFile, where: f.version_id == ^version.id),
        set: [content_type: "image/png"]
      )

      refute Artifacts.exists?(context.work_item, "st_build", "demo-video")
    end
  end

  describe "after a push" do
    test "the work item's workspace hears of the version", %{run: run} = context do
      work_item = context.work_item
      Phoenix.PubSub.subscribe(Apiary.PubSub, Apiary.WorkItems.topic(work_item.workspace_id))

      {:ok, version} = Artifacts.push({:run, run}, work_item, "explainer", [doc()])

      assert_receive {:artifact_pushed, work_item_id, version_id}
      assert {work_item_id, version_id} == {work_item.public_id, version.public_id}

      assert {:error, {:invalid, :no_files}} =
               Artifacts.push({:run, run}, work_item, "explainer", [])

      refute_receive {:artifact_pushed, _work_item_id, _version_id}
    end
  end

  describe "the rows" do
    test "go with their work item", %{run: run} = context do
      {:ok, _version} = Artifacts.push({:run, run}, context.work_item, "explainer", [doc()])
      Repo.delete!(context.work_item)
      assert {count(Artifact), count(Version), count(ArtifactFile)} == {0, 0, 0}
    end

    test "keep a run's version once its run of the queue goes", %{run: run} = context do
      {:ok, version} = Artifacts.push({:run, run}, context.work_item, "explainer", [doc()])
      Repo.delete_all(from r in Apiary.Runs.Run, where: r.dispatch_run_id == ^run.id)
      Repo.delete!(run)
      assert %Version{writer: :run, run_id: nil} = Repo.get!(Version, version.id)
    end
  end
end
