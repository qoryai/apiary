defmodule Apiary.Artifacts.SubmitTypeTest do
  # The type that the process's `submit` sets (`Apiary.Artifacts.submit_types/1`): a run's
  # version of it is checked against the schema in the harness commit the run composes,
  # and against the workspace's type in the three cases where that schema is not found
  # (`Apiary.Processes.submit_schema/2`); no one edits, deletes or adds a version of it by
  # hand. Not async: the tests serve the Qory harness at other commits, and the store's
  # root is the application's setting.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, QoryHarnessFixture}
  alias Apiary.Artifacts.Type
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.{Qory, RunHarness}
  alias Apiary.Processes.{HarnessUpdate, Version}

  @moduletag :tmp_dir
  @moduletag :capture_log
  @moduletag needs: [:workflow_model, :factory]

  @process "modules/software-factory/process.yaml"
  @repository "https://code.example.com/acme/harness"

  # The schemas the harness has at three commits, and the one the workspace's type may
  # have: `@loose` needs `summary`, `@strict` needs `summary` and `owner`, and `@any`
  # takes every object.
  @loose %{"type" => "object", "required" => ["summary"]}
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

  # Update from harness, with the Qory harness's main at a commit whose `submission` has
  # `schema`: the version it saves, current.
  defp update_from_harness!(%{scope: scope, workspace: workspace}, schema) do
    QoryHarnessFixture.serve!(harness_files(schema))
    assert {:ok, _commit} = Qory.read({:branch, "main"})
    assert {:ok, update} = HarnessUpdate.read(scope, workspace)
    assert {:ok, %Version{} = version} = HarnessUpdate.save(scope, workspace, update)
    version
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

      Repo.insert!(%RunHarness{
        dispatch_run_id: run.id,
        state: :resolved,
        origin: :setting,
        ref_kind: kind,
        document: %{"extends" => %{"git" => git, "ref" => Keyword.get(opts, :ref, "main")}}
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

  defp push(ctx, run, fields),
    do: Artifacts.push({:run, run}, ctx.work_item, "submission", submission(fields))

  @summary %{"summary" => "The basket keeps the sale price."}
  @owned Map.put(@summary, "owner", "Ada")

  describe "a run's version of the submit type, with the harness commit found" do
    test "an older version passes against its schema once Update from harness made a stricter one current",
         ctx do
      # The workspace's type needs more than the older schema does.
      older = update_from_harness!(ctx, @loose)
      current = update_from_harness!(ctx, @strict)
      assert current.number == older.number + 1

      assert ctx.workspace |> Processes.current() |> Map.fetch!(:id) == current.id
      assert Artifacts.type(ctx.workspace, "submission").json_schema != @loose

      assert {:ok, _version} = push(ctx, run_on!(ctx, older), @summary)

      assert {:error, {:invalid, {:schema, 0, _detail}}} =
               push(ctx, run_on!(ctx, current), @summary)

      assert {:ok, _version} = push(ctx, run_on!(ctx, current), @owned)
    end

    test "a stricter schema in the harness refuses what the workspace's type takes", ctx do
      version = update_from_harness!(ctx, @strict)
      copy!(ctx, @any)
      run = run_on!(ctx, version)

      assert {:error, {:invalid, {:schema, 0, _detail}}} = push(ctx, run, @summary)
      assert {:ok, _version} = push(ctx, run, @owned)
    end

    test "a harness repository's record has the schema, and a run's push is checked against it",
         ctx do
      version = update_from_harness!(ctx, @loose)

      version =
        record!(version, fn record ->
          Map.merge(record, %{
            "source" => "repository",
            "git" => @repository,
            "submit_schema" => @strict
          })
        end)

      copy!(ctx, @any)
      run = run_on!(ctx, version, git: @repository)

      assert {:error, {:invalid, {:schema, 0, _detail}}} = push(ctx, run, @summary)
      assert {:ok, _version} = push(ctx, run, @owned)
    end
  end

  describe "a run's version of the submit type, with the harness commit not found" do
    setup ctx do
      version = update_from_harness!(ctx, @loose)
      # The workspace's type is the stricter one, so a push of `@summary` passes only
      # against the harness's schema.
      copy!(ctx, @strict)
      Map.put(ctx, :version, version)
    end

    defp refused_as_the_workspace_type(ctx, run) do
      assert {:error, {:invalid, {:schema, 0, _detail}}} = push(ctx, run, @summary)
      assert {:ok, _version} = push(ctx, run, @owned)
    end

    test "control: with the commit found, the push passes against the harness's schema", ctx do
      assert {:ok, _version} = push(ctx, run_on!(ctx, ctx.version), @summary)
    end

    test "a process version of a harness repository saved before the schema was recorded",
         ctx do
      version =
        record!(ctx.version, fn record ->
          record
          |> Map.merge(%{"source" => "repository", "git" => @repository})
          |> Map.delete("submit_schema")
        end)

      refused_as_the_workspace_type(ctx, run_on!(ctx, version, git: @repository))
    end

    test "a Qory harness commit whose files are not kept", ctx do
      version = record!(ctx.version, &Map.put(&1, "commit", String.duplicate("b", 40)))
      assert Qory.template(version.template["commit"]) == nil

      refused_as_the_workspace_type(ctx, run_on!(ctx, version))
    end

    test "a base pinned to a tag, or to a commit", ctx do
      refused_as_the_workspace_type(ctx, run_on!(ctx, ctx.version, ref: "v1", ref_kind: :tag))

      refused_as_the_workspace_type(
        ctx,
        run_on!(ctx, ctx.version, ref: ctx.version.template["commit"], ref_kind: :commit)
      )
    end

    test "a record of another harness", ctx do
      refused_as_the_workspace_type(ctx, run_on!(ctx, ctx.version, git: @repository))
    end

    test "a run with no resolved walk", ctx do
      refused_as_the_workspace_type(ctx, run_on!(ctx, ctx.version, walk: false))
    end

    test "a run with no process version", ctx do
      %{dispatch_run: run} = explore_run_fixture(ctx.work_item, state: :handed_over)

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
          set: [process_version_id: nil]
        )

      refused_as_the_workspace_type(ctx, Repo.get!(DispatchRun, run.id))
    end
  end

  test "a run's version of another custom type is checked against the workspace's type", ctx do
    update_from_harness!(ctx, @loose)

    {:ok, _type} =
      Artifacts.create_type(ctx.scope, ctx.workspace, %{
        "name" => "findings",
        "base_view" => "structured",
        "json_schema" => @strict
      })

    version = Processes.current(ctx.workspace)
    run = run_on!(ctx, version)

    assert {:error, {:invalid, {:schema, 0, _detail}}} =
             Artifacts.push({:run, run}, ctx.work_item, "findings", submission(@summary))
  end

  test "no type is set by the harness where the process has no submit", ctx do
    assert Artifacts.submit_types(ctx.workspace) == []
    assert "submission" in Enum.map(Artifacts.person_types(ctx.workspace), & &1.name)
  end

  describe "the type that the process's submit sets" do
    setup ctx do
      Map.put(ctx, :version, update_from_harness!(ctx, @loose))
    end

    test "is the type of the current version and of each version in use", ctx do
      assert Artifacts.submit_types(ctx.workspace) == ["submission"]

      # The current version sets another type: the older one stays set while a run is on
      # that version, and no longer once the run ended.
      run = run_on!(ctx, ctx.version)
      newer = update_from_harness!(ctx, @strict)
      record!(newer, &put_in(&1, ["submit", "type"], "findings"))

      assert Enum.sort(Artifacts.submit_types(ctx.workspace)) == ["findings", "submission"]

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      assert Artifacts.submit_types(ctx.workspace) == ["findings"]
    end

    test "is refused an edit and a delete, and no row changes", ctx do
      type = Artifacts.type(ctx.workspace, "submission")
      before = Repo.get!(Type, type.id)

      assert {:error, :set_by_harness} =
               Artifacts.update_type(ctx.scope, type, %{"size_limit" => 1000})

      assert {:error, :set_by_harness} = Artifacts.delete_type(ctx.scope, type)
      assert Repo.get!(Type, type.id) == before
    end

    test "is refused an edit and a delete for an admin too, and refused as forbidden for a member",
         ctx do
      type = Artifacts.type(ctx.workspace, "submission")
      %{scope: admin} = member_fixture(ctx.scope, :admin)
      %{scope: member} = member_fixture(ctx.scope, :member)

      assert {:error, :set_by_harness} = Artifacts.delete_type(admin, type)
      assert {:error, reason} = Artifacts.delete_type(member, type)
      assert reason in [:forbidden, :not_found]
    end

    test "can be edited and deleted where no version sets it", ctx do
      {:ok, other} =
        Artifacts.create_type(ctx.scope, ctx.workspace, %{
          "name" => "findings",
          "base_view" => "structured",
          "json_schema" => @any
        })

      assert {:ok, _type} = Artifacts.update_type(ctx.scope, other, %{"size_limit" => 1000})
      assert {:ok, _type} = Artifacts.delete_type(ctx.scope, other)
    end

    test "is not offered to a person, and a person's push of it is an unknown type", ctx do
      names = ctx.workspace |> Artifacts.person_types() |> Enum.map(& &1.name)
      refute "submission" in names
      assert "submission" in Enum.map(Artifacts.types(ctx.workspace), & &1.name)

      assert {:error, {:unknown_type, "submission"}} =
               Artifacts.push(
                 {:person, ctx.scope},
                 ctx.work_item,
                 "submission",
                 submission(@owned)
               )

      assert Repo.aggregate(Artifacts.Version, :count) == 0
    end
  end

  describe "the record a version keeps of its harness" do
    @template %{
      submit: %{"type" => "submission", "send" => "after_gate"},
      artifact_types: [
        %{"name" => "explainer"},
        %{
          "name" => "submission",
          "base_view" => "structured",
          "json_schema" => %{"type" => "object"}
        }
      ]
    }

    test "has the submit type's schema for a harness repository, not for the Qory harness" do
      assert %{"submit" => %{"type" => "submission"}, "submit_schema" => %{"type" => "object"}} =
               Processes.with_submit(%{"source" => "repository"}, @template)

      record = Processes.with_submit(%{"source" => "qory"}, @template)
      assert Map.has_key?(record, "submit")
      refute Map.has_key?(record, "submit_schema")
    end

    test "has no schema when the template lists none for the submit type" do
      template = %{@template | artifact_types: [%{"name" => "explainer"}]}
      record = Processes.with_submit(%{"source" => "repository"}, template)
      refute Map.has_key?(record, "submit_schema")

      assert Processes.with_submit(%{"source" => "repository"}, %{submit: nil}) == %{
               "source" => "repository"
             }
    end
  end
end
