defmodule Apiary.Artifacts.TemplateTypesTest do
  # The artifact types of a factory's process.yaml: the check of the list, its refusals'
  # texts, and what a new workspace gets from a checked template.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Artifacts
  alias Apiary.Artifacts.{CustomSchema, TemplateTypes, Type}
  alias Apiary.Audit.Entry
  alias Apiary.Harnesses.Reader
  alias Apiary.Organisations.Workspace

  @sources Path.expand("../../fixtures/harness/v1/sources", __DIR__)

  @document %{
    "name" => "reply-draft",
    "base_view" => "document",
    "size_limit" => 65_536,
    "max_files" => 1
  }

  @structured %{
    "name" => "customer-facts",
    "base_view" => "structured",
    "size_limit" => 65_536,
    "max_files" => 1,
    "json_schema" => %{"type" => "object", "required" => ["customer"]}
  }

  # The fields of a template that the module reads.
  defp template(listed, stages \\ []) do
    %{
      artifact_types: listed,
      process: %{"schema" => "qory.process/v1", "stages" => stages}
    }
  end

  defp stage(name, inputs, outputs) do
    %{
      "name" => name,
      "inputs" => Enum.map(inputs, &%{"type" => &1}),
      "outputs" => Enum.map(outputs, &%{"type" => &1, "required" => true})
    }
  end

  defp names(names), do: Enum.map(names, &%{"name" => &1})

  describe "check/1" do
    test "takes a template without the key, whatever its process names" do
      assert :ok = TemplateTypes.check(template(nil, [stage("Answer", ["mockup"], ["no-type"])]))
    end

    test "takes a template read from a file without the key" do
      path = Path.join(@sources, "factory/modules/support-desk/process.yaml")
      assert {:ok, template} = path |> File.read!() |> Reader.template()
      assert TemplateTypes.check(template) == :ok
    end

    test "takes standard names and full definitions" do
      assert :ok = TemplateTypes.check(template([%{"name" => "mockup"}, @document, @structured]))
    end

    test "takes an empty list" do
      assert :ok = TemplateTypes.check(template([]))
    end

    test "refuses a name alone that is not a standard type" do
      assert TemplateTypes.check(template(names(["mockup", "reply-draft"]))) ==
               {:error, [{:not_standard, "reply-draft"}]}
    end

    test "refuses a custom type with a standard name, and does not check its definition" do
      assert TemplateTypes.check(template([%{@document | "name" => "mockup"}])) ==
               {:error, [{:standard_name, "mockup"}]}
    end

    test "refuses a stage's input and output that the list does not have" do
      stages = [stage("Answer", ["mockup"], ["screenshot", "reply-draft"])]

      assert TemplateTypes.check(template(names(["screenshot"]), stages)) ==
               {:error,
                [{:not_listed, "Answer", "mockup"}, {:not_listed, "Answer", "reply-draft"}]}
    end

    test "refuses a type once per stage" do
      stages = [stage("Answer", ["mockup"], ["mockup"]), stage("Check", ["mockup"], [])]

      assert TemplateTypes.check(template([], stages)) ==
               {:error, [{:not_listed, "Answer", "mockup"}, {:not_listed, "Check", "mockup"}]}
    end

    test "takes a stage's listed types, custom types among them" do
      stages = [stage("Answer", ["screenshot"], ["reply-draft"])]
      assert :ok = TemplateTypes.check(template([%{"name" => "screenshot"}, @document], stages))
    end

    test "needs no listing of an always-on type" do
      stages = [stage("Answer", Type.always_on(), Type.always_on())]
      assert :ok = TemplateTypes.check(template([], stages))
    end

    test "refuses a definition the changeset refuses, by the field that failed" do
      for {change, error} <- [
            {%{"name" => "Reply draft"}, :name},
            {%{"base_view" => "spreadsheet"}, :base_view},
            {%{"size_limit" => 10_485_761}, {:size_limit, :document}},
            {%{"size_limit" => 1.5}, {:size_limit, :document}},
            {%{"max_files" => 21}, {:max_files, :document}},
            {%{"json_schema" => %{}}, :json_schema}
          ] do
        entry = Map.merge(@document, change)

        assert TemplateTypes.check(template([entry])) ==
                 {:error, [{:invalid, entry["name"], error}]}
      end
    end

    test "takes a withdrawable that is true or false, and refuses any other value" do
      for value <- [true, false] do
        assert :ok = TemplateTypes.check(template([Map.put(@document, "withdrawable", value)]))
      end

      for value <- ["false", 0, 1, nil, %{}, []] do
        entry = Map.put(@document, "withdrawable", value)

        assert TemplateTypes.check(template([entry])) ==
                 {:error, [{:invalid, "reply-draft", :withdrawable}]}
      end
    end

    test "takes a standard type with withdrawable alone beside its name" do
      for value <- [true, false] do
        entry = %{"name" => "mockup", "withdrawable" => value}
        assert :ok = TemplateTypes.check(template([entry, @document]))
      end
    end

    test "refuses a standard entry whose withdrawable is not a boolean, once per entry" do
      for value <- ["false", 0, nil, []] do
        entry = %{"name" => "mockup", "withdrawable" => value}

        assert TemplateTypes.check(template([entry])) ==
                 {:error, [{:invalid, "mockup", :withdrawable}]}
      end
    end

    test "an entry with another key beside the name of a standard type is a custom type" do
      for extra <- [%{"base_view" => "image"}, %{"size_limit" => 10}, %{"max_files" => 1}] do
        entry = Map.merge(%{"name" => "mockup", "withdrawable" => false}, extra)
        assert TemplateTypes.check(template([entry])) == {:error, [{:standard_name, "mockup"}]}
      end
    end

    test "a name that is no standard type is not standard with withdrawable beside it" do
      entry = %{"name" => "reply-draft", "withdrawable" => false}
      assert TemplateTypes.check(template([entry])) == {:error, [{:not_standard, "reply-draft"}]}
    end

    test "refuses a standard name listed with withdrawable and without, once" do
      listed = [%{"name" => "mockup"}, %{"name" => "mockup", "withdrawable" => false}]
      assert TemplateTypes.check(template(listed)) == {:error, [{:repeated, "mockup"}]}
    end

    test "refuses a schema CustomSchema refuses" do
      for schema <- [%{"type" => 5}, %{"$ref" => "https://example.com/remote.json"}] do
        entry = %{@structured | "json_schema" => schema}

        assert TemplateTypes.check(template([entry])) ==
                 {:error, [{:invalid, "customer-facts", :json_schema}]}
      end
    end

    test "stops at the first definition that fails" do
      first = %{@structured | "json_schema" => %{"type" => 5}}
      second = %{@document | "size_limit" => 10_485_761}

      assert TemplateTypes.check(template([first, second])) ==
               {:error, [{:invalid, "customer-facts", :json_schema}]}
    end

    test "gives every kind of refusal together, in order" do
      listed = [
        %{"name" => "reply-draft"},
        %{@document | "name" => "mockup"},
        %{@structured | "json_schema" => %{"type" => 5}}
      ]

      assert TemplateTypes.check(template(listed, [stage("Answer", ["walkthrough"], [])])) ==
               {:error,
                [
                  {:not_standard, "reply-draft"},
                  {:standard_name, "mockup"},
                  {:not_listed, "Answer", "walkthrough"},
                  {:invalid, "customer-facts", :json_schema}
                ]}
    end

    test "refuses a custom name listed more than once, one refusal per name" do
      listed = [@document, @structured, @document, @document]

      assert TemplateTypes.check(template(listed)) ==
               {:error, [{:invalid, "reply-draft", :repeated}]}
    end

    test "refuses a repeated name after the stages and before the definitions" do
      bad = %{@structured | "json_schema" => %{"type" => 5}}
      listed = [@document, @document, bad]

      assert TemplateTypes.check(template(listed, [stage("Answer", ["walkthrough"], [])])) ==
               {:error,
                [
                  {:not_listed, "Answer", "walkthrough"},
                  {:invalid, "reply-draft", :repeated},
                  {:invalid, "customer-facts", :json_schema}
                ]}
    end

    test "refuses a standard name listed more than once, once per name" do
      assert TemplateTypes.check(template(names(["mockup", "mockup", "mockup", "screenshot"]))) ==
               {:error, [{:repeated, "mockup"}]}

      assert TemplateTypes.check(
               template(names(["mockup", "walkthrough", "mockup", "walkthrough"]))
             ) ==
               {:error, [{:repeated, "mockup"}, {:repeated, "walkthrough"}]}
    end

    test "a name of no standard type listed twice is only the refusal of that type" do
      assert TemplateTypes.check(template(names(["reply-draft", "reply-draft"]))) ==
               {:error, [{:not_standard, "reply-draft"}]}
    end

    test "a standard name listed twice comes after a stage's type and before a custom type" do
      listed = [
        @document,
        %{"name" => "mockup"},
        %{"name" => "mockup"},
        @document
      ]

      assert TemplateTypes.check(template(listed, [stage("Answer", ["walkthrough"], [])])) ==
               {:error,
                [
                  {:not_listed, "Answer", "walkthrough"},
                  {:repeated, "mockup"},
                  {:invalid, @document["name"], :repeated}
                ]}
    end

    test "a standard name beside a custom type of that name is only that refusal" do
      listed = [%{"name" => "mockup"}, %{@document | "name" => "mockup"}]

      assert TemplateTypes.check(template(listed)) == {:error, [{:standard_name, "mockup"}]}
    end

    test "a repeated custom type with a standard name is only that refusal" do
      entry = %{@document | "name" => "mockup"}

      assert TemplateTypes.check(template([entry, entry])) ==
               {:error, [{:standard_name, "mockup"}]}
    end

    test "does not raise on odd shapes of the process" do
      for stages <- [
            [1, "Answer", nil, []],
            [%{}],
            [%{"name" => "Answer", "inputs" => "mockup", "outputs" => %{"type" => "mockup"}}],
            [%{"name" => "Answer", "inputs" => nil, "outputs" => 1}],
            [%{"name" => "Answer", "inputs" => [1, "mockup", nil, [], %{}]}],
            [%{"name" => "Answer", "inputs" => [%{"type" => 1}, %{"type" => %{}}]}],
            [%{"name" => 1, "inputs" => [%{"type" => "mockup"}]}],
            [%{"inputs" => [%{"type" => "mockup"}]}]
          ] do
        assert :ok = TemplateTypes.check(template([], stages))
      end

      assert :ok = TemplateTypes.check(%{artifact_types: [], process: %{"stages" => "Answer"}})
      assert :ok = TemplateTypes.check(%{artifact_types: [], process: %{}})
      assert :ok = TemplateTypes.check(%{artifact_types: [], process: nil})
    end

    test "reads a stage's type beside odd entries" do
      inputs = [1, %{"type" => "mockup"}]

      assert TemplateTypes.check(template([], [%{"name" => "Answer", "inputs" => inputs}])) ==
               {:error, [{:not_listed, "Answer", "mockup"}]}
    end
  end

  describe "the check of submit" do
    defp with_submit(template, type, send \\ "after_gate"),
      do: Map.put(template, :submit, %{"type" => type, "send" => send})

    test "takes a submit that names a structured custom type of the list" do
      for send <- ["end_of_run", "after_gate"] do
        submitted = with_submit(template([@document, @structured]), "customer-facts", send)
        assert TemplateTypes.check(submitted) == :ok
        assert TemplateTypes.check_submit(submitted) == :ok
      end
    end

    test "takes a template with no submit, or a nil one" do
      assert TemplateTypes.check_submit(template([@document])) == :ok
      assert TemplateTypes.check(Map.put(template([@document]), :submit, nil)) == :ok
    end

    test "refuses a type no entry of the list is named" do
      submitted = with_submit(template([@structured]), "reply-draft")

      assert TemplateTypes.check(submitted) == {:error, [{:submit, "reply-draft", :missing}]}
      assert TemplateTypes.check_submit(submitted) == TemplateTypes.check(submitted)
    end

    test "refuses a type when the template has no artifact_types" do
      submitted = with_submit(template(nil), "customer-facts")

      assert TemplateTypes.check(submitted) == {:error, [{:submit, "customer-facts", :missing}]}
    end

    test "refuses a standard type, listed by its name alone" do
      submitted = with_submit(template([%{"name" => "mockup"}, @structured]), "mockup")

      assert TemplateTypes.check(submitted) == {:error, [{:submit, "mockup", :standard}]}
    end

    test "refuses a custom type of another base view" do
      submitted = with_submit(template([@document, @structured]), "reply-draft")

      assert TemplateTypes.check(submitted) ==
               {:error, [{:submit, "reply-draft", {:base_view, "document"}}]}
    end

    test "refuses a name alone that is no standard name, once in check/1" do
      listed = [%{"name" => "reply-draft"}, @structured]

      assert TemplateTypes.check(with_submit(template(listed), "reply-draft")) ==
               {:error, [{:not_standard, "reply-draft"}]}

      assert TemplateTypes.check_submit(with_submit(template(listed), "reply-draft")) ==
               {:error, [{:not_standard, "reply-draft"}]}
    end

    test "comes after the refusals of the list, and calls a standard name a standard type" do
      listed = [%{"name" => "reply-draft"}, %{"name" => "walkthrough"}, @structured]

      assert {:error, refusals} =
               TemplateTypes.check(with_submit(template(listed), "walkthrough"))

      assert refusals == [{:not_standard, "reply-draft"}, {:submit, "walkthrough", :standard}]

      assert TemplateTypes.message({:submit, "walkthrough", :standard}) ==
               "set submit.type to a structured type of artifact_types: " <>
                 "walkthrough is a standard type"
    end

    test "check_submit/1 makes no other refusal of the list" do
      submitted =
        with_submit(template([%{"name" => "reply-draft"}, @structured]), "customer-facts")

      assert {:error, [{:not_standard, "reply-draft"}]} = TemplateTypes.check(submitted)
      assert TemplateTypes.check_submit(submitted) == :ok
    end

    test "takes a template read from a file with a valid submit" do
      path = Path.join(@sources, "factory/modules/support-desk/process.yaml")

      text =
        File.read!(path) <>
          """
          artifact_types:
            - name: customer-facts
              base_view: structured
              size_limit: 65536
              max_files: 1
              json_schema: {type: object}
          submit:
            type: customer-facts
            send: end_of_run
          """

      assert {:ok, template} = Reader.template(text)
      assert template.submit == %{"type" => "customer-facts", "send" => "end_of_run"}
      assert TemplateTypes.check(template) == :ok
    end
  end

  describe "the total over a template's schemas" do
    # `count` structured definitions, each with a schema of the form `schema.(index)`.
    defp structured(count, schema \\ fn _index -> %{} end) do
      for index <- 1..count,
          do: %{@structured | "name" => "t#{index}", "json_schema" => schema.(index)}
    end

    # The reductions of one build of `{}`, read after a first build has loaded the code.
    defp one_build do
      left = CustomSchema.total(reductions: 1_000_000, ms: 30_000)
      {:ok, _left} = CustomSchema.check_within(%{}, left)
      {:ok, after_one} = CustomSchema.check_within(%{}, left)
      left.reductions - after_one.reductions
    end

    test "stops a loop of schemas that each pass" do
      total = [reductions: one_build() * 10, ms: 30_000]

      assert :ok = TemplateTypes.check(template(structured(1)), total)
      assert :ok = TemplateTypes.check(template(structured(100)))

      assert TemplateTypes.check(template(structured(100)), total) ==
               {:error, [:schemas_too_long]}
    end

    test "stops a loop that has no time left" do
      assert TemplateTypes.check(template(structured(1)), reductions: 1_000_000, ms: 0) ==
               {:error, [:schemas_too_long]}
    end

    test "comes after the other refusals" do
      listed = [%{"name" => "reply-draft"} | structured(2)]

      assert TemplateTypes.check(template(listed), reductions: 0, ms: 0) ==
               {:error, [{:not_standard, "reply-draft"}, :schemas_too_long]}
    end

    test "has its text" do
      assert TemplateTypes.message(:schemas_too_long) ==
               "the JSON Schemas in artifact_types take too long to check: use fewer or smaller schemas"
    end

    test "a schema over the limit of its patterns stays not valid" do
      # 210 patterns, each counted at the most one pattern can take, pass 16 MiB.
      properties = Map.new(1..210, &{"p#{&1}", %{"pattern" => "(?x)a#{&1}"}})
      [entry] = structured(1, fn _index -> %{"properties" => properties} end)

      assert CustomSchema.check_within(
               entry["json_schema"],
               CustomSchema.total(TemplateTypes.total(30_000))
             ) ==
               {:error, :budget}

      assert TemplateTypes.check(template([entry])) ==
               {:error, [{:invalid, "t1", :json_schema}]}
    end

    test "takes a file of 430 definitions that each reach the metaschema" do
      meta = "https://json-schema.org/draft/2020-12/schema"
      listed = structured(430, &%{"title" => "x#{&1}", "$ref" => meta})

      assert :ok = TemplateTypes.check(template(listed))
    end

    test "total/1 is the same reductions and the smaller time" do
      assert [reductions: 300_000_000, ms: 30_000] = TemplateTypes.total(60_000)
      assert [reductions: 300_000_000, ms: 5_000] = TemplateTypes.total(5_000)
      assert [reductions: 300_000_000, ms: 0] = TemplateTypes.total(-1)
    end

    test "a template with no JSON Schema does no such work" do
      listed = [%{"name" => "mockup"}, @document]

      assert :ok = TemplateTypes.check(template(listed), reductions: 0, ms: 0)
      assert :ok = TemplateTypes.check(template(nil), reductions: 0, ms: 0)
    end
  end

  describe "message/1" do
    test "is the plan's text of each refusal" do
      assert TemplateTypes.message({:not_standard, "reply-draft"}) ==
               "reply-draft is not a standard type, so it needs a definition"

      assert TemplateTypes.message({:standard_name, "mockup"}) ==
               "the custom type mockup has a standard type's name"

      assert TemplateTypes.message({:repeated, "mockup"}) ==
               "list mockup once in artifact_types"

      assert TemplateTypes.message({:schema, "reply-draft"}) ==
               "the entry reply-draft in artifact_types does not match process.schema.json"

      assert TemplateTypes.message({:not_listed, "Answer", "mockup"}) ==
               "the stage Answer uses mockup, which artifact_types does not list"

      assert TemplateTypes.message({:invalid, "reply-draft", :base_view}) ==
               "the custom type reply-draft is not valid: Choose a base view."

      assert TemplateTypes.message({:submit, "reply-draft", :missing}) ==
               "add reply-draft to artifact_types as structured"

      assert String.length(TemplateTypes.message({:submit, String.duplicate("a", 64), :missing})) <=
               100

      assert TemplateTypes.message({:submit, "mockup", :standard}) ==
               "set submit.type to a structured type of artifact_types: mockup is a standard type"

      assert TemplateTypes.message({:submit, "reply-draft", {:base_view, "document"}}) ==
               "set submit.type to a type whose base_view is structured, not document"

      # The text prints the base view, not the type name, so each view bounds its length.
      for view <- Type.base_views() -- [:structured] do
        first_line =
          {:submit, String.duplicate("a", 64), {:base_view, Atom.to_string(view)}}
          |> TemplateTypes.message()
          |> String.split("\n")
          |> hd()

        assert String.length(first_line) <= 100
      end
    end

    test "ends an invalid definition's text with the Artifact types form's line" do
      for {error, line} <- [
            {:name,
             "Use lowercase letters and digits, in groups joined by single hyphens, at most 64 characters."},
            {:repeated, "List this name once."},
            {{:size_limit, :document}, "Set a size limit above 0 and at most 10 MiB."},
            {{:size_limit, :video}, "Set a size limit above 0 and at most 2,048 MiB."},
            {{:max_files, :image}, "Set most files to a whole number from 1 to 20."},
            {{:max_files, :structured}, "A structured type has one file."},
            {:json_schema,
             "Paste a JSON Schema: one JSON object of at most 64 KiB that Qory Apiary can build."},
            {:withdrawable, "Set withdrawable to true or false."}
          ] do
        assert TemplateTypes.message({:invalid, "reply-draft", error}) ==
                 "the custom type reply-draft is not valid: " <> line
      end
    end
  end

  describe "apply/3" do
    setup do
      scope = scope_fixture()
      %{scope: scope, workspace: workspace_fixture(scope.organisation, "Web shop")}
    end

    defp applied(workspace, template, scope) do
      Repo.transact(fn -> TemplateTypes.apply(workspace, template, scope) end)
    end

    defp audit_entries(workspace) do
      Repo.all(
        from e in Entry,
          where: e.action == "artifact_type.edit" and e.workspace_id == ^workspace.id,
          order_by: e.inserted_at
      )
    end

    defp shown_list(workspace), do: Repo.get!(Workspace, workspace.id).shown_standard_types

    test "gives a workspace its custom types, its audit entries and its list", ctx do
      listed = [%{"name" => "screenshot"}, %{"name" => "mockup"}, @document, @structured]

      assert {:ok, %Workspace{} = workspace} =
               applied(ctx.workspace, template(listed), ctx.scope)

      assert workspace.shown_standard_types == ["mockup", "screenshot"]
      assert shown_list(workspace) == ["mockup", "screenshot"]

      assert %Type{base_view: :document, size_limit: 65_536, max_files: 1} =
               Artifacts.type(workspace, "reply-draft")

      assert %Type{base_view: :structured, json_schema: schema} =
               Artifacts.type(workspace, "customer-facts")

      assert schema == @structured["json_schema"]

      assert Enum.sort(Enum.map(audit_entries(workspace), & &1.details)) ==
               [
                 %{"change" => "create", "type" => "customer-facts"},
                 %{"change" => "create", "type" => "reply-draft"}
               ]
    end

    test "writes the entries with a scope that has no workspace, as a creation's has", ctx do
      scope = %{ctx.scope | workspace: nil}

      assert {:ok, workspace} = applied(ctx.workspace, template([@document]), scope)
      assert [%Entry{} = entry] = audit_entries(workspace)
      assert entry.organisation_id == workspace.organisation_id
      assert entry.subject_kind == "workspace"
      assert entry.subject_id == workspace.id
    end

    test "leaves out of the list the always-on types a template lists", ctx do
      listed = names(["verdict", "proposal", "questions", "walkthrough"])

      assert {:ok, workspace} = applied(ctx.workspace, template(listed), ctx.scope)
      assert shown_list(workspace) == ["walkthrough"]
    end

    test "writes an empty list for an empty artifact_types", ctx do
      assert {:ok, workspace} = applied(ctx.workspace, template([]), ctx.scope)
      assert shown_list(workspace) == []
      assert Enum.map(Artifacts.types(workspace), & &1.name) == Type.always_on()
    end

    test "with no artifact_types leaves the list nil and writes nothing", ctx do
      assert {:ok, workspace} = applied(ctx.workspace, template(nil), ctx.scope)

      assert shown_list(workspace) == nil
      assert audit_entries(workspace) == []
      assert length(Artifacts.types(workspace)) == 11
    end

    test "leaves types/1 with what the template listed and the always-on types", ctx do
      listed = [%{"name" => "screenshot"}, @document, @structured]

      assert {:ok, workspace} = applied(ctx.workspace, template(listed), ctx.scope)

      assert Enum.map(Artifacts.types(workspace), & &1.name) ==
               ~w(screenshot proposal questions review-comments verdict customer-facts reply-draft)
    end

    @tag needs: :workflow_model
    test "does not ask for artifact_type.edit", ctx do
      member = member_fixture(ctx.scope).scope

      assert {:error, :forbidden} =
               Artifacts.create_type(member, ctx.scope.workspace, %{
                 "name" => "reply-draft",
                 "base_view" => "document"
               })

      assert {:ok, _workspace} = applied(ctx.workspace, template([@document]), member)
    end

    test "opens no transaction: without the caller's, a failure leaves the rows it wrote", ctx do
      assert {:error, _reason} =
               TemplateTypes.apply(ctx.workspace, template([@document, @document]), ctx.scope)

      assert %Type{} = Artifacts.type(ctx.workspace, "reply-draft")
    end

    test "fails on a custom name listed twice, and the caller's roll back leaves nothing", ctx do
      listed = [%{"name" => "mockup"}, @document, @structured, @document]

      assert applied(ctx.workspace, template(listed), ctx.scope) ==
               {:error, {:invalid, "reply-draft", :repeated}}

      assert Artifacts.type(ctx.workspace, "reply-draft") == nil
      assert Artifacts.type(ctx.workspace, "customer-facts") == nil
      assert audit_entries(ctx.workspace) == []
      assert shown_list(ctx.workspace) == nil
    end

    test "writes withdrawable false, and true for a definition that has none", ctx do
      listed = [Map.put(@document, "withdrawable", false), @structured]
      assert {:ok, workspace} = applied(ctx.workspace, template(listed), ctx.scope)

      assert %Type{withdrawable: false} = Artifacts.type(workspace, "reply-draft")
      assert %Type{withdrawable: true} = Artifacts.type(workspace, "customer-facts")
    end

    test "locks a standard type that has withdrawable false, and no other", ctx do
      listed = [
        %{"name" => "screenshot"},
        %{"name" => "mockup", "withdrawable" => false},
        %{"name" => "demo-video", "withdrawable" => true}
      ]

      assert {:ok, workspace} = applied(ctx.workspace, template(listed), ctx.scope)
      assert Repo.get!(Workspace, workspace.id).locked_standard_types == ["mockup"]
      assert shown_list(workspace) == ["mockup", "screenshot", "demo-video"]

      assert %Type{withdrawable: false, standard: true} = Artifacts.type(workspace, "mockup")
      assert %Type{withdrawable: true} = Artifacts.type(workspace, "screenshot")
      assert %Type{withdrawable: true} = Artifacts.type(workspace, "demo-video")

      locked =
        for %Type{withdrawable: false} = type <- Artifacts.all_types(workspace), do: type.name

      assert locked == ["mockup"]
      assert Enum.find(Artifacts.types(workspace), &(&1.name == "mockup")).withdrawable == false
    end

    test "locks the standard type of a harness file read by the Reader", ctx do
      path = Path.join(@sources, "factory/modules/support-desk/process.yaml")

      yaml =
        File.read!(path) <>
          "\nartifact_types:\n  - name: mockup\n    withdrawable: false\n  - name: screenshot\n"

      assert {:ok, template} = Reader.template(yaml)
      assert {:ok, workspace} = applied(ctx.workspace, template, ctx.scope)

      assert %Type{withdrawable: false} = Artifacts.type(workspace, "mockup")
      assert %Type{withdrawable: true} = Artifacts.type(workspace, "screenshot")
    end

    test "a template with no withdrawable locks no standard type", ctx do
      assert {:ok, workspace} = applied(ctx.workspace, template(names(["mockup"])), ctx.scope)
      assert Repo.get!(Workspace, workspace.id).locked_standard_types == []
      assert %Type{withdrawable: true} = Artifacts.type(workspace, "mockup")
    end

    test "fails on a withdrawable that is not a boolean", ctx do
      entry = Map.put(@document, "withdrawable", "no")

      assert applied(ctx.workspace, template([entry]), ctx.scope) ==
               {:error, {:invalid, "reply-draft", :withdrawable}}
    end

    test "fails on a definition the changeset refuses, by the field that failed", ctx do
      entry = %{@document | "size_limit" => 10_485_761}

      assert applied(ctx.workspace, template([entry]), ctx.scope) ==
               {:error, {:invalid, "reply-draft", {:size_limit, :document}}}
    end
  end
end
