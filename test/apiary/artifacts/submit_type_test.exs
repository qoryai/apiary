defmodule Apiary.Artifacts.SubmitTypeTest do
  # A process version saved before Qory Apiary stopped keeping `submit` has it in its
  # template record. Only the stage tab and the Workflow tab of a work item on that
  # version read it; for the Artifacts context the type it sets is an ordinary type. A
  # type that the process marks `deliver` is locked instead
  # (`Apiary.Artifacts.submit_types/1`).
  # Not async: the tests serve the Qory harness at other commits, and the store's root is
  # the application's setting.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, QoryHarnessFixture}
  alias Apiary.Artifacts.Type
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.{Qory, RunHarness}
  alias Apiary.Processes.{HarnessUpdate, Version}

  @moduletag :tmp_dir
  @moduletag :capture_log
  @moduletag needs: [:workflow_model, :factory]

  @process "modules/software-factory/process.yaml"

  # The schema the harness has, and the one the workspace's type is set to: `@strict`
  # needs `summary` and `owner`, and `@any` takes every object.
  @strict %{"type" => "object", "required" => ["summary", "owner"]}
  @any %{"type" => "object"}

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    %{scope: scope, workspace: workspace} = sign_up_fixture()
    %{scope: scope, workspace: workspace, work_item: work_item_fixture(scope)}
  end

  # The fixture's template with its `submission` entry replaced by one with `schema`, and
  # the template's submit step set to it.
  defp harness_files(schema) do
    [head, _submission] =
      String.split(QoryHarnessFixture.files()[@process], "  - name: submission\n", parts: 2)

    process =
      head <>
        "  - name: submission\n    base_view: structured\n    size_limit: 1048576\n" <>
        "    max_files: 1\n    json_schema: #{Jason.encode!(schema)}\n" <>
        "submit:\n  type: submission\n  send: after_gate\n"

    Map.put(QoryHarnessFixture.files(), @process, process)
  end

  # The fixture's files with `submission` marked `deliver`, sent after the gate.
  defp delivering_files do
    process =
      String.replace(
        QoryHarnessFixture.files()[@process],
        "    size_limit: 1048576\n    max_files: 1\n",
        "    size_limit: 786432\n    max_files: 1\n    deliver: {send: after_gate}\n"
      )

    Map.put(QoryHarnessFixture.files(), @process, process)
  end

  # Update from harness, with the Qory harness's main at `files`: the version it saves.
  defp save_from_harness!(%{scope: scope, workspace: workspace}, files) do
    QoryHarnessFixture.serve!(files)
    assert {:ok, _commit} = Qory.read({:branch, "main"})
    assert {:ok, update} = HarnessUpdate.read(scope, workspace)
    assert {:ok, %Version{} = version} = HarnessUpdate.save(scope, workspace, update)
    version
  end

  # Update from harness, with the Qory harness's main at a commit whose `submission` has
  # `schema`: the version it saves, current, with `submit` written into its record as a
  # version saved before has it.
  defp update_from_harness!(%{scope: scope, workspace: workspace}, schema) do
    QoryHarnessFixture.serve!(harness_files(schema))
    assert {:ok, _commit} = Qory.read({:branch, "main"})
    assert {:ok, update} = HarnessUpdate.read(scope, workspace)
    assert {:ok, %Version{} = version} = HarnessUpdate.save(scope, workspace, update)
    record!(version, &Map.put(&1, "submit", %{"type" => "submission", "send" => "after_gate"}))
  end

  # The workspace's `submission` type with `schema`, as a row, whatever the harness has.
  defp copy!(%{workspace: workspace}, schema) do
    {1, _rows} =
      Repo.update_all(
        from(t in Type, where: t.workspace_id == ^workspace.id and t.name == "submission"),
        set: [json_schema: schema]
      )
  end

  # A handed-over run of the work item, on `version`, with a resolved walk whose base
  # follows `main` of the harness at `git`.
  defp run_on!(ctx, version, opts \\ []) do
    %{dispatch_run: run} = explore_run_fixture(ctx.work_item, state: :handed_over)

    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
        set: [process_version_id: version.id]
      )

    unless opts[:walk] == false do
      git = Keyword.get(opts, :git, Qory.git())
      kind = Keyword.get(opts, :ref_kind, :branch)

      origin = Keyword.get(opts, :origin, :setting)
      document = %{"extends" => %{"git" => git, "ref" => Keyword.get(opts, :ref, "main")}}

      Repo.insert!(%RunHarness{
        dispatch_run_id: run.id,
        state: :resolved,
        origin: origin,
        ref_kind: kind,
        # A walk from a file has no document (`run_harnesses_document_check`).
        document: if(origin == :file, do: nil, else: document)
      })
    end

    Repo.get!(DispatchRun, run.id)
  end

  # The version `version` with its harness record changed by `fun`.
  defp record!(version, fun) do
    {1, _rows} =
      Repo.update_all(from(v in Version, where: v.id == ^version.id),
        set: [template: fun.(version.template)]
      )

    Repo.get!(Version, version.id)
  end

  defp submission(fields) do
    [
      %{
        filename: "submission.json",
        content_type: "application/json",
        binary: Jason.encode!(fields)
      }
    ]
  end

  defp push(ctx, run, fields, work_item \\ nil),
    do: Artifacts.push({:run, run}, work_item || ctx.work_item, "submission", submission(fields))

  # `version` with its record's `submission` entry delivered, with `schema`.
  defp delivered_schema!(version, schema) do
    entry = %{
      "name" => "submission",
      "base_view" => "structured",
      "deliver" => %{"send" => "end_of_run"},
      "json_schema" => schema
    }

    record!(version, &Map.put(&1, "artifact_types", [entry]))
  end

  @owner %{"type" => "object", "required" => ["owner"]}
  @summary_only %{"type" => "object", "required" => ["summary"]}

  @summary %{"summary" => "The basket keeps the sale price."}

  describe "the type that a version's submit sets" do
    setup ctx do
      Map.put(ctx, :version, update_from_harness!(ctx, @strict))
    end

    test "a run's version of it is checked against the workspace's type", ctx do
      copy!(ctx, @any)
      assert {:ok, _version} = push(ctx, run_on!(ctx, ctx.version), @summary)
    end

    test "is not set by the harness: a person edits and deletes it", ctx do
      assert Artifacts.submit_types(ctx.workspace) == []

      type = Artifacts.type(ctx.workspace, "submission")
      assert {:ok, type} = Artifacts.update_type(ctx.scope, type, %{"size_limit" => 1000})
      assert {:ok, _type} = Artifacts.delete_type(ctx.scope, type)
    end
  end

  describe "the types that the process marks deliver" do
    setup ctx do
      version = save_from_harness!(ctx, delivering_files())
      assert [%{"name" => "submission"}] = version.template["artifact_types"]
      Map.put(ctx, :version, version)
    end

    test "are those of the current version and of each version in use", ctx do
      assert Artifacts.submit_types(ctx.workspace) == ["submission"]

      # The current version marks another type: the older one stays locked while a run is
      # on that version, and no longer once the run ended.
      run = run_on!(ctx, ctx.version)
      newer = save_from_harness!(ctx, QoryHarnessFixture.explore_named("Discover"))

      record!(
        newer,
        &Map.put(&1, "artifact_types", [
          %{
            "name" => "findings",
            "base_view" => "structured",
            "deliver" => %{"send" => "end_of_run"}
          }
        ])
      )

      assert Enum.sort(Artifacts.submit_types(ctx.workspace)) == ["findings", "submission"]

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      assert Artifacts.submit_types(ctx.workspace) == ["findings"]
    end

    test "a delivered type is refused an edit and a delete; another type is not", ctx do
      type = Artifacts.type(ctx.workspace, "submission")
      before = Repo.get!(Type, type.id)

      assert {:error, :set_by_harness} =
               Artifacts.update_type(ctx.scope, type, %{"size_limit" => 1000})

      assert {:error, :set_by_harness} = Artifacts.delete_type(ctx.scope, type)
      assert Repo.get!(Type, type.id) == before

      {:ok, other} =
        Artifacts.create_type(ctx.scope, ctx.workspace, %{
          "name" => "findings",
          "base_view" => "structured",
          "json_schema" => @any
        })

      assert {:ok, other} = Artifacts.update_type(ctx.scope, other, %{"size_limit" => 1000})
      assert {:ok, _type} = Artifacts.delete_type(ctx.scope, other)
    end

    test "an entry that is not delivered locks nothing", ctx do
      for entry <- [
            %{"name" => "submission", "base_view" => "structured", "deliver" => %{"send" => "x"}},
            %{"name" => "submission", "deliver" => %{"send" => "end_of_run"}},
            %{"name" => "submission", "base_view" => "document", "deliver" => %{}}
          ] do
        record!(ctx.version, &Map.put(&1, "artifact_types", [entry]))
        assert Artifacts.submit_types(ctx.workspace) == [], inspect(entry)
      end

      type = Artifacts.type(ctx.workspace, "submission")
      assert {:ok, _type} = Artifacts.update_type(ctx.scope, type, %{"size_limit" => 1000})
    end

    test "a run's version is checked against the schema in the record, not the workspace's type",
         ctx do
      version = delivered_schema!(ctx.version, @owner)
      copy!(ctx, @summary_only)
      run = run_on!(ctx, version)

      assert {:ok, _version} = push(ctx, run, %{"owner" => "Ana"})
      assert {:error, {:invalid, {:schema, 0, _detail}}} = push(ctx, run, @summary)
    end

    test "a version saved from the harness keeps the schema that checks a run's version",
         ctx do
      # The setup's version, as the harness save wrote it: the fixture's `submission`
      # schema needs `ref` and more, which `@summary` lacks.
      assert [%{"json_schema" => %{"required" => ["ref" | _]}}] =
               ctx.version.template["artifact_types"]

      copy!(ctx, @any)
      run = run_on!(ctx, ctx.version)

      assert {:error, {:invalid, {:schema, 0, _detail}}} = push(ctx, run, @summary)
    end

    test "two runs on two process versions each use the schema of their version", ctx do
      older = delivered_schema!(ctx.version, @owner)
      newer = save_from_harness!(ctx, QoryHarnessFixture.explore_named("Discover"))
      newer = delivered_schema!(newer, @summary_only)
      copy!(ctx, @any)

      other = work_item_fixture(ctx.scope)
      on_older = run_on!(ctx, older)
      on_newer = run_on!(%{ctx | work_item: other}, newer)

      assert {:error, {:invalid, {:schema, 0, _detail}}} = push(ctx, on_older, @summary)
      assert {:ok, _version} = push(ctx, on_older, %{"owner" => "Ana"})
      assert {:ok, _version} = push(ctx, on_newer, @summary, other)

      assert {:error, {:invalid, {:schema, 0, _detail}}} =
               push(ctx, on_newer, %{"owner" => "Ana"}, other)
    end

    test "a type with no deliver is checked against the workspace's type", ctx do
      entry = %{"name" => "submission", "base_view" => "structured", "json_schema" => @owner}
      version = record!(ctx.version, &Map.put(&1, "artifact_types", [entry]))
      copy!(ctx, @summary_only)
      run = run_on!(ctx, version)

      assert {:ok, _version} = push(ctx, run, @summary)
      assert {:error, {:invalid, {:schema, 0, _detail}}} = push(ctx, run, %{"owner" => "Ana"})
    end

    # A delivered type's schema whose required `target` is `$ref` to `address`.
    defp target_schema(address) do
      %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "required" => ["target"],
        "properties" => %{"target" => %{"$ref" => address}}
      }
    end

    test "a record schema with a $ref to the harness primitives checks a run's version", ctx do
      reference = "https://qory.dev/contracts/harness/v1/primitives.schema.json#/$defs/reference"
      version = delivered_schema!(ctx.version, target_schema(reference))
      copy!(ctx, @any)
      run = run_on!(ctx, version)

      assert push(ctx, run, @summary) ==
               {:error,
                {:invalid, {:schema, 0, %{path: "#", error: "property 'target' is required"}}}}

      assert {:ok, _version} = push(ctx, run, %{"target" => %{"collection" => "example/shop"}})
    end

    test "a record schema with a $ref to another address cannot be read", ctx do
      version =
        delivered_schema!(
          ctx.version,
          target_schema("https://example.com/primitives.schema.json")
        )

      copy!(ctx, @any)
      run = run_on!(ctx, version)

      assert push(ctx, run, @summary) ==
               {:error,
                {:invalid, {:schema, 0, %{path: "#", error: "the JSON Schema cannot be read"}}}}
    end

    test "a run cannot withdraw a name of a delivered type", ctx do
      run = run_on!(ctx, ctx.version)

      assert Artifacts.withdraw({:run, run}, ctx.work_item, "submission", name: "main") ==
               {:error, {:withdraw, :delivered}}
    end
  end

  describe "a delivered type that refers to the primitives of the harness" do
    @sha String.duplicate("a1", 20)

    # A document that the harness's `pull-request` schema takes, with `changes` merged.
    defp pull_request(changes \\ %{}) do
      commit = %{
        "collection" => "example/shop",
        "address" => %{"system" => "forge.example.com", "path" => @sha}
      }

      Map.merge(
        %{
          "target" => %{"collection" => "example/shop"},
          "title" => "Keep the sale price in the basket",
          "text" => "The basket keeps the sale price.",
          "commits" => [commit],
          "head" => commit,
          "base" => commit,
          "branch" => "sale-price",
          "base_branch" => "main",
          "steps" => [],
          "draft" => true
        },
        changes
      )
    end

    defp push_pull_request(run, work_item, document) do
      file = %{
        filename: "pull-request.json",
        content_type: "application/json",
        binary: Jason.encode!(document)
      }

      Artifacts.push({:run, run}, work_item, "pull-request", [file])
    end

    # The workspace's `pull-request` type set to take any object, so a refusal comes from
    # the record's schema.
    defp any_pull_request!(workspace) do
      {1, _rows} =
        Repo.update_all(
          from(t in Type, where: t.workspace_id == ^workspace.id and t.name == "pull-request"),
          set: [json_schema: @any]
        )
    end

    defp entry(version),
      do: Enum.find(version.template["artifact_types"], &(&1["name"] == "pull-request"))

    test "Update from harness saves it, and a run's push is checked against its schema",
         ctx do
      version = save_from_harness!(ctx, QoryHarnessFixture.with_pull_request())
      schema = QoryHarnessFixture.pull_request_schema()
      assert %{"json_schema" => ^schema} = entry(version)

      any_pull_request!(ctx.workspace)
      run = run_on!(ctx, version)

      assert {:ok, _version} = push_pull_request(run, ctx.work_item, pull_request())

      assert {:error, {:invalid, {:schema, 0, %{path: "#/title"}}}} =
               push_pull_request(run, ctx.work_item, pull_request(%{"title" => " "}))

      assert {:error, {:invalid, {:schema, 0, _detail}}} =
               push_pull_request(run, ctx.work_item, pull_request(%{"target" => %{}}))
    end

    test "the Qory start saves it, and a run's push is checked against its schema", ctx do
      QoryHarnessFixture.serve!(QoryHarnessFixture.with_pull_request())
      %{scope: scope, workspace: workspace} = sign_up_fixture()

      schema = QoryHarnessFixture.pull_request_schema()

      assert %Type{json_schema: ^schema} =
               Repo.get_by(Type, workspace_id: workspace.id, name: "pull-request")

      version = Apiary.Processes.current(workspace)
      assert %{"json_schema" => ^schema} = entry(version)

      any_pull_request!(workspace)
      work_item = work_item_fixture(scope)
      run = run_on!(%{ctx | work_item: work_item}, version)

      assert {:ok, _version} = push_pull_request(run, work_item, pull_request())

      assert {:error, {:invalid, {:schema, 0, %{path: "#/title"}}}} =
               push_pull_request(run, work_item, pull_request(%{"title" => " "}))
    end
  end
end
