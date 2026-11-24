defmodule ApiaryWeb.WorkItemLive.SubmissionsTabTest do
  @moduledoc """
  The Submissions frame on the tab of a stage that outputs the submission type
  (`ApiaryWeb.SubmissionComponents.frame/1`): one frame in place of the frame of the type,
  with a row for each run that stored a version, newest first, and the usual
  frame of the type where the work item's process version names no submit type.

  The fake changes the whole node (`ApiaryWeb.WorkflowFake.install/0`), so the module is
  not async.
  """
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, Repo, WorkItems}
  alias Apiary.Processes.Version, as: ProcessVersion
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.WorkflowFake

  @moduletag needs: [:factory, :workflow_model]
  @moduletag :tmp_dir

  @shape "st_p9w5cvh311"
  @build "st_6ns22c4pav"
  @head String.duplicate("a1", 20)
  @base String.duplicate("9f", 20)
  @change String.duplicate("4c", 20)
  @fix String.duplicate("7e", 20)
  @plan """
  ## Deliverables

  | Id | Change | Criteria | Files | Check |
  |---|---|---|---|---|
  | d-2 | Show the dates at checkout | AC-2, "Shown" | `src/page.tsx` | scenario-1 |
  """

  setup_all do
    previous = WorkflowFake.install()
    on_exit(fn -> WorkflowFake.uninstall(previous) end)
    :ok
  end

  setup :register_and_log_in_user

  setup %{scope: scope, tmp_dir: tmp_dir} do
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    workspace = scope.workspace

    :ok =
      Processes.record_declared(
        workspace,
        Processes.qory_workflows(Apiary.Stacks.Sources.chosen(workspace)) ++
          ~w(shape-a-ticket build-it)
      )

    for workflow <- ~w(shape-a-ticket build-it) do
      Repo.insert!(%Apiary.Stacks.Stack{
        organisation_id: workspace.organisation_id,
        workspace_id: workspace.id,
        workflow: workflow,
        access: :read
      })
    end

    # The workspace's types: `submission` with a schema that takes any object, and the build
    # plan.
    Repo.delete_all(
      from t in Apiary.Artifacts.Type,
        where: t.workspace_id == ^workspace.id and t.name in ["submission", "build-plan"]
    )

    for {name, attrs} <- [
          {"submission", %{"base_view" => "structured", "json_schema" => %{"type" => "object"}}},
          {"build-plan",
           %{"base_view" => "document", "size_limit" => 1_048_576, "max_files" => 1}}
        ] do
      {:ok, _type} =
        Artifacts.create_type(scope, workspace, Map.put(attrs, "name", name))
    end

    :ok
  end

  # The default process with Shape running a workflow and outputting the submission type.
  # `opts`: `outputs`, more output types of Shape; `gate`, Shape's gate kind, "person" by
  # default; `build_inputs`, the input types of Build, the stage after Shape; `required`,
  # whether Shape requires the submission type, false by default; `person_saved`, true for a
  # process version that a person saved after the one with the harness record, so its
  # `template` is nil and `Processes.harness_template/1` reads the version it is based on.
  defp process!(scope, submit, opts \\ []) do
    more_outputs = Keyword.get(opts, :outputs, [])
    gate = Keyword.get(opts, :gate, "person")
    build_inputs = Keyword.get(opts, :build_inputs, [])
    required = Keyword.get(opts, :required, false)
    document = Processes.default_document("software")

    stages =
      Enum.map(document["stages"], fn
        %{"id" => @shape} = stage ->
          Map.merge(stage, %{
            "sequence" => [%{"workflow" => "shape-a-ticket"}],
            "outputs" =>
              [%{"type" => "submission", "required" => required}] ++
                for(type <- more_outputs, do: %{"type" => type, "required" => false}),
            "gate" =>
              if(gate == "none",
                do: %{"kind" => "none"},
                else: %{"kind" => "person", "approvers" => "members"}
              )
          })

        %{"id" => @build} = stage when build_inputs != [] ->
          Map.put(
            stage,
            "inputs",
            for(type <- build_inputs, do: %{"type" => type, "required" => false})
          )

        stage ->
          stage
      end)

    {:ok, version} = Processes.save(scope, scope.workspace, %{document | "stages" => stages})
    template = %{"commit" => String.duplicate("a", 40)}
    template = if submit, do: Map.put(template, "submit", submit), else: template

    {_n, _rows} =
      Repo.update_all(from(v in ProcessVersion, where: v.workspace_id == ^scope.workspace.id),
        set: [template: template]
      )

    if Keyword.get(opts, :person_saved, false) do
      renamed =
        Enum.map(stages, fn
          %{"id" => @build} = stage -> %{stage | "name" => "Build it"}
          stage -> stage
        end)

      {:ok, saved} =
        Processes.save(scope, scope.workspace, %{document | "stages" => renamed},
          based_on: version
        )

      saved
    else
      version
    end
  end

  defp at_shape!(scope) do
    work_item = scope |> taken_in_fixture() |> end_run!(understood_result())
    {:ok, _confirmed} = WorkItems.confirm(scope, work_item, 1)
    Repo.get!(WorkItem, work_item.id)
  end

  defp stage_path(scope, work_item),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}/stages/#{@shape}"

  defp repository do
    %{
      "system" => "git.example.com",
      "path" => "northwind/storefront",
      "commit" => @head,
      "commit_url" => "https://git.example.com/northwind/storefront/commit/#{@head}",
      "base" => %{"commit" => @base, "commit_url" => "https://git.example.com/x/commit/#{@base}"},
      "commits" => [
        %{"commit" => @change, "step" => "deliverable:d-2"},
        %{"commit" => @fix, "step" => "fix:f1"},
        %{"commit" => @head, "step" => "fix:f2"}
      ],
      "draft" => %{
        "number" => 34,
        "url" => "https://git.example.com/northwind/storefront/pulls/34",
        "title" => "Show delivery dates at checkout",
        "state" => "draft",
        "action" => "opened"
      }
    }
  end

  defp push!(run, work_item, type, filename, content_type, binary) do
    {:ok, version} =
      Artifacts.push(
        {:run, run},
        work_item,
        type,
        [%{filename: filename, content_type: content_type, binary: binary}],
        stage_id: @shape
      )

    version
  end

  defp submission!(run, work_item, repository, more \\ []) do
    value = %{
      "ref" => "qory/wi_qk5p97dt9vdq39a2",
      "verdict" => "passed",
      "repositories" => [repository | List.wrap(more)]
    }

    push!(
      run,
      work_item,
      "submission",
      "submission.json",
      "application/json",
      Jason.encode!(value)
    )
  end

  # A run of the work item at Shape, live, with a registered run. The fixture's attempts
  # stop at 3, so the run takes the attempt the fixture allows and moves to a higher one.
  defp shape_run!(work_item) do
    taken =
      Repo.all(
        from d in Apiary.Dispatches.DispatchRun,
          where: d.work_item_id == ^work_item.id and d.take_in == ^work_item.take_in,
          select: d.attempt
      )

    free = Enum.find(1..3, &(&1 not in taken))

    %{dispatch_run: run, run: registered} =
      explore_run_fixture(work_item, state: :handed_over, attempt: free)

    {1, _rows} =
      Repo.update_all(from(d in Apiary.Dispatches.DispatchRun, where: d.id == ^run.id),
        set: [
          stage_id: @shape,
          attempt: 100 + rem(System.unique_integer([:positive, :monotonic]), 800),
          of: 1000
        ]
      )

    %{dispatch_run: Repo.reload!(run), run: registered}
  end

  # Two runs of the work item that stored a submission each, the second after the first,
  # and the plan the first stored before it.
  defp two_runs!(work_item) do
    %{dispatch_run: first, run: first_run} = shape_run!(work_item)
    %{dispatch_run: second, run: second_run} = shape_run!(work_item)

    # Both runs record the plan type their workflow's stack entry sets.
    for run <- [first, second] do
      Repo.insert!(%Apiary.Harnesses.RunHarness{
        dispatch_run_id: run.id,
        state: :resolved,
        origin: :none,
        plan_type: "build-plan"
      })
    end

    push!(first, work_item, "build-plan", "build-plan.md", "text/markdown", @plan)
    one = submission!(first, work_item, repository())

    two =
      submission!(
        second,
        work_item,
        %{
          repository()
          | "base" => %{"commit" => @head},
            "commits" => [%{"commit" => @fix, "step" => "fix:f3"}],
            "commit" => @fix
        }
      )

    %{one: one, two: two, first_run: first_run, second_run: second_run}
  end

  test "a process version with no submit type keeps the frame of the type", ctx do
    process!(ctx.scope, nil)
    work_item = at_shape!(ctx.scope)
    %{dispatch_run: run} = shape_run!(work_item)
    submission!(run, work_item, repository())

    {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

    assert has_element?(view, "#work-item-tab-output-submission-h", "Submission")
    refute has_element?(view, "#work-item-tab-output-submission-h", "Submissions")
    refute has_element?(view, "#work-item-tab-output-submission-list > ul > li[id*=\"-r0\"]")
    assert has_element?(view, "#work-item-tab-output-submission .q-xp-cap", "Version 1")
  end

  test "the record's artifacts list the submission as before", ctx do
    process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
    work_item = at_shape!(ctx.scope)
    two_runs!(work_item)

    {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

    assert has_element?(view, "#work-item-record", "submission v2")
  end
end
