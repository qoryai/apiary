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
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures, only: [with_domain: 2]
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

  test "the tab has one Submissions frame, with a row for each run, newest first", ctx do
    process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
    work_item = at_shape!(ctx.scope)
    %{one: one, two: two, first_run: first_run, second_run: second_run} = two_runs!(work_item)

    {:ok, view, html} = live(ctx.conn, stage_path(ctx.scope, work_item))

    frame = "#work-item-tab-output-submission"
    assert has_element?(view, "#{frame}-h", "Submissions")
    assert has_element?(view, "#{frame} .q-xp-cap", "Newest first")

    # Newest first: the second run's row, then the first's.
    ids =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#{frame}-list > ul > li")
      |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))

    assert ids == [
             "work-item-tab-output-submission-#{two.public_id}",
             "work-item-tab-output-submission-#{one.public_id}"
           ]

    first = "#{frame}-#{one.public_id}"
    second = "#{frame}-#{two.public_id}"

    run_path = fn run ->
      ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/runs/#{run.number}"
    end

    assert has_element?(
             view,
             ~s(#{first} a[href="#{run_path.(first_run)}"]),
             "Run #{first_run.number}"
           )

    assert has_element?(
             view,
             ~s(#{second} a[href="#{run_path.(second_run)}"]),
             "Run #{second_run.number}"
           )
  end

  test "a row has the branch, the commits with the base, the change with its text, the fixes and Head",
       ctx do
    process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
    work_item = at_shape!(ctx.scope)
    %{one: one, two: two, first_run: first_run} = two_runs!(work_item)

    {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

    first = "#work-item-tab-output-submission-#{one.public_id}-r0"
    assert has_element?(view, "#{first}-branch", "qory/wi_qk5p97dt9vdq39a2")
    assert has_element?(view, "#{first}-branch a", "a1a1a1a")
    assert has_element?(view, "#{first}-commits", "3 commits")
    assert has_element?(view, "#{first}-base", "9f9f9f9")
    assert has_element?(view, "#{first}-base", "Base: where the branch starts")
    assert has_element?(view, "#{first}-c0", "d-2 · Show the dates at checkout")
    assert has_element?(view, "#{first}-c1", "Fix of review finding f1")
    assert has_element?(view, "#{first}-c2", "Fix of review finding f2")
    assert has_element?(view, "#{first}-c2 .badge", "Head")
    refute has_element?(view, "#{first}-c0 .badge")
    refute has_element?(view, "#{first}-c1 .badge")
    assert has_element?(view, "#{first}-draft", "#34 “Show delivery dates at checkout”")

    # The second run's base is where the first run's submission ends.
    second = "#work-item-tab-output-submission-#{two.public_id}-r0"
    assert has_element?(view, "#{second}-base", "Base: the head of Run #{first_run.number}")
    assert has_element?(view, "#{second}-commits", "1 commit")
  end

  test "the first row's commits are open and an older row's closed", ctx do
    process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
    work_item = at_shape!(ctx.scope)
    %{one: one, two: two} = two_runs!(work_item)

    {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

    assert has_element?(view, "#work-item-tab-output-submission-#{two.public_id}-r0-fold[open]")
    refute has_element?(view, "#work-item-tab-output-submission-#{one.public_id}-r0-fold[open]")
  end

  test "a commit with no address shows its short id with no link", ctx do
    process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
    work_item = at_shape!(ctx.scope)
    %{dispatch_run: run} = shape_run!(work_item)

    repository = %{repository() | "commits" => [%{"commit" => @head, "step" => "fix:f1"}]}
    version = submission!(run, work_item, repository)

    {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

    commit = "#work-item-tab-output-submission-#{version.public_id}-r0-c0"
    assert has_element?(view, commit, "a1a1a1a")
    refute has_element?(view, "#{commit} a")
    assert has_element?(view, "#{commit} .badge", "Head")
  end

  test "a draft's number has its system's mark beside it", ctx do
    process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
    work_item = at_shape!(ctx.scope)
    %{dispatch_run: run} = shape_run!(work_item)
    version = submission!(run, work_item, repository())

    collection =
      collection_fixture(ctx.scope,
        target_system: "git.example.com",
        target_path: "northwind/storefront"
      )

    adapter = Repo.get!(Apiary.Nodes.Node, collection.adapter_id)
    name = Apiary.Adapters.title(adapter)

    {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

    draft = "#work-item-tab-output-submission-#{version.public_id}-r0-draft"
    assert has_element?(view, ~s(#{draft} [role="img"][aria-label="#{name}"]))
    assert has_element?(view, "#{draft} a", "#34")
  end

  test "a submission with no list of commits renders the branch and the draft only", ctx do
    process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
    work_item = at_shape!(ctx.scope)
    %{dispatch_run: run} = shape_run!(work_item)
    repository = repository() |> Map.delete("base") |> Map.delete("commits")
    version = submission!(run, work_item, repository)

    {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

    row = "#work-item-tab-output-submission-#{version.public_id}-r0"
    assert has_element?(view, "#{row}-branch", "a1a1a1a")
    assert has_element?(view, "#{row}-draft")
    refute has_element?(view, "#{row}-commits")
  end

  test "a run that sent no draft says so", ctx do
    process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
    work_item = at_shape!(ctx.scope)
    %{dispatch_run: run} = shape_run!(work_item)
    version = submission!(run, work_item, %{repository() | "draft" => %{"none" => "not-passed"}})

    {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

    row = "#work-item-tab-output-submission-#{version.public_id}-r0"
    assert has_element?(view, "#{row}-no-draft", "The run sent no draft to the destination.")
    refute has_element?(view, "#{row}-draft")
  end

  test "a submission with many commits lists at most 100 and counts them all", ctx do
    process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
    work_item = at_shape!(ctx.scope)
    %{dispatch_run: run} = shape_run!(work_item)

    commits =
      for n <- 1..150 do
        %{
          "commit" =>
            n |> Integer.to_string(16) |> String.pad_leading(40, "0") |> String.downcase(),
          "step" => "fix:f#{n}"
        }
      end

    head = List.last(commits)["commit"]

    version =
      submission!(run, work_item, %{repository() | "commits" => commits, "commit" => head})

    {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

    row = "#work-item-tab-output-submission-#{version.public_id}-r0"
    assert has_element?(view, "#{row}-commits", "150 commits")
    assert has_element?(view, "#{row}-c99 .badge", "Head")
    refute has_element?(view, "#{row}-c100")
  end

  test "a stored string is text, never markup", ctx do
    process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
    work_item = at_shape!(ctx.scope)
    %{dispatch_run: run} = shape_run!(work_item)

    evil = "<script>alert(1)</script>"

    repository = %{
      repository()
      | "path" => evil,
        "draft" => %{"number" => 34, "title" => evil, "url" => "javascript:alert(1)"},
        "commits" => [%{"commit" => @head, "step" => "deliverable:<b>x</b>"}]
    }

    version = submission!(run, work_item, repository)

    {:ok, view, html} = live(ctx.conn, stage_path(ctx.scope, work_item))

    refute html =~ "<script>alert(1)"
    refute html =~ "<b>x</b>"
    draft = "#work-item-tab-output-submission-#{version.public_id}-r0-draft"
    assert has_element?(view, draft, "<script>alert(1)</script>")
    refute has_element?(view, "#{draft} a")
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

  describe "the words of the workspace's domain" do
    test "a software workspace reads Branch, Commits, Head and the head of the run", ctx do
      process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
      work_item = at_shape!(ctx.scope)
      %{one: one, two: two, first_run: first_run} = two_runs!(work_item)

      {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

      row = "#work-item-tab-output-submission-#{two.public_id}-r0"
      assert has_element?(view, "#{row}-branch + dt", "Commits")
      assert has_element?(view, "#{row}-branch", "qory/wi_qk5p97dt9vdq39a2")
      assert has_element?(view, "#{row}-base", "Base: the head of Run #{first_run.number}")
      assert has_element?(view, "#{row}-commits .badge", "Head")

      words =
        view
        |> element("#work-item-tab-output-submission")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert words =~ "Branch"
      assert words =~ "Commits"
      refute words =~ "Latest"
      refute words =~ "Reference"
      refute words =~ "Revisions"
      refute words =~ "the result of Run"
      assert has_element?(view, "#work-item-tab-output-submission-#{one.public_id}")
    end

    test "a workspace that is not a software factory reads the engine's words", ctx do
      process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
      work_item = at_shape!(ctx.scope)
      %{two: two, first_run: first_run} = two_runs!(work_item)
      scope = with_domain(ctx.scope, "example")

      {:ok, view, _html} = live(ctx.conn, stage_path(scope, work_item))

      row = "#work-item-tab-output-submission-#{two.public_id}-r0"
      assert has_element?(view, "#{row}-base", "Base: the result of Run #{first_run.number}")
      assert has_element?(view, "#{row}-commits .badge", "Latest")

      words =
        view
        |> element("#work-item-tab-output-submission")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert words =~ "Reference"
      assert words =~ "Revisions"
      assert words =~ "Base: where the work starts"
      refute words =~ "Head"
      refute words =~ "Branch"
      refute words =~ "Commits"
      refute words =~ "commit"
      refute words =~ "the head of Run"
    end
  end

  describe "two repositories" do
    test "each has its path, draft, base, commits and head mark", ctx do
      process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
      work_item = at_shape!(ctx.scope)
      %{dispatch_run: run} = shape_run!(work_item)

      other = String.duplicate("b2", 20)

      second = %{
        "system" => "forge.example.org",
        "path" => "northwind/basket",
        "commit" => other,
        "base" => %{"commit" => String.duplicate("8a", 20)},
        "commits" => [
          %{"commit" => String.duplicate("5d", 20), "step" => "fix:f9"},
          %{"commit" => other, "step" => "fix:f10"}
        ],
        "draft" => %{
          "number" => 35,
          "url" => "https://forge.example.org/pulls/35",
          "title" => "Cache it"
        }
      }

      version = submission!(run, work_item, repository(), second)

      {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

      row = "#work-item-tab-output-submission-#{version.public_id}"
      assert has_element?(view, "#{row}-r0-path", "northwind/storefront")
      assert has_element?(view, "#{row}-r1-path", "northwind/basket")
      assert has_element?(view, "#{row}-r0-draft", "#34")
      assert has_element?(view, "#{row}-r1-draft", "#35")
      assert has_element?(view, "#{row}-r0-commits", "3 commits")
      assert has_element?(view, "#{row}-r1-commits", "2 commits")
      assert has_element?(view, "#{row}-r0-c2 .badge", "Head")
      assert has_element?(view, "#{row}-r1-c1 .badge", "Head")
      assert has_element?(view, "#{row}-r1-base", "8a8a8a8")
    end
  end

  describe "a person's version of the submission type (696 (c))" do
    # A person's version of `type` at Shape's gate, as `Apiary.Stages.add_version/5` stores
    # an upload: no run. `name` is `main` unless given.
    defp person_version!(scope, work_item, type, filename, content_type, binary, name \\ "main") do
      {:ok, version} =
        Apiary.Stages.add_version(
          scope,
          Repo.get!(WorkItem, work_item.id),
          type,
          [%{filename: filename, content_type: content_type, binary: binary}],
          name: name
        )

      version
    end

    # A person's version of the submission type. `Apiary.Artifacts.push/5` refuses a
    # person's push of a type that `submit` sets (`unknown_type`), but a person's version of
    # it remains where a work item moves to a process version that sets `submit` after the
    # person stored it: `Apiary.Processes.assign/3`, or a new take in
    # (`Apiary.Stages.take_in/2`), which moves it to the current version. The helper makes
    # one in a step: the push runs while the process versions have no `submit`, and each
    # gets its `template` back after. Its document has a draft in `northwind/by-hand`, which
    # no gate line shows.
    defp person_submission!(scope, work_item, name \\ "main") do
      kept =
        Repo.all(
          from v in ProcessVersion,
            where: v.workspace_id == ^scope.workspace.id,
            select: {v.id, v.template}
        )

      for {id, template} <- kept,
          is_map(template),
          do: template!(id, Map.delete(template, "submit"))

      version =
        person_version!(
          scope,
          work_item,
          "submission",
          "submission.json",
          "application/json",
          Jason.encode!(%{"ref" => "by-hand", "repositories" => [by_hand()]}),
          name
        )

      for {id, template} <- kept, do: template!(id, template)
      version
    end

    defp by_hand do
      %{
        repository()
        | "path" => "northwind/by-hand",
          "draft" => %{
            "number" => 99,
            "url" => "https://git.example.com/northwind/by-hand/pulls/99",
            "title" => "By hand",
            "state" => "draft",
            "action" => "opened"
          }
      }
    end

    defp template!(id, template) do
      {1, _rows} =
        Repo.update_all(from(v in ProcessVersion, where: v.id == ^id), set: [template: template])
    end

    defp at_gate!(work_item) do
      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_state: :at_gate]
        )

      Repo.get!(WorkItem, work_item.id)
    end

    defp notes_type!(scope) do
      Repo.delete_all(
        from t in Apiary.Artifacts.Type,
          where: t.workspace_id == ^scope.workspace.id and t.name == "notes"
      )

      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "notes",
          "base_view" => "document",
          "size_limit" => 1_048_576,
          "max_files" => 1
        })
    end

    defp gate_frames(work_item) do
      work_item = Repo.get!(WorkItem, work_item.id) |> Repo.preload(:process_version)
      Apiary.Stages.gate_frames(work_item, work_item.process_version, @shape)
    end

    test "is neither recorded nor framed; a person's version of another output is", ctx do
      notes_type!(ctx.scope)
      process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"}, outputs: ["notes"])
      work_item = at_shape!(ctx.scope)
      %{one: one, two: two} = two_runs!(work_item)
      work_item = at_gate!(work_item)

      submission = person_submission!(ctx.scope, work_item)

      notes =
        person_version!(ctx.scope, work_item, "notes", "notes.md", "text/markdown", "## By hand")

      assert submission.number > two.number

      # The recorded set: the newest run's submission and the person's notes.
      ids = for %{version: version} <- gate_frames(work_item), do: version.public_id
      assert two.public_id in ids
      assert notes.public_id in ids
      refute submission.public_id in ids

      {:ok, view, html} = live(ctx.conn, stage_path(ctx.scope, work_item))

      # The Submissions list has the runs' rows alone.
      rows =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#work-item-tab-output-submission-list > ul > li")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))

      assert rows == [
               "work-item-tab-output-submission-#{two.public_id}",
               "work-item-tab-output-submission-#{one.public_id}"
             ]

      refute has_element?(view, "#work-item-tab-output-submission-#{submission.public_id}")

      # The gate card shows the run's version and links nowhere to the person's.
      assert has_element?(
               view,
               ~s(#work-item-stage-gate-version-submission[href$="/#{two.public_id}"])
             )

      refute has_element?(view, ~s(#work-item-stage-gate [href$="/#{submission.public_id}"]))

      # The notes frame has the person's version with its caption.
      short = ApiaryWeb.People.short(ctx.user.email)

      assert has_element?(
               view,
               "#work-item-tab-output-notes",
               "Version #{notes.number} · #{short}"
             )

      # The approval records the same set.
      {:ok, _approved} =
        Apiary.Stages.approve(ctx.scope, Repo.get!(WorkItem, work_item.id), nil,
          expect_stage: @shape
        )

      recorded =
        Repo.one(
          from d in Apiary.Stages.GateDecision,
            where:
              d.work_item_id == ^work_item.id and d.kind == :approve and d.stage_id == ^@shape,
            select: d.versions
        )

      assert two.public_id in recorded
      assert notes.public_id in recorded
      refute submission.public_id in recorded

      # Shape's tab after the gate frames the versions that approval recorded.
      ids = for %{version: version} <- gate_frames(work_item), do: version.public_id
      assert Enum.sort(ids) == Enum.sort(recorded)
    end

    test "a gate none approval records the run's version, not a person's later one", ctx do
      process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"}, gate: "none")
      work_item = at_shape!(ctx.scope)

      parent = self()

      _work_item =
        end_run!(work_item, fn run, _registered ->
          held = Repo.get!(WorkItem, run.work_item_id)
          ran = submission!(run, held, repository())

          person = person_submission!(ctx.scope, held)

          verdict = %{"verdict" => "passed"}
          opts = [stage_id: run.stage_id]

          {:ok, _verdict} =
            Apiary.Stages.Artifacts.push_json({:run, run}, held, "verdict", verdict, opts)

          send(parent, {:versions, ran, person})
        end)

      assert_received {:versions, ran, person}
      assert person.number > ran.number

      recorded =
        Repo.one(
          from d in Apiary.Stages.GateDecision,
            where:
              d.work_item_id == ^work_item.id and d.kind == :approve and d.stage_id == ^@shape,
            select: d.versions
        )

      assert ran.public_id in recorded
      refute person.public_id in recorded
    end

    test "is no change: the gate card and the next stage's inputs have the run's version; a person's notes count",
         ctx do
      notes_type!(ctx.scope)

      process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"},
        outputs: ["notes"],
        build_inputs: ["submission", "notes"]
      )

      work_item = at_shape!(ctx.scope)
      %{dispatch_run: run} = shape_run!(work_item)
      ran = submission!(run, work_item, repository())
      push!(run, work_item, "notes", "notes.md", "text/markdown", "## By the run")
      work_item = at_gate!(work_item)

      submission = person_submission!(ctx.scope, work_item)

      notes =
        person_version!(ctx.scope, work_item, "notes", "notes.md", "text/markdown", "## By hand")

      # The gate card: the run's submission, the person's notes.
      {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

      assert has_element?(
               view,
               ~s(#work-item-stage-gate-version-submission[href$="/#{ran.public_id}"]),
               "submission v#{ran.number}"
             )

      assert has_element?(
               view,
               ~s(#work-item-stage-gate-version-notes[href$="/#{notes.public_id}"]),
               "notes v#{notes.number}"
             )

      # The run API's view of the gate agrees.
      outputs = Map.new(Apiary.Stages.status(work_item).outputs, &{&1.type, &1.version})
      assert outputs["submission"].id == ran.public_id
      assert outputs["notes"].id == notes.public_id

      {:ok, _approved} =
        Apiary.Stages.approve(ctx.scope, Repo.get!(WorkItem, work_item.id), nil,
          expect_stage: @shape
        )

      work_item = Repo.get!(WorkItem, work_item.id)
      assert work_item.stage_id == @build

      # A person's later versions at Build: the notes are a change, the submission is not.
      later_submission = person_submission!(ctx.scope, work_item)

      later_notes =
        person_version!(ctx.scope, work_item, "notes", "notes.md", "text/markdown", "## Later")

      assert later_submission.number > submission.number

      inputs = Map.new(Apiary.Stages.inputs(work_item), &{&1.type, &1.version})
      assert inputs["submission"].id == ran.public_id
      assert inputs["notes"].id == later_notes.public_id
    end

    test "the gate card's draft line has the run's submission, not a person's", ctx do
      process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
      work_item = at_shape!(ctx.scope)
      %{dispatch_run: run} = shape_run!(work_item)
      _ran = submission!(run, work_item, repository())
      work_item = at_gate!(work_item)
      _person = person_submission!(ctx.scope, work_item)

      {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

      assert has_element?(
               view,
               "#work-item-stage-gate-draft-0",
               "the draft in northwind/storefront"
             )

      refute has_element?(view, "#work-item-stage-gate", "northwind/by-hand")
    end

    test "a person's later version marks no output newer or changed after approval", ctx do
      process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
      work_item = at_shape!(ctx.scope)
      %{dispatch_run: run} = shape_run!(work_item)
      ran = submission!(run, work_item, repository())
      work_item = at_gate!(work_item)

      {:ok, _approved} =
        Apiary.Stages.approve(ctx.scope, work_item, nil, expect_stage: @shape)

      work_item = Repo.get!(WorkItem, work_item.id)
      assert work_item.stage_id == @build
      later = person_submission!(ctx.scope, work_item)
      assert later.number > ran.number

      # Back at Shape, a version made at Build after Shape's approval would read as a change
      # after approval, were it a run's.
      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_id: @shape, stage_state: :at_gate]
        )

      work_item = Repo.get!(WorkItem, work_item.id)

      # `GET artifacts` reads the index: the approved version, no change, every version.
      entry =
        work_item
        |> Apiary.Stages.artifact_index()
        |> Enum.find(&(&1.type == "submission" and &1.name == "main"))

      assert entry.approved_version == ran.public_id
      refute entry.changed_after_approval
      assert Enum.map(entry.versions, & &1.id) == [later.public_id, ran.public_id]

      # The marks of the page: no newer version, no change.
      page = ApiaryWeb.WorkItemLive.Workflow.page(ctx.scope, work_item)
      mark = Enum.find(page.index, &(&1.type == "submission"))
      assert mark.approved == ran.number
      assert mark.newer == nil
      refute mark.changed_after_approval

      {:ok, _view, html} = live(ctx.conn, stage_path(ctx.scope, work_item))
      refute html =~ "is newer"
      refute html =~ "Changed after approval"
    end

    test "the Exists check passes on a run's version of the type, not a person's", ctx do
      process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"}, required: true)
      work_item = ctx.scope |> at_shape!() |> at_gate!()
      _person = person_submission!(ctx.scope, work_item)

      assert Apiary.Stages.missing_outputs(work_item) == ["submission"]
      outputs = Map.new(Apiary.Stages.status(work_item).outputs, &{&1.type, &1})
      assert outputs["submission"].check == :missing

      %{dispatch_run: run} = shape_run!(work_item)
      _ran = submission!(run, work_item, repository())

      assert Apiary.Stages.missing_outputs(work_item) == []
      outputs = Map.new(Apiary.Stages.status(work_item).outputs, &{&1.type, &1})
      assert outputs["submission"].check == :passed
    end

    test "the row of a frame of another name of the type links the run's version", ctx do
      process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"})
      work_item = at_shape!(ctx.scope)
      %{dispatch_run: run} = shape_run!(work_item)

      {:ok, ran} =
        Artifacts.push(
          {:run, run},
          work_item,
          "submission",
          [
            %{
              filename: "submission.json",
              content_type: "application/json",
              binary: Jason.encode!(%{"ref" => "qory/second", "repositories" => [repository()]})
            }
          ],
          stage_id: @shape,
          name: "second"
        )

      work_item = at_gate!(work_item)
      person = person_submission!(ctx.scope, work_item, "second")
      assert person.number > ran.number

      {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

      row = "#work-item-tab-output-submission--second---row"
      assert has_element?(view, ~s(#{row} a[href$="/#{ran.public_id}"]))
      refute has_element?(view, ~s(#{row} a[href$="/#{person.public_id}"]))
    end

    test "a person's version alone: no frame, no gate line, no output and no input", ctx do
      process!(ctx.scope, %{"type" => "submission", "send" => "end_of_run"},
        build_inputs: ["submission"]
      )

      work_item = ctx.scope |> at_shape!() |> at_gate!()
      person = person_submission!(ctx.scope, work_item)

      assert gate_frames(work_item) == []

      {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))
      refute has_element?(view, "#work-item-tab-output-submission")
      refute has_element?(view, "#work-item-stage-gate-draft-0")
      refute has_element?(view, ~s(#work-item-stage-gate [href$="/#{person.public_id}"]))

      outputs = Map.new(Apiary.Stages.status(work_item).outputs, &{&1.type, &1.version})
      assert outputs["submission"] == nil

      {:ok, _approved} =
        Apiary.Stages.approve(ctx.scope, work_item, nil, expect_stage: @shape)

      work_item = Repo.get!(WorkItem, work_item.id)
      assert work_item.stage_id == @build
      inputs = Map.new(Apiary.Stages.inputs(work_item), &{&1.type, &1.version})
      assert inputs["submission"] == nil
    end

    test "on a version a person saved, the harness record's submit type still leaves a person's out",
         ctx do
      submit = %{"type" => "submission", "send" => "end_of_run"}
      version = process!(ctx.scope, submit, person_saved: true, required: true)
      assert version.template == nil
      assert %{"submit" => ^submit} = Processes.harness_template(version)

      work_item = ctx.scope |> at_shape!() |> at_gate!()
      assert work_item.process_version_id == version.id
      _person = person_submission!(ctx.scope, work_item)

      # The Exists check: a person's version alone does not pass.
      assert Apiary.Stages.missing_outputs(work_item) == ["submission"]

      %{dispatch_run: run} = shape_run!(work_item)
      ran = submission!(run, work_item, repository())

      {:ok, second} =
        Artifacts.push(
          {:run, run},
          work_item,
          "submission",
          [
            %{
              filename: "submission.json",
              content_type: "application/json",
              binary: Jason.encode!(%{"ref" => "qory/second", "repositories" => [repository()]})
            }
          ],
          stage_id: @shape,
          name: "second"
        )

      later = person_submission!(ctx.scope, work_item)
      person_second = person_submission!(ctx.scope, work_item, "second")
      assert later.number > ran.number
      assert Apiary.Stages.missing_outputs(work_item) == []

      # The draft line has the run's draft, and the row of `second` links the run's version.
      {:ok, view, _html} = live(ctx.conn, stage_path(ctx.scope, work_item))

      assert has_element?(
               view,
               "#work-item-stage-gate-draft-0",
               "the draft in northwind/storefront"
             )

      refute has_element?(view, "#work-item-stage-gate", "northwind/by-hand")
      row = "#work-item-tab-output-submission--second---row"
      # The frame of `second` is folded beside the Submissions list: its row shows once open.
      view |> element("#work-item-tab-output-submission--second---s") |> render_click()
      assert has_element?(view, ~s(#{row} a[href$="/#{second.public_id}"]))
      refute has_element?(view, ~s(#{row} a[href$="/#{person_second.public_id}"]))

      # The approval records the run's version, and the marks have no newer version for the
      # person's later one.
      {:ok, _approved} =
        Apiary.Stages.approve(ctx.scope, Repo.get!(WorkItem, work_item.id), nil,
          expect_stage: @shape
        )

      page = ApiaryWeb.WorkItemLive.Workflow.page(ctx.scope, Repo.get!(WorkItem, work_item.id))
      mark = Enum.find(page.index, &(&1.type == "submission" and &1.name == "main"))
      assert mark.approved == ran.number
      assert mark.newer == nil
    end

    test "with no submit type, a person's version of the type is recorded as any other", ctx do
      process!(ctx.scope, nil)
      work_item = at_shape!(ctx.scope)
      %{dispatch_run: run} = shape_run!(work_item)
      _run_version = submission!(run, work_item, repository())
      work_item = at_gate!(work_item)

      submission =
        person_version!(
          ctx.scope,
          work_item,
          "submission",
          "submission.json",
          "application/json",
          Jason.encode!(%{"ref" => "by-hand"})
        )

      ids = for %{version: version} <- gate_frames(work_item), do: version.public_id
      assert ids == [submission.public_id]
    end
  end
end
