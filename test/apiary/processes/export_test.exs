defmodule Apiary.Processes.ExportTest do
  # A workspace's process as a `process.yaml` (`Apiary.Processes.export/1`): the file
  # validates against qory's `process.schema.json`, `Apiary.Harnesses.Reader` reads it
  # back, and a string keeps its characters through the YAML.
  #
  # Not async: each test sets the instance's features, which are the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.MachineTypesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Artifacts, Organisations, Processes, Stacks}
  alias Apiary.Artifacts.{TemplateTypes, Type}
  alias Apiary.Harnesses.Reader
  alias Apiary.Kinds.Schema
  alias Apiary.Organisations.Workspace
  alias Apiary.Processes.{TypeTemplate, TypeTemplates}

  @moduletag with_features: Apiary.Features.all()

  # Every standard type no workspace has to show, in Core's order.
  @seven ~w(acceptance-criteria explainer decision-record mockup screenshot demo-video change)

  @schema ["contract", "harness", "v1", "process.schema.json"]

  setup do
    # A sign-up's workspace is made from the Qory template; `workspace_fixture/2` makes one
    # with no template, and `Apiary.Processes.current/1` inserts its first version.
    %{scope: signed_up, user: user} = sign_up_fixture()
    workspace = workspace_fixture(signed_up.organisation, "Web shop")

    %{
      scope: workspace_scope(user, workspace),
      workspace: workspace,
      templated: signed_up.workspace
    }
  end

  defp stored(workspace), do: Repo.get!(Workspace, workspace.id)

  # The file of `workspace`, parsed, valid against the schema, and read as a template.
  defp exported(workspace) do
    bytes = Processes.export(workspace)
    assert {:ok, file} = Reader.parse(bytes)
    assert Schema.valid?(file, Schema.file!(@schema, &Schema.code_point_lengths/1))
    assert {:ok, template} = Reader.template(bytes)
    assert TemplateTypes.check(template) == :ok
    template
  end

  defp saved!(scope, document) do
    assert {:ok, version} = Processes.save(scope, scope.workspace, document)
    version
  end

  defp current(workspace), do: Processes.current(workspace).document

  # The document with the first stage's `field` set to `value`.
  defp with_stage_field(document, field, value) do
    update_in(document["stages"], fn [first | rest] -> [Map.put(first, field, value) | rest] end)
  end

  defp with_note(scope, note) do
    version = saved!(scope, with_stage_field(current(scope.workspace), "note", note))
    version.document
  end

  # The document with a gate on its first two stages that lists the people `ids`.
  defp named_gates(document, ids) do
    gate = %{"kind" => "person", "approvers" => %{"members" => ids}}

    update_in(document["stages"], fn [first, second | rest] ->
      [Map.put(first, "gate", gate), Map.put(second, "gate", gate) | rest]
    end)
  end

  defp custom!(scope, attrs) do
    assert {:ok, type} = Artifacts.create_type(scope, scope.workspace, attrs)
    type
  end

  defp texts!(summary, description) do
    %{scope: admin, user: user} = sign_up_fixture()
    {:ok, _user} = Organisations.grant_instance_admin(user)
    newest = TypeTemplates.newest("qory.software")
    # A stage description no other save writes, so the document changes.
    described =
      update_in(newest.document, ["stages", Access.at(0)], fn stage ->
        Map.put(stage, "description", "Version #{System.unique_integer([:positive])}.")
      end)

    assert {:ok, %TypeTemplate{}} =
             TypeTemplates.save(
               admin,
               "qory.software",
               described,
               texts: %{summary: summary, description: description}
             )
  end

  describe "the file validates against process.schema.json and reads back" do
    test "for a workspace made with no template", %{workspace: workspace} do
      template = exported(workspace)

      assert template.process == current(workspace)
      assert template.name == workspace.name
      assert template.type == "qory.software"
      assert template.stack == "core"
      assert Enum.map(template.artifact_types, & &1["name"]) == @seven
      assert Enum.all?(template.artifact_types, &(map_size(&1) == 1))
    end

    test "for a workspace made from the Qory template", %{templated: workspace} do
      assert Processes.current(workspace).template["source"] == "qory"

      template = exported(workspace)

      assert template.stack == workspace.qory_stack
      assert template.stack != "core"
      assert template.process == current(workspace)

      assert template.artifact_types |> Enum.filter(&(map_size(&1) > 1)) |> Enum.map(& &1["name"]) ==
               workspace
               |> Artifacts.all_types()
               |> Enum.reject(& &1.standard)
               |> Enum.map(& &1.name)

      assert "branch" in Enum.map(template.artifact_types, & &1["name"])
    end

    test "for a workspace with hidden types, with custom types after the shown ones", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, _} = Artifacts.switch_type(scope, workspace, "screenshot", false)
      {:ok, _} = Artifacts.switch_type(scope, workspace, "demo-video", false)

      custom!(scope, %{"name" => "report", "base_view" => "document"})

      custom!(scope, %{
        "name" => "bid-set",
        "base_view" => "structured",
        "json_schema" => %{"type" => "object", "required" => ["bids"]}
      })

      assert exported(workspace).artifact_types ==
               Enum.map(@seven -- ["screenshot", "demo-video"], &%{"name" => &1}) ++
                 [
                   %{
                     "name" => "bid-set",
                     "base_view" => "structured",
                     "size_limit" => 1_048_576,
                     "max_files" => 1,
                     "json_schema" => %{"type" => "object", "required" => ["bids"]}
                   },
                   %{
                     "name" => "report",
                     "base_view" => "document",
                     "size_limit" => 1_048_576,
                     "max_files" => 1
                   }
                 ]
    end

    test "reads the shown types from the database, not from a stale struct", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, _} = Artifacts.switch_type(scope, workspace, "mockup", false)

      refute "mockup" in Enum.map(exported(workspace).artifact_types, & &1["name"])
    end

    test "writes a gate that lists people as all members, and changes nothing else", %{
      scope: scope,
      workspace: workspace
    } do
      saved!(scope, named_gates(current(workspace), [scope.user.id]))
      saved = current(workspace)
      all_members = %{"kind" => "person", "approvers" => "members"}

      template = exported(workspace)

      assert [%{"gate" => ^all_members}, %{"gate" => ^all_members} | rest] =
               template.process["stages"]

      assert rest == Enum.drop(saved["stages"], 2)

      assert Enum.map(template.process["stages"], &Map.delete(&1, "gate")) ==
               Enum.map(saved["stages"], &Map.delete(&1, "gate"))

      refute Processes.export(workspace) =~ scope.user.id
    end

    test "writes each machine type key as the document has it, which the harness reader reads", %{
      scope: scope,
      workspace: workspace
    } do
      large = machine_type_fixture(%{key: "large"})

      typed =
        current(workspace)
        |> Map.put("machine", large.key)
        |> update_in(["stages", Access.at(0), "sequence"], fn _sequence ->
          [
            %{"workflow" => "explore-a-ticket", "machine" => large.key},
            %{"workflow" => "shape", "machine" => "default"},
            %{
              "loop" => %{"rounds" => 2, "body" => [%{"workflow" => "fix", "machine" => "large"}]}
            }
          ]
        end)

      saved!(scope, typed)
      saved = current(workspace)
      assert saved["machine"] == "large"

      template = exported(workspace)

      assert template.process["machine"] == "large"

      assert hd(template.process["stages"])["sequence"] == [
               %{"workflow" => "explore-a-ticket", "machine" => "large"},
               %{"workflow" => "shape", "machine" => "default"},
               %{
                 "loop" => %{
                   "rounds" => 2,
                   "body" => [%{"workflow" => "fix", "machine" => "large"}]
                 }
               }
             ]

      assert tl(template.process["stages"]) == tl(saved["stages"])
    end
  end

  describe "the YAML" do
    test "starts with the keys in the table's order, each a quoted string", ctx do
      lines = String.split(Processes.export(ctx.workspace), "\n")

      assert Enum.at(lines, 0) == ~s("apiVersion": "qory.dev/v1alpha1")
      assert Enum.at(lines, 1) == ~s("name": "#{ctx.workspace.name}")

      keys =
        for line <- lines, [_, key] <- [Regex.run(~r/^"([a-zA-Z_]+)":/, line)], do: key

      assert keys == ~w(apiVersion name summary description type stack process artifact_types)
    end

    test "writes the same bytes twice, with the keys of a json_schema sorted", %{
      scope: scope,
      workspace: workspace
    } do
      # A map of more than 32 keys does not iterate in sorted order.
      names = many_keys()

      custom!(scope, %{
        "name" => "bid-set",
        "base_view" => "structured",
        "json_schema" => %{"type" => "object", "properties" => Map.new(names, &{&1, %{}})}
      })

      bytes = Processes.export(workspace)
      properties = Enum.map_join(names, ", ", &~s("#{&1}": {}))

      assert bytes == Processes.export(workspace)
      assert bytes =~ ~s(  "json_schema": {"properties": {#{properties}}, "type": "object"}\n)
    end

    test "sorts the keys inside process", %{scope: scope, workspace: workspace} do
      # A map of more than 32 keys does not iterate in sorted order.
      document = Enum.reduce(many_keys(), current(workspace), &with_stage_field(&2, &1, 1))
      saved!(scope, document)

      lines = String.split(Processes.export(workspace), "\n")

      # The keys of the first stage, from the `- ` of its first key to the next stage.
      first = Enum.find_index(lines, &String.starts_with?(&1, ~s(    - "field-)))

      stage =
        lines |> Enum.drop(first + 1) |> Enum.take_while(&(!String.starts_with?(&1, "    - ")))

      keys =
        for line <- stage, [_, key] <- [Regex.run(~r/^      "([a-z0-9_-]+)":/, line)], do: key

      assert length(keys) > 32
      assert keys == Enum.sort(keys)
    end

    test "writes an empty mapping, an empty list, a null, a boolean and a number as such", %{
      scope: scope,
      workspace: workspace
    } do
      document =
        current(workspace)
        |> with_stage_field("map", %{})
        |> with_stage_field("list", [])
        |> with_stage_field("nothing", nil)
        |> with_stage_field("yes", true)
        |> with_stage_field("count", 3)
        |> with_stage_field("share", 0.5)
        |> with_stage_field("whole", 1.0)
        |> with_stage_field("text", "null")

      saved!(scope, document)

      bytes = Processes.export(workspace)

      for line <- [
            ~s("map": {}\n),
            ~s("list": []\n),
            ~s("nothing": null\n),
            ~s("yes": true\n),
            ~s("count": 3\n),
            ~s("share": 0.5\n),
            ~s("whole": 1.0\n),
            ~s("text": "null"\n)
          ],
          do: assert(bytes =~ line)

      assert exported(workspace).process === current(workspace)
    end

    test "keeps nested lists, and numbers of every kind in a json_schema", %{
      scope: scope,
      workspace: workspace
    } do
      saved!(scope, with_stage_field(current(workspace), "grid", [[1, 2], [%{"a" => [3]}], []]))

      schema = %{
        "type" => "object",
        "default" => nil,
        "properties" => %{
          "share" => %{
            "minimum" => 0.5,
            "maximum" => 1.0,
            "exclusiveMaximum" => 1.0e20,
            "multipleOf" => 1.5e-7
          }
        },
        "enum" => [1, -2, true, false, nil, "text", [], %{}]
      }

      type =
        custom!(scope, %{
          "name" => "bid-set",
          "base_view" => "structured",
          "json_schema" => schema
        })

      stored = Repo.reload!(type).json_schema

      # jsonb keeps 1.0e20 as the number with no decimal point, which reads as an integer.
      assert stored["properties"]["share"]["exclusiveMaximum"] === 100_000_000_000_000_000_000
      assert stored["properties"]["share"]["maximum"] === 1.0

      template = exported(workspace)

      assert template.process === current(workspace)

      assert Enum.find(template.artifact_types, &(&1["name"] == "bid-set"))["json_schema"] ===
               stored
    end

    test "fits a json_schema of nearly 64 KiB into the reader's budget", %{
      scope: scope,
      workspace: workspace
    } do
      custom!(scope, %{
        "name" => "bid-set",
        "base_view" => "structured",
        "json_schema" => %{"type" => "object", "properties" => properties(1_000)}
      })

      assert byte_size(Processes.export(workspace)) in 50_000..65_536
      assert %{artifact_types: _types} = exported(workspace)
    end

    test "writes a file over the reader's limit of bytes", %{
      scope: scope,
      workspace: workspace
    } do
      for name <- ["bid-set", "bid-sum"] do
        custom!(scope, %{
          "name" => name,
          "base_view" => "structured",
          "json_schema" => %{"type" => "object", "properties" => properties(700)}
        })
      end

      assert byte_size(Processes.export(workspace)) > Reader.max_bytes()
      assert Reader.template(Processes.export(workspace)) == {:error, :too_large}
    end

    test "writes a json_schema deeper than the reader's limit", %{
      scope: scope,
      workspace: workspace
    } do
      nested = Enum.reduce(1..16, %{"type" => "object"}, &%{"properties" => %{"a#{&1}" => &2}})

      custom!(scope, %{"name" => "bid-set", "base_view" => "structured", "json_schema" => nested})

      assert Reader.template(Processes.export(workspace)) == {:error, :too_deep}
    end
  end

  # 40 keys, in the sorted order of their bytes.
  defp many_keys, do: Enum.map(10..49, &"field-#{&1}")

  defp properties(count),
    do: Map.new(1..count, &{"field-#{&1}", %{"type" => "string", "description" => "Field #{&1}"}})

  describe "a string" do
    @strings [
      ~s(a "quoted" word),
      "a back\\slash",
      "two\nlines",
      "ends with a line break\n",
      "a\ttab",
      "a carriage\rreturn",
      "Crème brûlée, 日本語, Ελληνικά",
      "an emoji 😀 above U+FFFF, 𝒜 too",
      "a line\u2028separator and a paragraph\u2029separator",
      "a byte order mark \uFEFF and a noncharacter \uFFFE\uFFFF",
      "  spaces around  ",
      "null",
      "true",
      "12",
      "~",
      "- a: [b] # c",
      "%{not} {{a}} 'template' *alias &anchor !tag |",
      ""
    ]

    test "survives in a process and in a key", %{scope: scope, workspace: workspace} do
      for string <- @strings do
        with_note(scope, string)
        assert hd(exported(workspace).process["stages"])["note"] == string
      end

      for string <- @strings -- [""] do
        saved!(scope, with_stage_field(current(workspace), string, 1))
        assert hd(exported(workspace).process["stages"])[string] == 1
      end
    end

    test "writes the characters YAML does not allow in a file as escapes", %{
      scope: scope,
      workspace: workspace
    } do
      with_note(scope, "a\u2028b\u2029c\uFEFFd\uFFFEe\uFFFFf")

      bytes = Processes.export(workspace)

      assert bytes =~ ~S("note": "a\u2028b\u2029c\uFEFFd\uFFFEe\uFFFFf")

      for raw <- ["\u2028", "\u2029", "\uFEFF", "\uFFFE", "\uFFFF"],
          do: refute(String.contains?(bytes, raw))
    end

    test "survives in a json_schema", %{scope: scope, workspace: workspace} do
      schema = %{"type" => "object", "description" => "x", "enum" => @strings}

      custom!(scope, %{"name" => "bid-set", "base_view" => "structured", "json_schema" => schema})

      assert Enum.find(exported(workspace).artifact_types, &(&1["name"] == "bid-set"))[
               "json_schema"
             ] == schema
    end

    test "writes U+0085 and U+2028 as escapes, which YAML does not fold", %{
      scope: scope,
      workspace: workspace
    } do
      with_note(scope, "next\u0085line and line\u2028separator")

      bytes = Processes.export(workspace)

      assert bytes =~ ~S("note": "next\u0085line and line\u2028separator")

      assert [{:yamerl_doc, root}] =
               :yamerl_constr.string(bytes, detailed_constr: true, str_node_as_binary: true)

      assert yaml_strings(root) |> Enum.member?("next\u0085line and line\u2028separator")
    end

    test "U+0085 and the other control characters in a process: the reader returns an error",
         %{scope: scope, workspace: workspace} do
      for character <- ["\u0085", "\u0001", "\u007F"] do
        with_note(scope, "a#{character}b")
        assert Reader.template(Processes.export(workspace)) == {:error, :control_character}
      end
    end
  end

  # Every text of a yamerl node.
  defp yaml_strings({:yamerl_map, _module, _tag, _place, pairs}),
    do: Enum.flat_map(pairs, fn {_key, value} -> yaml_strings(value) end)

  defp yaml_strings({:yamerl_seq, _module, _tag, _place, items, _count}),
    do: Enum.flat_map(items, &yaml_strings/1)

  defp yaml_strings({:yamerl_str, _module, _tag, _place, text}), do: [text]
  defp yaml_strings(_node), do: []

  describe "a long key" do
    @long String.duplicate("k", 1_100)

    # 600 characters, with 1,200 bytes of escapes.
    @escaped String.duplicate("\"", 600)

    test "in a block is an explicit key, which the reader reads", %{
      scope: scope,
      workspace: workspace
    } do
      saved!(
        scope,
        current(workspace)
        |> with_stage_field(@long, %{"nested" => [1, %{@long => "value"}]})
        |> with_stage_field("short", 1)
      )

      bytes = Processes.export(workspace)

      assert bytes =~ ~s(? "#{@long}"\n      :\n        "nested":\n)
      assert bytes =~ ~s(- ? "#{@long}"\n)
      assert exported(workspace).process === current(workspace)
    end

    test "in flow is an explicit key, which the reader reads", %{
      scope: scope,
      workspace: workspace
    } do
      schema = %{
        "type" => "object",
        "default" => %{@long => 1, "short" => 2},
        "properties" => %{"a" => %{"default" => [%{@long => %{}}]}}
      }

      custom!(scope, %{"name" => "bid-set", "base_view" => "structured", "json_schema" => schema})

      assert Processes.export(workspace) =~ ~s({? "#{@long}" : 1, "short": 2})

      assert Enum.find(exported(workspace).artifact_types, &(&1["name"] == "bid-set"))[
               "json_schema"
             ] === schema
    end

    test "counts the bytes of its escapes", %{scope: scope, workspace: workspace} do
      saved!(scope, with_stage_field(current(workspace), @escaped, 1))

      custom!(scope, %{
        "name" => "bid-set",
        "base_view" => "structured",
        "json_schema" => %{"type" => "object", "default" => %{@escaped => 1}}
      })

      written = String.duplicate(~S(\"), 600)
      template = exported(workspace)

      assert Processes.export(workspace) =~ ~s(? "#{written}"\n      : 1\n)
      assert Processes.export(workspace) =~ ~s({? "#{written}" : 1})
      assert template.process === current(workspace)
    end

    test "stays implicit up to 1,000 written bytes", %{scope: scope, workspace: workspace} do
      fits = String.duplicate("k", 998)
      over = String.duplicate("j", 999)

      saved!(
        scope,
        current(workspace) |> with_stage_field(fits, 1) |> with_stage_field(over, 2)
      )

      bytes = Processes.export(workspace)

      assert bytes =~ ~s(      "#{fits}": 1\n)
      assert bytes =~ ~s(? "#{over}"\n      : 2\n)
      assert exported(workspace).process === current(workspace)
    end
  end

  describe "the name" do
    defp renamed(workspace, name),
      do: workspace |> Workspace.changeset(%{name: name}) |> Repo.update!()

    test "keeps a short name with quotes", %{workspace: workspace} do
      assert exported(renamed(workspace, ~s(Acme "Web shop")))
             |> Map.fetch!(:name) == ~s(Acme "Web shop")
    end

    test "cuts a name of 120 characters to 60 code points", %{workspace: workspace} do
      assert exported(renamed(workspace, String.duplicate("a", 120))).name ==
               String.duplicate("a", 60)
    end

    test "counts code points, with a character of two bytes at position 60", %{
      workspace: workspace
    } do
      name = String.duplicate("a", 59) <> "é" <> String.duplicate("b", 60)

      assert exported(renamed(workspace, name)).name == String.duplicate("a", 59) <> "é"
    end

    test "counts code points, with an emoji above U+FFFF at position 60", %{workspace: workspace} do
      name = String.duplicate("a", 59) <> "😀" <> String.duplicate("b", 60)

      assert exported(renamed(workspace, name)).name == String.duplicate("a", 59) <> "😀"
    end

    test "drops whole a character of two code points across position 60", %{workspace: workspace} do
      name = String.duplicate("a", 59) <> "e\u0301" <> String.duplicate("b", 59)

      assert String.length(name) == 119
      assert exported(renamed(workspace, name)).name == String.duplicate("a", 59)
    end

    test "cuts graphemes that count more code points than characters", %{workspace: workspace} do
      # 40 graphemes of 2 code points: 80 code points, which String.length/1 counts as 40.
      name = String.duplicate("e\u0301", 40)

      assert exported(renamed(workspace, name)).name == String.duplicate("e\u0301", 30)
    end

    test "drops whole an emoji sequence across position 60", %{workspace: workspace} do
      family = "👩\u200D👩\u200D👧"
      name = String.duplicate("a", 58) <> family <> "b"

      assert exported(renamed(workspace, name)).name == String.duplicate("a", 58)
    end

    test "cuts inside a first character longer than the limit", %{workspace: workspace} do
      name = "a" <> String.duplicate("\u0301", 70)

      assert exported(renamed(workspace, name)).name == "a" <> String.duplicate("\u0301", 59)
    end

    test "trims what the cut leaves", %{workspace: workspace} do
      name = String.duplicate("a", 30) <> String.duplicate(" ", 40) <> "b"

      assert exported(renamed(workspace, name)).name == String.duplicate("a", 30)
    end

    test "leaves text after a long run of leading spaces", %{workspace: workspace} do
      {1, _} =
        Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
          set: [name: "\u00A0" <> String.duplicate(" ", 70) <> "Web shop"]
        )

      assert exported(stored(workspace)).name == "Web shop"
    end
  end

  describe "the texts" do
    test "are the workspace type's, where it has them", %{workspace: workspace} do
      texts!("Agents work on tickets.", "Each ticket goes through the stages.")

      template = exported(workspace)

      assert template.summary == "Agents work on tickets."
      assert template.description == "Each ticket goes through the stages."
    end

    test "are the release's where the version has none", %{workspace: workspace} do
      texts = Processes.type_text_defaults("qory.software")

      template = exported(workspace)

      assert template.summary == texts.summary
      assert template.description == texts.description
    end

    test "fall back to the workspace's name for a type with no texts", %{workspace: workspace} do
      workspace = %{workspace | type: "qory.other"}
      fallback = "Exported from the workspace Web shop."

      assert %{summary: ^fallback, description: ^fallback, type: "qory.other"} =
               exported(workspace)
    end

    test "fall back when a blank text is stored" do
      %{scope: scope} = sign_up_fixture()
      newest = TypeTemplates.newest("qory.software")

      {1, _} =
        Repo.update_all(from(t in TypeTemplate, where: t.id == ^newest.id),
          set: [summary: "   ", description: " \n "]
        )

      fallback = "Exported from the workspace #{scope.workspace.name}."

      assert %{summary: ^fallback, description: ^fallback} = exported(scope.workspace)
    end

    test "fall back for a description the save's count passes and the schema's does not", %{
      workspace: workspace
    } do
      # String.split/1 keeps a no-break space inside a word: one word for the save, and 100
      # words for the schema, whose \s reads every Unicode space.
      description = Enum.map_join(1..100, "\u00A0", &"w#{&1}")

      texts!("Agents work on tickets.", description)

      assert exported(workspace).description == "Exported from the workspace #{workspace.name}."
    end

    test "fall back for a text over the limit in code points and within it in graphemes", %{
      workspace: workspace
    } do
      # The table's check keeps a stored text within the limits. The release's texts have
      # no such check, so the test takes it away, inside this test's transaction.
      Repo.query!(
        "ALTER TABLE type_template_versions DROP CONSTRAINT type_template_versions_texts_check"
      )

      summary = String.duplicate("e\u0301", 150)
      description = Enum.map_join(1..80, " ", fn _word -> String.duplicate("e\u0301", 10) end)
      newest = TypeTemplates.newest("qory.software")

      assert String.length(summary) <= 200
      assert String.length(description) <= 1200
      assert length(String.split(description)) == 80

      {1, _} =
        Repo.update_all(from(t in TypeTemplate, where: t.id == ^newest.id),
          set: [summary: summary, description: description]
        )

      fallback = "Exported from the workspace Web shop."

      assert %{summary: ^fallback, description: ^fallback} = exported(workspace)
    end

    test "keep a description of 80 words", %{workspace: workspace} do
      description = Enum.map_join(1..80, " ", &"w#{&1}")

      texts!("Agents work on tickets.", description)

      assert exported(workspace).description == description
    end

    test "fall back for a text with a control character", %{
      workspace: workspace
    } do
      texts!("Agents work\u0085on tickets.", "Each ticket\u0001 goes through the stages.")

      fallback = "Exported from the workspace #{workspace.name}."

      assert %{summary: ^fallback, description: ^fallback} = exported(workspace)
    end

    test "take a long name with quotes in the fallback, within the limits", %{
      workspace: workspace
    } do
      name = ~s(" ) <> String.duplicate("a ", 58) <> "b"
      workspace = %{renamed(workspace, name) | type: "qory.other"}

      assert exported(workspace).description == "Exported from the workspace #{name}."
    end
  end

  describe "the stack" do
    defp base(field),
      do: "extends: {git: https://code.example.com/team/stacks, ref: main, #{field}}\n"

    test "is the stack of the harness choice's base", %{scope: scope, workspace: workspace} do
      {:ok, _row} =
        Stacks.put_stack(scope, {:workspace, workspace}, base("stack: web-shop"),
          choice: :repository
        )

      assert exported(workspace).stack == "web-shop"
    end

    test "is qory_stack/1 for a choice given by path, which has no stack name", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, _row} =
        Stacks.put_stack(scope, {:workspace, workspace}, base("path: stacks/web"),
          choice: :repository
        )

      assert exported(workspace).stack == "core"
    end
  end

  describe "the version" do
    test "is the current one: a trial is not exported", %{scope: scope, workspace: workspace} do
      trial = with_stage_field(current(workspace), "note", "the trial")
      assert {:ok, _trial} = Processes.save(scope, workspace, trial, trial: true)

      assert exported(workspace).process == current(workspace)
      refute Processes.export(workspace) =~ "the trial"
    end

    test "a new version replaces it", %{scope: scope, workspace: workspace} do
      before = Processes.export(workspace)
      with_note(scope, "a new version")

      refute Processes.export(workspace) == before
      assert Processes.export(workspace) =~ "a new version"
    end
  end

  test "the types leave out what no workspace can hide", %{workspace: workspace} do
    names = Enum.map(exported(workspace).artifact_types, & &1["name"])

    assert names -- Type.always_on() == names
  end
end
