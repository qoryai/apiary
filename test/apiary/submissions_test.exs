defmodule Apiary.SubmissionsTest do
  # The rows of a work item's submissions (`Apiary.Submissions`): one for each version of
  # the type in `submit.type` of the process version, with the commits of the run, the
  # `Base` line from the earlier submissions, the text of each change from the plan of
  # the type the run's walk recorded (`run_harnesses.plan_type`), and every stored member
  # read as untrusted. Not async: the store's root is the application's setting.
  use Apiary.DataCase, async: false

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Submissions}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Organisations.Workspace
  alias Apiary.Artifacts.Type
  alias Apiary.Processes.Version, as: ProcessVersion
  alias Apiary.Stages.GateDecision

  @moduletag :tmp_dir
  @moduletag needs: [:workflow_model, :factory]

  @build "st_6ns22c4pav"
  @submit %{"type" => "submission", "send" => "end_of_run"}
  @head String.duplicate("a1", 20)
  @base String.duplicate("9f", 20)
  @change String.duplicate("4c", 20)
  @fix_one String.duplicate("7e", 20)
  @plan """
  ## Summary

  Dates at checkout.

  ## Deliverables

  | Id | Change | Criteria | Files | Check |
  |---|---|---|---|---|
  | d-1 | Compute the delivery date | AC-1, "Date" | `src/date.ts` | `tests/date.test.ts` |
  | d-2 | Show the dates at checkout | AC-2, "Shown" | `src/page.tsx` | scenario-1 |

  ## Commands

  | Kind | Command | Result file | Source |
  |---|---|---|---|
  | full | `npm test` | none | found |
  """

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    scope = without_template_types(scope_fixture())
    work_item = work_item_fixture(scope)
    %{dispatch_run: first, run: first_run} = explore_run_fixture(work_item, state: :handed_over)
    %{dispatch_run: second, run: second_run} = explore_run_fixture(work_item, state: :handed_over)

    for {name, view} <- [{"submission", "structured"}, {"build-plan", "document"}] do
      {:ok, _type} =
        Artifacts.create_type(
          scope,
          scope.workspace,
          Map.merge(%{"name" => name, "base_view" => view}, definition(view))
        )
    end

    ctx = %{
      scope: scope,
      work_item: work_item,
      first: first,
      second: second,
      first_run: first_run,
      first_number: first_run.number,
      second_number: second_run.number
    }

    ctx = submits!(ctx, @submit)
    plan_type!(ctx.first, "build-plan")
    plan_type!(ctx.second, "build-plan")
    ctx
  end

  # The plan type of the run's walk (`run_harnesses.plan_type`), nil for none.
  defp plan_type!(%DispatchRun{id: id}, type) do
    case Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^id),
           set: [plan_type: type]
         ) do
      {0, _rows} ->
        Repo.insert!(%RunHarness{
          dispatch_run_id: id,
          state: :resolved,
          origin: :none,
          plan_type: type
        })

        :ok

      {1, _rows} ->
        :ok
    end
  end

  defp definition("structured"), do: %{"json_schema" => %{"type" => "object"}}
  defp definition("document"), do: %{"size_limit" => 1_048_576, "max_files" => 1}

  defp without_template_types(%{workspace: %{id: id}} = scope) do
    Repo.delete_all(from t in Type, where: t.workspace_id == ^id)
    Repo.update_all(from(w in Workspace, where: w.id == ^id), set: [shown_standard_types: nil])
    %{scope | workspace: Repo.get!(Workspace, id)}
  end

  # The process version of the runs, saved once, with `submit` in its template (nil for
  # none). Returns the runs read again.
  defp submits!(%{scope: scope, first: first, second: second} = ctx, submit) do
    version =
      case Repo.get(DispatchRun, first.id).process_version_id do
        nil ->
          {:ok, version} =
            Apiary.Processes.save(scope, scope.workspace, %{
              "schema" => "qory.process/v1",
              "machine" => "default",
              "stages" => [
                %{
                  "id" => @build,
                  "name" => "Build",
                  "inputs" => [],
                  "sequence" => [%{"workflow" => "build-it"}],
                  "outputs" => [],
                  "gate" => %{"kind" => "person", "approvers" => "members"}
                }
              ]
            })

          {2, _rows} =
            Repo.update_all(from(d in DispatchRun, where: d.id in ^[first.id, second.id]),
              set: [process_version_id: version.id]
            )

          version

        id ->
          Repo.get!(ProcessVersion, id)
      end

    template = %{"commit" => String.duplicate("a", 40)}
    template = if submit, do: Map.put(template, "submit", submit), else: template

    {1, _rows} =
      Repo.update_all(from(v in ProcessVersion, where: v.id == ^version.id),
        set: [template: template]
      )

    %{ctx | first: Repo.reload!(first), second: Repo.reload!(second)}
  end

  # A new current version of the workspace's process, with `submit` in its template (nil for
  # none), under another name of Build so that the save is a change.
  defp version!(%{scope: scope}, name, submit) do
    {:ok, version} =
      Apiary.Processes.save(scope, scope.workspace, %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "stages" => [
          %{
            "id" => @build,
            "name" => name,
            "inputs" => [],
            "sequence" => [%{"workflow" => "build-it"}],
            "outputs" => [],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          }
        ]
      })

    template = %{"commit" => String.duplicate("a", 40)}
    template = if submit, do: Map.put(template, "submit", submit), else: template

    {1, _rows} =
      Repo.update_all(from(v in ProcessVersion, where: v.id == ^version.id),
        set: [template: template]
      )

    version
  end

  defp json(value),
    do: [
      %{
        filename: "submission.json",
        content_type: "application/json",
        binary: Jason.encode!(value)
      }
    ]

  defp plan!(ctx, run, markdown \\ @plan, type \\ "build-plan") do
    {:ok, version} =
      Artifacts.push(
        {:run, run},
        ctx.work_item,
        type,
        [%{filename: "#{type}.md", content_type: "text/markdown", binary: markdown}],
        stage_id: @build
      )

    version
  end

  defp store!(ctx, run, value, opts \\ []) do
    {:ok, version} =
      Artifacts.push({:run, run}, ctx.work_item, "submission", json(value),
        stage_id: @build,
        name: Keyword.get(opts, :name, "main")
      )

    version
  end

  # The repository of a submission.
  defp repository(overrides \\ %{}) do
    Map.merge(
      %{
        "system" => "git.example.com",
        "path" => "northwind/storefront",
        "commit" => @head,
        "commit_url" => "https://git.example.com/northwind/storefront/commit/#{@head}",
        "base" => %{
          "commit" => @base,
          "commit_url" => "https://git.example.com/northwind/storefront/commit/#{@base}"
        },
        "commits" => [
          %{
            "commit" => @change,
            "step" => "deliverable:d-2",
            "commit_url" => "https://git.example.com/northwind/storefront/commit/#{@change}"
          },
          %{
            "commit" => @fix_one,
            "step" => "fix:f1",
            "commit_url" => "https://git.example.com/northwind/storefront/commit/#{@fix_one}"
          },
          %{
            "commit" => @head,
            "step" => "fix:f2",
            "commit_url" => "https://git.example.com/northwind/storefront/commit/#{@head}"
          }
        ],
        "draft" => %{
          "number" => 34,
          "url" => "https://git.example.com/northwind/storefront/pulls/34",
          "title" => "Show delivery dates at checkout",
          "state" => "draft",
          "action" => "opened"
        }
      },
      overrides
    )
  end

  defp submission(repository \\ repository()),
    do: %{
      "ref" => "qory/wi_qk5p97dt9vdq39a2",
      "verdict" => "passed",
      "repositories" => [repository]
    }

  defp rows(ctx, only \\ nil) do
    type = Submissions.type(ctx.work_item)
    Submissions.list(ctx.work_item, type, Artifacts.list(ctx.work_item), only)
  end

  defp repository_of(row), do: hd(row.repositories)

  describe "type/1" do
    test "is the type in submit.type of the work item's process version", ctx do
      assert Submissions.type(ctx.work_item) == "submission"
    end

    test "is nil for a process version with no submit", ctx do
      ctx = submits!(ctx, nil)
      assert Submissions.type(ctx.work_item) == nil
    end
  end

  describe "a submission with one change and two fixes" do
    test "lists the base, the change with its text, both fixes and the head", ctx do
      plan!(ctx, ctx.first)
      store!(ctx, ctx.first, submission())

      assert [row] = rows(ctx)
      repository = repository_of(row)

      assert repository.base == %{
               commit: @base,
               short: "9f9f9f9",
               url: "https://git.example.com/northwind/storefront/commit/#{@base}",
               line: :start
             }

      assert repository.count == 3

      assert [
               %{
                 short: "4c4c4c4",
                 step: {:change, "d-2", "Show the dates at checkout"},
                 head: false
               },
               %{short: "7e7e7e7", step: {:fix, "f1"}, head: false},
               %{short: "a1a1a1a", step: {:fix, "f2"}, head: true}
             ] = repository.commits

      assert repository.short == "a1a1a1a"
      assert repository.url == "https://git.example.com/northwind/storefront/commit/#{@head}"

      assert repository.draft ==
               {:draft,
                %{
                  number: 34,
                  url: "https://git.example.com/northwind/storefront/pulls/34",
                  title: "Show delivery dates at checkout"
                }}

      assert row.ref == "qory/wi_qk5p97dt9vdq39a2"
      assert row.approved == false
    end

    test "the change has no text where the plan has no such deliverable", ctx do
      plan!(ctx, ctx.first, "## Deliverables\n\n| Id | Change |\n|---|---|\n| d-9 | Other |\n")
      store!(ctx, ctx.first, submission())

      assert [row] = rows(ctx)
      assert [%{step: {:change, "d-2", nil}} | _fixes] = repository_of(row).commits
    end

    test "the change has no text where the work item has no plan", ctx do
      store!(ctx, ctx.first, submission())

      assert [row] = rows(ctx)
      assert [%{step: {:change, "d-2", nil}} | _fixes] = repository_of(row).commits
    end

    test "the change reads the plan that was newest when the submission was stored", ctx do
      plan!(ctx, ctx.first)
      store!(ctx, ctx.first, submission())

      plan!(
        ctx,
        ctx.second,
        "## Deliverables\n\n| Id | Change |\n|---|---|\n| d-2 | Show the dates in the basket |\n"
      )

      assert [row] = rows(ctx)

      assert [%{step: {:change, "d-2", "Show the dates at checkout"}} | _fixes] =
               repository_of(row).commits
    end

    test "a commit with a step the list does not word has no step", ctx do
      commits = [%{"commit" => @head, "step" => "unreviewed"}]
      store!(ctx, ctx.first, submission(repository(%{"commits" => commits})))

      assert [row] = rows(ctx)
      assert [%{step: nil, head: true, url: nil}] = repository_of(row).commits
    end
  end

  describe "the plan type of the run" do
    defp release_plan_type!(ctx) do
      {:ok, _type} =
        Artifacts.create_type(
          ctx.scope,
          ctx.scope.workspace,
          Map.merge(
            %{"name" => "release-plan", "base_view" => "document"},
            definition("document")
          )
        )
    end

    defp first_change(ctx) do
      assert [row] = rows(ctx)

      assert [%{step: {:change, "d-2", text}, short: "4c4c4c4"} | _fixes] =
               repository_of(row).commits

      text
    end

    test "a custom document type with a Deliverables table shows the texts", ctx do
      release_plan_type!(ctx)
      plan_type!(ctx.first, "release-plan")
      plan!(ctx, ctx.first, @plan, "release-plan")
      store!(ctx, ctx.first, submission())

      assert first_change(ctx) == "Show the dates at checkout"
    end

    test "the plan of another type shows no texts", ctx do
      release_plan_type!(ctx)
      plan_type!(ctx.first, "release-plan")
      plan!(ctx, ctx.first)
      store!(ctx, ctx.first, submission())

      assert first_change(ctx) == nil
    end

    test "a type with no Deliverables table shows no text and the commits stay", ctx do
      release_plan_type!(ctx)
      plan_type!(ctx.first, "release-plan")
      plan!(ctx, ctx.first, "## Summary\n\nDates at checkout.\n", "release-plan")
      plan!(ctx, ctx.first)
      store!(ctx, ctx.first, submission())

      assert [row] = rows(ctx)

      assert [
               %{short: "4c4c4c4", step: {:change, "d-2", nil}},
               %{short: "7e7e7e7"},
               %{head: true}
             ] =
               repository_of(row).commits
    end

    test "a nil plan type shows no text, though a build-plan exists", ctx do
      plan_type!(ctx.first, nil)
      plan!(ctx, ctx.first)
      store!(ctx, ctx.first, submission())

      assert first_change(ctx) == nil
    end

    test "a run with no walk shows no text, though a build-plan exists", ctx do
      %DispatchRun{id: id} = ctx.first
      {1, _rows} = Repo.delete_all(from h in RunHarness, where: h.dispatch_run_id == ^id)
      plan!(ctx, ctx.first)
      store!(ctx, ctx.first, submission())

      assert first_change(ctx) == nil
    end

    test "a version with only fix steps shows its commits and reads no run_harnesses", ctx do
      commits = [
        %{"commit" => @fix_one, "step" => "fix:f1"},
        %{"commit" => @head, "step" => "fix:f2"}
      ]

      plan!(ctx, ctx.first)
      store!(ctx, ctx.first, submission(repository(%{"commits" => commits})))

      parent = self()
      handler = "submissions-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == parent, do: send(parent, {:query, meta.query})
        end,
        nil
      )

      rows =
        try do
          rows(ctx)
        after
          :telemetry.detach(handler)
        end

      queries = Stream.repeatedly(fn -> receive(do: ({:query, q} -> q), after: (0 -> nil)) end)
      queries = queries |> Enum.take_while(& &1)

      assert queries != []
      refute Enum.any?(queries, &String.contains?(&1, "run_harnesses"))
      assert [row] = rows
      assert [%{step: {:fix, "f1"}}, %{step: {:fix, "f2"}}] = repository_of(row).commits
    end

    test "a later session of a shared run reads the plan type of the run's first session",
         ctx do
      release_plan_type!(ctx)

      {:ok, version} =
        Apiary.Processes.save(ctx.scope, ctx.scope.workspace, %{
          "schema" => "qory.process/v1",
          "machine" => "default",
          "stages" => [
            %{
              "id" => @build,
              "name" => "Shared build",
              "shared_run" => true,
              "inputs" => [],
              "sequence" => [
                %{"workflow" => "plan-the-build"},
                %{"workflow" => "implement-changes"}
              ],
              "outputs" => [],
              "gate" => %{"kind" => "person", "approvers" => "members"}
            }
          ]
        })

      {1, _rows} =
        Repo.update_all(from(v in ProcessVersion, where: v.id == ^version.id),
          set: [template: %{"commit" => String.duplicate("a", 40), "submit" => @submit}]
        )

      %DispatchRun{id: id} = ctx.second

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^id),
          set: [
            process_version_id: version.id,
            stage_id: @build,
            workflow: "plan-the-build",
            stage_entry: 0,
            round: 1
          ]
        )

      {1, _rows} =
        Repo.update_all(from(w in Apiary.WorkItems.WorkItem, where: w.id == ^ctx.work_item.id),
          set: [
            process_version_id: version.id,
            stage_id: @build,
            stage_state: :running,
            stage_entry: 0,
            stage_round: 1
          ]
        )

      {1, _rows} =
        Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^id),
          set: [workflow: "plan-the-build", plan_type: "release-plan"]
        )

      ctx = %{ctx | work_item: Repo.reload!(ctx.work_item)}
      run = Repo.get!(DispatchRun, id)
      {:ok, :ok} = Repo.transact(fn -> {:ok, Apiary.Stages.claim_sessions!(run, %{})} end)

      {:ok, _verdict} =
        Apiary.Stages.Artifacts.push_json(
          {:run, run},
          ctx.work_item,
          "verdict",
          %{"verdict" => "passed"},
          stage_id: @build
        )

      assert {:session, %{session: 2, workflow: "implement-changes"}} =
               Apiary.Stages.next_session(run, %{session: 1, state: "succeeded", reason: nil})

      plan!(ctx, run, @plan, "release-plan")

      plan!(
        ctx,
        run,
        "## Deliverables\n\n| Id | Change |\n|---|---|\n| d-2 | Build plan text |\n"
      )

      store!(ctx, run, submission())

      assert first_change(ctx) == "Show the dates at checkout"
    end

    test "build-plan as the plan type shows its texts, not those of another type", ctx do
      release_plan_type!(ctx)
      plan_type!(ctx.first, "build-plan")

      plan!(
        ctx,
        ctx.first,
        "## Deliverables\n\n| Id | Change |\n|---|---|\n| d-2 | Ship the dates |\n",
        "release-plan"
      )

      plan!(ctx, ctx.first)
      store!(ctx, ctx.first, submission())

      assert first_change(ctx) == "Show the dates at checkout"
    end

    test "each submission reads the plan of its run's type", ctx do
      release_plan_type!(ctx)
      plan_type!(ctx.first, "release-plan")

      plan!(
        ctx,
        ctx.first,
        "## Deliverables\n\n| Id | Change |\n|---|---|\n| d-2 | Ship the dates |\n",
        "release-plan"
      )

      plan!(ctx, ctx.second)
      store!(ctx, ctx.first, submission())
      store!(ctx, ctx.second, submission())

      assert [newest, oldest] = rows(ctx)

      assert [%{step: {:change, "d-2", "Show the dates at checkout"}} | _] =
               repository_of(newest).commits

      assert [%{step: {:change, "d-2", "Ship the dates"}} | _] = repository_of(oldest).commits
    end
  end

  describe "for_run/4, the run page's rows" do
    defp outputs_of(version),
      do: [%{name: "main", type: "submission", public_id: version.public_id}]

    defp run_change(ctx, version) do
      run = Repo.reload!(ctx.first_run)

      assert {%{rows: rows}, _cache} =
               Submissions.for_run(ctx.scope, run, outputs_of(version), %{})

      assert %{repositories: [%{commits: [%{step: {:change, "d-2", text}} | _]}]} =
               rows[version.public_id]

      text
    end

    test "a run with a plan type shows the change texts of its plan", ctx do
      plan!(ctx, ctx.first)
      version = store!(ctx, ctx.first, submission())

      assert run_change(ctx, version) == "Show the dates at checkout"
    end

    test "a run with no plan type shows no change text, though a build-plan exists", ctx do
      plan_type!(ctx.first, nil)
      plan!(ctx, ctx.first)
      version = store!(ctx, ctx.first, submission())

      assert run_change(ctx, version) == nil
    end
  end

  describe "the Base line" do
    test "is the head of the run whose submission ends at the base commit", ctx do
      store!(
        ctx,
        ctx.first,
        submission(repository(%{"commit" => @base, "base" => nil, "commits" => []}))
      )

      store!(ctx, ctx.second, submission())

      assert [newest, oldest] = rows(ctx)
      assert repository_of(newest).base.line == {:head, ctx.first_number}
      assert repository_of(oldest).base == nil
    end

    test "is where the work starts for a base that no earlier submission ended at", ctx do
      store!(ctx, ctx.first, submission())
      store!(ctx, ctx.second, submission())

      assert [newest, oldest] = rows(ctx)
      assert repository_of(newest).base.line == :start
      assert repository_of(oldest).base.line == :start
    end
  end

  describe "a submission with no list of commits" do
    test "has the branch and the draft and no base or commits", ctx do
      store!(ctx, ctx.first, submission(repository(%{"base" => nil, "commits" => nil})))

      assert [row] = rows(ctx)
      repository = repository_of(row)
      assert repository.base == nil
      assert repository.commits == []
      assert repository.count == 0
      assert repository.short == "a1a1a1a"
      assert {:draft, %{number: 34}} = repository.draft
    end

    test "with no member it has the row and no repository", ctx do
      store!(ctx, ctx.first, %{"ref" => "qory/wi_qk5p97dt9vdq39a2"})

      assert [%{repositories: [], ref: "qory/wi_qk5p97dt9vdq39a2"}] = rows(ctx)
    end
  end

  describe "the draft" do
    test "records why none was sent", ctx do
      draft = %{"none" => "not-passed"}
      store!(ctx, ctx.first, submission(repository(%{"draft" => draft})))

      assert [row] = rows(ctx)
      assert repository_of(row).draft == :none
    end

    test "a draft with an address that is not https has no link", ctx do
      draft = %{
        "number" => 34,
        "url" => "javascript:alert(1)",
        "title" => "T",
        "state" => "draft",
        "action" => "opened"
      }

      store!(ctx, ctx.first, submission(repository(%{"draft" => draft})))

      assert [row] = rows(ctx)
      assert {:draft, %{number: 34, url: nil}} = repository_of(row).draft
    end

    test "names each system of a draft by its collection's integration", ctx do
      store!(ctx, ctx.first, submission())
      assert [row] = rows(ctx)
      assert Submissions.draft_systems([row]) == ["git.example.com"]
      assert Submissions.system_names(ctx.work_item, ["git.example.com"]) == %{}
      assert Submissions.system_names(ctx.work_item, []) == %{}

      collection =
        collection_fixture(ctx.scope,
          target_system: "git.example.com",
          target_path: "northwind/storefront"
        )

      adapter = Repo.get!(Apiary.Nodes.Node, collection.adapter_id)

      assert Submissions.system_names(ctx.work_item, ["git.example.com", "other"]) ==
               %{"git.example.com" => Apiary.Adapters.title(adapter)}
    end
  end

  describe "what is stored is read as untrusted" do
    test "a link that is not https, or has a user name, is dropped", ctx do
      commits = [
        %{"commit" => @change, "commit_url" => "http://git.example.com/x"},
        %{"commit" => @fix_one, "commit_url" => "https://user:secret@git.example.com/x"},
        %{"commit" => @head, "commit_url" => "javascript:alert(1)"}
      ]

      store!(
        ctx,
        ctx.first,
        submission(
          repository(%{
            "commits" => commits,
            "commit_url" => "data:text/html,x",
            "base" => %{"commit" => @base, "commit_url" => "//evil.example.com"}
          })
        )
      )

      assert [row] = rows(ctx)
      repository = repository_of(row)
      assert repository.url == nil
      assert repository.base.url == nil
      assert Enum.map(repository.commits, & &1.url) == [nil, nil, nil]
    end

    test "a commit that is not a full hex id is left out", ctx do
      commits = [
        %{"commit" => "abc"},
        %{"commit" => String.duplicate("G", 40)},
        %{"commit" => String.upcase(@change)},
        %{"commit" => 7},
        "no",
        %{"commit" => @head}
      ]

      store!(ctx, ctx.first, submission(repository(%{"commits" => commits})))

      assert [row] = rows(ctx)
      assert [%{commit: @head}] = repository_of(row).commits
    end

    test "a repository with a head that is not a full hex id is left out", ctx do
      repositories = [repository(%{"commit" => "<script>"}), repository()]
      store!(ctx, ctx.first, %{"ref" => "qory/wi_1", "repositories" => repositories})

      assert [row] = rows(ctx)
      assert [%{commit: @head}] = row.repositories
    end

    test "a step with a character outside the id form has no step", ctx do
      commits = [
        %{"commit" => @change, "step" => "deliverable:<b>x</b>"},
        %{"commit" => @fix_one, "step" => "fix:" <> String.duplicate("f", 65)},
        %{"commit" => @head, "step" => 5}
      ]

      store!(ctx, ctx.first, submission(repository(%{"commits" => commits})))

      assert [row] = rows(ctx)
      assert Enum.map(repository_of(row).commits, & &1.step) == [nil, nil, nil]
    end

    test "a list that is not a list, and a repository that is not an object, are left out", ctx do
      store!(ctx, ctx.first, %{"ref" => "r", "repositories" => "x"})
      store!(ctx, ctx.second, %{"ref" => 5, "repositories" => [1, nil, "x"]})

      assert [%{repositories: [], ref: nil}, %{repositories: [], ref: "r"}] = rows(ctx)
    end

    test "at most 20 repositories are read", ctx do
      repositories = for n <- 1..25, do: repository(%{"path" => "northwind/repo-#{n}"})
      store!(ctx, ctx.first, %{"ref" => "r", "repositories" => repositories})

      assert [row] = rows(ctx)
      assert length(row.repositories) == 20
    end
  end

  describe "many commits" do
    test "list the first 99 and the head, and count them all", ctx do
      commits =
        for n <- 1..150 do
          %{"commit" => hex(n), "step" => "fix:f#{n}"}
        end

      head = hex(150)
      store!(ctx, ctx.first, submission(repository(%{"commit" => head, "commits" => commits})))

      assert [row] = rows(ctx)
      repository = repository_of(row)
      assert repository.count == 150
      assert length(repository.commits) == 100

      assert List.last(repository.commits) == %{
               commit: head,
               short: binary_part(head, 0, 7),
               url: nil,
               step: {:fix, "f150"},
               head: true
             }

      assert Enum.at(repository.commits, 98).step == {:fix, "f99"}
    end

    test "list the first 100 when the head is among them", ctx do
      commits = for n <- 1..150, do: %{"commit" => hex(n)}
      store!(ctx, ctx.first, submission(repository(%{"commit" => hex(5), "commits" => commits})))

      assert [row] = rows(ctx)
      repository = repository_of(row)
      assert length(repository.commits) == 100
      assert Enum.count(repository.commits, & &1.head) == 1
      assert Enum.at(repository.commits, 4).head
    end

    defp hex(n),
      do: n |> Integer.to_string(16) |> String.pad_leading(40, "0") |> String.downcase()
  end

  describe "which versions are listed" do
    test "a version of a run a member cancelled is left out", ctx do
      store!(ctx, ctx.first, submission())
      store!(ctx, ctx.second, submission())

      {1, _rows} =
        Repo.update_all(
          from(r in Apiary.Runs.Run, where: r.dispatch_run_id == ^ctx.second.id),
          set: [cancel_requested_at: DateTime.utc_now()]
        )

      assert [%{run: run}] = rows(ctx)
      assert run == ctx.first_number
    end

    test "a version approved at a gate has the mark", ctx do
      version = store!(ctx, ctx.first, submission())

      Repo.insert!(%GateDecision{
        organisation_id: ctx.work_item.organisation_id,
        workspace_id: ctx.work_item.workspace_id,
        work_item_id: ctx.work_item.id,
        process_version_id: Apiary.Processes.version_for(ctx.work_item).id,
        user_id: ctx.scope.user.id,
        stage_id: @build,
        kind: :approve,
        versions: [version.public_id],
        take_in: ctx.work_item.take_in,
        inserted_at: DateTime.utc_now()
      })

      assert [%{approved: true}] = rows(ctx)
    end

    test "a row has the end of its run", ctx do
      store!(ctx, ctx.first, submission())

      exited =
        Repo.one!(
          from r in Apiary.Runs.Run,
            where: r.dispatch_run_id == ^ctx.first.id,
            select: r.exited_at
        )

      assert [%{at: at}] = rows(ctx)
      assert at == (exited || at)
    end

    test "only the versions asked for are returned", ctx do
      first = store!(ctx, ctx.first, submission())
      store!(ctx, ctx.second, submission())

      assert [%{id: id}] = rows(ctx, [first.public_id])
      assert id == first.public_id
    end

    test "a type of another name lists none", ctx do
      store!(ctx, ctx.first, submission())

      assert Submissions.list(ctx.work_item, "other", Artifacts.list(ctx.work_item)) == []
      assert Submissions.list(ctx.work_item, nil, Artifacts.list(ctx.work_item)) == []
    end
  end

  describe "the window of versions" do
    test "lists the newest 50, and a base that may be a head beyond them is unknown", ctx do
      oldest = String.duplicate("e1", 20)

      store!(
        ctx,
        ctx.first,
        submission(repository(%{"commit" => oldest, "base" => nil, "commits" => []}))
      )

      for n <- 2..55 do
        value =
          if n == 6,
            do: submission(repository(%{"base" => %{"commit" => oldest}})),
            else: submission(repository(%{"base" => nil, "commits" => []}))

        store!(ctx, ctx.first, value)
      end

      rows = rows(ctx)
      assert length(rows) == 50
      assert hd(rows).number == 55
      assert List.last(rows).number == 6
      assert repository_of(List.last(rows)).base.line == :unknown
    end

    test "a base that a run a member cancelled may have is unknown", ctx do
      store!(
        ctx,
        ctx.first,
        submission(repository(%{"commit" => @base, "base" => nil, "commits" => []}))
      )

      store!(ctx, ctx.second, submission())

      {1, _rows} =
        Repo.update_all(
          from(r in Apiary.Runs.Run, where: r.dispatch_run_id == ^ctx.first.id),
          set: [cancel_requested_at: DateTime.utc_now()]
        )

      assert [row] = rows(ctx)
      assert repository_of(row).base.line == :unknown
    end

    test "a base that no earlier version can have is where the work starts", ctx do
      store!(ctx, ctx.first, submission())
      assert [row] = rows(ctx)
      assert repository_of(row).base.line == :start
    end
  end

  describe "the head" do
    test "is marked on the last entry that is the repository's commit", ctx do
      commits = for c <- [@change, @head, @fix_one, @head], do: %{"commit" => c}
      store!(ctx, ctx.first, submission(repository(%{"commits" => commits})))

      assert [row] = rows(ctx)
      assert Enum.map(repository_of(row).commits, & &1.head) == [false, false, false, true]
    end

    test "is on no entry where the last entry is another commit, and the list is as read", ctx do
      commits = for c <- [@head, @change, @fix_one], do: %{"commit" => c, "step" => "fix:f1"}
      store!(ctx, ctx.first, submission(repository(%{"commits" => commits})))

      assert [row] = rows(ctx)
      repository = repository_of(row)
      assert Enum.map(repository.commits, & &1.commit) == [@head, @change, @fix_one]
      assert Enum.map(repository.commits, & &1.head) == [true, false, false]
      assert repository.count == 3
    end

    test "is on no entry where no entry is the commit", ctx do
      commits = [%{"commit" => @change}, %{"commit" => @fix_one}]
      store!(ctx, ctx.first, submission(repository(%{"commits" => commits})))

      assert [row] = rows(ctx)
      assert Enum.map(repository_of(row).commits, & &1.head) == [false, false]
    end

    test "lists the first 100 and no head where more entries follow and none is the commit",
         ctx do
      commits = for n <- 1..130, do: %{"commit" => hex(n)}
      store!(ctx, ctx.first, submission(repository(%{"commits" => commits})))

      assert [row] = rows(ctx)
      repository = repository_of(row)
      assert length(repository.commits) == 100
      assert repository.count == 130
      refute Enum.any?(repository.commits, & &1.head)
    end

    test "lists a duplicated commit as often as it is listed", ctx do
      commits = for c <- [@change, @change, @head], do: %{"commit" => c}
      store!(ctx, ctx.first, submission(repository(%{"commits" => commits})))

      assert [row] = rows(ctx)
      assert Enum.map(repository_of(row).commits, & &1.commit) == [@change, @change, @head]
      assert repository_of(row).count == 3
    end
  end

  describe "two repositories" do
    defp other_repository(overrides \\ %{}) do
      other = String.duplicate("b2", 20)

      Map.merge(
        %{
          "system" => "forge.example.org",
          "path" => "northwind/basket",
          "commit" => other,
          "base" => %{"commit" => String.duplicate("8a", 20)},
          "commits" => [
            %{"commit" => String.duplicate("5d", 20), "step" => "fix:f9"},
            %{"commit" => other, "step" => "deliverable:d-7"}
          ],
          "draft" => %{
            "number" => 35,
            "url" => "https://forge.example.org/pulls/35",
            "title" => "Cache it"
          }
        },
        overrides
      )
    end

    defp two_repositories(ctx, other) do
      store!(ctx, ctx.first, %{"ref" => "qory/wi_1", "repositories" => [repository(), other]})
      assert [row] = rows(ctx)
      assert [first, second] = row.repositories
      {first, second}
    end

    test "each has a base, commits, count, head and draft", ctx do
      {first, second} = two_repositories(ctx, other_repository())

      assert first.path == "northwind/storefront"
      assert second.path == "northwind/basket"
      assert Enum.map(first.commits, & &1.short) == ["4c4c4c4", "7e7e7e7", "a1a1a1a"]
      assert Enum.map(second.commits, & &1.short) == ["5d5d5d5", "b2b2b2b"]
      assert List.last(first.commits).commit == first.commit
      assert List.last(second.commits).commit == second.commit
      assert Enum.map(first.commits, & &1.head) == [false, false, true]
      assert Enum.map(second.commits, & &1.head) == [false, true]
      assert {first.count, second.count} == {3, 2}
      assert first.base.short == "9f9f9f9"
      assert second.base.short == "8a8a8a8"
      assert {:draft, %{number: 34}} = first.draft
      assert {:draft, %{number: 35}} = second.draft
    end

    test "the base of one repository is not matched against the other's heads", ctx do
      store!(ctx, ctx.first, %{
        "ref" => "r",
        "repositories" => [repository(%{"commit" => @base, "base" => nil, "commits" => []})]
      })

      # The second submission's second repository has the first one's head as its base, in
      # another repository: it is not that run's head.
      other = other_repository(%{"base" => %{"commit" => @base}})

      store!(ctx, ctx.second, %{
        "ref" => "r",
        "repositories" => [repository(%{"base" => %{"commit" => @base}}), other]
      })

      assert [newest, _oldest] = rows(ctx)
      assert [first, second] = newest.repositories
      assert first.base.line == {:head, ctx.first_number}
      assert second.base.line == :start
    end

    test "each repository's commits are cut to 100", ctx do
      commits = for n <- 1..150, do: %{"commit" => hex(n), "step" => "fix:f#{n}"}
      first = repository(%{"commits" => commits, "commit" => hex(150)})
      second = other_repository(%{"commits" => commits, "commit" => hex(150)})

      store!(ctx, ctx.first, %{"ref" => "r", "repositories" => [first, second]})

      assert [%{repositories: [first, second]}] = rows(ctx)

      for repository <- [first, second] do
        assert {length(repository.commits), repository.count} == {100, 150}
        assert List.last(repository.commits).head
        assert Enum.count(repository.commits, & &1.head) == 1
      end
    end

    test "a repository with no list does not hide the other's", ctx do
      {first, second} =
        two_repositories(ctx, other_repository(%{"base" => nil, "commits" => nil}))

      assert second.base == nil
      assert second.commits == []
      assert second.count == 0
      assert {:draft, %{number: 35}} = second.draft
      assert length(first.commits) == 3
      assert first.base.short == "9f9f9f9"
    end
  end

  describe "a step" do
    test "that is not a string has no step", ctx do
      commits = [
        %{"commit" => @change, "step" => ["deliverable:d-2"]},
        %{"commit" => @fix_one, "step" => %{"a" => 1}},
        %{"commit" => @head, "step" => nil}
      ]

      store!(ctx, ctx.first, submission(repository(%{"commits" => commits})))

      assert [row] = rows(ctx)
      assert Enum.map(repository_of(row).commits, & &1.step) == [nil, nil, nil]
    end
  end

  describe "stored values are bounded" do
    test "a text is cut to 200 characters and an address over 2048 has no link", ctx do
      long = String.duplicate("é", 500)
      url = "https://git.example.com/" <> String.duplicate("a", 2100)

      draft = %{"number" => 1, "url" => url, "title" => long}
      commits = [%{"commit" => @head, "step" => "fix:f1", "commit_url" => url}]

      store!(
        ctx,
        ctx.first,
        %{
          "ref" => long,
          "repositories" => [
            repository(%{
              "path" => long,
              "system" => long,
              "draft" => draft,
              "commits" => commits,
              "commit_url" => url
            })
          ]
        }
      )

      assert [row] = rows(ctx)
      repository = repository_of(row)
      assert String.length(row.ref) == 200
      assert String.length(repository.path) == 200
      assert String.length(repository.system) == 200
      assert {:draft, %{title: title, url: nil}} = repository.draft
      assert String.length(title) == 200
      assert repository.url == nil
      assert [%{url: nil}] = repository.commits
    end

    test "the text of a change is cut to 200 characters", ctx do
      plan!(
        ctx,
        ctx.first,
        "## Deliverables\n\n| Id | Change |\n|---|---|\n| d-2 | #{String.duplicate("x", 500)} |\n"
      )

      store!(ctx, ctx.first, submission())

      assert [row] = rows(ctx)
      assert [%{step: {:change, "d-2", text}} | _fixes] = repository_of(row).commits
      assert String.length(text) == 200
    end

    test "a plan over 256 KiB shows no change text", ctx do
      big =
        "## Deliverables\n\n| Id | Change |\n|---|---|\n| d-2 | Show |\n\n" <>
          String.duplicate("x", 262_144)

      plan!(ctx, ctx.first, big)
      store!(ctx, ctx.first, submission())

      assert [row] = rows(ctx)
      assert [%{step: {:change, "d-2", nil}} | _fixes] = repository_of(row).commits
    end

    test "a title of a draft that is not a string leaves the number alone", ctx do
      draft = %{"number" => 34, "url" => "https://git.example.com/p/34"}
      store!(ctx, ctx.first, submission(repository(%{"draft" => draft})))

      assert [row] = rows(ctx)
      assert {:draft, %{number: 34, title: nil}} = repository_of(row).draft
    end
  end

  describe "repositories/1" do
    test "has the path, number and link of each draft with an https link" do
      content = %{
        "repositories" => [
          repository(),
          repository(%{"path" => "northwind/basket", "draft" => %{"none" => "no-text"}}),
          repository(%{
            "path" => "northwind/search",
            "draft" => %{"number" => 7, "url" => "javascript:alert(1)", "title" => "T"}
          }),
          "x"
        ]
      }

      assert Submissions.repositories(content) == [
               %{
                 path: "northwind/storefront",
                 number: 34,
                 url: "https://git.example.com/northwind/storefront/pulls/34"
               }
             ]
    end

    test "is empty for a content that has no repositories" do
      assert Submissions.repositories(%{}) == []
      assert Submissions.repositories(%{"repositories" => "x"}) == []
      assert Submissions.repositories(nil) == []
    end
  end

  describe "a page that draws again" do
    defmodule CountingStore do
      # The volume store, counting the files opened for a read.
      @behaviour Apiary.Artifacts.Store
      alias Apiary.Artifacts.Store.Volume

      @impl true
      defdelegate commit(staged), to: Volume
      @impl true
      defdelegate discard(staged), to: Volume
      @impl true
      defdelegate stage(source, limit), to: Volume

      @impl true
      def open(key) do
        :counters.add(Application.fetch_env!(:apiary, __MODULE__), 1, 1)
        Volume.open(key)
      end
    end

    defp opens(fun) do
      counter = :counters.new(1, [])
      Application.put_env(:apiary, CountingStore, counter)
      previous = Application.get_env(:apiary, Apiary.Artifacts.Store)
      Application.put_env(:apiary, Apiary.Artifacts.Store, adapter: CountingStore)

      try do
        result = fun.()
        {result, :counters.get(counter, 1)}
      after
        Application.delete_env(:apiary, CountingStore)

        if previous,
          do: Application.put_env(:apiary, Apiary.Artifacts.Store, previous),
          else: Application.delete_env(:apiary, Apiary.Artifacts.Store)
      end
    end

    test "reads a plan once for every row, and nothing the second time", ctx do
      plan!(ctx, ctx.first)
      store!(ctx, ctx.first, submission())
      store!(ctx, ctx.second, submission())

      type = Submissions.type(ctx.work_item)
      artifacts = Artifacts.list(ctx.work_item)

      {{rows, cache}, first} =
        opens(fn -> Submissions.list_cached(ctx.work_item, type, artifacts, nil, %{}) end)

      # Two submissions and one plan.
      assert first == 3
      assert length(rows) == 2

      assert [%{step: {:change, "d-2", "Show the dates at checkout"}} | _] =
               hd(rows) |> repository_of() |> Map.fetch!(:commits)

      {{again, _cache}, second} =
        opens(fn -> Submissions.list_cached(ctx.work_item, type, artifacts, nil, cache) end)

      assert second == 0
      assert again == rows
    end

    test "reads no plan for rows with no deliverable step", ctx do
      plan!(ctx, ctx.first)
      commits = [%{"commit" => @head, "step" => "fix:f1"}]
      store!(ctx, ctx.first, submission(repository(%{"commits" => commits})))

      type = Submissions.type(ctx.work_item)
      artifacts = Artifacts.list(ctx.work_item)

      {{[_row], _cache}, count} =
        opens(fn -> Submissions.list_cached(ctx.work_item, type, artifacts, nil, %{}) end)

      assert count == 1
    end

    test "a cache keeps only the versions it used", ctx do
      first = store!(ctx, ctx.first, submission())
      second = store!(ctx, ctx.second, submission())
      type = Submissions.type(ctx.work_item)
      artifacts = Artifacts.list(ctx.work_item)

      {_rows, cache} = Submissions.list_cached(ctx.work_item, type, artifacts, nil, %{})
      assert Map.has_key?(cache, {:version, first.public_id})

      {_rows, cache} =
        Submissions.list_cached(ctx.work_item, type, artifacts, [second.public_id], cache)

      assert Map.has_key?(cache, {:version, second.public_id})
    end

    test "reads only the wanted version where it has no base", ctx do
      first = store!(ctx, ctx.first, submission(repository(%{"base" => nil, "commits" => []})))
      second = store!(ctx, ctx.second, submission(repository(%{"base" => nil, "commits" => []})))
      type = Submissions.type(ctx.work_item)
      artifacts = Artifacts.list(ctx.work_item)

      {{[row], _cache}, count} =
        opens(fn ->
          Submissions.list_cached(ctx.work_item, type, artifacts, [second.public_id], %{})
        end)

      assert row.id == second.public_id
      assert count == 1
      refute first.public_id == second.public_id
    end

    test "a type is asked once for a work item whose process version is fixed", ctx do
      {:ok, work_item} =
        {:ok,
         Repo.update!(
           Ecto.Changeset.change(ctx.work_item,
             process_version_id: Apiary.Processes.version_for(ctx.work_item).id
           )
         )}

      {"submission", cache} = Submissions.type_cached(work_item, %{})
      assert cache == %{{:type, work_item.process_version_id} => "submission"}
      assert {"submission", ^cache} = Submissions.type_cached(work_item, cache)
    end
  end

  describe "deliverables/1" do
    test "reads the Id and Change cells of the table under Deliverables" do
      assert Submissions.deliverables(@plan) == %{
               "d-1" => "Compute the delivery date",
               "d-2" => "Show the dates at checkout"
             }
    end

    test "stops at the next section and ignores other tables" do
      markdown =
        "## Deliverables\n\n| Id | Change |\n|---|---|\n| d-1 | One |\n\n## Commands\n\n| d-2 | Two |\n"

      assert Submissions.deliverables(markdown) == %{"d-1" => "One"}
    end

    test "leaves out a row with an id outside the form or no change" do
      markdown = """
      ## Deliverables

      | Id | Change |
      |---|---|
      | <b>x</b> | Bold |
      | d-1 |  |
      | d-2 | Two \\| pieces |
      """

      assert Submissions.deliverables(markdown) == %{"d-2" => "Two | pieces"}
    end

    test "skips the header row by its position, whatever its text" do
      markdown = "## Deliverables\n\n| ID | What |\n|---|---|\n| d-1 | One |\n"
      assert Submissions.deliverables(markdown) == %{"d-1" => "One"}
    end

    test "reads the rows of a table whose header has other titles" do
      markdown =
        "## Deliverables\n\n| Number | Summary |\n| :--- | ---: |\n| d-1 | One |\n| d-2 | Two |\n"

      assert Submissions.deliverables(markdown) == %{"d-1" => "One", "d-2" => "Two"}
    end

    test "a table with no separator row has its first row skipped and the rest read" do
      markdown = "## Deliverables\n\n| Id | Change |\n| d-1 | One |\n| d-2 | Two |\n"
      assert Submissions.deliverables(markdown) == %{"d-1" => "One", "d-2" => "Two"}

      assert Submissions.deliverables("## Deliverables\n\n| d-1 | One |\n| d-2 | Two |\n") ==
               %{"d-2" => "Two"}

      assert Submissions.deliverables("## Deliverables\n\n| Id | Change |\n") == %{}
    end

    test "is empty for a plan with no table" do
      assert Submissions.deliverables("## Summary\n\nNothing.\n") == %{}
      assert Submissions.deliverables("") == %{}
    end
  end

  describe "a run's withdrawal of the submission type" do
    test "is refused, and a withdrawal of another custom type passes", ctx do
      store!(ctx, ctx.first, submission())

      assert {:error, {:withdraw, :submit_type}} =
               Artifacts.withdraw({:run, ctx.first}, ctx.work_item, "submission", name: "main")

      {:ok, _type} =
        Artifacts.create_type(ctx.scope, ctx.scope.workspace, %{
          "name" => "demo-script",
          "base_view" => "file",
          "size_limit" => 1000,
          "max_files" => 1
        })

      {:ok, _version} =
        Artifacts.push(
          {:run, ctx.first},
          ctx.work_item,
          "demo-script",
          [%{filename: "a.txt", content_type: "text/plain", binary: "a"}],
          stage_id: @build
        )

      assert {:ok, %{withdrawn: true}} =
               Artifacts.withdraw({:run, ctx.first}, ctx.work_item, "demo-script", name: "main")
    end

    test "is refused for the type of the run's process version after the work item's changed",
         ctx do
      store!(ctx, ctx.first, submission())
      version!(ctx, "Build 2", nil)
      assert Submissions.type(ctx.work_item) == nil

      assert {:error, {:withdraw, :submit_type}} =
               Artifacts.withdraw({:run, ctx.first}, ctx.work_item, "submission", name: "main")
    end

    test "is refused for the type of the work item's process version", ctx do
      store!(ctx, ctx.first, submission())
      none = version!(ctx, "Build 2", nil)

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.first.id),
          set: [process_version_id: none.id]
        )

      version!(ctx, "Build 3", @submit)
      first = Repo.reload!(ctx.first)
      assert Submissions.type(ctx.work_item) == "submission"

      assert {:error, {:withdraw, :submit_type}} =
               Artifacts.withdraw({:run, first}, ctx.work_item, "submission", name: "main")
    end

    test "passes where the run's process version has no submit", ctx do
      ctx = submits!(ctx, nil)
      store!(ctx, ctx.first, submission())

      assert {:ok, %{withdrawn: true}} =
               Artifacts.withdraw({:run, ctx.first}, ctx.work_item, "submission", name: "main")
    end
  end
end
