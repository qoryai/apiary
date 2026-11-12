defmodule ApiaryWeb.WorkItemLive.WorkflowTest do
  # The work item page and the board under the workflow model
  # (`ApiaryWeb.WorkItemLive.Workflow`), with the stage runner (`Apiary.Stages`), the
  # artifacts (`Apiary.Artifacts`), and `ApiaryWeb.WorkflowFake` in place of the read of
  # the harness: without the feature, the page and the list as before it; the stage
  # track; each stage state (running, waiting for inputs, for answers or for a workflow
  # with Check again, escalated with each cause, at the gate, done); a gate's missing
  # outputs and Add to the artifact page; the runs with their rounds and verdicts; the
  # approval marks; the artifact list; Explore's gate with today's Confirm and no second
  # Approve; each action, for the owner, an admin and a member, hidden from a person the
  # stage does not list and refused on the server; the page read again on the stage and
  # artifact topics; and the list's boxes on every view and its groups, a removed stage's
  # and the migrated work items' included, with each view's line.
  #
  # The fake changes the whole node (`ApiaryWeb.WorkflowFake.install/0`), so the module
  # is not async.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Access, Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.Artifacts.Artifact
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.Run
  alias Apiary.Stages.{Escalation, GateDecision}
  alias Apiary.WorkItems.{Confirmation, WorkItem, WorkList}
  alias ApiaryWeb.WorkflowFake

  @moduletag needs: [:factory, :workflow_model]

  setup_all do
    previous = WorkflowFake.install()
    on_exit(fn -> WorkflowFake.uninstall(previous) end)
    :ok
  end

  setup :register_and_log_in_user

  # A ready pool, for the tests that read a queued run's words: without one, the page
  # shows that no pool can take the run (`ApiaryWeb.WorkItemLive.NoPoolTest`).
  defp ready_pool(%{scope: scope}) do
    _place = Apiary.DispatchedRunsFixtures.handover_place_fixture(scope)
    :ok
  end

  # The stage ids of the software type's default process (`Apiary.Processes`), and one
  # more for a stage a later version removes.
  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"
  @build "st_6ns22c4pav"
  @verify "st_m1mqbeywdg"
  @release "st_k9kpv17xmy"
  @review "st_rev0000000"

  # The point of a run outside a loop that ended with no verdict (`Apiary.Stages.Points`).
  @no_verdict %{"text" => "The run stopped before its verdict.", "action" => "run_again"}

  # The points of Build's failed Exists checks (`Apiary.Stages.Points.check_failed/1`).
  @no_demo "No demo-video was stored in this stage."
  @no_explainer "No explainer was stored in this stage."

  # The default process, with Build's inputs, sequence and outputs of § 4, and its gate's
  # approvers.
  defp document(approvers) do
    default = Processes.default_document("software")

    stages =
      for stage <- default["stages"] do
        if stage["id"] == @build do
          %{
            stage
            | "inputs" => [
                %{"type" => "acceptance-criteria", "required" => true},
                %{"type" => "mockup", "required" => false}
              ],
              "sequence" => [
                %{"workflow" => "implement"},
                %{
                  "loop" => %{
                    "rounds" => 3,
                    "body" => [
                      %{"workflow" => "capture-demo"},
                      %{"workflow" => "fix-demo-findings"}
                    ]
                  }
                }
              ],
              "outputs" => [
                %{"type" => "change", "required" => true, "check" => %{"reported" => "opened"}},
                %{"type" => "demo-video", "required" => true},
                %{"type" => "explainer", "required" => true},
                %{"type" => "decision-record", "required" => false}
              ],
              "gate" => %{"kind" => "person", "approvers" => approvers}
          }
        else
          stage
        end
      end

    %{default | "stages" => stages}
  end

  # A saved version of the scope's workspace with `document`, current; the current one
  # where it has that document already.
  defp save!(scope, document) do
    case Processes.save(scope, scope.workspace, document) do
      {:ok, version} -> version
      {:error, [%{error: :unchanged} | _]} -> Processes.current(scope.workspace)
    end
  end

  # The document of the workspace's current version, with `fun` applied to Explore's
  # sequence.
  defp explore_sequence(scope, fun) do
    Map.update!(Processes.current(scope.workspace).document, "stages", fn stages ->
      Enum.map(stages, fn
        %{"id" => @explore} = stage -> Map.update!(stage, "sequence", fun)
        stage -> stage
      end)
    end)
  end

  # The end of a run that pushes its proposal and no verdict.
  defp proposal_only, do: &push_output!(&1, &2, understood_result())

  # A work item at Explore whose run pushed its proposal and passed, with the stage
  # escalated `check_failed`: Explore also requires a mockup, which no run pushed.
  defp mockup_missing!(scope) do
    document =
      Map.update!(Processes.current(scope.workspace).document, "stages", fn stages ->
        Enum.map(stages, fn
          %{"id" => @explore} = stage ->
            Map.update!(stage, "outputs", &(&1 ++ [%{"type" => "mockup", "required" => true}]))

          stage ->
            stage
        end)
      end)

    save!(scope, document)
    work_item = scope |> taken_in_fixture() |> end_run!(understood_result())
    assert %Escalation{cause: :check_failed} = escalation(work_item)
    work_item
  end

  # What the rows of the page's runs show, newest first.
  defp shows(scope, work_item) do
    scope
    |> ApiaryWeb.WorkItemLive.Workflow.page(Repo.get!(WorkItem, work_item.id))
    |> Map.fetch!(:runs)
    |> Enum.map(& &1.shows)
  end

  # The end of a run that pushes the verdict `passed`.
  defp passed do
    fn run, _registered ->
      {:ok, _version} =
        Stages.Artifacts.push_json(
          {:run, run},
          Repo.get!(WorkItem, run.work_item_id),
          "verdict",
          %{"verdict" => "passed"},
          stage_id: run.stage_id
        )
    end
  end

  # A work item whose Explore passed and was confirmed, with the run of a next stage of
  # one workflow outside a loop queued: Shape's sequence is `shape-a-ticket`.
  defp at_workflow_stage(scope) do
    document =
      Map.update!(Processes.current(scope.workspace).document, "stages", fn stages ->
        Enum.map(stages, fn
          %{"id" => @shape} = stage ->
            Map.put(stage, "sequence", [%{"workflow" => "shape-a-ticket"}])

          stage ->
            stage
        end)
      end)

    save!(scope, document)
    work_item = explore_gate_fixture(scope)
    {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
    work_item = Repo.get!(WorkItem, work_item.id)
    assert %WorkItem{stage_id: @shape, stage_state: :running} = work_item
    work_item
  end

  # Saves the workspace's current version with Explore's sequence a loop of
  # explore-a-ticket of `rounds` rounds, in place of the default's one workflow. In the
  # loop, each run with no open question and no verdict starts the next round, up to the
  # limit.
  defp explore_loop!(scope, rounds \\ 3) do
    save!(
      scope,
      explore_sequence(scope, fn _sequence ->
        [%{"loop" => %{"rounds" => rounds, "body" => [%{"workflow" => "explore-a-ticket"}]}}]
      end)
    )
  end

  # Moves `work_item` to a trial version of the workspace's current one with 2 Explore
  # rounds instead of 3; its queued run moves with it and keeps its stored `of`.
  defp two_rounds!(scope, work_item) do
    document =
      explore_sequence(scope, fn sequence ->
        Enum.map(sequence, fn
          %{"loop" => loop} = entry -> %{entry | "loop" => Map.put(loop, "rounds", 2)}
          entry -> entry
        end)
      end)

    {:ok, trial} = Processes.save(scope, scope.workspace, document, trial: true)
    {:ok, work_item} = Processes.assign(scope, Repo.get!(WorkItem, work_item.id), trial)
    work_item
  end

  # A second take in after a first that used its 3 runs, each with no result: the page's
  # Details line while
  # attempt 1 of take in 2 is queued, then the line and its link after attempts 1 and 2
  # of take in 2 ended.
  defp details_of_a_second_take_in(conn, scope) do
    ticket = backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

    work_item = end_run!(Repo.get!(WorkItem, work_item.id), nil)
    {:ok, _} = WorkItems.explore_again(scope, work_item, 1)
    work_item = end_run!(Repo.get!(WorkItem, work_item.id), nil)
    {:ok, _} = WorkItems.explore_again(scope, work_item, 2)
    work_item = end_run!(Repo.get!(WorkItem, work_item.id), nil)
    assert %DispatchRun{take_in: 1, attempt: 3} = newest_run(work_item)
    {:ok, _} = WorkItems.close(scope, work_item)
    {:ok, _} = WorkItems.take_in_again(scope, ticket.public_id)

    work_item = Repo.get!(WorkItem, work_item.id)
    assert %DispatchRun{take_in: 2, attempt: 1, state: :waiting} = newest_run(work_item)
    {:ok, view, _html} = live(conn, page(scope, work_item.number))
    queued = line(view, "#work-item-details-runs")

    work_item = end_run!(work_item, nil)
    {:ok, _} = WorkItems.explore_again(scope, work_item, 1)
    work_item = end_run!(Repo.get!(WorkItem, work_item.id), nil)
    %DispatchRun{take_in: 2, attempt: 2} = latest = newest_run(work_item)
    number = Repo.one(from r in Run, where: r.dispatch_run_id == ^latest.id, select: r.number)

    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    %{
      queued: queued,
      ended: line(view, "#work-item-details-runs"),
      link: has_element?(view, ~s(#work-item-details-runs a[href$="/runs/#{number}"]), "2"),
      number: number
    }
  end

  # The text of the element `selector`, its whitespace collapsed: the whole line.
  defp line(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # The Explore tab's HTML before the record block, which has every run of the work item at
  # a stage after Explore.
  defp above_record(view) do
    view
    |> element("#work-item-explore")
    |> render()
    |> String.split(~s(id="work-item-record"), parts: 2)
    |> hd()
  end

  defp place!(work_item, version, stage_id, state, fields \\ []) do
    {1, _} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [process_version_id: version.id, stage_id: stage_id, stage_state: state] ++ fields
      )

    Repo.get!(WorkItem, work_item.id)
  end

  # A work item at Build in `state`, on a version with Build's inputs, sequence and
  # outputs, at the entry `entry` of its sequence (1, the loop, by default; 2 is past its
  # end) and the loop's entry `loop_entry`.
  defp at_build(scope, state, opts \\ []) do
    version = save!(scope, document(Keyword.get(opts, :approvers, "members")))

    scope
    |> work_item_fixture()
    |> place!(version, @build, state,
      stage_round: Keyword.get(opts, :round, 1),
      stage_entry: Keyword.get(opts, :entry, 1),
      loop_entry: Keyword.get(opts, :loop_entry)
    )
  end

  # A work item where the migration of piece F puts an open one: on the workspace's
  # current version, in Explore, or in Shape at its gate.
  defp backfilled!(scope, stage_id, state) do
    scope
    |> work_item_fixture()
    |> place!(Processes.current(scope.workspace), stage_id, state, stage_round: 1)
  end

  # A work item confirmed at Explore, approved on to Build, then moved back to Explore,
  # which queues a run of Explore in the same take in.
  defp moved_back!(scope) do
    work_item = shape_gate_fixture(scope)
    {:ok, _work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
    at_build = Repo.get!(WorkItem, work_item.id)
    assert at_build.stage_id == @build

    {:ok, _work_item} = Stages.move(scope, at_build, @explore, nil, expect_stage: @build)
    Repo.get!(WorkItem, work_item.id)
  end

  # The run that a move back queues, handed over to a machine, with its row in `runs`.
  defp running_after_move!(scope) do
    work_item = moved_back!(scope)
    {run, dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)
    {work_item, run, dispatch_run}
  end

  # A run of the queue at `stage_id`, in the take in `take_in`, after the work item's
  # newest.
  defp stage_run!(work_item, stage_id, take_in \\ nil) do
    newest = newest_run(work_item)

    %DispatchRun{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id
    }
    |> DispatchRun.queue_changeset(%{
      work_item_id: work_item.id,
      step: newest.step,
      take_in: take_in || newest.take_in,
      attempt: if(take_in, do: 1, else: newest.attempt + 1),
      of: newest.of,
      queued_at: DateTime.utc_now()
    })
    |> Ecto.Changeset.change(stage_id: stage_id, workflow: "capture-demo", round: 1)
    |> Repo.insert!()
  end

  # `dispatch_run` in `state`, with its row in `runs`.
  defp registered!(work_item, dispatch_run, state) do
    dispatch_run = dispatch_run |> Ecto.Changeset.change(state: state) |> Repo.update!()

    run =
      %Run{
        number:
          Apiary.RunEventsFixtures.next_run_number(
            work_item.organisation_id,
            work_item.workspace_id
          ),
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        node_run_id: dispatch_run.run_id,
        dispatch_run_id: dispatch_run.id
      }
      |> Ecto.Changeset.change(state: "running", started_at: DateTime.utc_now())
      |> Apiary.RunEventsFixtures.insert_run!()

    {run, dispatch_run}
  end

  # A moved-back work item's page, in a workspace where the member may read it, with the
  # running run's row in a workspace where the member may not read runs.
  defp running_where_runs_are_unreadable!(conn, scope) do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.MembersReachNamed)
    {work_item, _run, _dispatch_run} = running_after_move!(scope)
    there = workspace_fixture(scope.organisation, "There")

    Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
      set: [workspace_id: there.id]
    )

    %{user: member} = member_fixture(scope, :member)
    Apiary.EditionStubs.MembersReachNamed.put([there.id])

    {:ok, view, _html} =
      conn
      |> log_in_user(member)
      |> live(~p"/#{scope.organisation}/#{there}/work/#{work_item.number}")

    view
  end

  # A work item at Build with a running run, which has its row in `runs`.
  defp running_at_build!(scope) do
    work_item =
      scope
      |> taken_in_fixture()
      |> place!(Processes.current(scope.workspace), @build, :running)

    dispatch_run =
      work_item |> newest_run() |> Ecto.Changeset.change(state: :handed_over) |> Repo.update!()

    %Run{
      number:
        Apiary.RunEventsFixtures.next_run_number(
          work_item.organisation_id,
          work_item.workspace_id
        ),
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      node_run_id: dispatch_run.run_id,
      dispatch_run_id: dispatch_run.id,
      state: "running",
      started_at: DateTime.utc_now()
    }
    |> Ecto.Changeset.change()
    |> Apiary.RunEventsFixtures.insert_run!()

    work_item
  end

  # An open escalation with `points`: a text alone is a `run_again` point; nil is none.
  defp escalate!(work_item, cause, points, run \\ nil) do
    Repo.insert!(%Escalation{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      process_version_id: work_item.process_version_id,
      stage_id: work_item.stage_id,
      round: work_item.stage_round,
      cause: cause,
      points: points(points),
      run_id: run && run.id,
      inserted_at: DateTime.utc_now()
    })
  end

  defp points(nil), do: []
  defp points(text) when is_binary(text), do: points([text])

  defp points(points) when is_list(points) do
    for point <- points do
      if is_binary(point), do: %{"text" => point, "action" => "run_again"}, else: point
    end
  end

  # Pushes the run's verdict escalate with `points`.
  defp push_verdict!(run, points) do
    {:ok, _version} =
      Stages.Artifacts.push_json(
        {:run, run},
        Repo.get!(WorkItem, run.work_item_id),
        "verdict",
        %{"verdict" => "escalate", "points" => points},
        stage_id: run.stage_id
      )
  end

  defp push!(actor, work_item, type, stage_id) do
    {:ok, version} = Artifacts.push(actor, work_item, type, [sample(type)], stage_id: stage_id)
    version
  end

  # A file `Apiary.Artifacts.push/5` takes for `type`.
  defp sample("demo-video") do
    %{
      filename: "demo.mp4",
      content_type: "video/mp4",
      binary: <<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0, "isomiso2">>
    }
  end

  defp sample("change") do
    json("change.json", %{"url" => "https://forge.example.com/example/shop/pull/4"})
  end

  defp sample(type) do
    %{filename: "#{type}.md", content_type: "text/markdown", binary: "# #{type}"}
  end

  defp json(filename, value) do
    %{filename: filename, content_type: "application/json", binary: Jason.encode!(value)}
  end

  defp decisions(work_item, kind),
    do:
      Repo.all(from d in GateDecision, where: d.work_item_id == ^work_item.id and d.kind == ^kind)

  defp escalation(work_item),
    do:
      Repo.one(
        from e in Escalation,
          where: e.work_item_id == ^work_item.id,
          order_by: [desc: e.inserted_at],
          limit: 1
      )

  defp page(scope, number), do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}"

  # The ids of the work item's open review comments, in their order.
  defp open_review_comments(work_item) do
    {_version, document} = Apiary.Explore.ReviewComments.newest(work_item)

    for %{"id" => id, "state" => "open"} <-
          Apiary.Explore.ReviewComments.entries(document),
        do: id
  end

  # The workspace's process saved with one member as the only approver of Explore's gate:
  # that member's scope.
  defp explore_gate_listing(scope) do
    listed = member_fixture(scope, :member)
    list_explore_approvers!(scope, [listed.user.id])
    Apiary.Organisations.load_scope(Apiary.Accounts.Scope.for_user(listed.user))
  end

  # Saves the default process as the workspace's current version, with Explore's gate
  # listing the accounts `ids` as its approvers, in that order.
  defp list_explore_approvers!(scope, ids) do
    default = Processes.default_document("software")

    stages =
      for stage <- default["stages"] do
        if stage["id"] == @explore,
          do: %{stage | "gate" => %{"kind" => "person", "approvers" => %{"members" => ids}}},
          else: stage
      end

    save!(scope, %{default | "stages" => stages})
  end

  # A person's gate that lists the accounts `ids` as its approvers.
  defp listing(ids), do: %{"kind" => "person", "approvers" => %{"members" => ids}}

  # How many queries this process ran while `fun` ran.
  defp queries(fun) do
    handler = "workflow-queries-#{System.unique_integer([:positive])}"
    me = self()

    :ok =
      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, _meta, _config -> if self() == me, do: send(me, :query) end,
        nil
      )

    try do
      fun.()
      count_queries(0)
    after
      :telemetry.detach(handler)
    end
  end

  defp count_queries(n) do
    receive do
      :query -> count_queries(n + 1)
    after
      0 -> n
    end
  end

  # How many reads of `process_versions` the test process and the page's LiveView ran
  # while the page at `path` loaded, with the view.
  defp version_reads(conn, path) do
    version_reads_in(
      fn ->
        {:ok, view, _html} = live(conn, path)
        _ = render(view)
        view
      end,
      &[&1.pid]
    )
  end

  # The `process_version` field of the work item in the assigns of the LiveView `view`.
  defp loaded_version(view), do: :sys.get_state(view.pid).socket.assigns.row.process_version

  # How many reads of `process_versions` this process, and the processes `pids` gives for
  # the result of `fun`, ran while `fun` ran, with that result.
  defp version_reads_in(fun, pids \\ fn _result -> [] end) do
    handler = "workflow-version-reads-in-#{System.unique_integer([:positive])}"
    me = self()

    :ok =
      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if meta.source == "process_versions", do: send(me, {:version_read, self()})
        end,
        nil
      )

    try do
      result = fun.()
      {count_version_reads([me | pids.(result)], 0), result}
    after
      :telemetry.detach(handler)
    end
  end

  defp count_version_reads(pids, n) do
    receive do
      {:version_read, pid} -> count_version_reads(pids, if(pid in pids, do: n + 1, else: n))
    after
      0 -> n
    end
  end

  # The name the page shows for the account `id`.
  defp shown_name(scope, id), do: ApiaryWeb.WorkItemLive.View.people(scope, [id])[id].name

  defp list(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/work"

  # The texts of the elements `selector` names, each with its spaces made one.
  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  # The rows of the runs fold at the foot of the tab, oldest first, each with its parts
  # joined by " · ", as the page shows them.
  defp fold_rows(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(
      "#work-item-record-fold > .q-xp-inner > .q-xp-runrow, " <>
        "#work-item-record-fold > .q-xp-inner > details > summary"
    )
    |> Enum.map(fn row ->
      row
      |> LazyHTML.query(".q-xp-it")
      |> Enum.map_join(" · ", &(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
    end)
  end

  defp as(conn, _scope, :owner), do: conn

  defp as(_conn, scope, level),
    do: log_in_user(build_conn(), member_fixture(scope, level).user)

  describe "without the feature" do
    @describetag with_features: Apiary.Features.all() -- [:workflow_model]

    test "the page reads no process version", %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      # A work item placed while the model was on still reads its version up to 3 times.
      {reads, view} = version_reads(conn, page(scope, work_item.number))

      assert reads == 0
      assert %Ecto.Association.NotLoaded{} = loaded_version(view)
      assert has_element?(view, "#work-item-step")
    end

    test "after a move back, Build's run is at another stage, with Explore's stage read once",
         %{scope: scope} do
      # The fixtures move the work item with the feature on, as before it was turned off.
      off = Apiary.Features.enabled()
      Application.put_env(:apiary, :features, Apiary.Features.all())
      work_item = moved_back!(scope)
      {explore, _dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)
      {build, _dispatch_run} = registered!(work_item, stage_run!(work_item, @build), :handed_over)
      Application.put_env(:apiary, :features, off)

      row = Repo.get!(WorkItem, work_item.id)
      read = WorkItems.explore(scope, row, DateTime.utc_now())

      # Explore's stage is read once (`Apiary.Stages.explore_stage_id/1`): the work item's
      # version, and the workspace's current version for the commit of the Qory harness
      # in use (`Apiary.Processes.HarnessUpdate.qory_in_use/1`).
      {reads, page} =
        version_reads_in(fn -> ApiaryWeb.WorkItemLive.View.page(scope, row, read, [], %{}) end)

      other_stage =
        Map.new([page.work_item.run | page.earlier_runs], &{&1.number, &1.other_stage})

      assert reads == 2
      assert other_stage[build.number] == true
      assert other_stage[explore.number] == false
    end

    test "the page has the step card and the stages as before it", %{conn: conn, scope: scope} do
      work_item = backfilled!(scope, @explore, :running)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-step")
      assert has_element?(view, "#work-item-head-stages-explore")
      refute has_element?(view, "#work-item-stage")
      refute has_element?(view, "#work-item-flow")
    end

    test "/explore draws Explore's tab, and a stage's address goes to the work item's page", %{
      conn: conn,
      scope: scope
    } do
      work_item = backfilled!(scope, @explore, :running)
      to = page(scope, work_item.number)

      {:ok, view, _html} = live(conn, to <> "/explore")

      assert page_assigns(view).live_action == :explore
      assert has_element?(view, "#work-item-tabs-explore[aria-current=page]")

      assert {:error, {:live_redirect, %{to: ^to}}} = live(conn, to <> "/stages/#{@explore}")
    end

    test "a second take in: Details counts only that take in's runs", %{
      conn: conn,
      scope: scope
    } do
      assert %{queued: "None yet", ended: ended, link: true, number: number} =
               details_of_a_second_take_in(conn, scope)

      assert ended == "Attempt 2 (Run #{number}) · 2 runs, ended"
    end

    test "a stage event does nothing", %{conn: conn, scope: scope} do
      work_item = backfilled!(scope, @shape, :at_gate)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      render_hook(view, "stage_approve", %{
        "number" => "#{work_item.number}",
        "seen" => @shape,
        "note" => ""
      })

      assert decisions(work_item, :approve) == []
    end

    test "the list has the stages strip and no board", %{conn: conn, scope: scope} do
      backfilled!(scope, @shape, :at_gate)
      {:ok, view, _html} = live(conn, list(scope))

      assert has_element?(view, "#work-items-stages")
      refute has_element?(view, "#work-items-board")
    end

    test "the list has its bands with Fold, and the line of Waiting on you alone", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, list(scope))

      assert has_element?(view, ".q-wl-fold")
      assert has_element?(view, "#work-item-#{work_item.public_id}")
      refute has_element?(view, "#work-items-groups")
      refute has_element?(view, "#work-items-note")

      {:ok, view, _html} = live(conn, list(scope) <> "?view=closed")
      assert has_element?(view, "#work-items-stages")
      refute has_element?(view, "#work-items-note")
    end
  end

  describe "a work item the stage runner has not placed" do
    test "draws as before the feature", %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-step")
      refute has_element?(view, "#work-item-stage")
    end

    test "the page loads the workspace's current process version on the work item", %{
      conn: conn,
      scope: scope
    } do
      work_item = work_item_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert %Processes.Version{status: :current} = loaded_version(view)
      assert has_element?(view, "#work-item-step")
    end
  end

  # Answers to `questions_result/0`'s two questions, by question id.
  @answers [%{"id" => "q1", "note" => "a"}, %{"id" => "q2", "note" => "b"}]

  # An answer to each open question of the current take in in the work item's newest
  # questions, by question id (`Apiary.Explore.Questions.open_in_take_in/2`).
  defp open_answers(work_item) do
    work_item = Repo.get!(WorkItem, work_item.id)
    {_version, document} = Apiary.Explore.Questions.newest(work_item)
    runs = Apiary.Explore.Questions.take_in_runs(work_item.id, work_item.take_in)

    for %{"id" => id} <- Apiary.Explore.Questions.open_in_take_in(document, runs),
        do: %{"id" => id, "note" => "a"}
  end

  describe "Explore" do
    setup :ready_pool

    test "running: the track, one card with the stage's state, and the run", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, ~s|#work-item-head-stages-#{@explore}[aria-current="step"]|)
      assert has_element?(view, "#work-item-head-stages-#{@release}.q-wi-stage-todo")
      refute has_element?(view, "#work-item-head-stages-explore")

      # One card: the step card, with the stage's state as its badge; no stage card.
      assert has_element?(view, "#work-item-step")
      refute has_element?(view, "#work-item-stage")

      # The run waits for a machine: the card shows Queued, as the head does, and not
      # Running.
      assert has_element?(view, "#work-item-step-state", "Queued")
      refute has_element?(view, "#work-item-step-state", "Running")
      refute render(view) =~ "Explore is running."
      assert has_element?(view, "#work-item-head-meta", "Explore is queued")
      # No round, and the process version in Details; no runs list above the tabs.
      refute render(view) =~ "Round "
      refute render(view) =~ "Process version"
      assert has_element?(view, "#work-item-details-process", "Version 1")
      refute has_element?(view, "#work-item-runs-0")
      refute html =~ "explore-a-ticket · round"

      # Details names the queued run, as the run list does, and not None yet.
      assert has_element?(view, "#work-item-details-runs", "Attempt 1 is queued.")
      refute has_element?(view, "#work-item-details-runs", "None yet")
    end

    test "a queued run moved to a version with fewer rounds: Details shows its attempt", %{
      conn: conn,
      scope: scope
    } do
      explore_loop!(scope)
      work_item = taken_in_fixture(scope)
      assert %DispatchRun{attempt: 1, of: 3} = newest_run(work_item)

      two_rounds!(scope, work_item)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      # The runner stops after round 2 of the version the work item is on, whatever the
      # stored run's limit is. Explore's card shows no round.
      refute has_element?(view, "#work-item-stage-round")
      assert has_element?(view, "#work-item-details-runs", "Attempt 1 is queued.")
    end

    test "a queued run without its limit: Details shows its attempt", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket, fn socket ->
          item = socket.assigns.item
          Phoenix.Component.assign(socket, :item, put_in(item.run.of, nil))
        end)
      end)

      render_hook(view, "cancel_question", %{})
      assert has_element?(view, "#work-item-details-runs", "Attempt 1 is queued.")
      refute has_element?(view, "#work-item-details-runs", "None yet")
    end

    test "a later queued run moved to a version with fewer rounds: the step card shows its attempt",
         %{conn: conn, scope: scope} do
      explore_loop!(scope)
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result())
      {:ok, _} = WorkItems.answer(scope, work_item, 1, @answers)
      assert %DispatchRun{attempt: 2, of: 3} = newest_run(work_item)

      two_rounds!(scope, work_item)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-stage-round")
      assert has_element?(view, "#work-item-step-run", "Attempt 2 is queued.")
    end

    test "a run queued for Explore's next workflow: the page shows its attempt", %{
      conn: conn,
      scope: scope
    } do
      # Explore: explore-a-ticket, then one more workflow.
      save!(
        scope,
        explore_sequence(scope, fn sequence ->
          sequence ++ [%{"workflow" => "explore-a-ticket"}]
        end)
      )

      work_item =
        Enum.reduce(1..2, taken_in_fixture(scope), fn attempt, work_item ->
          work_item = end_run!(work_item, questions_result())
          {:ok, _} = WorkItems.answer(scope, work_item, attempt, open_answers(work_item))
          Repo.get!(WorkItem, work_item.id)
        end)

      # Run 3 proposes; the next workflow is queued with the runs it may have in its round,
      # not the runs of the first.
      work_item = end_run!(work_item, understood_result())
      assert %DispatchRun{attempt: 4, of: 6} = newest_run(work_item)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert render(view) =~ "Attempt 4 is queued."
    end

    test "a second take in: the step card and the fold of the runs count its attempts", %{
      conn: conn,
      scope: scope
    } do
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

      # Take in 1: two runs, then the work item is closed and taken in again.
      work_item = end_run!(Repo.get!(WorkItem, work_item.id), questions_result())
      {:ok, _} = WorkItems.answer(scope, work_item, 1, open_answers(work_item))
      work_item = end_run!(Repo.get!(WorkItem, work_item.id), questions_result())
      {:ok, _} = WorkItems.close(scope, work_item)
      {:ok, _} = WorkItems.take_in_again(scope, ticket.public_id)

      # Take in 2: run 1 asks, the answer queues attempt 2.
      work_item = end_run!(Repo.get!(WorkItem, work_item.id), questions_result())
      {:ok, _} = WorkItems.answer(scope, work_item, 1, open_answers(work_item))
      assert %DispatchRun{take_in: 2, attempt: 2, of: 3} = newest_run(work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-runs-0")
      assert has_element?(view, "#work-item-step-run", "Attempt 2 is queued.")
      refute render(view) =~ "Attempt 4"

      # The fold of the runs on Explore's tab has this take in's two runs.
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert line(view, "#work-item-record-fold > summary") =~ "2 runs"
      refute render(view) =~ "Attempt 3"
      refute render(view) =~ "Attempt 4"
    end

    test "a second take in: Details counts only that take in's runs", %{
      conn: conn,
      scope: scope
    } do
      assert %{queued: "Attempt 1 is queued.", ended: ended, link: true, number: number} =
               details_of_a_second_take_in(conn, scope)

      assert ended == "Attempt 2 (Run #{number}) · 2 runs, ended"
    end

    test "a run before the work item was placed: the step card shows its attempt",
         %{conn: conn, scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result())

      # As the migration placed the work item: its first run has no stage.
      {1, _} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^newest_run(work_item).id),
          set: [stage_id: nil]
        )

      {:ok, _} = WorkItems.answer(scope, work_item, 1, @answers)
      # The runs of Explore's entry count only the runs placed in it: the first is not.
      assert %DispatchRun{attempt: 2, of: 4} = newest_run(work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-runs-0")
      assert has_element?(view, "#work-item-step-run", "Attempt 2 is queued.")
    end

    test "a claimed run reads queued, as the step card does", %{conn: conn, scope: scope} do
      work_item = taken_in_fixture(scope)

      work_item
      |> newest_run()
      |> Ecto.Changeset.change(state: :claimed)
      |> Repo.update!()

      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-step-state", "Queued")
      refute has_element?(view, "#work-item-stage")
      refute html =~ "explore-a-ticket · round"
    end

    test "a run whose row is running reads Running on the stage card, running in the block", %{
      conn: conn,
      scope: scope
    } do
      # Past Explore, where the stage card stands alone.
      work_item = running_at_build!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Running")
      assert has_element?(view, "#work-item-stage-line", "Build is running.")
      assert has_element?(view, "#work-item-head-stage-status", "Build · Running")
      assert has_element?(view, "#work-item-record .q-xp-runrow", "Attempt 1")
      assert has_element?(view, "#work-item-record .q-xp-runrow", "running")
    end

    test "a run handed over with its row still pending: Running on the stage card, queued in the block",
         %{conn: conn, scope: scope} do
      work_item =
        scope
        |> taken_in_fixture()
        |> place!(Processes.current(scope.workspace), @build, :running)

      {run, dispatch_run} = registered!(work_item, stage_run!(work_item, @build), :handed_over)
      run |> Ecto.Changeset.change(state: "pending", started_at: nil) |> Repo.update!()
      assert dispatch_run.stage_id == @build

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Running")
      assert has_element?(view, "#work-item-stage-line", "Build is running.")
      assert has_element?(view, "#work-item-head-stage-status", "Build · Running")

      # The run has not started: the row reads queued, as the top line of the tab.
      assert texts(view, "div#work-item-record-#{run.number}.q-xp-runrow .q-xp-it") ==
               ["Attempt 2 (Run #{run.number})", "capture-demo", "round 1", "queued"]
    end

    test "a stage tab's run handed over with its row still pending: queued on the top line and in the fold",
         %{conn: conn, scope: scope} do
      work_item = at_workflow_stage(scope)
      {run, _dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)
      run |> Ecto.Changeset.change(state: "pending", started_at: nil) |> Repo.update!()

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/stages/#{@shape}")
      assert line(view, "#work-item-tab-run") == "Attempt 2 (Run #{run.number})Queued"

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/ticket")

      assert fold_rows(view) |> List.last() ==
               "Attempt 2 (Run #{run.number}) · shape-a-ticket · round 1 · queued"
    end

    test "a stage tab's run handed over with its row lost: Lost on the top line and in the fold",
         %{conn: conn, scope: scope} do
      work_item = at_workflow_stage(scope)
      {run, _dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)
      run |> Ecto.Changeset.change(state: "lost", lost_at: DateTime.utc_now()) |> Repo.update!()

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/stages/#{@shape}")
      assert line(view, "#work-item-tab-run") =~ ~r/^Attempt 2 \(Run #{run.number}\)Lost/

      # The stage run reads running; the row has the run's state, as the top line.
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/ticket")

      assert fold_rows(view) |> List.last() ==
               "Attempt 2 (Run #{run.number}) · shape-a-ticket · round 1 · Lost"
    end

    for {state, word} <- [{"failed", "Failed"}, {"cancelled", "Cancelled"}] do
      @tag run_state: state, word: word
      test "a stage tab's run that ended without a verdict, its row #{state}: #{word} in the fold",
           %{conn: conn, scope: scope, run_state: state, word: word} do
        work_item = at_workflow_stage(scope)
        {run, _dispatch_run} = settled_run!(work_item, newest_run(work_item), state)

        assert [:no_verdict, :passed] = shows(scope, work_item)
        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/ticket")

        assert fold_rows(view) |> List.last() ==
                 "Attempt 2 (Run #{run.number}) · shape-a-ticket · round 1 · #{word} · 4 minutes ago"
      end
    end

    test "a stage tab's run that wrote passed and whose row was lost: passed in the fold",
         %{conn: conn, scope: scope} do
      work_item = at_workflow_stage(scope)
      {run, dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)

      {:ok, _version} =
        Stages.Artifacts.push_json(
          {:run, dispatch_run},
          work_item,
          "verdict",
          %{"verdict" => "passed"},
          stage_id: dispatch_run.stage_id
        )

      run |> Ecto.Changeset.change(state: "lost", lost_at: DateTime.utc_now()) |> Repo.update!()

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^dispatch_run.id),
          set: [state: :ended, end_cause: :lost]
        )

      # The verdict comes before the run's state.
      assert [:passed, :passed] = shows(scope, work_item)
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/ticket")
      row = fold_rows(view) |> List.last()

      assert row =~ ~r/^Attempt 2 \(Run #{run.number}\) · shape-a-ticket · round 1 · passed · \S/
      refute row =~ "Lost"
    end

    test "an address with no tab: Explore's tab after a move back from Build", %{
      conn: conn,
      scope: scope
    } do
      work_item = moved_back!(scope)

      # The confirmation stays, so Explore's status is still Ready for Shape.
      assert work_item.stage_id == @explore
      assert %{status: :shape} = WorkItems.explore(scope, work_item, DateTime.utc_now())

      {:ok, view, html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, "#work-item-head-stage-status", "Explore · Queued")
      assert has_element?(view, "#work-item-explore")
      refute has_element?(view, "#work-item-ticket-text")

      # The queued run has no row in `runs`: the wait block, with no link to it.
      refute html =~ "ended with an error"
      assert has_element?(view, "#work-item-explore-wait-h", "Explore is queued")
      refute has_element?(view, "#work-item-explore-wait a")
    end

    test "after a move back, Explore's tab has the wait block with a link to the live run", %{
      conn: conn,
      scope: scope
    } do
      for {state, words} <- [claimed: "Explore is queued", handed_over: "Explore is running"] do
        work_item = moved_back!(scope)
        {run, dispatch_run} = registered!(work_item, newest_run(work_item), state)
        href = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

        {:ok, view, html} = live(conn, page(scope, work_item.number))

        refute html =~ "ended with an error"
        refute has_element?(view, "#work-item-explore-none")
        assert has_element?(view, ~s(#work-item-explore-wait-h a[href="#{href}"]), words)

        refute has_element?(view, "#work-item-explore-wait p + p a")

        assert has_element?(
                 view,
                 "#work-item-explore-wait p + p",
                 "Attempt #{dispatch_run.attempt}"
               )
      end
    end

    test "after a move back, only Explore's runs of this take in link their pages", %{
      conn: conn,
      scope: scope
    } do
      work_item = moved_back!(scope)
      path = fn run -> ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}" end

      # A second take in, with one run of the take in before it.
      for schema <- [DispatchRun, Confirmation] do
        Repo.update_all(from(d in schema, where: d.work_item_id == ^work_item.id),
          inc: [take_in: 1]
        )
      end

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: [take_in: 2])
      work_item = Repo.get!(WorkItem, work_item.id)

      {explore, _dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)
      {build, _dispatch_run} = registered!(work_item, stage_run!(work_item, @build), :handed_over)

      {earlier, _dispatch_run} =
        registered!(work_item, stage_run!(work_item, @explore, 1), :handed_over)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      # Newest first: Build's live run, then Explore's.
      assert has_element?(view, "#work-item-runs-0", "capture-demo")
      refute has_element?(view, "#work-item-runs-0 a")
      assert has_element?(view, ~s(#work-item-runs-1 a[href="#{path.(explore)}"]))

      refute has_element?(view, ~s(#work-item-runs a[href="#{path.(build)}"]))
      refute has_element?(view, ~s(#work-item-runs a[href="#{path.(earlier)}"]))

      # The stage's row and the head link Explore's run, not the newer run of Build.
      assert has_element?(
               view,
               ~s(#work-item-stage-run-link[href="#{path.(explore)}"]),
               "Run #{explore.number}"
             )

      refute has_element?(view, "#work-item-stage-line a")
      assert has_element?(view, ~s(#work-item-head-stage-status a[href="#{path.(explore)}"]))
      assert has_element?(view, ~s(#work-item-explore-wait-h a[href="#{path.(explore)}"]))
    end

    test "after a move back, Build's run is at another stage and Explore's run is not", %{
      scope: scope
    } do
      work_item = moved_back!(scope)
      {explore, _dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)
      {build, _dispatch_run} = registered!(work_item, stage_run!(work_item, @build), :handed_over)

      row = Repo.get!(WorkItem, work_item.id)
      read = WorkItems.explore(scope, row, DateTime.utc_now())
      page = ApiaryWeb.WorkItemLive.View.page(scope, row, read, [], %{})

      other_stage =
        Map.new([page.work_item.run | page.earlier_runs], &{&1.number, &1.other_stage})

      assert other_stage[build.number] == true
      assert other_stage[explore.number] == false
    end

    test "Details: a claimed run with a pending row reads queued, its attempt linked", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      {run, _dispatch_run} = registered!(work_item, newest_run(work_item), :claimed)
      run |> Ecto.Changeset.change(state: "pending", started_at: nil) |> Repo.update!()

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert line(view, "#work-item-details-runs") == "Attempt 1 (Run 1) · 1 run, queued"
      assert has_element?(view, ~s(#work-item-details-runs a[href$="/runs/#{run.number}"]))
    end

    test "Details: a running run reads 1 running, its attempt linked", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      {run, _dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert line(view, "#work-item-details-runs") == "Attempt 1 (Run 1) · 1 run, 1 running"
      assert has_element?(view, ~s(#work-item-details-runs a[href$="/runs/#{run.number}"]))
    end

    # One run's dot on the head and the step card, and on the run's page.
    defp dots(view) do
      for place <- [".q-wi-meta", "#work-item-step"] do
        cond do
          has_element?(view, "#{place} .q-sdot-running > i.q-ripple") -> :alive
          has_element?(view, "#{place} .q-sdot-running > .q-dot.q-alive-amber") -> :quiet
          has_element?(view, "#{place} .q-sdot-running > i") -> :still
          has_element?(view, "#{place} .q-wi-mk-todo") -> :queued
        end
      end
    end

    test "a running run's dot follows its page: alive, then quiet from when it was heard of", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      {run, _dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)
      run_page = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert dots(view) == [:alive, :alive]
      {:ok, page, _html} = live(conn, run_page)
      refute has_element?(page, "#run-alive.q-alive-amber")

      run
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -62, :second))
      |> Repo.update!()

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert dots(view) == [:quiet, :quiet]
      {:ok, page, _html} = live(conn, run_page)
      assert has_element?(page, "#run-alive.q-alive-amber")

      # A heartbeat one interval ago or less: the dots are alive again.
      run
      |> Ecto.Changeset.change(last_heartbeat_at: DateTime.utc_now())
      |> Repo.update!()

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert dots(view) == [:alive, :alive]
    end

    # What the page holds of the run's row, as it stands once `seconds` passed with the page
    # open.
    defp seconds_pass(view, seconds) do
      at = DateTime.add(DateTime.utc_now(), -seconds, :second)

      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns.followed_run, &%{&1 | last_heartbeat_at: at})
      end)
    end

    defp page_assigns(view), do: :sys.get_state(view.pid).socket.assigns

    # One tick, run to its end: the queries the page's process ran for it.
    defp tick_queries(view) do
      me = self()
      handler = "tick-queries-#{System.unique_integer([:positive])}"
      pid = view.pid

      :ok =
        :telemetry.attach(
          handler,
          [:apiary, :repo, :query],
          # Who may sign up is read from `ApiaryPro.SignUp.Cache` in production, which the
          # tests start without, so its row is not counted.
          fn _event, _measurements, meta, _config ->
            if self() == pid and meta[:source] != "instance_sign_up",
              do: send(me, :tick_query)
          end,
          nil
        )

      send(pid, :quiet_tick)
      _ = render(view)
      :telemetry.detach(handler)
      count_tick_queries(0)
    end

    defp count_tick_queries(n) do
      receive do
        :tick_query -> count_tick_queries(n + 1)
      after
        0 -> n
      end
    end

    defp running_explore(conn, scope) do
      work_item = taken_in_fixture(scope)
      {run, _dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)

      run =
        run
        |> Ecto.Changeset.change(last_heartbeat_at: DateTime.utc_now())
        |> Repo.update!()

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      {view, run}
    end

    test "a heartbeat that arrives keeps the dots alive across a tick", %{
      conn: conn,
      scope: scope
    } do
      {view, run} = running_explore(conn, scope)

      send(view.pid, :quiet_tick)
      assert dots(view) == [:alive, :alive]

      # A timer on the row the page read would turn this run amber.
      seconds_pass(view, 62)

      run
      |> Ecto.Changeset.change(last_heartbeat_at: DateTime.utc_now())
      |> Repo.update!()
      |> Apiary.Runs.broadcast_projected(1, 1)

      send(view.pid, :quiet_tick)
      assert dots(view) == [:alive, :alive]
    end

    test "a run past its interval turns quiet with no reload and no query on the tick", %{
      conn: conn,
      scope: scope
    } do
      {view, _run} = running_explore(conn, scope)
      assert dots(view) == [:alive, :alive]

      seconds_pass(view, 62)
      assert tick_queries(view) == 0
      assert dots(view) == [:quiet, :quiet]
    end

    test "a new heartbeat returns a quiet run to alive with no reload", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      {run, _dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)

      run =
        run
        |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -62, :second))
        |> Repo.update!()

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert dots(view) == [:quiet, :quiet]

      run
      |> Ecto.Changeset.change(last_heartbeat_at: DateTime.utc_now())
      |> Repo.update!()
      |> Apiary.Runs.broadcast_projected(1, 1)

      assert dots(view) == [:alive, :alive]
    end

    test "a tick changes only the dots: no read of the page, and a draft stays", %{
      conn: conn,
      scope: scope
    } do
      {view, _run} = running_explore(conn, scope)
      before = page_assigns(view)

      seconds_pass(view, 62)
      send(view.pid, :quiet_tick)
      assert dots(view) == [:quiet, :quiet]

      now = page_assigns(view)
      changed = for {key, value} <- now, Map.get(before, key) != value, do: key

      assert Enum.sort(changed -- [:__changed__]) -- [:followed_run, :item, :quiet_timer] == []
      assert now.now == before.now
    end

    test "a page with no live run has no timer and does no query on a tick", %{
      conn: conn,
      scope: scope
    } do
      # Queued, with no run row.
      work_item = taken_in_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert page_assigns(view).quiet_timer == nil
      assert tick_queries(view) == 0
      assert page_assigns(view).quiet_timer == nil

      # A run that ended.
      ended = scope |> taken_in_fixture() |> end_run!(understood_result())
      {:ok, view, _html} = live(conn, page(scope, ended.number))
      assert page_assigns(view).followed_run == nil
      assert tick_queries(view) == 0
      assert page_assigns(view).quiet_timer == nil
    end

    test "the timer stops when the run ends", %{conn: conn, scope: scope} do
      {view, run} = running_explore(conn, scope)
      assert is_reference(page_assigns(view).quiet_timer)

      run
      |> Ecto.Changeset.change(state: "completed")
      |> Repo.update!()
      |> Apiary.Runs.broadcast_changed()

      _ = render(view)
      assert page_assigns(view).quiet_timer == nil
      assert tick_queries(view) == 0
    end

    test "a run of a later stage has no timer, and its dot stays as it is", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(understood_result())
        |> place!(Processes.current(scope.workspace), @build, :running)

      registered!(work_item, stage_run!(work_item, @build), :handed_over)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert page_assigns(view).followed_run == nil
      assert page_assigns(view).quiet_timer == nil
      assert tick_queries(view) == 0
      refute has_element?(view, ".q-dot.q-alive-amber")
      refute has_element?(view, ".q-wi-meta .q-ripple")
      assert has_element?(view, ".q-wi-meta .q-sdot-running > i")
      refute has_element?(view, ".q-wi-mk-run")
      assert has_element?(view, "#work-item-stage-state .q-wi-badge.bg-info-soft", "Running")
      refute has_element?(view, ".bg-success-soft")
      assert has_element?(view, "#work-item-record .text-info-soft-content", "running")
      # The stage that is done has the green mark.
      assert has_element?(view, ".q-wi-stage-done .q-wi-stage-n")
    end

    test "a quiet run's badge is amber on the one card, and blue while it is alive", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      registered!(work_item, newest_run(work_item), :handed_over)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-step .q-wi-badge.bg-info-soft", "Running")
      refute has_element?(view, "#work-item-step .bg-success-soft")

      seconds_pass(view, 3600)
      send(view.pid, :quiet_tick)

      assert has_element?(view, "#work-item-step .q-wi-badge.bg-primary-soft", "Running")
      refute has_element?(view, "#work-item-step .bg-info-soft")
    end

    test "a queued run's dot has no ripple, also with a pending row", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert dots(view) == [:queued, :queued]

      {run, _dispatch_run} = registered!(work_item, newest_run(work_item), :claimed)
      run |> Ecto.Changeset.change(state: "pending", started_at: nil) |> Repo.update!()

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert dots(view) == [:queued, :queued]
    end

    test "a run handed over with no run row has a still dot", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      newest_run(work_item) |> Ecto.Changeset.change(state: :handed_over) |> Repo.update!()

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert dots(view) == [:still, :still]
      refute has_element?(view, "#work-item-step-run-link")
    end

    test "the step card's top row links the run by its number; its line has no link", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      {run, _dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)
      href = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, ~s(#work-item-step-run-link[href="#{href}"]), "Run #{run.number}")
      refute has_element?(view, "#work-item-step-line a")
      refute line(view, "#work-item-step-line") =~ "(Run"

      # The head has the link and no number.
      assert line(view, ".q-wi-meta .q-wi-st") == "Explore is running"
      assert has_element?(view, ~s(.q-wi-meta .q-wi-st a[href="#{href}"]))

      # A block has both, of the same run.
      assert has_element?(
               view,
               ~s(#work-item-details-runs a[href="#{href}"]),
               "Attempt 1 (Run #{run.number})"
             )
    end

    # A gate `none`, or a move forward and an approve, leaves Explore with no confirmation,
    # so a live Build run sets Explore's status.
    test "unconfirmed, with a live Build run: an ended Explore run has no wait block", %{
      conn: conn,
      scope: scope
    } do
      for {result, shows} <- [
            {understood_result(), "#work-item-explore-proposal"},
            {questions_result(), "#work-item-explore-questions"},
            {nil, "#work-item-explore-none"}
          ],
          {state, status} <- [handed_over: :running, queued: :queued] do
        work_item =
          scope
          |> taken_in_fixture()
          |> end_run!(result)
          |> place!(Processes.current(scope.workspace), @build, :running)

        build = stage_run!(work_item, @build)

        href =
          if state == :handed_over do
            {run, _dispatch_run} = registered!(work_item, build, state)
            ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"
          end

        assert %{status: ^status} = WorkItems.explore(scope, work_item, DateTime.utc_now())

        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
        tab = above_record(view)

        refute tab =~ "is running"
        refute tab =~ "is queued"
        refute tab =~ "n/a"
        if href, do: refute(tab =~ ~s(href="#{href}"))
        refute has_element?(view, "#work-item-explore-wait")
        assert has_element?(view, shows)
      end
    end

    test "unconfirmed, with a live Build run: no line that the run reads a review comment", %{
      conn: conn,
      scope: scope
    } do
      for {state, status} <- [handed_over: :running, queued: :queued] do
        ended = scope |> taken_in_fixture() |> end_run!(understood_result())
        read = Repo.get!(WorkItem, ended.id)
        {:ok, _} = WorkItems.review_comment(scope, read, 1, "Show the order's currency.")

        work_item = place!(read, Processes.current(scope.workspace), @build, :running)
        build = stage_run!(work_item, @build)
        if state == :handed_over, do: registered!(work_item, build, state)

        assert %{status: ^status} = WorkItems.explore(scope, work_item, DateTime.utc_now())

        {:ok, view, html} = live(conn, page(scope, work_item.number) <> "/explore")

        assert has_element?(view, "#work-item-review", "Show the order's currency.")
        refute html =~ "reads this comment"
      end
    end

    test "unconfirmed, with a live Build run: a live Explore run has the wait block", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope
        |> taken_in_fixture()
        |> place!(Processes.current(scope.workspace), @build, :running)

      {build, _dispatch_run} =
        registered!(work_item, stage_run!(work_item, @build), :handed_over)

      assert %{status: :running} = WorkItems.explore(scope, work_item, DateTime.utc_now())
      href = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{build.number}"

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      wait = view |> element("#work-item-explore-wait") |> render()

      assert wait =~ "Explore is queued."
      refute wait =~ ~s(href="#{href}")
    end

    test "unconfirmed, with a live Build run and no Explore run: no wait block, no n/a", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope
        |> taken_in_fixture()
        |> place!(Processes.current(scope.workspace), @build, :running)

      only =
        work_item
        |> newest_run()
        |> Ecto.Changeset.change(stage_id: @build, workflow: "capture-demo")
        |> Repo.update!()

      {build, _dispatch_run} = registered!(work_item, only, :handed_over)
      assert %{status: :running} = WorkItems.explore(scope, work_item, DateTime.utc_now())
      href = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{build.number}"

      # With no Explore run and the stage at Build, Explore has no tab, and the address goes
      # to the work item's page.
      to = page(scope, work_item.number)

      assert {:error, {:live_redirect, %{to: ^to}}} =
               live(conn, page(scope, work_item.number) <> "/explore")

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/ticket")

      refute has_element?(view, "#work-item-tabs-explore")
      refute has_element?(view, "#work-item-explore-wait")
      refute has_element?(view, "#work-item-explore-none")
      # The record block has every run of the work item, Build's with its link.
      assert has_element?(view, ~s(#work-item-record .q-xp-runrow a[href="#{href}"]))
    end

    test "at a later stage, Explore's tab does not count that stage's live run as Explore's", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)
      {:ok, _work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      at_build = Repo.get!(WorkItem, work_item.id)
      assert at_build.stage_id == @build

      {run, _dispatch_run} = registered!(at_build, stage_run!(at_build, @build), :handed_over)
      href = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      {:ok, view, html} = live(conn, page(scope, at_build.number) <> "/explore")

      refute html =~ "ended with an error"
      refute has_element?(view, "#work-item-explore-none")
      refute has_element?(view, "#work-item-explore-wait")
      refute has_element?(view, "#work-item-explore-run")
      refute has_element?(view, ~s(#work-item-explore-proposal a[href="#{href}"]))
      assert has_element?(view, "#work-item-explore-proposal")
      # Explore's tab lists only Explore's runs.
      refute has_element?(view, ~s(#work-item-record .q-xp-runrow a[href="#{href}"]))
    end

    test "after a move back, the stage card's line and the fold's row link the running run", %{
      conn: conn,
      scope: scope
    } do
      {work_item, run, dispatch_run} = running_after_move!(scope)
      href = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               ~s(#work-item-stage-run-link[href="#{href}"]),
               "Run #{run.number}"
             )

      assert line(view, "#work-item-stage-line") == "Explore is running."
      refute has_element?(view, "#work-item-stage-line a")

      # Each of the take in's runs is Explore's, so Explore's fold lists them, and the
      # Runs list is not above the tabs.
      refute has_element?(view, "#work-item-runs")

      assert has_element?(
               view,
               ~s(#work-item-record .q-xp-runrow a[href="#{href}"]),
               "Attempt #{dispatch_run.attempt} (Run #{run.number})"
             )

      assert List.last(fold_rows(view)) =~ "· round 1 ·"
    end

    test "after a move back, the header's status links the running run as a whole", %{
      conn: conn,
      scope: scope
    } do
      {work_item, run, _dispatch_run} = running_after_move!(scope)
      href = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               ~s(#work-item-head-stage-status a[href="#{href}"]),
               "Explore · Running"
             )
    end

    test "after a move back, a queued run with no row has a header status with no link", %{
      conn: conn,
      scope: scope
    } do
      work_item = moved_back!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-head-stage-status", "Explore · Queued")
      refute has_element?(view, "#work-item-head-stage-status a")
    end

    test "after a move back, a reader with no run.read has a header status with no link", %{
      conn: conn,
      scope: scope
    } do
      view = running_where_runs_are_unreadable!(conn, scope)

      assert has_element?(view, "#work-item-head-stage-status", "Explore · Running")
      refute has_element?(view, "#work-item-head-stage-status a")
    end

    test "a later stage's header status has no link", %{conn: conn, scope: scope} do
      work_item = running_at_build!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-head-stage-status", "Build · Running")
      refute has_element?(view, "#work-item-head-stage-status a")
    end

    test "after a move back, a reader who may not read the run's workspace gets no link", %{
      conn: conn,
      scope: scope
    } do
      view = running_where_runs_are_unreadable!(conn, scope)

      assert has_element?(view, "#work-item-stage-line", "Explore is running.")
      assert has_element?(view, "#work-item-record .q-xp-runrow", "Attempt")
      refute has_element?(view, ~s(a[href*="/runs/"]))
    end

    test "a later stage's line has no link, and the record block's row links the run", %{
      conn: conn,
      scope: scope
    } do
      work_item = running_at_build!(scope)
      number = Repo.one(from r in Run, order_by: [desc: r.number], limit: 1, select: r.number)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-line", "Build is running.")
      refute has_element?(view, "#work-item-stage-line a")
      refute has_element?(view, "#work-item-stage-run-link")
      refute has_element?(view, "#work-item-runs")

      assert has_element?(
               view,
               ~s(#work-item-record .q-xp-runrow a[href$="/runs/#{number}"]),
               "Attempt 1 (Run #{number})"
             )
    end

    test "an address with no tab: Explore's tab at Explore's gate, the Ticket tab at Shape", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, "#work-item-explore")
      refute has_element?(view, "#work-item-ticket-text")

      {:ok, _} = WorkItems.confirm(scope, work_item, 1)
      assert Repo.get!(WorkItem, work_item.id).stage_id == @shape

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, "#work-item-ticket-text")
      refute has_element?(view, "#work-item-explore")
    end

    test "waiting for answers: a link to the questions", %{conn: conn, scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result())
      {:ok, view, html} = live(conn, page(scope, work_item.number) <> "/ticket")

      # One card: the step card, with the stage's state, and the link to the answers.
      assert has_element?(view, "#work-item-step-state", "Needs answers")
      refute has_element?(view, "#work-item-stage")
      refute html =~ "Explore waits for answers to the agent's questions."
      refute has_element?(view, "#work-item-stage-answers")
      assert length(String.split(html, "Answer the questions")) == 2

      assert has_element?(
               view,
               ~s|#work-item-step a[href$="/stages/#{@explore}"]|,
               "Answer the questions"
             )

      refute html =~ "explore-a-ticket · round"
    end

    test "waiting for answers past Explore: the stage card has the link", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope
        |> shape_gate_fixture()
        |> place!(Processes.current(scope.workspace), @build, :waiting_answers)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      # Build runs no workflow here, so it has no tab, and the link goes to Explore's.
      assert has_element?(
               view,
               ~s|#work-item-stage-answers[href="#{page(scope, work_item.number)}/stages/#{@explore}"]|
             )
    end

    test "at its gate: Confirm on Explore's tab, and no second Approve", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)
      {:ok, view, html} = live(conn, page(scope, work_item.number) <> "/ticket")

      # One card: the step card with the stage's name and state; no Outputs, no stage card.
      assert has_element?(view, "#work-item-step-h", "Explore")
      refute has_element?(view, "#work-item-step-h", "Approve")
      assert has_element?(view, "#work-item-step-state", "At the gate")
      refute has_element?(view, "#work-item-stage")
      refute has_element?(view, "#work-item-stage-gate-output-proposal")
      assert has_element?(view, "#work-item-step-explore", "Read the proposal")
      refute has_element?(view, "#work-item-stage-gate-approve")
      refute has_element?(view, "#work-item-stage-gate-ask-changes")
      # The decision is Confirm's: the gate card says nothing of who approves.
      refute has_element?(view, "#work-item-stage-gate-approvers")
      refute render(view) =~ "Any member approves."
      refute html =~ "explore-a-ticket · round"
      # Artifacts are in the fold of the runs, on Explore's tab.
      refute has_element?(view, "#work-item-artifact-list")
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert line(view, "#work-item-record-fold > summary") =~ "proposal v1"
      assert has_element?(view, "#work-item-artifact-list", "proposal v1")
      # Beside the frames of the tab, not under Questions.
      assert has_element?(view, "#work-item-record h3#work-item-artifacts-h", "Artifacts")

      # Inside the work item, runs count by attempt; only Artifacts shows the run's number
      # in its workspace.
      number =
        Repo.one(
          from r in Apiary.Runs.Run,
            where: r.dispatch_run_id == ^newest_run(work_item).id,
            select: r.number
        )

      Repo.update_all(from(d in DispatchRun, where: d.id == ^newest_run(work_item).id),
        set: [round: 2]
      )

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert has_element?(view, "#work-item-artifact-list", "Run #{number}")
      refute has_element?(view, "#work-item-artifact-list", "round")
      assert line(view, "#work-item-details-runs") == "Attempt 1 (Run 1) · 1 run, ended"
      refute render(view) =~ "Run 1 · explore-a-ticket"
      refute render(view) =~ "rn_"

      render_hook(view, "stage_approve", %{
        "number" => "#{work_item.number}",
        "seen" => @explore,
        "note" => ""
      })

      assert decisions(work_item, :approve) == []

      view |> element("#work-item-explore-gate-go", "Approve") |> render_click()
      assert [%GateDecision{stage_id: @explore}] = decisions(work_item, :approve)
      assert has_element?(view, ~s|#work-item-head-stages-#{@shape}[aria-current="step"]|)
    end

    test "a run that pushed the verdict escalate: the escalation, and no Approve", %{
      conn: conn,
      scope: scope
    } do
      text = "The ticket describes two baskets."

      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(fn run, registered ->
          push_result!(run, registered, understood_result())

          {:ok, _version} =
            Stages.Artifacts.push_json(
              {:run, run},
              Repo.get!(WorkItem, run.work_item_id),
              "verdict",
              %{
                "verdict" => "escalate",
                "points" => [%{"text" => text, "action" => "run_again"}]
              },
              stage_id: run.stage_id
            )
        end)

      assert %Escalation{cause: :escalate} = escalation(work_item)

      # The Ticket tab has the line to the block; the Explore tab has the block.
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/ticket")
      refute has_element?(view, "#work-item-needs")

      assert has_element?(
               view,
               ~s|#work-item-stage-waits a[href="#{page(scope, work_item.number)}/explore#work-item-needs"]|,
               "Waits for you: 1 point"
             )

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert has_element?(view, "#work-item-needs-point-1", text <> " Run another round.")
      assert has_element?(view, ~s|#work-item-stage-waits a[href="#work-item-needs"]|)

      for view <- [view, elem(live(conn, page(scope, work_item.number) <> "/ticket"), 1)] do
        refute has_element?(view, "#work-item-stage-gate-approve")
        refute has_element?(view, "#work-item-explore-gate-go")
      end
    end

    test "a run that asks and escalates: the block above the questions, and no note field", %{
      conn: conn,
      scope: scope
    } do
      # Run 1 proposes and escalates; Run another round queues run 2, which asks two
      # questions and escalates while they are open.
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(fn run, registered ->
          push_result!(run, registered, understood_result())

          push_verdict!(run, [
            %{"text" => "The ticket describes two baskets.", "action" => "run_again"}
          ])
        end)

      {:ok, _} =
        Stages.resolve_escalation(scope, work_item, :another_round, nil,
          expect_stage: work_item.stage_id
        )

      work_item =
        work_item
        |> then(&Repo.get!(WorkItem, &1.id))
        |> end_run!(fn run, registered ->
          push_result!(run, registered, questions_result())

          push_verdict!(run, [
            %{
              "text" => "The ticket does not say which sale.",
              "action" => "answer",
              "question" => "q2"
            },
            %{
              "text" => "The checks script failed on the proposal's links.",
              "action" => "run_again"
            }
          ])
        end)

      assert Repo.get!(WorkItem, work_item.id).stage_state == :waiting_answers
      assert %Escalation{resolved_at: nil} = escalation(work_item)

      {:ok, view, html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert line(view, "#work-item-needs-point-1") ==
               "The ticket does not say which sale. Answer question 2."

      assert has_element?(
               view,
               ~s|#work-item-needs-point-1 a[href="#work-item-explore-questions-question-2"]|,
               "question 2"
             )

      assert line(view, "#work-item-needs-point-2") ==
               "The checks script failed on the proposal's links. Run another round."

      # The answers run the next round: the block has no note field and no button.
      refute has_element?(view, "#work-item-needs textarea")
      refute has_element?(view, "#work-item-stage-escalation-another")

      # The block, then the proposal of run 1, from an earlier round, then the questions.
      [needs, proposal, questions] =
        for id <- [
              "work-item-needs",
              "work-item-explore-proposal",
              "work-item-explore-questions-question-1"
            ],
            do: :binary.match(html, ~s|id="#{id}"|) |> elem(0)

      assert needs < proposal and proposal < questions
      assert html =~ "Version 1 · from an earlier round"

      # The step card keeps its line, and leads to the block.
      assert has_element?(
               view,
               "#work-item-step-line",
               "Answer the 2 questions or add a comment, then run another round."
             )

      assert has_element?(
               view,
               ~s|#work-item-stage-waits a[href="#work-item-needs"]|,
               "Waits for you: 2 points"
             )

      # On the Ticket tab, the line leads to the Explore tab's block.
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/ticket")
      refute has_element?(view, "#work-item-needs")

      assert has_element?(
               view,
               ~s|#work-item-stage-waits a[href="#{page(scope, work_item.number)}/explore#work-item-needs"]|
             )

      # The answers resolve the escalation and run the next round.
      {:ok, _} = WorkItems.answer(scope, work_item, 2, open_answers(work_item))
      assert %Escalation{resolution: :another_round} = escalation(work_item)
      assert %DispatchRun{attempt: 3} = newest_run(work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      refute has_element?(view, "#work-item-needs")
    end

    test "a result that did not pass the check: both cards name the run by its attempt", %{
      conn: conn,
      scope: scope
    } do
      # A run that stopped, whose row a release before the run API kept as refused: the
      # result Core read did not pass its check.
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(nil, %{exit_state: "failed", outcome_state: "failed"})

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^newest_run(work_item).id),
          set: [result_outcome: :refused]
        )

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert line(view, "#work-item-stage-escalation-run") == "From attempt 1 · explore-a-ticket"
      # The step card is hidden while the stage is escalated; the block has the point the
      # stage stored when the run ended.
      refute has_element?(view, "#work-item-step")

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert line(view, "#work-item-needs-point-1") ==
               "The run stopped: it ended without a result. Run another round."
    end

    test "a run that stopped: the escalation with its cause", %{conn: conn, scope: scope} do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(nil, %{exit_state: "failed", outcome_state: "failed"})

      {:ok, _view, html} = live(conn, page(scope, work_item.number))
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert has_element?(view, "#work-item-stage-state", "Waits for a person")
      # Waiting on you counts the escalation for its owner.
      assert has_element?(view, "#nav-work_items .q-nav-count", "1")
      assert has_element?(view, "#work-item-stage-waits", "Waits for you: 1 point")

      # The run gave no result, so there is nothing to accept.
      refute has_element?(view, "#work-item-stage-escalation-accept")
      assert has_element?(view, "#work-item-needs #work-item-stage-escalation-another")

      assert line(view, "#work-item-needs-point-1") ==
               "The run stopped: it ended without a result. Run another round."

      # The block takes the place of the banner of a run with no result.
      refute has_element?(view, "#work-item-explore-none")

      assert has_element?(
               view,
               "#work-item-stage-escalation-run",
               "From attempt 1 · explore-a-ticket"
             )

      refute has_element?(view, "#work-item-stage-escalation-move")
      # No runs list above the tabs: the fold of the runs on Explore's tab has the run.
      refute html =~ "explore-a-ticket · round"

      # The block's Run another round runs Explore again: the step card is hidden, and the
      # step card's event does nothing.
      refute has_element?(view, "#work-item-step")

      runs = fn ->
        Repo.aggregate(from(r in DispatchRun, where: r.work_item_id == ^work_item.id), :count)
      end

      before = runs.()
      render_hook(view, "explore_again", %{"number" => "#{work_item.number}"})
      assert runs.() == before

      # Run another round runs Explore again, in the same round, as it has no loop; the run
      # that stopped still reads as it did.
      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "another_round"})

      confirm_spend(view)

      assert %DispatchRun{attempt: 2} = newest_run(work_item)
      assert has_element?(view, "#work-item-step-state", "Queued")

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert line(view, "#work-item-record-fold > summary") =~ "2 runs"
      assert has_element?(view, "#work-item-record-fold", "Attempt 1")
      assert has_element?(view, "#work-item-record-fold", "Attempt 2")
    end

    test "a run that ended at its claim keeps its line after another round", %{
      conn: conn,
      scope: scope
    } do
      # The claim could not form the run, so the run ended with no registered run and no
      # result (`Apiary.Dispatches.Handover.end_claimed/3`).
      work_item = taken_in_fixture(scope)
      run = newest_run(work_item)

      run
      |> Ecto.Changeset.change(
        state: :ended,
        end_cause: :variables_invalid,
        result_outcome: :error
      )
      |> Repo.update!()

      [run.id] |> Stages.claim_ended() |> Apiary.Dispatches.broadcast()
      assert %{cause: :run_stopped, run_id: run_id} = escalation(work_item)
      assert run_id == run.id

      refute Repo.exists?(
               from r in Apiary.Runs.Run.registered(), where: r.dispatch_run_id == ^run.id
             )

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, "#work-item-stage-escalation-form")

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "another_round"})

      confirm_spend(view)

      assert %DispatchRun{attempt: 2} = newest_run(work_item)
      assert has_element?(view, "#work-item-step-state", "Queued")

      # The run that ended at its claim still has its line in the fold of the runs.
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert line(view, "#work-item-record-fold > summary") =~ "2 runs"
      assert has_element?(view, "#work-item-record-fold", "Attempt 1")
      assert has_element?(view, "#work-item-record-fold", "Attempt 2")
    end
  end

  # Take in 1 of a new work item: its run writes "Which basket?" (q1), and, with
  # `answer`, a member answers it; then the work item is closed and taken in again. The
  # work item in take in 2, its first run queued.
  defp second_take_in!(scope, answer \\ false) do
    ticket = backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    work_item = end_run!(Repo.get!(WorkItem, work_item.id), questions_result(["Which basket?"]))

    if answer,
      do: {:ok, _} = WorkItems.answer(scope, work_item, 1, [%{"id" => "q1", "note" => "a"}])

    {:ok, _} = WorkItems.close(scope, Repo.get!(WorkItem, work_item.id))
    {:ok, _} = WorkItems.take_in_again(scope, ticket.public_id)
    Repo.get!(WorkItem, work_item.id)
  end

  describe "a proposal's images" do
    @cart "The cart page:\n\n![A cart](a-cart.png)\n"

    # A copy of the Markdown file of version `number` of `work_item`'s proposal, saved as
    # the image `a-cart.png` of that version.
    defp add_cart!(work_item, number) do
      file =
        Repo.one!(
          from f in Apiary.Artifacts.ArtifactFile,
            join: v in Apiary.Artifacts.Version,
            on: v.id == f.version_id,
            join: a in Artifact,
            on: a.id == v.artifact_id,
            where:
              a.work_item_id == ^work_item.id and a.type == "proposal" and v.number == ^number
        )

      file
      |> Map.merge(%{id: nil, filename: "a-cart.png", content_type: "image/png"})
      |> Ecto.put_meta(state: :built)
      |> Repo.insert!()
    end

    @img ~s(img[src$="/files/a-cart.png"][alt="A cart"])

    test "the newest proposal shows the image of its version from the version's files", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope |> taken_in_fixture() |> end_run!(understood_result(%{"message" => @cart}))

      cart = add_cart!(work_item, 1)
      %{public_id: version_id} = Repo.get!(Apiary.Artifacts.Version, cart.version_id)
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert has_element?(
               view,
               ~s(#work-item-explore-proposal-text img[src$="/artifacts/#{version_id}/files/a-cart.png"])
             )
    end

    test "an earlier take in's proposal shows the image of its version", %{
      conn: conn,
      scope: scope
    } do
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

      work_item =
        end_run!(Repo.get!(WorkItem, work_item.id), understood_result(%{"message" => @cart}))

      add_cart!(work_item, 1)
      {:ok, _} = WorkItems.close(scope, work_item)
      {:ok, _} = WorkItems.take_in_again(scope, ticket.public_id)
      work_item = Repo.get!(WorkItem, work_item.id)
      end_run!(work_item, understood_result(%{"message" => "Take in two."}))

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      fold = "#work-item-explore-take-ins-1"
      view |> element("#{fold}-s") |> render_click()
      assert has_element?(view, "#{fold} #{@img}")
    end

    test "with the workflow model hidden from the reader, an image shows as its words", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope |> taken_in_fixture() |> end_run!(understood_result(%{"message" => @cart}))

      add_cart!(work_item, 1)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:workflow_model])
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert has_element?(view, "#work-item-explore-proposal-text", "Image: A cart")
      refute has_element?(view, "#work-item-explore-proposal-text img")
    end
  end

  describe "Explore after a take in that left a question" do
    test "take in 1 left q1 open; take in 2's run writes a proposal: Confirm", %{
      conn: conn,
      scope: scope
    } do
      work_item = second_take_in!(scope)
      work_item = end_run!(work_item, understood_result())

      assert %{status: :confirm} = WorkItems.explore(scope, work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert has_element?(view, "#work-item-explore-gate-go", "Approve")
      # q1 shows only in take in 1's fold, not in a Questions frame.
      refute has_element?(view, "#work-item-explore-questions")
      assert has_element?(view, "#work-item-explore-take-ins-1", "Which basket?")
    end

    test "take in 1 left q1 open; take in 2 writes q2, the member answers it, the next run writes a proposal: Confirm",
         %{conn: conn, scope: scope} do
      work_item = second_take_in!(scope)
      work_item = end_run!(work_item, questions_result(["Which sale?"]))
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      q = "#work-item-explore-questions"
      assert has_element?(view, "#{q}-form [name^='answers[q2]']")
      refute has_element?(view, "#{q}-form [name^='answers[q1]']")

      view
      |> element("#{q}-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q2" => %{"note" => "The spring sale."}}
      })

      confirm_spend(view)

      assert %DispatchRun{take_in: 2, attempt: 2, state: :waiting} = newest_run(work_item)
      work_item = end_run!(work_item, understood_result())
      assert %{status: :confirm} = WorkItems.explore(scope, work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert has_element?(view, "#work-item-explore-gate-go", "Approve")
      refute has_element?(view, "#{q}-form")
    end

    test "take in 1 answered q1; take in 2's run reopens it: the form shows q1", %{
      conn: conn,
      scope: scope
    } do
      work_item = second_take_in!(scope, true)

      work_item =
        end_run!(work_item, fn run, registered ->
          {_version, document} = Apiary.Explore.Questions.newest(work_item)
          at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

          questions =
            for %{"id" => "q1", "answer" => answer} = question <- document["questions"] do
              question
              |> Map.delete("answer")
              |> Map.merge(%{
                "state" => "open",
                "history" => [
                  Map.put(answer, "reopened", %{"run" => registered.number, "at" => at})
                ]
              })
            end

          {:ok, _version} =
            Artifacts.push(
              {:run, run},
              work_item,
              "questions",
              [Apiary.Explore.Questions.file(%{"questions" => questions})],
              name: "main",
              stage_id: run.stage_id
            )
        end)

      assert %{status: :questions} = WorkItems.explore(scope, work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      q = "#work-item-explore-questions"
      assert has_element?(view, "#{q}-question-1", "Which basket?")
      assert has_element?(view, "#{q}-form [name^='answers[q1]']")
    end
  end

  describe "at Shape's gate" do
    for level <- [:owner, :admin, :member] do
      test "#{level}: one Approve, and Request changes", %{conn: conn, scope: scope} do
        work_item = shape_gate_fixture(scope)
        conn = as(conn, scope, unquote(level))
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        assert has_element?(view, "#work-item-head-stages-#{@explore}.q-wi-stage-done")
        assert has_element?(view, "#work-item-stage-gate-none", "This stage has no outputs.")

        assert has_element?(
                 view,
                 "#work-item-stage-gate-approvers",
                 "One approval covers each version. Any member approves."
               )

        view |> element("#work-item-stage-gate-ask-changes") |> render_click()
        view |> form("#work-item-stage-gate-changes", %{"note" => ""}) |> render_submit()

        assert has_element?(
                 view,
                 "#work-item-stage-gate-changes-note-error",
                 "Write what needs to change."
               )

        view
        |> form("#work-item-stage-gate-changes", %{"note" => "Split the plan in two"})
        |> render_submit()

        assert [%GateDecision{note: "Split the plan in two"}] =
                 decisions(work_item, :request_changes)

        view |> form("#work-item-stage-gate-approve") |> render_submit()

        assert [%GateDecision{}] =
                 work_item |> decisions(:approve) |> Enum.filter(&(&1.stage_id == @shape))

        assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
      end
    end

    test "an earlier stage's artifact changed after approval", %{conn: conn, scope: scope} do
      work_item = shape_gate_fixture(scope)
      push!({:person, scope}, work_item, "proposal", @explore)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-marks-proposal-main-m", "Approved v1; v2 is newer")

      assert has_element?(
               view,
               "#work-item-marks-proposal-main-m-changed",
               "Changed after approval"
             )

      # The two marks read apart.
      words =
        view
        |> element("#work-item-marks-proposal-main")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.split()
        |> Enum.join(" ")

      assert words =~ "Approved v1; v2 is newer · Changed after approval"
    end

    test "an event for another number does nothing", %{conn: conn, scope: scope} do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      render_hook(view, "stage_approve", %{
        "number" => "#{work_item.number + 1}",
        "seen" => @shape,
        "note" => ""
      })

      assert work_item |> decisions(:approve) |> Enum.all?(&(&1.stage_id == @explore))
    end
  end

  describe "at Build's gate" do
    test "each output with its version and its check", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :at_gate)
      push!({:person, scope}, work_item, "demo-video", @build)
      video = push!({:person, scope}, work_item, "demo-video", @build)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-gate-output-demo-video", "demo video v2")
      assert has_element?(view, "#work-item-stage-gate-check-demo-video", "Passed")

      assert has_element?(
               view,
               "#work-item-stage-gate-check-change",
               "Not checked in this version"
             )

      assert has_element?(view, "#work-item-stage-gate-check-explainer", "Missing")
      assert has_element?(view, "#work-item-stage-gate-check-decision-record", "Optional, none")

      view |> element("#work-item-stage-gate-ask-changes") |> render_click()

      assert has_element?(
               view,
               ~s|#work-item-stage-gate-changes-version option[value="#{video.public_id}"]|,
               "demo video v2"
             )

      render_hook(view, "stage_request_changes", %{
        "number" => "#{work_item.number}",
        "seen" => @build,
        "version" => "av_other",
        "note" => "Show two gift cards"
      })

      assert decisions(work_item, :request_changes) == []
    end
  end

  describe "a gate with a missing output" do
    # A work item at the gate of Shape, a stage with no workflow that has `outputs` as
    # required outputs and `gate` as its gate.
    defp at_shape_gate(scope, outputs, gate \\ %{"kind" => "person", "approvers" => "members"}) do
      default = Processes.default_document("software")

      stages =
        for stage <- default["stages"] do
          if stage["id"] == @shape do
            %{
              stage
              | "outputs" => Enum.map(outputs, &%{"type" => &1, "required" => true}),
                "gate" => gate
            }
          else
            stage
          end
        end

      version = save!(scope, %{default | "stages" => stages})

      scope
      |> work_item_fixture()
      |> place!(version, @shape, :at_gate, stage_round: 1, stage_entry: 1)
    end

    defp markdown(name),
      do: [%{filename: name, content_type: "text/markdown", binary: "# Done"}]

    test "one line, an Add for each output, and no Approve that can only fail", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape_gate(scope, ["acceptance-criteria", "explainer"])
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-stage-gate-line",
               "Shape needs acceptance criteria and explainer"
             )

      assert has_element?(view, "#work-item-stage-gate-add-acceptance-criteria", "Add")
      assert has_element?(view, "#work-item-stage-gate-add-explainer", "Add")
      refute has_element?(view, "#work-item-stage-gate-approve")
      assert has_element?(view, "#work-item-stage-gate-ask-changes")
    end

    test "Add opens the artifact page with the type chosen", %{conn: conn, scope: scope} do
      work_item = at_shape_gate(scope, ["acceptance-criteria"])
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      {:ok, new, _html} =
        view
        |> element("#work-item-stage-gate-add-acceptance-criteria")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(new, "#artifact-new")
      assert has_element?(new, ~s|#artifact-form option[selected][value="acceptance-criteria"]|)
    end

    test "the line goes when a person adds the output, and Approve works", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape_gate(scope, ["acceptance-criteria"])
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      {:ok, _version} =
        Stages.add_version(scope, work_item, "acceptance-criteria", markdown("ac.md"))

      refute has_element?(view, "#work-item-stage-gate-line")
      refute has_element?(view, "#work-item-stage-gate-add-acceptance-criteria")

      view |> form("#work-item-stage-gate-approve") |> render_submit()

      assert [%GateDecision{stage_id: @shape}] = decisions(work_item, :approve)
      assert Repo.get!(WorkItem, work_item.id).stage_id == @build
    end

    test "a member the gate does not list may add the output and has no Approve", %{
      conn: conn,
      scope: scope
    } do
      listed = member_fixture(scope, :member)
      gate = %{"kind" => "person", "approvers" => %{"members" => [listed.user.id]}}
      work_item = at_shape_gate(scope, ["acceptance-criteria"], gate)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-gate-line", "Shape needs acceptance criteria")
      assert has_element?(view, "#work-item-stage-gate-add-acceptance-criteria")
      refute has_element?(view, "#work-item-stage-gate-approve")
    end

    test "a stage with a workflow keeps Approve beside the line", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :at_gate)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-gate-line", "Build needs")
      assert has_element?(view, "#work-item-stage-gate-approve")
    end

    test "at a gate none: the line and Add, no approval, and a real push passes it on", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape_gate(scope, ["acceptance-criteria"], %{"kind" => "none"})
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-gate-line", "Shape needs acceptance criteria")
      assert has_element?(view, "#work-item-stage-gate-add-acceptance-criteria", "Add")
      refute has_element?(view, "#work-item-stage-gate-approvers")
      refute has_element?(view, "#work-item-stage-gate-ask-changes")
      refute has_element?(view, "#work-item-stage-gate-approve")

      {:ok, _version} =
        Stages.add_version(scope, work_item, "acceptance-criteria", markdown("ac.md"))

      assert Repo.get!(WorkItem, work_item.id).stage_id == @build
      assert decisions(work_item, :approve) == []
      assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
    end

    test "a member Explore's gate does not list has no review links, and goes back from their form pages",
         %{conn: conn, scope: scope} do
      listed = explore_gate_listing(scope)
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(listed, work_item, 1, "Offer a refund first.")
      explore = page(scope, work_item.number) <> "/stages/#{@explore}"

      {:ok, view, _html} = live(conn, explore)
      refute has_element?(view, "#work-item-explore-proposal-review-add")
      refute has_element?(view, "[id$='-reply']")

      assert {:error, {:live_redirect, %{to: ^explore}}} = live(conn, explore <> "?reply=c1")

      assert Apiary.Explore.ReviewComments.newest(work_item) != nil

      approver = log_in_user(build_conn(), listed.user)
      {:ok, view, _html} = live(approver, explore)
      refute has_element?(view, "#work-item-explore-proposal-review-add")
      assert has_element?(view, "#work-item-explore-gate-comment")
      assert has_element?(view, "[id$='-reply']", "Reply")

      {:ok, view, _html} = live(approver, explore <> "?reply=c1")
      assert has_element?(view, "#work-item-review-page-form")
    end

    test "a page read while the member was an approver: the line under the field when they send",
         %{scope: scope} do
      listed = explore_gate_listing(scope)
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(listed, work_item, 1, "Offer a refund first.")
      approver = log_in_user(build_conn(), listed.user)
      explore = page(scope, work_item.number) <> "/explore"
      {:ok, reply, _html} = live(approver, explore <> "?reply=c1")

      # The work item moves to a version whose Explore lists another member.
      version = list_explore_approvers!(scope, [scope.user.id])

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [process_version_id: version.id]
      )

      reply
      |> element("#work-item-review-page-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "comment" => "c1",
        "text" => "Only for card payments."
      })

      assert has_element?(
               reply,
               "#work-item-review-page-error",
               "Ask one of this stage's approvers to write comments on the proposal. Only approvers of the stage can write them."
             )

      assert has_element?(reply, "#work-item-review-page-text", "Only for card payments.")
      assert has_element?(reply, "#work-item-review-page-text[aria-describedby]")
    end

    test "Run another round with every answer blank from an approver: the open review comments go to the next run",
         %{conn: conn, scope: scope} do
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Offer a refund first.")
      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)
      work_item = end_run!(Repo.get!(WorkItem, work_item.id), questions_result(["Which refund?"]))

      count = fn ->
        Repo.aggregate(from(d in DispatchRun, where: d.work_item_id == ^work_item.id), :count)
      end

      runs = count.()

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{"number" => "#{work_item.number}", "answers" => %{}})

      confirm_spend(view)

      refute has_element?(view, "#work-item-explore-questions-error")
      assert count.() == runs + 1
    end

    test "Run another round with every answer blank from a member Explore's gate does not list: the blank-answer error, and no run",
         %{conn: conn, scope: scope} do
      listed = explore_gate_listing(scope)
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(listed, work_item, 1, "Offer a refund first.")
      {:ok, _} = WorkItems.send_review_comments(listed, work_item, 1)
      work_item = end_run!(Repo.get!(WorkItem, work_item.id), questions_result(["Which refund?"]))

      runs =
        Repo.aggregate(from(d in DispatchRun, where: d.work_item_id == ^work_item.id), :count)

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{"number" => "#{work_item.number}", "answers" => %{}})

      assert has_element?(
               view,
               "#work-item-explore-questions-error[role=alert]",
               "Choose an option or write an answer. If nobody knows, say so: Explore reads that too."
             )

      refute render(view) =~ "Ask an approver of Explore to act on it."

      assert Repo.aggregate(
               from(d in DispatchRun, where: d.work_item_id == ^work_item.id),
               :count
             ) ==
               runs
    end

    test "Run another round with every answer blank from a member Explore's gate does not list, not shown the workflow model: the blank-answer error, and no run",
         %{conn: conn, scope: scope} do
      listed = explore_gate_listing(scope)
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(listed, work_item, 1, "Offer a refund first.")
      {:ok, _} = WorkItems.send_review_comments(listed, work_item, 1)
      work_item = end_run!(Repo.get!(WorkItem, work_item.id), questions_result(["Which refund?"]))

      runs =
        Repo.aggregate(from(d in DispatchRun, where: d.work_item_id == ^work_item.id), :count)

      # The instance has the workflow model; the reader is not shown it, so the page has
      # no stage card.
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:workflow_model])
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      refute has_element?(view, "#work-item-stage")
      assert open_review_comments(work_item) == ["c1"]

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{"number" => "#{work_item.number}", "answers" => %{}})

      assert has_element?(
               view,
               "#work-item-explore-questions-error[role=alert]",
               "Choose an option or write an answer. If nobody knows, say so: Explore reads that too."
             )

      assert Repo.aggregate(
               from(d in DispatchRun, where: d.work_item_id == ^work_item.id),
               :count
             ) ==
               runs

      assert open_review_comments(work_item) == ["c1"]
    end

    test "Explore's gate shows to a member the gate lists, and not to one it does not list",
         %{conn: conn, scope: scope} do
      listed = explore_gate_listing(scope)
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(listed, work_item, 1, "Offer a refund first.")
      explore = page(scope, work_item.number) <> "/explore"

      {:ok, view, _html} = live(log_in_user(build_conn(), listed.user), explore)
      assert has_element?(view, "#work-item-explore-gate")

      # The owner is not among the approvers Explore's gate lists: no Confirm and no Send
      # review comments, as `Apiary.Access` allows neither action (`work_item.confirm`,
      # `work_item.review_comment`).
      {:ok, view, _html} = live(conn, explore)
      refute has_element?(view, "#work-item-explore-gate")
      refute Access.can?(scope, :"work_item.confirm", Repo.get!(WorkItem, work_item.id))
    end

    test "a member Explore's gate does not list: who approves next, with one, two and three approvers, and no gate",
         %{conn: conn, scope: scope} do
      users = for _ <- 1..3, do: member_fixture(scope, :member).user
      people = Enum.map(users, & &1.id)
      [a, b, _c] = Enum.map(people, &shown_name(scope, &1))
      first = Apiary.Organisations.load_scope(Apiary.Accounts.Scope.for_user(hd(users)))

      for {ids, head, step, thread} <- [
            {Enum.take(people, 1), "#{a} approves next",
             "#{a} approves the proposal or runs another round.",
             "Explore wrote a proposal, after 30 s. #{a} approves next"},
            # The gate's order, not the names' order.
            {people |> Enum.take(2) |> Enum.reverse(), "#{b} or #{a} approves next",
             "#{b} or #{a} approves the proposal or runs another round.",
             "Explore wrote a proposal, after 30 s. #{b} or #{a} approves next"},
            {people, "One of 3 approvers approves next",
             "One of the stage's 3 approvers approves the proposal or runs another round.",
             "Explore wrote a proposal, after 30 s. One of 3 approvers approves next"}
          ] do
        list_explore_approvers!(scope, ids)
        work_item = explore_gate_fixture(scope)
        {:ok, _} = WorkItems.review_comment(first, work_item, 1, "Offer a refund.")
        explore = page(scope, work_item.number) <> "/explore"

        {:ok, view, _html} = live(conn, explore)
        assert has_element?(view, "#work-item-head-meta", head)
        assert has_element?(view, "#work-item-head-meta .q-wi-mk-wait_other")
        refute render(view) =~ "You approve next"
        assert texts(view, "#work-item-step-line") == [step]
        refute has_element?(view, "#work-item-explore-gate")
        refute has_element?(view, "#work-item-step-explore")
        refute render(view) =~ "Run another round starts the next run."
        refute render(view) =~ "Approve leaves 1 comment unread."

        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/thread")
        assert has_element?(view, "#work-item-thread", thread)
      end
    end

    test "a stage that lists one approver: the approver reads You approve next, the owner the approver's name",
         %{conn: conn, scope: scope} do
      listed = explore_gate_listing(scope)
      name = shown_name(scope, listed.user.id)
      work_item = explore_gate_fixture(scope)

      for {conn, head, thread} <- [
            {log_in_user(build_conn(), listed.user), "You approve next",
             "Explore wrote a proposal, after 30 s. You approve next"},
            {conn, "#{name} approves next",
             "Explore wrote a proposal, after 30 s. #{name} approves next"}
          ] do
        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
        assert has_element?(view, "#work-item-head-meta", head)

        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/thread")
        assert has_element?(view, "#work-item-thread", thread)
      end
    end

    test "after an approver sends review comments, the Thread's proposal of run 1 has no one who approves next",
         %{conn: conn, scope: scope} do
      listed = explore_gate_listing(scope)
      name = shown_name(scope, listed.user.id)
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(listed, work_item, 1, "Offer a refund first.")
      {:ok, _} = WorkItems.send_review_comments(listed, work_item, 1)

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/thread")

      assert has_element?(view, "#work-item-thread", "Explore wrote a proposal, after 30 s")
      refute has_element?(view, "#work-item-thread", "#{name} approves next")
      refute has_element?(view, "#work-item-thread", "You approve next")
    end

    test "at a later stage that lists another approver, the Thread's proposal has no one who approves next",
         %{conn: conn, scope: scope} do
      explore_approver = member_fixture(scope, :member)
      later_approver = member_fixture(scope, :member)
      default = Processes.default_document("software")

      stages =
        for stage <- default["stages"] do
          case stage["id"] do
            @explore -> %{stage | "gate" => listing([explore_approver.user.id])}
            @shape -> %{stage | "gate" => listing([later_approver.user.id])}
            _other -> stage
          end
        end

      save!(scope, %{default | "stages" => stages})
      work_item = explore_gate_fixture(scope)

      confirmer =
        Apiary.Organisations.load_scope(Apiary.Accounts.Scope.for_user(explore_approver.user))

      {:ok, _} = WorkItems.confirm(confirmer, work_item, 1)
      assert Repo.get!(WorkItem, work_item.id).stage_id == @shape

      later_conn = log_in_user(build_conn(), later_approver.user)
      {:ok, view, _html} = live(later_conn, page(scope, work_item.number) <> "/thread")

      assert has_element?(view, "#work-item-thread", "Explore wrote a proposal, after 30 s")
      refute has_element?(view, "#work-item-thread", "confirms next")
      refute has_element?(view, "#work-item-thread", "You approve next")

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/thread")
      refute has_element?(view, "#work-item-thread", "You approve next")
    end

    test "a confirm that moves to a stage with other approvers: the open form page stays, with the draft and its line",
         %{scope: scope} do
      dana = member_fixture(scope, :member)
      eve = member_fixture(scope, :member)
      frank = member_fixture(scope, :member)
      default = Processes.default_document("software")

      stages =
        for stage <- default["stages"] do
          case stage["id"] do
            @explore -> %{stage | "gate" => listing([dana.user.id, eve.user.id])}
            @shape -> %{stage | "gate" => listing([frank.user.id])}
            _other -> stage
          end
        end

      save!(scope, %{default | "stages" => stages})

      eve_scope = Apiary.Organisations.load_scope(Apiary.Accounts.Scope.for_user(eve.user))
      dana_scope = Apiary.Organisations.load_scope(Apiary.Accounts.Scope.for_user(dana.user))

      for {address, comment, line} <- [
            {"?reply=c1", [{"comment", "c1"}],
             "Copy your text if you need it. You can no longer send this reply, because the work item changed."}
          ] do
        work_item = explore_gate_fixture(scope)
        {:ok, _} = WorkItems.review_comment(eve_scope, work_item, 1, "Name the field.")

        {:ok, view, _html} =
          live(
            log_in_user(build_conn(), eve.user),
            page(scope, work_item.number) <> "/explore" <> address
          )

        view
        |> element("#work-item-review-page-form")
        |> render_change(
          Map.new([{"number", "#{work_item.number}"}, {"text", "Keep the old PDFs."} | comment])
        )

        {:ok, _} = WorkItems.confirm(dana_scope, work_item, 1)
        assert Repo.get!(WorkItem, work_item.id).stage_id == @shape
        send(view.pid, {:work_items_changed, [work_item.public_id]})

        assert has_element?(view, "#work-item-review-page-form")
        assert has_element?(view, "#work-item-review-page-text", "Keep the old PDFs.")
        assert has_element?(view, "#work-item-review-page-error", line)
        assert has_element?(view, "#work-item-review-page-form a", "Cancel")
        refute has_element?(view, ~s(#work-item-review-page-form button[type="submit"]))

        # A send from the kept page writes nothing, and the line and the text stay.
        view
        |> element("#work-item-review-page-form")
        |> render_submit(
          Map.new([{"number", "#{work_item.number}"}, {"text", "Keep the old PDFs."} | comment])
        )

        assert has_element?(view, "#work-item-review-page-text", "Keep the old PDFs.")
        assert has_element?(view, "#work-item-review-page-error", line)

        {_version, document} = Apiary.Explore.ReviewComments.newest(work_item)
        assert [%{"id" => "c1"} = c1] = document["review_comments"]
        assert (c1["replies"] || []) == []
      end
    end

    test "a reader not shown the workflow model reads the approver's name, and has no Confirm",
         %{conn: conn, scope: scope} do
      listed = explore_gate_listing(scope)
      name = shown_name(scope, listed.user.id)
      work_item = explore_gate_fixture(scope)

      # The instance has the workflow model; the reader is not shown it.
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:workflow_model])
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      refute has_element?(view, "#work-item-stage")
      assert has_element?(view, "#work-item-head-meta", "#{name} approves next")
      refute has_element?(view, "#work-item-explore-gate-go")
    end

    test "the Work items list: the approver reads You approve next, the owner the approver's name, with one query per row",
         %{conn: conn, scope: scope} do
      listed = explore_gate_listing(scope)
      name = shown_name(scope, listed.user.id)
      work_items = for _ <- 1..2, do: explore_gate_fixture(scope)
      rows = Enum.map(work_items, &"#work-item-#{&1.public_id}")

      {:ok, view, _html} = live(conn, list(scope))

      for row <- rows do
        assert has_element?(view, "#{row} .q-wl-nx", "#{name} approves next")
        refute has_element?(view, "#{row} .q-wl-row-hot")
        assert has_element?(view, "#{row} .q-wi-mk-wait_other")
      end

      {:ok, view, _html} = live(log_in_user(build_conn(), listed.user), list(scope))

      for row <- rows do
        assert has_element?(view, "#{row} .q-wl-nx", "You approve next")
        assert has_element?(view, "#{row} .q-wl-row-hot")
        assert has_element?(view, "#{row} .q-wi-mk-wait")
      end

      # The rows are read for the list at once. The access check of each row
      # (`ApiaryPro.Access`) reads the organisation's tenant row, so a second row takes
      # one query more.
      list_rows = fn ids ->
        Enum.map(ids, &%{id: &1.public_id, state: :exploring, status: :confirm})
      end

      assert queries(fn ->
               ApiaryWeb.WorkItemLive.Workflow.row_confirmers(
                 scope,
                 list_rows.(Enum.take(work_items, 1))
               )
             end) + 1 ==
               queries(fn ->
                 ApiaryWeb.WorkItemLive.Workflow.row_confirmers(scope, list_rows.(work_items))
               end)
    end

    test "the Work items list's counts and Waiting on you go to the approver, not to an owner who is not listed",
         %{conn: conn, scope: scope} do
      listed = explore_gate_listing(scope)
      work_item = explore_gate_fixture(scope)
      row = "#work-item-#{work_item.public_id}"
      approver = log_in_user(build_conn(), listed.user)

      {:ok, view, _html} = live(approver, list(scope))
      assert has_element?(view, "#nav-work_items .q-nav-count", "1")
      assert has_element?(view, "#work-items-views", "Waiting on you 1")
      {:ok, view, _html} = live(approver, list(scope) <> "?view=you")
      assert has_element?(view, row)

      {:ok, view, _html} = live(conn, list(scope))
      refute has_element?(view, "#nav-work_items .q-nav-count")
      assert has_element?(view, "#work-items-views", "Waiting on you 0")
      {:ok, view, _html} = live(conn, list(scope) <> "?view=you")
      refute has_element?(view, row)

      # The instance has the workflow model; the reader is not shown it, so the page has the
      # strip and the bands in place of the board.
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:workflow_model])

      {:ok, view, _html} = live(approver, list(scope))
      assert has_element?(view, "#work-items-stages-confirm .q-wl-attn", "1 waits for you")
      assert has_element?(view, "#work-items-confirm .q-wl-attn", "1 waits for you")

      {:ok, view, _html} = live(conn, list(scope))
      assert has_element?(view, "#work-items-stages-confirm .q-wl-attn", "1 waits for a member")
      assert has_element?(view, "#work-items-confirm .q-wl-attn", "1 waits for a member")

      # Filtered to the owner, it still does not wait for the owner.
      {:ok, view, _html} = live(conn, list(scope) <> "?owner=#{scope.user.id}")
      assert has_element?(view, "#work-items-stages-confirm .q-wl-attn", "1 waits for a member")
    end

    test "an escalated work item still at Confirm waits only for whoever may resolve it",
         %{scope: scope} do
      listed = explore_gate_listing(scope)
      work_item = explore_gate_fixture(scope)
      row = "#work-item-#{work_item.public_id}"

      # Explore's status stays confirm, but the stage escalated: the page hides Confirm.
      {1, _} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_state: :escalated]
        )

      escalate!(Repo.get!(WorkItem, work_item.id), :escalate, "Blocked")
      approver = log_in_user(build_conn(), listed.user)

      # The listed approver may resolve the escalation: it counts once.
      {:ok, view, _html} = live(approver, list(scope))
      assert has_element?(view, "#nav-work_items .q-nav-count", "1")
      assert has_element?(view, "#work-items-views", "Waiting on you 1")
      {:ok, view, _html} = live(approver, list(scope) <> "?view=you")
      assert has_element?(view, row)

      # Without the workflow model, the approver may confirm but not resolve: neither
      # Waiting on you nor Approve counts it.
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:workflow_model])

      {:ok, view, _html} = live(approver, list(scope))
      refute has_element?(view, "#nav-work_items .q-nav-count")
      assert has_element?(view, "#work-items-views", "Waiting on you 0")
      refute has_element?(view, "#work-items-stages-confirm .q-wl-attn", "waits for you")
      {:ok, view, _html} = live(approver, list(scope) <> "?view=you")
      refute has_element?(view, row)
    end

    test "a work item with no process version follows the current version's approvers",
         %{scope: scope} do
      listed = explore_gate_listing(scope)
      work_item = explore_gate_fixture(scope)

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [process_version_id: nil]
      )

      assert WorkItems.count_waiting_on(listed) == 1
      assert WorkItems.count_waiting_on(scope) == 0
    end

    test "an escalation at a gate of every member waits for the owner only, as Confirm does",
         %{conn: conn, scope: scope} do
      other = member_fixture(scope, :member)
      work_item = at_build(scope, :escalated, round: 3)
      escalate!(work_item, :escalate, "Blocked")
      row = "#work-item-#{work_item.public_id}"

      {:ok, view, _html} = live(conn, list(scope))
      assert has_element?(view, "#nav-work_items .q-nav-count", "1")
      assert has_element?(view, "#work-items-views", "Waiting on you 1")
      {:ok, view, _html} = live(conn, list(scope) <> "?view=you")
      assert has_element?(view, row)

      reader = log_in_user(build_conn(), other.user)
      {:ok, view, _html} = live(reader, list(scope))
      refute has_element?(view, "#nav-work_items .q-nav-count")
      assert has_element?(view, "#work-items-views", "Waiting on you 0")

      {:ok, _} =
        Stages.resolve_escalation(scope, work_item, :close, nil, expect_stage: work_item.stage_id)

      assert WorkItems.count_waiting_on(scope) == 0
    end

    test "an escalation at a gate that lists approvers waits for a listed member only",
         %{scope: scope} do
      listed = member_fixture(scope, :member)
      unlisted = member_fixture(scope, :member)

      work_item =
        at_build(scope, :escalated, round: 3, approvers: %{"members" => [listed.user.id]})

      escalate!(work_item, :escalate, "Blocked")
      row = "#work-item-#{work_item.public_id}"

      reader = log_in_user(build_conn(), listed.user)
      {:ok, view, _html} = live(reader, list(scope))
      assert has_element?(view, "#work-items-views", "Waiting on you 1")
      {:ok, view, _html} = live(reader, list(scope) <> "?view=you")
      assert has_element?(view, row)

      reader = log_in_user(build_conn(), unlisted.user)
      {:ok, view, _html} = live(reader, list(scope))
      refute has_element?(view, "#nav-work_items .q-nav-count")
      assert has_element?(view, "#work-items-views", "Waiting on you 0")
      {:ok, view, _html} = live(reader, list(scope) <> "?view=you")
      refute has_element?(view, row)
    end

    test "a gate of every member: the counts and Waiting on you stay with the owner, with no query per row",
         %{conn: conn, scope: scope} do
      other = member_fixture(scope, :member)
      work_item = explore_gate_fixture(scope)
      row = "#work-item-#{work_item.public_id}"

      {:ok, view, _html} = live(conn, list(scope))
      assert has_element?(view, "#nav-work_items .q-nav-count", "1")
      assert has_element?(view, "#work-items-views", "Waiting on you 1")
      {:ok, view, _html} = live(conn, list(scope) <> "?view=you")
      assert has_element?(view, row)

      reader = log_in_user(build_conn(), other.user)
      {:ok, view, _html} = live(reader, list(scope))
      refute has_element?(view, "#nav-work_items .q-nav-count")
      assert has_element?(view, "#work-items-views", "Waiting on you 0")
      {:ok, view, _html} = live(reader, list(scope) <> "?view=you")
      refute has_element?(view, row)

      one = queries(fn -> WorkItems.count_waiting_on(scope) end)
      explore_gate_fixture(scope)
      assert queries(fn -> WorkItems.count_waiting_on(scope) end) == one
      assert WorkItems.count_waiting_on(scope) == 2
    end

    test "an approver of a stage that lists them: the gate and the lines as for every member",
         %{conn: conn, scope: scope} do
      other = member_fixture(scope, :member)
      list_explore_approvers!(scope, [other.user.id, scope.user.id])
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Offer a refund first.")

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert has_element?(view, "#work-item-head-meta", "You approve next")

      assert texts(view, "#work-item-step-line") == [
               "Approve the proposal, or add a comment and run another round."
             ]

      assert has_element?(view, "#work-item-explore-gate-send", "Run another round")
      assert has_element?(view, "#work-item-explore-gate-go", "Approve")

      assert has_element?(
               view,
               "#work-item-explore-gate",
               "Run another round starts the next run."
             )

      assert has_element?(
               view,
               "#work-item-explore-gate-unread",
               "Approve leaves 1 comment unread."
             )

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/thread")
      assert has_element?(view, "#work-item-thread", "after 30 s. You approve next")
    end

    test "each control of Explore's gate and questions shows where Apiary.Access allows its action",
         %{conn: conn, scope: scope} do
      listed = explore_gate_listing(scope)
      at_gate = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(listed, at_gate, 1, "Offer a refund first.")
      asked = scope |> taken_in_fixture() |> end_run!(questions_result(["Which refund?"]))

      for {reader, conn} <- [{scope, conn}, {listed, log_in_user(build_conn(), listed.user)}] do
        {:ok, view, _html} = live(conn, page(scope, at_gate.number) <> "/explore")
        row = Repo.get!(WorkItem, at_gate.id)

        for {selector, action} <- [
              {"#work-item-explore-gate-go", :"work_item.confirm"},
              {"#work-item-explore-gate-send", :"work_item.review_comment"}
            ] do
          assert has_element?(view, selector) == Access.can?(reader, action, row),
                 "#{selector} for #{inspect(action)}"
        end

        {:ok, view, _html} = live(conn, page(scope, asked.number) <> "/explore")
        row = Repo.get!(WorkItem, asked.id)
        assert Access.can?(reader, :"work_item.answer", row)
        assert has_element?(view, "#work-item-explore-questions-form")
      end
    end

    test "Run another round from a page read while the reader was an approver: the line, and no run",
         %{scope: scope} do
      listed = explore_gate_listing(scope)
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(listed, work_item, 1, "Offer a refund first.")

      runs =
        Repo.aggregate(from(d in DispatchRun, where: d.work_item_id == ^work_item.id), :count)

      {:ok, view, _html} =
        live(
          log_in_user(build_conn(), listed.user),
          page(scope, work_item.number) <> "/explore"
        )

      assert has_element?(view, "#work-item-explore-gate-send")

      # The member is taken off the approver list after the page read the work item.
      version = list_explore_approvers!(scope, [scope.user.id])

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [process_version_id: version.id]
      )

      view
      |> element("#work-item-explore-gate")
      |> render_submit(%{"number" => "#{work_item.number}"})

      confirm_spend(view)

      assert has_element?(
               view,
               "#work-item-explore-gate-error",
               "Ask an approver of Explore to act on it."
             )

      refute has_element?(view, "#work-item-explore-gate-send")
      assert open_review_comments(work_item) == ["c1"]

      assert Repo.aggregate(
               from(d in DispatchRun, where: d.work_item_id == ^work_item.id),
               :count
             ) == runs
    end

    test "the blank-answer error of a member the gate does not list is gone once the page reads the work item again",
         %{conn: conn, scope: scope} do
      listed = explore_gate_listing(scope)
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(listed, work_item, 1, "Offer a refund first.")
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      # The owner is not among the approvers: no gate to send the review comments from.
      refute has_element?(view, "#work-item-explore-gate")

      # The approver sends the review comments, and the run ends with a question.
      {:ok, _} = WorkItems.send_review_comments(listed, work_item, 1)
      work_item = end_run!(Repo.get!(WorkItem, work_item.id), questions_result(["Which refund?"]))
      send(view.pid, {:work_items_changed, [work_item.public_id]})

      assert has_element?(view, "#work-item-explore-questions-form")
      refute has_element?(view, "#work-item-explore-questions-error")

      # With the review comment still open, the member sends every answer blank and sees
      # the blank-answer error. The approver sends the review comments again, and the run
      # ends with another question: the error is gone from the form.
      assert open_review_comments(work_item) == ["c1"]

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{"number" => "#{work_item.number}", "answers" => %{}})

      assert has_element?(
               view,
               "#work-item-explore-questions-error",
               "Choose an option or write an answer."
             )

      {:ok, _} = WorkItems.send_review_comments(listed, work_item, 2)
      work_item = end_run!(Repo.get!(WorkItem, work_item.id), questions_result(["Which card?"]))
      send(view.pid, {:work_items_changed, [work_item.public_id]})

      assert has_element?(view, "#work-item-explore-questions-form", "Which card?")
      refute has_element?(view, "#work-item-explore-questions-error")
      refute render(view) =~ "Choose an option or write an answer."
    end

    test "Run another round of an approver at Explore's gate: the next run, and no line", %{
      scope: scope
    } do
      listed = explore_gate_listing(scope)
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(listed, work_item, 1, "Offer a refund first.")

      runs =
        Repo.aggregate(from(d in DispatchRun, where: d.work_item_id == ^work_item.id), :count)

      {:ok, view, _html} =
        live(
          log_in_user(build_conn(), listed.user),
          page(scope, work_item.number) <> "/explore"
        )

      view
      |> element("#work-item-explore-gate")
      |> render_submit(%{"number" => "#{work_item.number}"})

      confirm_spend(view)

      refute has_element?(view, "#work-item-explore-gate-error")
      refute render(view) =~ "Ask an approver of Explore to act on it."

      assert Repo.aggregate(
               from(d in DispatchRun, where: d.work_item_id == ^work_item.id),
               :count
             ) == runs + 1
    end

    test "at Explore with a proposal waiting and no artifact: Confirm and no needs line", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)
      Repo.delete_all(from a in Artifact, where: a.work_item_id == ^work_item.id)

      assert %{state: :at_gate, missing_outputs: ["proposal"]} = Stages.status(work_item, scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/ticket")

      assert has_element?(view, "#work-item-step-explore", "Read the proposal")
      refute has_element?(view, "#work-item-stage-gate-line")
      refute has_element?(view, "#work-item-stage-gate-add-proposal")
      refute has_element?(view, "#work-item-stage-gate-output-proposal")
    end

    test "past Explore with a proposal waiting: Shape's card keeps its needs and Approve", %{
      conn: conn,
      scope: scope
    } do
      # Explore with gate none passes on to Shape while the proposal waits for Confirm.
      default = Processes.default_document("software")

      stages =
        for stage <- default["stages"] do
          case stage["id"] do
            @explore ->
              %{stage | "gate" => %{"kind" => "none"}}

            @shape ->
              %{stage | "outputs" => [%{"type" => "acceptance-criteria", "required" => true}]}

            _other ->
              stage
          end
        end

      save!(scope, %{default | "stages" => stages})
      work_item = explore_gate_fixture(scope)

      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} =
               Repo.get!(WorkItem, work_item.id)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      refute has_element?(view, "#work-item-step-explore", "Read Qory's proposal")
      assert has_element?(view, "#work-item-stage-gate-line", "Shape needs acceptance criteria")
      assert has_element?(view, "#work-item-stage-gate-output-acceptance-criteria")
      assert has_element?(view, "#work-item-stage-gate-ask-changes")

      {:ok, _version} =
        Stages.add_version(scope, work_item, "acceptance-criteria", markdown("ac.md"))

      refute has_element?(view, "#work-item-stage-gate-line")
      view |> form("#work-item-stage-gate-approve") |> render_submit()
      assert Repo.get!(WorkItem, work_item.id).stage_id == @build
    end

    test "a stale Approve: the notice lists the output and the stage", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape_gate(scope, ["acceptance-criteria"])
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      render_hook(view, "stage_approve", %{
        "number" => "#{work_item.number}",
        "seen" => @shape,
        "note" => ""
      })

      assert decisions(work_item, :approve) == []

      assert has_element?(
               view,
               "#work-item-stage-notice",
               "Add acceptance criteria before you approve Shape."
             )
    end
  end

  describe "a stage that lists its approvers" do
    test "only a listed member sees Approve; anyone else is refused on the server", %{
      conn: conn,
      scope: scope
    } do
      listed = member_fixture(scope, :member)
      work_item = at_build(scope, :at_gate, approvers: %{"members" => [listed.user.id]})
      push!({:person, scope}, work_item, "demo-video", @build)
      push!({:person, scope}, work_item, "explainer", @build)
      push!({:person, scope}, work_item, "change", @build)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      refute has_element?(view, "#work-item-stage-gate-approve")
      refute has_element?(view, "#work-item-stage-gate-ask-changes")

      assert has_element?(
               view,
               "#work-item-stage-gate-approvers",
               "The members this stage lists approve."
             )

      render_hook(view, "stage_approve", %{
        "number" => "#{work_item.number}",
        "seen" => @build,
        "note" => ""
      })

      assert decisions(work_item, :approve) == []

      {:ok, view, _html} =
        live(log_in_user(build_conn(), listed.user), page(scope, work_item.number))

      view |> form("#work-item-stage-gate-approve") |> render_submit()
      assert [%GateDecision{stage_id: @build}] = decisions(work_item, :approve)
    end

    # Explore's gate `none` passes the proposal on to Shape's gate, which needs an output,
    # so Explore's status stays at Confirm. Shape's gate is `shape_gate`, or the default's.
    defp left_explore!(scope, shape_gate \\ nil) do
      default = Processes.default_document("software")

      stages =
        for stage <- default["stages"] do
          case stage["id"] do
            @explore ->
              %{stage | "gate" => %{"kind" => "none"}}

            @shape ->
              %{
                stage
                | "outputs" => [%{"type" => "acceptance-criteria", "required" => true}],
                  "gate" => shape_gate || stage["gate"]
              }

            _other ->
              stage
          end
        end

      save!(scope, %{default | "stages" => stages})
      work_item = explore_gate_fixture(scope)

      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} =
               Repo.get!(WorkItem, work_item.id)

      assert %{status: :confirm} = WorkItems.explore(scope, work_item, DateTime.utc_now())
      work_item
    end

    test "the Work items list: a proposal that waits after its work item left Explore waits for no one",
         %{conn: conn, scope: scope} do
      # Shape lists no one (the owner rule), or lists the owner.
      for shape_gate <- [nil, listing([scope.user.id])] do
        work_item = left_explore!(scope, shape_gate)
        row = "#work-item-#{work_item.public_id}"

        # The row looks like any row at Shape's gate.
        {:ok, view, _html} = live(conn, list(scope))
        assert texts(view, "#{row} .q-wl-nx") == ["At the gate"]
        assert has_element?(view, "#{row} .q-wi-mk-wait")
        refute has_element?(view, "#{row} .q-wl-row-hot")
        refute has_element?(view, "#nav-work_items .q-nav-count")
        assert has_element?(view, "#work-items-views", "Waiting on you 0")

        {:ok, view, _html} = live(conn, list(scope) <> "?view=you")
        refute has_element?(view, row)
        assert WorkList.waiting_on(scope) == 0
      end
    end

    test "a reader not shown the workflow model: the Approve strip and band count no work item that left Explore",
         %{conn: conn, scope: scope} do
      member = as(conn, scope, :member)
      owner = shown_name(scope, scope.user.id)
      left = left_explore!(scope, listing([scope.user.id]))
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:workflow_model])

      {:ok, view, _html} = live(member, list(scope) <> "?owner=#{scope.user.id}")

      assert texts(view, "#work-items-stages-confirm") == [
               "Approve1A member approves the proposalNothing waits"
             ]

      assert has_element?(view, "#work-items-confirm #work-item-#{left.public_id}")
      refute has_element?(view, "#work-items-stages-confirm .q-wl-attn")
      refute has_element?(view, "#work-items-confirm .q-wl-attn")

      # A work item at Explore's gate, which lists no one, waits for its owner; the gate
      # that the other work item is at lists approvers, but it is not Explore's.
      :ok = Apiary.EditionStubs.HidesNamed.put([])
      save!(scope, Processes.default_document("software"))
      _waiting = explore_gate_fixture(scope)
      :ok = Apiary.EditionStubs.HidesNamed.put([:workflow_model])

      {:ok, view, _html} = live(member, list(scope) <> "?owner=#{scope.user.id}")
      assert has_element?(view, "#work-items-stages-confirm .q-wl-attn", "1 waits for #{owner}")
      assert has_element?(view, "#work-items-confirm .q-wl-attn", "1 waits for #{owner}")
    end

    test "the sidebar's count reads Explore's workflow unless the list read it already",
         %{scope: scope} do
      left_explore!(scope)
      explore = Stages.explore_workflow(scope.workspace)
      read = queries(fn -> Stages.explore_workflow(scope.workspace) end)
      given = queries(fn -> WorkList.waiting_on(scope, explore_workflow: explore) end)

      assert read > 0
      assert queries(fn -> WorkList.waiting_on(scope) end) == given + read
    end

    test "a listed approver who may not approve: their name is left out, the page says why",
         %{scope: scope} do
      robin = member_fixture(scope, :member).user
      kim = member_fixture(scope, :member).user
      kim_name = shown_name(scope, kim.id)
      robin_conn = log_in_user(build_conn(), robin)

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.RefusesConfirm)
      :ok = Apiary.EditionStubs.RefusesConfirm.put(robin.id)

      for {ids, head, lines, thread} <- [
            {[robin.id, kim.id], "#{kim_name} approves next",
             [
               "#{kim_name} approves the proposal or runs another round.",
               "You are listed as an approver, but you may not approve in this workspace."
             ], "Explore wrote a proposal, after 30 s. #{kim_name} approves next"},
            {[robin.id], "No listed approver may approve",
             ["You are the only listed approver, but you may not approve in this workspace."],
             "Explore wrote a proposal, after 30 s"}
          ] do
        list_explore_approvers!(scope, ids)
        work_item = explore_gate_fixture(scope)
        explore = page(scope, work_item.number) <> "/explore"

        {:ok, view, _html} = live(robin_conn, explore)
        assert texts(view, "#work-item-head-meta .q-wi-st") == [head]
        assert has_element?(view, "#work-item-head-meta .q-wi-mk-wait_other")
        assert texts(view, "#work-item-step p") == lines
        refute has_element?(view, "#work-item-explore-gate-go")

        {:ok, view, _html} = live(robin_conn, page(scope, work_item.number) <> "/thread")
        assert thread in event_lines(view)

        {:ok, view, _html} = live(robin_conn, list(scope))
        row = "#work-item-#{work_item.public_id}"
        assert texts(view, "#{row} .q-wl-nx") == [head]
        refute has_element?(view, "#{row} .q-wl-row-hot")
      end
    end

    # The Thread's event lines, each without when it happened.
    defp event_lines(view) do
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#work-item-thread .q-wi-ev > div > p:first-child")
      |> Enum.map(fn line ->
        at = line |> LazyHTML.query(".q-wi-when") |> LazyHTML.text()
        line |> LazyHTML.text() |> String.replace(at, "") |> String.split() |> Enum.join(" ")
      end)
    end
  end

  describe "waiting" do
    test "for inputs: what is missing, Add and Move back", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :waiting_inputs)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Waits for inputs")
      assert has_element?(view, "#work-item-stage-line", "Build needs acceptance criteria")
      refute has_element?(view, "#work-item-stage-input-mockup")

      assert has_element?(
               view,
               ~s|#work-item-stage-add-acceptance-criteria[href="#{page(scope, work_item.number)}/artifacts/new?type=acceptance-criteria"]|
             )

      render_hook(view, "stage_move", %{
        "number" => "#{work_item.number}",
        "seen" => @build,
        "stage" => @release,
        "note" => ""
      })

      assert decisions(work_item, :move) == []

      assert has_element?(
               view,
               "#work-item-stage-notice",
               "Choose a stage before Build to move back to."
             )

      view
      |> form("#work-item-stage-move", %{"stage" => @shape, "note" => "Write the criteria"})
      |> render_submit()

      assert [%GateDecision{note: "Write the criteria"}] = decisions(work_item, :move)
      assert Repo.get!(WorkItem, work_item.id).stage_id == @shape
    end

    test "for a workflow: the runner's line and Check again", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :waiting_workflow)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Waits for a workflow")

      WorkflowFake.check_result(scope.workspace, {:ok, ["review"]})
      view |> form("#work-item-stage-check") |> render_submit()
      render_async(view)

      assert has_element?(
               view,
               "#work-item-stage-check-result",
               "The harness still does not list capture-demo."
             )

      assert has_element?(view, "#work-item-stage-gap-0", "Build uses capture-demo, which")

      WorkflowFake.check_result(scope.workspace, {:error, {:unreadable, :address}})
      view |> form("#work-item-stage-check") |> render_submit()
      render_async(view)

      assert has_element?(
               view,
               "#work-item-stage-check-result",
               "Contact support to correct the address of"
             )

      assert has_element?(view, "#work-item-stage-check-go", "Try again")

      WorkflowFake.check_result(
        scope.workspace,
        {:ok, ["implement", "capture-demo", "fix-demo-findings"]}
      )

      view |> form("#work-item-stage-check") |> render_submit()
      render_async(view)
      # The stage leaves its wait for the workflow, and waits for Build's required input.
      assert has_element?(view, "#work-item-stage-state", "Waits for inputs")
      refute has_element?(view, "#work-item-stage-check")
    end

    defp check_line(view) do
      view
      |> element("#work-item-stage-check-result")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")
    end

    test "for a workflow: a check that stops on an error sends the reader to support", %{
      conn: conn,
      scope: scope
    } do
      on_exit(fn -> Application.put_env(:apiary, :support_address, nil) end)
      work_item = at_build(scope, :waiting_workflow)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      WorkflowFake.check_result(scope.workspace, fn -> raise "the check failed" end)

      ExUnit.CaptureLog.capture_log(fn ->
        view |> form("#work-item-stage-check") |> render_submit()
        render_async(view)
      end)

      assert check_line(view) ==
               "Try again, and contact support if it fails again. " <>
                 "The check of the harness stopped with an error in Qory Apiary."

      Application.put_env(:apiary, :support_address, "support@example.com")

      ExUnit.CaptureLog.capture_log(fn ->
        view |> form("#work-item-stage-check") |> render_submit()
        render_async(view)
      end)

      assert has_element?(
               view,
               ~s(#work-item-stage-check-result a[href="mailto:support@example.com"]),
               "contact support"
             )

      assert check_line(view) ==
               "Try again, and contact support if it fails again. " <>
                 "The check of the harness stopped with an error in Qory Apiary."

      # A read that failed, in the harness's words, links Contact support too.
      WorkflowFake.check_result(scope.workspace, {:error, {:unreadable, :address}})
      view |> form("#work-item-stage-check") |> render_submit()
      render_async(view)

      assert has_element?(
               view,
               ~s(#work-item-stage-check-result a[href="mailto:support@example.com"]),
               "Contact support"
             )
    end

    test "a refusal the page has no words for sends the reader to support" do
      on_exit(fn -> Application.put_env(:apiary, :support_address, nil) end)

      assert ApiaryWeb.WorkItemLive.Show.refused(:busy, nil) ==
               "Reload the page and act again, and contact support if it fails again. " <>
                 "Qory Apiary could not act on the stage."

      Application.put_env(:apiary, :support_address, "support@example.com")

      assert ApiaryWeb.WorkItemLive.Show.refused(:busy, nil) ==
               "Reload the page and act again, and contact support at support@example.com " <>
                 "if it fails again. Qory Apiary could not act on the stage."
    end

    # A work item at Build, which needs no input here, waiting for a workflow the harness
    # now lists: a check that finds it queues Build's run.
    defp waiting_for_found_workflow(scope) do
      stages =
        for stage <- document("members")["stages"] do
          if stage["id"] == @build, do: %{stage | "inputs" => []}, else: stage
        end

      version = save!(scope, %{document("members") | "stages" => stages})

      WorkflowFake.check_result(
        scope.workspace,
        {:ok, ["implement", "capture-demo", "fix-demo-findings"]}
      )

      scope
      |> work_item_fixture()
      |> place!(version, @build, :waiting_workflow, stage_round: 1, stage_entry: 1)
    end

    defp run_count(work_item),
      do: Repo.aggregate(from(r in DispatchRun, where: r.work_item_id == ^work_item.id), :count)

    test "for a workflow: Check again that finds it queues the stage's run", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_for_found_workflow(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = run_count(work_item)

      view |> form("#work-item-stage-check") |> render_submit()
      confirm_spend(view)
      render_async(view)

      assert run_count(work_item) == before + 1
    end

    test "for a workflow: a stale Check again on a closed work item queues no run", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_for_found_workflow(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = run_count(work_item)

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [state: :closed, closed_at: DateTime.utc_now()]
      )

      render_hook(view, "stage_check", %{"number" => "#{work_item.number}", "seen" => @build})
      render_async(view)

      assert run_count(work_item) == before
      assert Repo.get!(WorkItem, work_item.id).stage_state == :waiting_workflow
      refute has_element?(view, "#work-item-stage")
    end

    test "for a workflow: a work item closed during the check gets the check's message", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_for_found_workflow(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = run_count(work_item)

      WorkflowFake.check_result(scope.workspace, fn ->
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [state: :closed, closed_at: DateTime.utc_now()]
        )

        {:ok, ["implement", "capture-demo", "fix-demo-findings"]}
      end)

      view |> form("#work-item-stage-check") |> render_submit()
      confirm_spend(view)
      render_async(view)

      assert run_count(work_item) == before

      assert has_element?(
               view,
               "#work-item-stage-check-result",
               "Reload the page. The work item is closed, so it has no stage to check."
             )
    end

    test "for a workflow: a stale Check again on another stage does not run the check", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_build(scope, :waiting_workflow)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      WorkflowFake.check_result(
        scope.workspace,
        {:ok, ["implement", "capture-demo", "fix-demo-findings"]}
      )

      version = Repo.get!(Apiary.Processes.Version, work_item.process_version_id)
      place!(work_item, version, @release, :waiting_workflow, stage_round: 1)

      render_hook(view, "stage_check", %{"number" => "#{work_item.number}", "seen" => @build})
      render_async(view)

      assert %{stage_id: @release, stage_state: :waiting_workflow} =
               Repo.get!(WorkItem, work_item.id)

      assert has_element?(view, "#work-item-stage-notice", "moved from Build to Release")
    end

    test "for a workflow: no Check again for a person the stage does not list", %{
      conn: conn,
      scope: scope
    } do
      listed = member_fixture(scope, :member)

      work_item =
        at_build(scope, :waiting_workflow, approvers: %{"members" => [listed.user.id]})

      WorkflowFake.check_result(
        scope.workspace,
        {:ok, ["implement", "capture-demo", "fix-demo-findings"]}
      )

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-stage-check")
      render_hook(view, "stage_check", %{"number" => "#{work_item.number}", "seen" => @build})
      render_async(view)
      assert Repo.get!(WorkItem, work_item.id).stage_state == :waiting_workflow
    end
  end

  describe "escalated" do
    setup :ready_pool

    test "each cause: the block with the points the runner stored, and the side line", %{
      conn: conn,
      scope: scope
    } do
      for cause <- [:round_limit, :escalate, :check_failed, :run_stopped] do
        work_item = at_build(scope, :escalated, round: 3)

        escalate!(work_item, cause, [
          "The gift card field has no error text.",
          "The demo shows one gift card."
        ])

        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        assert texts(view, "#work-item-needs-points li") == [
                 "The gift card field has no error text. Run another round.",
                 "The demo shows one gift card. Run another round."
               ]

        assert has_element?(
                 view,
                 ~s|#work-item-stage-waits a[href="#work-item-needs"]|,
                 "Waits for you: 2 points"
               )

        assert has_element?(
                 view,
                 "#work-item-needs",
                 "A note you add goes to the next run as work item data."
               )

        assert has_element?(
                 view,
                 ~s|#work-item-needs textarea[form="work-item-stage-escalation-form"]|
               )

        refute has_element?(view, "#work-item-stage-escalation-cause")
      end
    end

    for level <- [:owner, :admin, :member] do
      test "#{level}: Move back and Close", %{conn: conn, scope: scope} do
        conn = as(conn, scope, unquote(level))

        moved = at_build(scope, :escalated, round: 3)
        escalate!(moved, :escalate, "Blocked")
        {:ok, view, _html} = live(conn, page(scope, moved.number))
        # At a gate of every member, Waiting on you has the escalation for its owner only.
        assert has_element?(view, "#nav-work_items .q-nav-count") == (unquote(level) == :owner)

        view
        |> form("#work-item-stage-escalation-form", %{"note" => "Plan again", "stage" => @shape})
        |> render_submit(%{"how" => "move_back"})

        assert %Escalation{resolution: :move_back, note: "Plan again"} = escalation(moved)
        assert Repo.get!(WorkItem, moved.id).stage_id == @shape

        work_item = at_build(scope, :escalated, round: 3)
        escalate!(work_item, :escalate, "Blocked")
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        view
        |> form("#work-item-stage-escalation-form", %{"note" => ""})
        |> render_submit(%{"how" => "close"})

        assert Repo.get!(WorkItem, work_item.id).state == :closed
      end
    end

    test "each button sends the note from the block, Run another round from outside the form",
         %{conn: conn, scope: scope} do
      for {how, button} <- [
            accept: "#work-item-stage-escalation-accept",
            another_round: "#work-item-stage-escalation-another",
            close: "#work-item-stage-escalation-close"
          ] do
        work_item = at_build(scope, :escalated, round: 3)
        push!({:person, scope}, work_item, "explainer", @build)
        escalate!(work_item, :escalate, "Blocked")
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        # The note field and Run another round sit in the block, outside the form in the
        # rail, and name it in their form attribute.
        assert has_element?(
                 view,
                 ~s|#work-item-needs [form="work-item-stage-escalation-form"]#work-item-stage-escalation-note|
               )

        view
        |> form("#work-item-stage-escalation-form", %{"note" => "Note for #{how}"})
        |> put_submitter(button)
        |> render_submit()

        confirm_spend(view)

        assert %Escalation{resolution: ^how, note: note} = escalation(work_item)
        assert note == "Note for #{how}"
      end
    end

    test "escalated with no escalation row: the point of no verdict, the note and Run another round",
         %{conn: conn, scope: scope} do
      work_item = at_build(scope, :escalated, round: 3)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-needs #work-item-stage-escalation-note")
      assert has_element?(view, "#work-item-needs #work-item-stage-escalation-another")

      assert texts(view, "#work-item-needs-points li") == [
               "The run stopped before its verdict. Run another round."
             ]

      assert has_element?(view, "#work-item-stage-waits", "Waits for you: 1 point")
    end

    test "a proposal with no verdict goes on: no stopped card, and Confirm moves it on", %{
      conn: conn,
      scope: scope
    } do
      work_item = scope |> taken_in_fixture() |> end_run!(proposal_only())

      assert work_item.stage_state == :at_gate
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-needs")
      assert render(view) =~ "You approve next"

      view |> element("[phx-click=confirm]") |> render_click()

      assert Repo.get!(WorkItem, work_item.id).stage_id == @shape
    end

    test "a Shape-style stage: no verdict stops with the card, and its row has one reading", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_workflow_stage(scope) |> end_run!(nil)

      assert work_item.stage_state == :escalated
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert line(view, "#work-item-needs-point-1") ==
               "The run stopped before its verdict. Run another round."

      assert has_element?(view, "#work-item-stage-escalation-another")

      assert has_element?(view, "#work-item-tabs-#{@shape}[aria-current=page]")
      assert [row] = fold_rows(view)

      assert row =~
               ~r/^Attempt 2 \(Run \d+\) · shape-a-ticket · round 1 · ended without a verdict · \S/

      refute row =~ "passed"
    end

    test "a Shape-style stage: passed reaches the gate and its row reads passed", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_workflow_stage(scope) |> end_run!(passed())

      assert work_item.stage_state == :at_gate
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-#{@shape}[aria-current=page]")
      assert [row] = fold_rows(view)
      assert row =~ ~r/^Attempt 2 \(Run \d+\) · shape-a-ticket · round 1 · passed · \S/
    end

    test "a test work item's run with no verdict shows no stopped card", %{
      conn: conn,
      scope: scope
    } do
      save!(
        scope,
        Map.update!(Processes.current(scope.workspace).document, "stages", fn stages ->
          Enum.map(stages, fn
            %{"id" => @explore} = stage -> Map.put(stage, "outputs", [])
            stage -> stage
          end)
        end)
      )

      {:ok, work_item} = WorkItems.take_in_test(scope, "Hi! Where are you running?")
      work_item = Repo.get!(WorkItem, work_item.id) |> end_run!(nil)

      assert work_item.stage_state == :at_gate
      # With no `proposal` output, Explore's stage has a stage's tab, and the work item's
      # address leads to it.
      {:ok, view, _html} = conn |> live(page(scope, work_item.number)) |> follow_redirect(conn)
      refute has_element?(view, "#work-item-needs")
    end

    test "a Shape-style run that wrote passed and was lost: the card, and no passed row", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_workflow_stage(scope)
      {_registered, run} = registered!(work_item, newest_run(work_item), :handed_over)

      {:ok, _version} =
        Stages.Artifacts.push_json(
          {:run, run},
          work_item,
          "verdict",
          %{"verdict" => "passed"},
          stage_id: run.stage_id
        )

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
          set: [state: :ended, end_cause: :lost]
        )

      {:ok, _told} = Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)

      assert %Escalation{cause: :run_stopped} = escalation(work_item)
      assert [:no_verdict, :passed] = shows(scope, work_item)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert line(view, "#work-item-needs-point-1") ==
               "The run stopped: Qory Apiary got no report from it and marked it lost. Run another round."

      assert has_element?(view, "#work-item-tabs-#{@shape}[aria-current=page]")
      assert [row] = fold_rows(view)

      assert row =~
               ~r/^Attempt 2 \(Run \d+\) · shape-a-ticket · round 1 · ended without a verdict · \S/

      refute row =~ "passed"
    end

    test "an escalation beside a proposal: no Confirm for any reader, until Accept as it is", %{
      conn: conn,
      scope: scope
    } do
      work_item = mockup_missing!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      for {:ok, view, _html} <- [
            {:ok, view, nil},
            live(as(conn, scope, :member), page(scope, work_item.number))
          ] do
        refute has_element?(view, "#work-item-step")
        refute has_element?(view, "[phx-click=confirm]")
        refute render(view) =~ "You approve next"
      end

      assert has_element?(view, "#work-item-stage-escalation-accept")

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "accept"})

      assert %WorkItem{stage_state: :at_gate} = Repo.get!(WorkItem, work_item.id)
      assert render(view) =~ "You approve next"

      view |> element("[phx-click=confirm]") |> render_click()
      assert %WorkItem{stage_id: @shape} = Repo.get!(WorkItem, work_item.id)
    end

    test "the Thread beside an escalation has no next confirmer, until Accept as it is", %{
      conn: conn,
      scope: scope
    } do
      work_item = mockup_missing!(scope)
      thread = page(scope, work_item.number) <> "/thread"

      {:ok, _view, html} = live(conn, thread)
      assert html =~ "Explore wrote a proposal"
      refute html =~ "You approve next"

      {:ok, _work_item} =
        Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @explore)

      {:ok, _view, html} = live(conn, thread)
      assert html =~ "You approve next"
    end

    test "a page opened before the stop: Confirm writes nothing, and the page shows the card", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, "[phx-click=confirm]")

      # The stage stops with no message to the open page.
      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_state: :escalated]
        )

      escalate!(
        work_item,
        :run_stopped,
        "The run stopped before its verdict.",
        newest_run(work_item)
      )

      view |> element("[phx-click=confirm]") |> render_click()

      assert %WorkItem{stage_state: :escalated, stage_id: @explore} =
               Repo.get!(WorkItem, work_item.id)

      refute Repo.get_by(Confirmation, work_item_id: work_item.id)
      refute has_element?(view, "[phx-click=confirm]")
      refute has_element?(view, "#work-item-step")
      assert has_element?(view, "#work-item-stage-waits", "Waits for you: 1 point")

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert line(view, "#work-item-needs-point-1") ==
               "The run stopped before its verdict. Run another round."
    end

    test "a stopped card: Run another round, then a proposal, reaches Confirm and the next stage",
         %{
           conn: conn,
           scope: scope
         } do
      work_item = scope |> taken_in_fixture() |> end_run!(nil)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "another_round"})

      confirm_spend(view)

      assert %WorkItem{stage_state: :running} = Repo.get!(WorkItem, work_item.id)
      assert %DispatchRun{attempt: 2} = newest_run(work_item)

      work_item = Repo.get!(WorkItem, work_item.id) |> end_run!(understood_result())
      assert work_item.stage_state == :at_gate

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert render(view) =~ "You approve next"
      view |> element("[phx-click=confirm]") |> render_click()
      assert %WorkItem{stage_id: @shape} = Repo.get!(WorkItem, work_item.id)
    end

    test "a run that asked and gave no verdict reads questions, answered or not", %{scope: scope} do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(&push_output!(&1, &2, questions_result()))

      assert work_item.stage_state == :waiting_answers
      assert [:questions] = shows(scope, work_item)

      {:ok, _} = WorkItems.answer(scope, work_item, 1, open_answers(work_item))
      assert [:queued, :questions] = shows(scope, Repo.get!(WorkItem, work_item.id))
    end

    test "a run with no proposal and no verdict shows the stopped block, not its step line", %{
      conn: conn,
      scope: scope
    } do
      work_item = scope |> taken_in_fixture() |> end_run!(nil)

      assert %Escalation{cause: :run_stopped, points: [@no_verdict]} = escalation(work_item)
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      # The step card is hidden while the stage is escalated; the block says what happened.
      refute has_element?(view, "#work-item-step-line")

      assert line(view, "#work-item-needs-point-1") ==
               "The run stopped before its verdict. Run another round."

      refute has_element?(view, "#work-item-stage-escalation-accept")
      assert has_element?(view, "#work-item-stage-escalation-another")
      assert [:no_verdict] = shows(scope, work_item)
    end

    test "a stage with no outputs: Accept after no verdict, none after a run that failed", %{
      conn: conn,
      scope: scope
    } do
      document =
        Map.update!(Processes.current(scope.workspace).document, "stages", fn stages ->
          Enum.map(stages, fn
            %{"id" => @explore} = stage -> Map.put(stage, "outputs", [])
            stage -> stage
          end)
        end)

      save!(scope, document)

      no_verdict = scope |> taken_in_fixture() |> end_run!(nil)
      assert %Escalation{cause: :run_stopped, points: [@no_verdict]} = escalation(no_verdict)
      {:ok, view, _html} = live(conn, page(scope, no_verdict.number))
      assert has_element?(view, "#work-item-stage-escalation-accept")

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "accept"})

      assert Repo.get!(WorkItem, no_verdict.id).stage_state == :at_gate

      failed =
        scope
        |> taken_in_fixture()
        |> end_run!(nil, %{exit_state: "failed", outcome_state: "failed"})

      assert %Escalation{cause: :run_stopped} = escalation(failed)
      {:ok, view, _html} = live(conn, page(scope, failed.number))
      refute has_element?(view, "#work-item-stage-escalation-accept")
      assert has_element?(view, "#work-item-stage-escalation-another")
    end

    test "a stage with no outputs, escalated by the migration: Run another round only", %{
      conn: conn,
      scope: scope
    } do
      document =
        Map.update!(Processes.current(scope.workspace).document, "stages", fn stages ->
          Enum.map(stages, fn
            %{"id" => @explore} = stage -> Map.put(stage, "outputs", [])
            stage -> stage
          end)
        end)

      save!(scope, document)
      work_item = scope |> taken_in_fixture() |> end_run!(nil)

      # As the migration placed it: no escalation row, and a run with no stage.
      Repo.update_all(from(r in DispatchRun, where: r.work_item_id == ^work_item.id),
        set: [stage_id: nil, round: nil, stage_entry: nil, workflow: nil]
      )

      Repo.delete_all(from e in Escalation, where: e.work_item_id == ^work_item.id)

      assert %{escalation: %{cause: :run_stopped, points: [no_verdict]}} =
               Stages.status(work_item)

      assert no_verdict["text"] == "The run stopped before its verdict."

      # Explore's stage has no stage's tab: the runs have no stage, so the work item's
      # address opens on the Explore tab.
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, "#work-item-tabs-explore[aria-current=page]")
      assert has_element?(view, "#work-item-needs")

      assert line(view, "#work-item-needs-point-1") ==
               "The run stopped before its verdict. Run another round."

      assert has_element?(view, "#work-item-stage-waits", "Waits for you: 1 point")
      refute has_element?(view, "#work-item-explore-none")
      refute has_element?(view, "#work-item-stage-escalation-accept")
      assert has_element?(view, "#work-item-stage-escalation-another")
    end

    test "no result: no Accept as it is, and a sent accept is refused", %{
      conn: conn,
      scope: scope
    } do
      stopped = scope |> taken_in_fixture() |> end_run!(nil)

      # Every output of the stage is missing: the agent escalated with nothing made.
      empty = at_build(scope, :escalated, round: 3)
      escalate!(empty, :escalate, "Blocked")

      for {work_item, stage} <- [{stopped, @explore}, {empty, @build}] do
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        refute has_element?(view, "#work-item-stage-escalation-accept")
        assert has_element?(view, "#work-item-stage-escalation-another")

        render_hook(view, "stage_resolve", %{
          "number" => "#{work_item.number}",
          "seen" => stage,
          "how" => "accept",
          "note" => ""
        })

        assert %Escalation{resolution: nil} = escalation(work_item)
        assert Repo.get!(WorkItem, work_item.id).stage_state == :escalated
      end
    end

    test "the round limit at Explore's last run: Run another round queues one more run", %{
      conn: conn,
      scope: scope
    } do
      # Explore's loop of 3 rounds, each run with no result.
      explore_loop!(scope)

      work_item =
        Enum.reduce(1..3, taken_in_fixture(scope), fn _attempt, work_item ->
          end_run!(work_item, nil)
        end)

      assert %Escalation{cause: :round_limit} = escalation(work_item)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      # The step card's "the last run of this take in" is false while Run another round is
      # on the escalation card: the step card is not shown.
      assert has_element?(view, "#work-item-stage-escalation-another")
      refute has_element?(view, "#work-item-stage-escalation-accept")
      refute has_element?(view, "#work-item-step")
      refute render(view) =~ "the last run of this take in."

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "another_round"})

      confirm_spend(view)

      assert %DispatchRun{attempt: 4, of: 4} = newest_run(work_item)

      # The round past the limit is the last before the stage escalates again: the count
      # is never under the attempt.
      assert has_element?(view, "#work-item-step-run", "Attempt 4 is queued.")
      refute render(view) =~ "4 of 3"
    end

    test "a move back to a later stage, or an action it does not know, is refused", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_build(scope, :escalated, round: 3)
      escalate!(work_item, :escalate, "Blocked")
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      n = "#{work_item.number}"

      render_hook(view, "stage_resolve", %{
        "number" => n,
        "seen" => @build,
        "how" => "move_back",
        "stage" => @release
      })

      assert has_element?(
               view,
               "#work-item-stage-notice",
               "Choose a stage before Build to move back to."
             )

      render_hook(view, "stage_resolve", %{"number" => n, "seen" => @build, "how" => "delete"})
      assert %Escalation{resolution: nil} = escalation(work_item)
    end
  end

  describe "a work item that ended" do
    test "close: no stage card, and the track and the head's words stay", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_build(scope, :escalated, round: 3)
      escalate!(work_item, :escalate, "Blocked")
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "close"})

      for view <- [view, elem(live(conn, page(scope, work_item.number)), 1)] do
        html = render(view)
        refute has_element?(view, "#work-item-stage")
        refute has_element?(view, "#work-item-stage-escalation-note")
        refute html =~ "Waits for a person"
        refute html =~ "Accept as it is"
        assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
        refute has_element?(view, "#work-item-head-stages-#{@build}.q-wi-stage-wait")
        assert has_element?(view, "#work-item-head-meta", "Closed by you")
        refute has_element?(view, "#work-item-head-stage-status")
      end
    end
  end

  describe "the head's status" do
    setup :ready_pool

    for {state, words} <- [
          {:running, "Build · Running"},
          {:waiting_inputs, "Build · Waits for inputs"},
          {:waiting_answers, "Build · Needs answers"},
          {:waiting_workflow, "Build · Waits for a workflow"},
          {:escalated, "Build · Waits for a person"},
          {:at_gate, "Build · At the gate"},
          {:done, "Build · Done"}
        ] do
      test "at Build, #{state}: the stage and its state", %{conn: conn, scope: scope} do
        work_item = at_build(scope, unquote(state))
        {:ok, view, _html} = live(conn, page(scope, work_item.number))
        assert has_element?(view, "#work-item-head-stage-status", unquote(words))
      end
    end

    test "past Explore, a run waiting for a machine: the stage and Queued", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope
        |> taken_in_fixture()
        |> place!(Processes.current(scope.workspace), @build, :running)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-head-stage-status", "Build · Queued")
      assert has_element?(view, "#work-item-stage-state", "Queued")
      refute has_element?(view, "#work-item-stage-line")
    end

    test "after Approve at Shape, it follows the stage", %{conn: conn, scope: scope} do
      save!(scope, document("members"))
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, "#work-item-head-stage-status", "Shape · At the gate")

      view |> form("#work-item-stage-gate-approve") |> render_submit()

      assert has_element?(view, "#work-item-head-stage-status", "Build · ")
      refute render(view) =~ "Ready for Shape"
    end

    test "at Explore, Explore's words while a run, its questions or its gate are on", %{
      conn: conn,
      scope: scope
    } do
      for {work_item, words} <- [
            {taken_in_fixture(scope), "Explore is queued"},
            {scope |> taken_in_fixture() |> end_run!(questions_result()), "Needs answers"},
            {explore_gate_fixture(scope), "You approve next"}
          ] do
        {:ok, view, _html} = live(conn, page(scope, work_item.number))
        assert has_element?(view, "#work-item-head-meta", words)
        refute has_element?(view, "#work-item-head-stage-status")
      end
    end

    test "at Explore, escalated: the stage and its state", %{conn: conn, scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(nil)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-head-stage-status",
               "Explore · Waits for a person"
             )
    end
  end

  describe "an action on a stage the work item left" do
    test "Approve does nothing and says where the work item moved", %{conn: conn, scope: scope} do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      place!(work_item, Processes.version_for(work_item), @build, :at_gate)
      view |> form("#work-item-stage-gate-approve") |> render_submit()

      assert work_item |> decisions(:approve) |> Enum.all?(&(&1.stage_id == @explore))
      assert Repo.get!(WorkItem, work_item.id).stage_id == @build

      assert has_element?(
               view,
               "#work-item-stage-notice",
               "Check the new stage and act again. The work item moved from Shape to Build before your click."
             )
    end

    test "a stale Move back does nothing", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :waiting_inputs)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      place!(work_item, Processes.version_for(work_item), @shape, :running)

      view
      |> form("#work-item-stage-move", %{"stage" => @explore, "note" => "Plan again"})
      |> render_submit()

      assert decisions(work_item, :move) == []
      assert Repo.get!(WorkItem, work_item.id).stage_id == @shape

      assert has_element?(
               view,
               "#work-item-stage-notice",
               "The work item moved from Build to Shape before your click."
             )
    end

    test "an open Request changes form closes when the stage changes", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      view |> element("#work-item-stage-gate-ask-changes") |> render_click()

      place!(work_item, Processes.version_for(work_item), @build, :running)

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        Stages.topic(work_item),
        {:stage_changed, work_item.public_id}
      )

      assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
      refute has_element?(view, "#work-item-stage-gate-changes")
    end
  end

  describe "a refused action" do
    defp notice(view), do: view |> element("#work-item-stage-notice") |> render()

    defp hook(view, work_item, event, params),
      do: render_hook(view, event, Map.merge(%{"number" => "#{work_item.number}"}, params))

    test "Approve while the stage runs: the stage changed", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :running)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      hook(view, work_item, "stage_approve", %{"seen" => @build, "note" => ""})
      assert decisions(work_item, :approve) == []
      assert notice(view) =~ "Check the stage and act again. Build changed before your click."
    end

    test "an escalation action with no escalation: the stage changed", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_build(scope, :at_gate)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      hook(view, work_item, "stage_resolve", %{"seen" => @build, "how" => "accept", "note" => ""})
      assert notice(view) =~ "Check the stage and act again. Build changed before your click."
    end

    test "a person the stage does not list", %{conn: conn, scope: scope} do
      listed = member_fixture(scope, :member)
      work_item = at_build(scope, :at_gate, approvers: %{"members" => [listed.user.id]})
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      hook(view, work_item, "stage_approve", %{"seen" => @build, "note" => ""})
      assert decisions(work_item, :approve) == []
      assert notice(view) =~ "Ask an approver of Build to act on it."
    end

    test "a stage the version does not have", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :waiting_inputs)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      hook(view, work_item, "stage_move", %{
        "seen" => @build,
        "stage" => "st_unknown000",
        "note" => ""
      })

      assert notice(view) =~
               "Choose a stage from the list. The stage you sent is not in the work item&#39;s process version."
    end

    test "a work item closed before the click", %{conn: conn, scope: scope} do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [state: :closed, closed_at: DateTime.utc_now()]
      )

      hook(view, work_item, "stage_approve", %{"seen" => @shape, "note" => ""})

      assert work_item |> decisions(:approve) |> Enum.all?(&(&1.stage_id == @explore))
      refute has_element?(view, "#work-item-stage")
    end

    test "a note over 4,000 characters", %{conn: conn, scope: scope} do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      hook(view, work_item, "stage_request_changes", %{
        "seen" => @shape,
        "note" => String.duplicate("a", 4001)
      })

      assert decisions(work_item, :request_changes) == []
      assert notice(view) =~ "Shorten the note to 4,000 characters or fewer."
    end

    test "a work item no longer in the workspace", %{conn: conn, scope: scope} do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      other = workspace_fixture(scope.organisation, "Platform")

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [workspace_id: other.id]
      )

      hook(view, work_item, "stage_approve", %{"seen" => @shape, "note" => ""})
      assert_redirect(view)
    end
  end

  describe "an escalation's points" do
    test "a numbered sentence each, escaped", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :escalated, round: 3)

      escalate!(work_item, :escalate, [
        "The build of the environment failed.",
        "An instance admin fixes the <b>image</b>."
      ])

      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-needs-point-1",
               "The build of the environment failed. Run another round."
             )

      assert has_element?(
               view,
               "#work-item-needs-point-2",
               "An instance admin fixes the <b>image</b>. Run another round."
             )

      refute html =~ "<b>image</b>"
    end

    test "a stopped run's fix line takes the place of Run another round", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_build(scope, :escalated, round: 3)

      escalate!(work_item, :run_stopped, [
        %{
          "text" => "The run stopped: the gateway had no model key for the run.",
          "action" => "run_again",
          "fix" => "Add a model key in Organisation settings › Model providers."
        }
      ])

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert line(view, "#work-item-needs-point-1") ==
               "The run stopped: the gateway had no model key for the run. Add a model key in Organisation settings › Model providers."
    end
  end

  describe "an escalation with no points" do
    # As an escalation open when points replaced gaps reads: the points the stage runner
    # writes for its cause, from what the stage reads now.
    # A round limit past the sequence's end is at round 2 of the loop's 3, so the shown
    # limit is the loop's, not the round.
    for {cause, at, points} <- [
          round_limit: {[round: 2, entry: 2], ["2 of 3 rounds ran.", @no_demo, @no_explainer]},
          check_failed: {[round: 3], [@no_demo, @no_explainer]},
          run_stopped: {[round: 3], ["The run stopped before its verdict."]}
        ] do
      test "#{cause}: the block with the runner's points, and the side line", %{
        conn: conn,
        scope: scope
      } do
        work_item = at_build(scope, :escalated, unquote(at))
        escalate!(work_item, unquote(cause), nil)
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        assert texts(view, "#work-item-needs-points li") ==
                 Enum.map(unquote(points), &(&1 <> " Run another round."))

        assert has_element?(
                 view,
                 ~s|#work-item-stage-waits a[href="#work-item-needs"]|,
                 case length(unquote(points)) do
                   1 -> "Waits for you: 1 point"
                   n -> "Waits for you: #{n} points"
                 end
               )

        assert has_element?(view, "#work-item-needs #work-item-stage-escalation-another")
      end
    end

    test "round_limit in the loop: the round point alone, with an output missing", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_build(scope, :escalated, round: 3, entry: 1, loop_entry: 1)
      escalate!(work_item, :round_limit, nil)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert %{missing_outputs: [_ | _]} = Stages.status(work_item)

      assert texts(view, "#work-item-needs-points li") == [
               "3 of 3 rounds ran. Run another round."
             ]

      assert has_element?(view, "#work-item-stage-waits", "Waits for you: 1 point")
    end

    test "check_failed with every output stored since: the block with no list", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_build(scope, :escalated, round: 3)

      for type <- ["demo-video", "explainer"],
          do: push!({:person, scope}, work_item, type, @build)

      escalate!(work_item, :check_failed, nil)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-needs #work-item-stage-escalation-another")
      refute has_element?(view, "#work-item-needs-points")
      refute has_element?(view, "#work-item-stage-waits")
    end

    # The stage runner reads a verdict that a run outside Explore pushed before it reads
    # whether its registered run failed (`Apiary.Stages.reported_result/2`), so a
    # `run_stopped` of such a run is one of no verdict (a value the runner does not know).
    test "run_stopped from a run outside Explore that pushed a verdict, then failed: no verdict",
         %{conn: conn, scope: scope} do
      work_item =
        scope
        |> taken_in_fixture()
        |> place!(save!(scope, document("members")), @build, :escalated,
          stage_round: 1,
          stage_entry: 0
        )

      {run, dispatch_run} =
        registered!(work_item, stage_run!(work_item, @build), :handed_over)

      verdict = %{"verdict" => "passed"}

      {:ok, _version} =
        Stages.Artifacts.push_json({:run, dispatch_run}, work_item, "verdict", verdict,
          stage_id: @build
        )

      run |> Ecto.Changeset.change(exit_state: "failed") |> Repo.update!()

      dispatch_run =
        dispatch_run
        |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended, explore: false)
        |> Repo.update!()

      escalate!(work_item, :run_stopped, nil, dispatch_run)

      assert %{escalation: %{points: [@no_verdict], no_verdict: true}} =
               Stages.status(work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert texts(view, "#work-item-needs-points li") == [
               "The run stopped before its verdict. Run another round."
             ]
    end

    # A run that ended before its record kept whether it is a run of Explore reads it from
    # its step and workflow (`Stages.explore_run?/1`).
    test "run_stopped from a run with no explore kept that pushed a verdict, then failed: no verdict",
         %{conn: conn, scope: scope} do
      work_item =
        scope
        |> taken_in_fixture()
        |> place!(save!(scope, document("members")), @build, :escalated,
          stage_round: 1,
          stage_entry: 0
        )

      {run, dispatch_run} =
        registered!(work_item, stage_run!(work_item, @build), :handed_over)

      {:ok, _version} =
        Stages.Artifacts.push_json(
          {:run, dispatch_run},
          work_item,
          "verdict",
          %{"verdict" => "passed"},
          stage_id: @build
        )

      run |> Ecto.Changeset.change(exit_state: "failed") |> Repo.update!()

      dispatch_run =
        dispatch_run
        |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended, explore: nil)
        |> Repo.update!()

      escalate!(work_item, :run_stopped, nil, dispatch_run)

      assert %{escalation: %{points: [@no_verdict], no_verdict: true}} =
               Stages.status(work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert texts(view, "#work-item-needs-points li") == [
               "The run stopped before its verdict. Run another round."
             ]
    end

    test "run_stopped from an Explore run with no explore kept that failed after its proposal",
         %{conn: conn, scope: scope} do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(understood_result(), %{exit_state: "failed", outcome_state: "failed"})

      {1, _rows} =
        Repo.update_all(from(e in Escalation, where: e.work_item_id == ^work_item.id),
          set: [points: []]
        )

      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^newest_run(work_item).id),
          set: [explore: nil]
        )

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert line(view, "#work-item-needs-point-1") ==
               "The run stopped: it failed after it wrote proposal version 1. Run another round."
    end

    test "placed run_stopped whose newest run has no end: no verdict", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope
        |> taken_in_fixture()
        |> place!(save!(scope, document("members")), @build, :escalated,
          stage_round: 1,
          stage_entry: 0
        )

      assert %DispatchRun{end_cause: nil} = newest_run(work_item)
      assert Repo.all(from e in Escalation, where: e.work_item_id == ^work_item.id) == []

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert texts(view, "#work-item-needs-points li") == [
               "The run stopped before its verdict. Run another round."
             ]
    end

    test "run_stopped from a run that stopped: its stop cause, in place of the banner", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(nil, %{exit_state: "failed", outcome_state: "failed"})

      {1, _rows} =
        Repo.update_all(from(e in Escalation, where: e.work_item_id == ^work_item.id),
          set: [points: []]
        )

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert line(view, "#work-item-needs-point-1") ==
               "The run stopped: it ended without a result. Run another round."

      assert has_element?(view, "#work-item-stage-waits", "Waits for you: 1 point")
      refute has_element?(view, "#work-item-explore-none")
    end

    test "escalate: the block with no list, and no side line", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :escalated, round: 3)
      escalate!(work_item, :escalate, nil)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-needs #work-item-stage-escalation-another")
      refute has_element?(view, "#work-item-needs-points")
      refute has_element?(view, "#work-item-stage-waits")
    end
  end

  describe "an escalation whose fix is on the set-up step Harness" do
    # A work item escalated at Explore because its run's harness did not resolve, with the
    # walk's `failure` (nil for none) and the fix line `fix` of its point.
    defp harness_escalated!(scope, failure, fix) do
      work_item = taken_in_fixture(scope)
      run = newest_run(work_item)

      run =
        run
        |> Ecto.Changeset.change(
          state: :ended,
          end_cause: :harness_unresolved,
          result_outcome: :error
        )
        |> Repo.update!()

      if failure do
        Repo.delete_all(
          from h in Apiary.Harnesses.RunHarness, where: h.dispatch_run_id == ^run.id
        )

        Repo.insert!(%Apiary.Harnesses.RunHarness{
          dispatch_run_id: run.id,
          state: :failed,
          failure: failure
        })
      end

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [stage_state: :escalated]
      )

      work_item = Repo.get!(WorkItem, work_item.id)

      escalate!(
        work_item,
        :run_stopped,
        [
          %{
            "text" => "The run stopped: its harness did not resolve.",
            "action" => "run_again",
            "fix" => fix
          }
        ],
        run
      )

      work_item
    end

    defp harness(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/set-up/harness"

    test "links the words in the fix line, and escapes the rest", %{conn: conn, scope: scope} do
      work_item =
        harness_escalated!(
          scope,
          "no_harness",
          "Owners and admins of <b>Main</b> choose a harness on the set-up step Harness."
        )

      {:ok, view, html} = live(conn, page(scope, work_item.number) <> "/explore")
      point = "#work-item-needs-point-1"

      assert has_element?(
               view,
               ~s|#{point} a[href="#{harness(scope)}"]|,
               "the set-up step Harness"
             )

      assert has_element?(view, point, "Owners and admins of <b>Main</b> choose a harness on")
      refute has_element?(view, point, "Run another round.")
      refute html =~ "<b>Main</b>"
    end

    test "a fix line without the words shows as it is", %{conn: conn, scope: scope} do
      work_item = harness_escalated!(scope, "no_harness", "Owners and admins choose a harness.")
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert line(view, "#work-item-needs-point-1") ==
               "The run stopped: its harness did not resolve. Owners and admins choose a harness."

      refute has_element?(view, "#work-item-needs-points a")
    end

    test "no link where the fix is not on that step", %{conn: conn, scope: scope} do
      work_item =
        harness_escalated!(
          scope,
          nil,
          "Owners and admins choose a harness on the set-up step Harness."
        )

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert has_element?(view, "#work-item-needs-point-1", "on the set-up step Harness.")
      refute has_element?(view, "#work-item-needs-points a")
    end
  end

  describe "notes" do
    test "a request for changes and a failed check, for the next run", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)

      {:ok, _work_item} =
        Stages.request_changes(scope, work_item, "Split the plan in two", nil,
          expect_stage: @shape
        )

      Repo.insert!(%Apiary.Stages.Check{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        process_version_id: work_item.process_version_id,
        stage_id: @shape,
        round: 1,
        gaps: "The plan has no test step.",
        inserted_at: DateTime.utc_now()
      })

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-notes-h", "Notes for the next run")
      assert has_element?(view, "#work-item-notes-0", "Changes requested · Shape")
      assert has_element?(view, "#work-item-notes-0", "Split the plan in two")
      assert has_element?(view, "#work-item-notes-1", "Failed check · Shape")
      assert has_element?(view, "#work-item-notes-1", "The plan has no test step.")
    end

    test "a review comment on the proposal is a card at Explore, for the next run", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)

      {:ok, _} =
        WorkItems.review_comment(
          scope,
          work_item,
          1,
          "Also check the total after a basket change."
        )

      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      # At Explore the review comment is a card in the right column, not a stage note.
      refute has_element?(view, "#work-item-notes-0")

      assert has_element?(
               view,
               "#work-item-review-c1",
               "Also check the total after a basket change."
             )

      assert has_element?(
               view,
               "#work-item-review-c1-reading",
               "Attempt 2 reads this comment."
             )
    end

    test "a request for changes at Explore shows above the tabs, without runs or artifacts", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)

      {:ok, _} =
        WorkItems.review_comment(scope, work_item, 1, "Also check the total.")

      {:ok, _work_item} =
        Stages.request_changes(scope, work_item, "Change the credit note PDF too.", nil,
          expect_stage: @explore
        )

      {:ok, view, html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert has_element?(view, "#work-item-notes-h", "Notes for the next run")
      assert texts(view, "#work-item-notes li > p:first-child") == ["Changes requested · Explore"]
      assert has_element?(view, "#work-item-notes-0", "Change the credit note PDF too.")

      # Only the gate's note: the review comment is a card, and the runs and the
      # artifacts are in the history fold.
      refute has_element?(view, "#work-item-flow #work-item-runs")
      refute has_element?(view, "#work-item-flow #work-item-artifacts")

      [before_tabs, _after] = String.split(html, ~s(id="work-item-tabs"), parts: 2)
      assert before_tabs =~ ~s(id="work-item-flow")
    end

    test "a move, a resolved escalation and a failed check at Explore show above the tabs; an answer does not",
         %{conn: conn, scope: scope} do
      work_item = taken_in_fixture(scope)
      work_item = end_run!(work_item, questions_result(["Which refund?"]))
      {:ok, work_item} = WorkItems.answer(scope, work_item, 1, %{"1" => "The full one."})
      at = fn seconds -> DateTime.add(DateTime.utc_now(), seconds, :second) end

      rows = %{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        process_version_id: work_item.process_version_id,
        stage_id: @explore
      }

      Repo.insert!(
        struct(
          GateDecision,
          Map.merge(rows, %{
            kind: :move,
            user_id: scope.user.id,
            note: "Back to Explore: name the refund rule.",
            inserted_at: at.(1)
          })
        )
      )

      Repo.insert!(
        struct(
          Escalation,
          Map.merge(rows, %{
            round: 1,
            cause: :round_limit,
            resolution: :another_round,
            note: "One more round for the refund rule.",
            resolved_by_id: scope.user.id,
            resolved_at: at.(2),
            inserted_at: at.(2)
          })
        )
      )

      Repo.insert!(
        struct(
          Apiary.Stages.Check,
          Map.merge(rows, %{round: 1, gaps: "No proposal was stored.", inserted_at: at.(3)})
        )
      )

      {:ok, view, html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert texts(view, "#work-item-notes li > p:first-child") == [
               "Moved · Explore",
               "Escalation resolved · Explore",
               "Failed check · Explore"
             ]

      assert has_element?(view, "#work-item-notes", "Back to Explore: name the refund rule.")
      assert has_element?(view, "#work-item-notes", "One more round for the refund rule.")
      assert has_element?(view, "#work-item-notes", "No proposal was stored.")
      refute has_element?(view, "#work-item-notes", "The full one.")

      [before_tabs, _after] = String.split(html, ~s(id="work-item-tabs"), parts: 2)
      assert before_tabs =~ ~s(id="work-item-flow")
    end

    test "at Explore without a note of a gate, an escalation or a check, no block", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Also check the total.")

      {:ok, view, html} = live(conn, page(scope, work_item.number) <> "/explore")

      refute has_element?(view, "#work-item-flow")
      assert has_element?(view, "#work-item-explore-proposal")

      [before_tabs, _after] = String.split(html, ~s(id="work-item-tabs"), parts: 2)
      refute before_tabs =~ ~s(id="work-item-explore-proposal")
    end

    test "a move with no note has no note line", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :waiting_inputs)
      {:ok, _work_item} = Stages.move(scope, work_item, @shape, nil, expect_stage: @build)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-notes-0", "Moved · Build")
      refute has_element?(view, "#work-item-notes-0 p.whitespace-pre-line")
    end
  end

  describe "done" do
    test "every stage done", %{conn: conn, scope: scope} do
      work_item = backfilled!(scope, @release, :done)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-head-stages-#{@release}.q-wi-stage-done")
      assert has_element?(view, "#work-item-stage-line", "Every stage is done.")
    end
  end

  describe "live" do
    test "the page is read again on the work item's stage and artifact topics", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      refute has_element?(view, "#work-item-marks-proposal-main-m")

      push!({:person, scope}, work_item, "proposal", @explore)
      assert has_element?(view, "#work-item-marks-proposal-main-m", "Approved v1; v2 is newer")

      {1, _} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_id: @build, stage_state: :running]
        )

      topic = Stages.topic(work_item)
      Phoenix.PubSub.broadcast(Apiary.PubSub, topic, {:stage_changed, work_item.public_id})
      assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
    end

    test "a message the pages do not know leaves them as they are", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)
      {:ok, show, _html} = live(conn, page(scope, work_item.number))
      {:ok, index, _html} = live(conn, list(scope))

      send(show.pid, {:something_else, work_item.public_id})
      send(index.pid, {:something_else, work_item.public_id})

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        Apiary.WorkItems.topic(work_item.workspace_id),
        :other
      )

      assert has_element?(show, "#work-item-stage-state", "At the gate")
      assert has_element?(index, "#work-item-#{work_item.public_id}")
    end

    test "the page is read again after an approval in another session", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, ~s|#work-item-head-stages-#{@shape}[aria-current="step"]|)

      {:ok, _work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
    end
  end

  describe "the record block at a stage after Explore" do
    @tabs ["/ticket", "/explore", "/thread"]
    @foot_tabs ["/ticket", "/thread"]

    # A work item at Shape's gate, on a version whose Shape has the outputs `outputs`, with
    # Explore's run and one ended run of Shape.
    defp shape_with_run!(scope, outputs \\ ["acceptance-criteria", "explainer"]) do
      work_item = shape_gate_on!(scope, outputs)
      {run, _dispatch_run} = ended_run!(work_item, @shape, "completed")
      {work_item, run}
    end

    defp shape_gate_on!(scope, outputs) do
      default = Processes.default_document("software")

      stages =
        for stage <- default["stages"] do
          if stage["id"] == @shape do
            %{stage | "outputs" => Enum.map(outputs, &%{"type" => &1, "required" => false})}
          else
            stage
          end
        end

      version = save!(scope, %{default | "stages" => stages})

      scope
      |> shape_gate_fixture()
      |> place!(version, @shape, :at_gate, stage_round: 1, stage_entry: 1)
    end

    # A run of `stage_id`, after the work item's newest, ended in `state` 4 minutes ago.
    defp ended_run!(work_item, stage_id, state),
      do: settled_run!(work_item, stage_run!(work_item, stage_id), state)

    # `dispatch_run` registered and ended in `state` 4 minutes ago, settled with the outcome
    # `none` (`Apiary.Dispatches.Settle`).
    defp settled_run!(work_item, dispatch_run, state) do
      {run, dispatch_run} = registered!(work_item, dispatch_run, :handed_over)

      dispatch_run =
        dispatch_run
        |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended, result_outcome: :none)
        |> Repo.update!()

      run =
        run
        |> Ecto.Changeset.change(
          state: state,
          exited_at: DateTime.add(DateTime.utc_now(), -240, :second)
        )
        |> Repo.update!()

      {run, dispatch_run}
    end

    defp found(view, selector) do
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
    end

    defp summary(view), do: texts(view, "#work-item-record-fold > summary .q-xp-it")

    test "each later stage, on each tab: one block at the foot, closed, no list above the tabs, notes above the tabs",
         %{conn: conn, scope: scope} do
      later =
        for %{"id" => id} <- Processes.default_document("software")["stages"],
            id != @explore,
            do: id

      assert length(later) >= 3

      for stage_id <- later do
        work_item =
          scope
          |> shape_gate_fixture()
          |> place!(Processes.current(scope.workspace), stage_id, :at_gate, stage_round: 1)

        Repo.insert!(%GateDecision{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id,
          work_item_id: work_item.id,
          process_version_id: work_item.process_version_id,
          stage_id: stage_id,
          kind: :move,
          user_id: scope.user.id,
          note: "Back for the refund rule.",
          inserted_at: DateTime.utc_now()
        })

        for tab <- @tabs do
          {:ok, view, html} = live(conn, page(scope, work_item.number) <> tab)

          assert found(view, "#work-item-record") == 1
          assert found(view, "#work-item-record-fold") == 1
          assert found(view, "#work-item-record-fold[open]") == 0
          assert found(view, "#work-item-record-fold[phx-mounted]") == 1
          assert found(view, "#work-item-artifact-list") == 1
          refute has_element?(view, "#work-item-runs")

          if tab == "/explore",
            do: assert(found(view, "#work-item-explore > #work-item-record:last-child") == 1),
            else: assert(found(view, ".q-wi-b > #work-item-record.q-wi-foot:last-child") == 1)

          [before_tabs, after_tabs] = String.split(html, ~s(id="work-item-tabs"), parts: 2)
          assert before_tabs =~ ~s(id="work-item-notes")
          assert before_tabs =~ "Back for the refund rule."
          refute before_tabs =~ ~s(id="work-item-record")
          refute before_tabs =~ ~s(id="work-item-artifacts")
          assert after_tabs =~ ~s(id="work-item-artifacts")
          refute after_tabs =~ ~s(id="work-item-notes")
        end
      end
    end

    test "a stage with no note has no block above the tabs", %{conn: conn, scope: scope} do
      {work_item, _run} = shape_with_run!(scope)

      for tab <- @tabs do
        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> tab)
        refute has_element?(view, "#work-item-flow")
      end
    end

    test "every tab has every run and all artifacts, and the count agrees with Details", %{
      conn: conn,
      scope: scope
    } do
      {work_item, run} = shape_with_run!(scope)
      push!({:person, scope}, work_item, "acceptance-criteria", @shape)
      href = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      for tab <- @foot_tabs do
        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> tab)

        assert has_element?(view, "#work-item-record-fold summary b", "2 runs")
        assert line(view, "#work-item-details-runs") =~ "2 runs, ended"

        # Shape's run is the latest, in the words of the row.
        row = "div#work-item-record-#{run.number}.q-xp-runrow"
        assert has_element?(view, ~s(#{row} a[href="#{href}"]), "Attempt 2 (Run #{run.number})")

        assert texts(view, "#{row} .q-xp-it") == [
                 "Attempt 2 (Run #{run.number})",
                 "capture-demo",
                 "round 1",
                 "ended without a verdict",
                 "4 minutes ago"
               ]

        refute has_element?(view, row, "passed")

        # Explore's run, no longer the latest, has its fold, and its workflow, round and
        # verdict on its line.
        assert has_element?(
                 view,
                 "#work-item-record-fold .q-xp-inner > details summary a",
                 "Attempt 1"
               )

        assert [explore, _shape] = fold_rows(view)
        assert explore =~ ~r/^Attempt 1 \(Run \d+\) · explore-a-ticket · round 1 · passed · \S/

        # All artifacts, with a run's round as the list above the tabs had it.
        assert has_element?(view, "#work-item-record #work-item-artifact-list", "proposal v1")

        assert has_element?(
                 view,
                 "#work-item-record #work-item-artifact-list",
                 "acceptance-criteria v1"
               )

        assert has_element?(view, "#work-item-record #work-item-artifacts-h", "Artifacts")
      end

      # Explore's tab lists Explore's run and artifact, and Details still counts both runs.
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/stages/#{@explore}")

      assert has_element?(view, "#work-item-record-fold summary b", "1 run")
      assert line(view, "#work-item-details-runs") =~ "2 runs, ended"
      assert has_element?(view, "#work-item-record #work-item-artifact-list", "proposal v1")

      refute has_element?(
               view,
               "#work-item-record #work-item-artifact-list",
               "acceptance-criteria v1"
             )
    end

    test "Explore's tab at Shape: Explore's frames stay, and Shape's run is not listed", %{
      conn: conn,
      scope: scope
    } do
      {work_item, run} = shape_with_run!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert has_element?(view, "#work-item-explore-proposal")
      refute has_element?(view, "#work-item-explore-wait")
      refute has_element?(view, "#work-item-explore-none")
      assert found(view, ~s(#work-item-explore a[href$="/runs/#{run.number}"])) == 0
    end

    test "the summary has the current stage's output versions; one with no version has no piece",
         %{conn: conn, scope: scope} do
      {work_item, _run} = shape_with_run!(scope)

      for tab <- @foot_tabs do
        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> tab)
        assert summary(view) == ["2 runs"]
      end

      push!({:person, scope}, work_item, "explainer", @shape)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert summary(view) == ["2 runs", "explainer v1"]

      push!({:person, scope}, work_item, "acceptance-criteria", @shape)
      push!({:person, scope}, work_item, "explainer", @shape)

      for tab <- @foot_tabs do
        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> tab)
        assert summary(view) == ["2 runs", "acceptance criteria v1", "explainer v2"]
      end
    end

    test "a stage with no outputs: the count alone, and the fold has all artifacts", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = shape_with_run!(scope, [])

      for tab <- @foot_tabs do
        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> tab)
        assert summary(view) == ["2 runs"]
        assert has_element?(view, "#work-item-artifact-list", "proposal v1")
      end
    end

    test "a later stage's row: running is blue, quiet is amber, a pending row reads queued", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope
        |> taken_in_fixture()
        |> place!(Processes.current(scope.workspace), @build, :running)

      {run, _dispatch_run} = registered!(work_item, stage_run!(work_item, @build), :handed_over)
      row = "div#work-item-record-#{run.number}.q-xp-runrow"
      blue = "#{row} .text-info-soft-content"
      amber = "#{row} .text-primary-soft-content"

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, blue, "running")
      refute has_element?(view, amber)

      late = DateTime.add(DateTime.utc_now(), -3600, :second)
      run = run |> Ecto.Changeset.change(last_heartbeat_at: late) |> Repo.update!()

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, amber, "running")
      refute has_element?(view, blue)

      run |> Ecto.Changeset.change(state: "pending", started_at: nil) |> Repo.update!()

      # A row still pending reads queued, in neither colour.
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, row, "queued")
      refute has_element?(view, blue)
      refute has_element?(view, amber)
    end

    test "no runs and no artifacts: the block shows, with Add a version", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape_gate(scope, ["acceptance-criteria"])
      add = ~s(#work-item-record #work-item-artifact-list-add[href*="/artifacts/new"])

      for tab <- @foot_tabs do
        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> tab)

        assert summary(view) == ["0 runs"]
        assert found(view, "#work-item-record-fold[open]") == 0
        assert found(view, "#work-item-record .q-xp-runrow") == 0
        assert has_element?(view, "#work-item-artifact-list-empty", "No artifacts yet.")
        assert has_element?(view, add, "Add a version")
        refute has_element?(view, "#work-item-explore-wait")
        refute has_element?(view, "#work-item-explore-run")
      end
    end

    test "a reader with no run.read reads a plain attempt", %{
      conn: conn,
      scope: scope
    } do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.MembersReachNamed)
      {work_item, _run} = shape_with_run!(scope)
      there = workspace_fixture(scope.organisation, "There")

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [workspace_id: there.id]
      )

      %{user: member} = member_fixture(scope, :member)
      Apiary.EditionStubs.MembersReachNamed.put([there.id])

      {:ok, view, _html} =
        conn
        |> log_in_user(member)
        |> live(~p"/#{scope.organisation}/#{there}/work/#{work_item.number}")

      assert has_element?(
               view,
               "#work-item-record-fold .q-xp-inner > details > summary",
               "Attempt 1"
             )

      refute has_element?(view, "#work-item-record-fold .q-xp-inner > details > summary", "(Run")

      assert has_element?(view, "#work-item-record .q-xp-runrow", "Attempt 2")
      refute has_element?(view, "#work-item-record .q-xp-runrow", "(Run")

      refute has_element?(
               view,
               ~s(#work-item-record .q-xp-inner > .q-xp-runrow a[href*="/runs/"])
             )

      refute has_element?(
               view,
               ~s(#work-item-record .q-xp-inner > details > summary a[href*="/runs/"])
             )
    end

    test "a later stage's run that has no row yet reads queued, with no link", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_on!(scope, [])
      stage_run!(work_item, @shape)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert texts(view, "#work-item-record-run-2 .q-xp-it") ==
               ["Attempt 2", "capture-demo", "round 1", "queued"]

      refute has_element?(view, "#work-item-record-run-2 a")
    end

    test "a fold row's pieces are in one strip whose first separator on each line is clipped",
         %{conn: conn, scope: scope} do
      work_item = shape_gate_on!(scope, [])
      {earlier, _dispatch_run} = ended_run!(work_item, @shape, "completed")
      {_latest, _dispatch_run} = ended_run!(work_item, @shape, "completed")

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      # Every piece of the summary and of a row is in the strip, which no other element
      # shares.
      assert texts(view, "#work-item-record-fold > summary > .q-xp-parts > .q-xp-it") ==
               summary(view)

      row = "div#work-item-record-#{earlier.number}.q-xp-runrow"
      assert length(texts(view, "#{row} > .q-xp-parts > .q-xp-it")) == 5
      assert texts(view, "#{row} > .q-xp-parts > .q-xp-it") == texts(view, "#{row} .q-xp-it")
      assert found(view, "#{row} > :not(.q-xp-parts)") == 0

      css =
        File.read!(Path.expand("../../../../assets/css/app.css", __DIR__))
        |> String.replace(~r{/\*.*?\*/}s, "")

      # The strip starts one separator left of the row, and the clip hides the separator of
      # each line's first piece, but not a focus ring 4px around a piece.
      assert [_, strip] = Regex.run(~r/\n  \.q-xp-parts \{([^}]*)\}/, css)
      assert strip =~ "\n    flex-wrap: wrap;\n"
      assert strip =~ "\n    margin-left: calc(-16px - 0.202em);\n"
      assert strip =~ "\n    clip-path: inset(-6px -6px -6px calc(10px + 0.202em));\n"

      # Every piece in the strip opens with the separator, the first one too.
      assert [_, separator] = Regex.run(~r/\n  \.q-xp-parts > \.q-xp-it::before \{([^}]*)\}/, css)
      assert separator =~ ~s(\n    content: "·" / "";\n)
      assert separator =~ "\n    margin: 0 8px;\n"
    end

    test "a paused run that a run continues shows why it paused, with a link to that run",
         %{conn: conn, scope: scope} do
      {:ok, provider} =
        Apiary.Connections.create_provider(scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-ant-fixture-main-0123456789"}]
        })

      work_item = shape_gate_on!(scope, [])
      {paused, paused_run} = ended_run!(work_item, @shape, "paused")

      paused
      |> Ecto.Changeset.change(
        provider_connection_id: provider.id,
        provider_secret_id: provider.secret_id,
        provider_chain: "organisation",
        provider_api: %{
          "format" => "anthropic-messages",
          "endpoint" => "https://api.model.example/anthropic",
          "auth" => %{"scheme" => "x-api-key"}
        },
        model_keys: [],
        run_settings: %{}
      )
      |> Repo.update!()

      continuation =
        work_item
        |> stage_run!(@shape)
        |> Ecto.Changeset.change(continues_id: paused_run.id)
        |> Repo.update!()

      {next, _dispatch_run} = registered!(work_item, continuation, :handed_over)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      row = "div#work-item-record-#{paused.number}.q-xp-runrow"

      assert has_element?(
               view,
               row,
               "Paused: a key of #{provider.name} reached its limit. It continues in run #{next.number}."
             )

      href = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{next.number}"
      assert has_element?(view, ~s(#{row} a[href="#{href}"]), "#{next.number}")
      refute has_element?(view, row, "ended without a verdict")
    end

    test "a later stage's run with no verdict in each state: its state once it failed, was cancelled or lost, in a row with no fold",
         %{conn: conn, scope: scope} do
      for {state, word, unshown} <- [
            {"completed", "ended without a verdict", "Completed"},
            {"failed", "Failed", "ended without a verdict"},
            {"cancelled", "Cancelled", "ended without a verdict"},
            {"lost", "Lost", "ended without a verdict"}
          ] do
        work_item = shape_gate_on!(scope, [])
        {earlier, _dispatch_run} = ended_run!(work_item, @shape, state)
        {_latest, _dispatch_run} = ended_run!(work_item, @shape, "completed")

        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        row = "div#work-item-record-#{earlier.number}.q-xp-runrow"

        assert texts(view, "#{row} .q-xp-it") == [
                 "Attempt 2 (Run #{earlier.number})",
                 "capture-demo",
                 "round 1",
                 word,
                 "4 minutes ago"
               ]

        refute has_element?(view, row, unshown)
        refute has_element?(view, "#work-item-record-#{earlier.number}-none")
      end

      work_item = shape_gate_on!(scope, [])

      {running, _dispatch_run} =
        registered!(work_item, stage_run!(work_item, @shape), :handed_over)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert [
               "Attempt 2 (Run " <> _rest,
               "capture-demo",
               "round 1",
               "running",
               "started " <> _ago
             ] =
               texts(view, "#work-item-record-#{running.number} .q-xp-it")
    end

    test "an unread proposal's fold reads it from the Ticket tab", %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: understood_result(%{"message" => "The first take."}))

      explore_run_fixture(work_item,
        result: understood_result(%{"message" => "The second take."})
      )

      {:ok, _work_item} = WorkItems.confirm(scope, Repo.get!(WorkItem, work_item.id), 2)

      work_item =
        WorkItem
        |> Repo.get!(work_item.id)
        |> place!(Processes.current(scope.workspace), @shape, :at_gate, stage_round: 1)

      ended_run!(work_item, @shape, "completed")

      number =
        Repo.one(
          from r in Run,
            join: d in DispatchRun,
            on: r.dispatch_run_id == d.id,
            where: d.work_item_id == ^work_item.id and d.attempt == 1,
            select: r.number
        )

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/ticket")
      fold = "#work-item-record-#{number}"
      refute has_element?(view, fold, "The first take.")

      view |> element("#{fold}-s") |> render_click()
      assert has_element?(view, "#{fold}-proposal-text", "The first take.")
    end

    test "the page's live updates refresh the block with no reload", %{conn: conn, scope: scope} do
      {work_item, _run} = shape_with_run!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/ticket")

      assert summary(view) == ["2 runs"]
      refute has_element?(view, "#work-item-artifact-list", "explainer v1")

      # `{:artifact_pushed, …}`
      push!({:person, scope}, work_item, "explainer", @shape)
      assert summary(view) == ["2 runs", "explainer v1"]
      assert has_element?(view, "#work-item-artifact-list", "explainer v1")

      # `{:work_items_changed, ids}`
      stage_run!(work_item, @shape)
      send(view.pid, {:work_items_changed, [work_item.public_id]})
      assert summary(view) == ["3 runs", "explainer v1"]
      assert line(view, "#work-item-details-runs") =~ "3 runs"

      # `{:stage_changed, id}`: Build's outputs, none of which has a version.
      {1, _} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_id: @build, stage_state: :running]
        )

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        Stages.topic(work_item),
        {:stage_changed, work_item.public_id}
      )

      assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
      assert summary(view) == ["3 runs"]
      # The same element, whose `open` the page leaves as the reader set it.
      assert found(view, "#work-item-record-fold[phx-mounted]") == 1
    end

    test "a page at Explore's stage is as before: no block on the Ticket tab or the Thread", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)

      for tab <- ["/ticket", "/thread"] do
        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> tab)
        refute has_element?(view, "#work-item-record")
        refute has_element?(view, "#work-item-artifact-list")
        refute has_element?(view, "#work-item-flow")
      end

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      refute has_element?(view, "#work-item-record.q-wi-foot")
      assert summary(view) == ["1 run", "proposal v1"]
      assert has_element?(view, "#work-item-record #work-item-artifact-list", "proposal v1")
      refute has_element?(view, "#work-item-artifact-list", "round")
    end

    test "a work item moved back to Explore has the artifacts above the tabs, its runs in Explore's fold",
         %{conn: conn, scope: scope} do
      work_item = moved_back!(scope)

      for tab <- @tabs do
        {:ok, view, html} = live(conn, page(scope, work_item.number) <> tab)
        [before_tabs, _after] = String.split(html, ~s(id="work-item-tabs"), parts: 2)

        refute has_element?(view, "#work-item-runs")
        assert before_tabs =~ ~s(id="work-item-artifacts")
        refute has_element?(view, "#work-item-record.q-wi-foot")
        assert found(view, "#work-item-artifact-list") == 1
      end
    end

    test "a work item moved back to Explore from Shape's gate lists each run once, in its tab's fold",
         %{conn: conn, scope: scope} do
      work_item = scope |> at_workflow_stage() |> end_run!(passed())
      assert work_item.stage_state == :at_gate
      {:ok, _work_item} = Stages.move(scope, work_item, @explore, nil, expect_stage: @shape)
      shape = page(scope, work_item.number) <> "/stages/#{@shape}"

      for path <- Enum.map(@tabs, &(page(scope, work_item.number) <> &1)) ++ [shape] do
        {:ok, view, html} = live(conn, path)
        [before_tabs, _after] = String.split(html, ~s(id="work-item-tabs"), parts: 2)

        refute has_element?(view, "#work-item-runs")
        assert before_tabs =~ ~s(id="work-item-artifacts")
      end

      # Explore's runs, attempts 1 and 3, in Explore's fold; Shape's run in Shape's.
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert [first, third] = fold_rows(view)
      assert first =~ ~r/^Attempt 1( \(Run \d+\))? · explore-a-ticket · round 1 · passed/
      assert third =~ ~r/^Attempt 3 · explore-a-ticket · round 1 · queued/

      {:ok, view, _html} = live(conn, shape)
      assert [row] = fold_rows(view)
      assert row =~ ~r/^Attempt 2( \(Run \d+\))? · shape-a-ticket · round 1 · passed/
    end

    test "a work item moved back while a later stage's only run waits keeps the list above the tabs",
         %{conn: conn, scope: scope} do
      # Shape's run, queued, is Shape's only run, and Shape has no version of an output:
      # Shape's tab has no runs fold, so the Runs list is the one list of that run.
      work_item = at_workflow_stage(scope)
      {:ok, _work_item} = Stages.move(scope, work_item, @explore, nil, expect_stage: @shape)

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/stages/#{@shape}")
      refute has_element?(view, "#work-item-record")
      assert has_element?(view, "#work-item-runs-1", "Attempt 2 · shape-a-ticket")
      assert has_element?(view, "#work-item-runs-1", "queued")
    end

    test "a work item moved back while a later stage's only run runs: its word is blue in the list",
         %{conn: conn, scope: scope} do
      work_item = at_workflow_stage(scope)
      {_run, _dispatch_run} = registered!(work_item, newest_run(work_item), :handed_over)
      {:ok, _work_item} = Stages.move(scope, work_item, @explore, nil, expect_stage: @shape)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-runs .text-info-soft-content", "running")
    end

    test "a work item closed at Explore has the artifacts above the tabs and no block at the foot",
         %{conn: conn, scope: scope} do
      work_item = explore_gate_fixture(scope)
      {:ok, _work_item} = WorkItems.close(scope, work_item)

      for tab <- @tabs do
        {:ok, view, html} = live(conn, page(scope, work_item.number) <> tab)
        [before_tabs, _after] = String.split(html, ~s(id="work-item-tabs"), parts: 2)

        # Its one run is Explore's, in Explore's fold.
        refute has_element?(view, "#work-item-runs")
        assert before_tabs =~ ~s(id="work-item-artifacts")
        assert found(view, ".q-wi-foot") == 0
        assert found(view, "#work-item-artifact-list") == 1
      end
    end

    test "a work item closed at Shape has one block on each tab and no list above the tabs", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = shape_with_run!(scope)
      {:ok, _work_item} = WorkItems.close(scope, work_item)

      for tab <- @tabs do
        {:ok, view, _html} = live(conn, page(scope, work_item.number) <> tab)

        assert found(view, "#work-item-record") == 1
        assert found(view, "#work-item-record-fold[open]") == 0
        assert found(view, "#work-item-artifact-list") == 1
        count = if tab == "/explore", do: "1 run", else: "2 runs"
        assert has_element?(view, "#work-item-record-fold summary b", count)
        refute has_element?(view, "#work-item-runs")
        refute has_element?(view, "#work-item-flow #work-item-artifacts")

        if tab == "/explore",
          do: assert(found(view, "#work-item-explore > #work-item-record:last-child") == 1),
          else: assert(found(view, ".q-wi-b > #work-item-record.q-wi-foot:last-child") == 1)
      end
    end

    # A process of two stages, Plan and Build, neither of which runs Explore's workflow.
    defp no_explore_document do
      stage = fn id, name, workflow ->
        %{
          "id" => id,
          "name" => name,
          "inputs" => [],
          "sequence" => [%{"workflow" => workflow}],
          "outputs" => [],
          "gate" => %{"kind" => "person", "approvers" => "members"}
        }
      end

      %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "stages" => [stage.(@shape, "Plan", "implement"), stage.(@build, "Build", "capture-demo")]
      }
    end

    # At Build of that process: attempt 1 ended with no result, and attempt 2 runs.
    defp no_explore_at_build!(scope) do
      taken_in = taken_in_fixture(scope)
      version = save!(scope, no_explore_document())
      work_item = place!(taken_in, version, @build, :running, stage_round: 1, stage_entry: 1)
      assert Stages.explore_stage_id(work_item) == nil

      first =
        work_item
        |> newest_run()
        |> Ecto.Changeset.change(stage_id: @build, workflow: "capture-demo")
        |> Repo.update!()

      {failed, _dispatch_run} = settled_run!(work_item, first, "failed")

      {running, _dispatch_run} =
        registered!(work_item, stage_run!(work_item, @build), :handed_over)

      {work_item, failed, running}
    end

    test "a process with no Explore stage: each staged run has a row, with no fold", %{
      conn: conn,
      scope: scope
    } do
      {work_item, failed, running} = no_explore_at_build!(scope)

      for tab <- @foot_tabs do
        {:ok, view, html} = live(conn, page(scope, work_item.number) <> tab)

        assert has_element?(view, "#work-item-record-fold summary b", "2 runs")

        assert texts(view, "div#work-item-record-#{failed.number}.q-xp-runrow .q-xp-it") == [
                 "Attempt 1 (Run #{failed.number})",
                 "capture-demo",
                 "round 1",
                 "Failed",
                 "4 minutes ago"
               ]

        refute html =~ "The run ended without a result."

        assert ["Attempt 2 (Run " <> _rest, "capture-demo", "round 1", "running" | _time] =
                 texts(view, "div#work-item-record-#{running.number}.q-xp-runrow .q-xp-it")
      end
    end

    test "a process with no Explore stage: a live run is not Explore's on the tab or the page",
         %{conn: conn, scope: scope} do
      {work_item, _failed, _running} = no_explore_at_build!(scope)
      to = page(scope, work_item.number)

      assert {:error, {:live_redirect, %{to: ^to}}} = live(conn, to <> "/explore")

      for tab <- @foot_tabs do
        {:ok, view, html} = live(conn, page(scope, work_item.number) <> tab)

        # `explore_status/2`: no wait block of Explore.
        refute has_element?(view, "#work-item-explore-wait")
        refute has_element?(view, "#work-item-explore-run")
        refute html =~ "Explore is"
        assert has_element?(view, "#work-item-head-stage-status", "Build · Running")
      end

      # `live_heard/1`: the page does not follow the run, as at a later stage of a process
      # with Explore.
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert page_assigns(view).followed_run == nil
    end
  end

  describe "work items the migration placed" do
    test "in Explore and in Shape at its gate, on the page and the board", %{
      conn: conn,
      scope: scope
    } do
      explore = backfilled!(scope, @explore, :running)
      shape = backfilled!(scope, @shape, :at_gate)

      {:ok, view, _html} = live(conn, list(scope))
      assert has_element?(view, "#work-items-group-0-h", "Explore")
      assert has_element?(view, "#work-items-group-0 #work-item-#{explore.public_id}")
      assert has_element?(view, "#work-items-group-1-h", "Shape")
      assert has_element?(view, "#work-items-group-1 #work-item-#{shape.public_id}")

      {:ok, view, _html} = live(conn, page(scope, explore.number))
      assert has_element?(view, ~s|#work-item-head-stages-#{@explore}[aria-current="step"]|)
      assert has_element?(view, "#work-item-step-state", "Running")

      {:ok, view, _html} = live(conn, page(scope, shape.number))
      assert has_element?(view, "#work-item-head-stages-#{@explore}.q-wi-stage-done")
      assert has_element?(view, ~s|#work-item-head-stages-#{@shape}[aria-current="step"]|)
      assert has_element?(view, "#work-item-stage-state", "At the gate")
      assert has_element?(view, "#work-item-stage-gate-approve-go", "Approve Shape")
    end
  end

  describe "the board" do
    test "a box per stage of the current version, and a removed stage's", %{
      conn: conn,
      scope: scope
    } do
      default = Processes.default_document("software")
      review = %{hd(tl(default["stages"])) | "id" => @review, "name" => "Review"}
      v2 = save!(scope, %{default | "stages" => default["stages"] ++ [review]})
      v3 = save!(scope, default)

      gift =
        scope
        |> work_item_fixture(%{title: "Add gift cards to checkout"})
        |> place!(v3, @build, :running)

      basket =
        scope
        |> work_item_fixture(%{title: "Fix the basket total"})
        |> place!(v2, @review, :at_gate)

      unplaced = work_item_fixture(scope, %{title: "Show the delivery date"})

      {:ok, view, _html} = live(conn, list(scope))

      refute has_element?(view, "#work-items-stages")

      assert texts(view, "#work-items-board .q-wl-st-name") ==
               ["Explore", "Shape", "Build", "Verify", "Release", "Review"]

      assert texts(view, "#work-items-board .q-wl-st-n") == ["1", "0", "1", "0", "0", "1"]

      assert has_element?(
               view,
               "#work-items-board-5-removed",
               "From version 2. This stage is not in the current version."
             )

      # A box has no link.
      refute has_element?(view, "#work-items-board a")

      assert texts(view, ".q-wl-grp h2") == ["Explore", "Build", "Review"]
      assert has_element?(view, "#work-items-group-0 #work-item-#{unplaced.public_id}")
      assert has_element?(view, "#work-items-group-2 #work-item-#{gift.public_id}")

      assert has_element?(
               view,
               ~s|#work-items-group-5 #work-item-#{basket.public_id} a[href="#{page(scope, basket.number)}"]|
             )
    end

    test "every view shows the same boxes, and its line", %{conn: conn, scope: scope} do
      backfilled!(scope, @explore, :running)
      backfilled!(scope, @shape, :at_gate)

      for {query, note} <- [
            {"", "Work items at a stage of the process. A finished one moves to Closed."},
            {"?view=you", "Work items that wait for you to approve the proposal. Oldest first."},
            {"?view=closed",
             "Finished work items, and work items that stopped: a member closed one or undid its take in, its ticket closed, or its integration was removed. Where the ticket of a stopped one is still in the Backlog, Take in again brings it back."}
          ] do
        {:ok, view, _html} = live(conn, list(scope) <> query)

        assert texts(view, "#work-items-board .q-wl-st-name") ==
                 ["Explore", "Shape", "Build", "Verify", "Release"]

        assert texts(view, "#work-items-board .q-wl-st-n") == ["1", "1", "0", "0", "0"]
        assert texts(view, "#work-items-note") == [note]
        refute has_element?(view, "#work-items-stages")
      end
    end

    test "the Open view groups its rows by stage, with no group at 0 and no control", %{
      conn: conn,
      scope: scope
    } do
      explored = backfilled!(scope, @explore, :running)
      shaped = backfilled!(scope, @shape, :at_gate)
      {:ok, view, _html} = live(conn, list(scope))

      assert texts(view, ".q-wl-grp h2") == ["Explore", "Shape"]
      assert texts(view, ".q-wl-grp .q-band-n") == ["1", "1"]
      assert has_element?(view, "#work-items-group-0 #work-item-#{explored.public_id}")
      assert has_element?(view, "#work-items-group-1 #work-item-#{shaped.public_id}")

      refute has_element?(view, "#work-items-rows")
      refute has_element?(view, ".q-wl-grp button")
      refute has_element?(view, ".q-wl-fold")
    end

    test "a row under its group shows the state; the group shows the stage", %{
      conn: conn,
      scope: scope
    } do
      queued = taken_in_fixture(scope)
      shaped = shape_gate_fixture(scope)
      stopped = scope |> taken_in_fixture() |> end_run!(nil)

      built =
        scope
        |> shape_gate_fixture()
        |> place!(Processes.current(scope.workspace), @build, :waiting_inputs)

      row = &"#work-items-groups #work-item-#{&1.public_id} .q-wl-nx"
      {:ok, view, _html} = live(conn, list(scope))

      assert has_element?(view, row.(queued), "Explore is queued")
      assert texts(view, row.(shaped)) == ["At the gate"]
      assert texts(view, row.(stopped)) == ["Waits for a person"]
      assert texts(view, row.(built)) == ["Waits for inputs"]
    end

    test "a running row under a group has the blue dot, on the board's list", %{
      conn: conn,
      scope: scope
    } do
      at_build =
        scope
        |> taken_in_fixture()
        |> end_run!(understood_result())
        |> place!(Processes.current(scope.workspace), @build, :running)

      registered!(at_build, stage_run!(at_build, @build), :handed_over)

      {:ok, view, _html} = live(conn, list(scope))

      assert has_element?(view, "#work-items-board")
      row = "#work-items-groups #work-item-#{at_build.public_id}"
      assert has_element?(view, "#{row} .q-sdot-running > i")
      refute has_element?(view, ".q-wi-mk-run")
    end

    test "search and filters keep the groups, the boxes count what they keep", %{
      conn: conn,
      scope: scope
    } do
      gift =
        scope
        |> work_item_fixture(%{title: "Add gift cards to checkout"})
        |> place!(Processes.current(scope.workspace), @build, :running)

      work_item_fixture(scope, %{title: "Fix the basket total"})

      {:ok, view, _html} = live(conn, list(scope) <> "?q=gift")

      assert texts(view, "#work-items-board .q-wl-st-n") == ["0", "0", "1", "0", "0"]
      assert texts(view, ".q-wl-grp h2") == ["Build"]
      assert texts(view, ".q-wl-grp .q-band-n") == ["1"]
      assert has_element?(view, "#work-items-group-2 #work-item-#{gift.public_id}")
      refute has_element?(view, ".q-wl-fold")

      {:ok, view, _html} = live(conn, list(scope) <> "?q=nothing+like+it")
      assert texts(view, "#work-items-board .q-wl-st-n") == ["0", "0", "0", "0", "0"]
      refute has_element?(view, ".q-wl-grp")
    end

    test "Waiting on you and Closed stay plain rows", %{conn: conn, scope: scope} do
      closed = work_item_fixture(scope, %{title: "Fix the basket total"})
      {:ok, _closed} = WorkItems.close(scope, closed)

      {:ok, view, _html} = live(conn, list(scope) <> "?view=closed")
      assert has_element?(view, "#work-items-rows #work-item-#{closed.public_id}")
      refute has_element?(view, "#work-items-groups")

      # Escalated at Build, it waits for its owner, the reader.
      waiting =
        scope
        |> explore_gate_fixture()
        |> place!(Processes.current(scope.workspace), @build, :escalated)

      {:ok, view, _html} = live(conn, list(scope) <> "?view=you")
      refute has_element?(view, "#work-items-groups")

      # With no group above it, a row keeps its stage's name.
      assert texts(view, "#work-items-rows #work-item-#{waiting.public_id} .q-wl-nx") ==
               ["Build · Waits for a person"]
    end

    test "an address with a stage shows that stage alone, under the boxes, with no control", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      {:ok, view, _html} = live(conn, list(scope) <> "?stage=explore")

      assert has_element?(view, "#work-items-board")
      refute has_element?(view, "#work-items-stages")
      assert texts(view, ".q-wl-grp h2") == ["Explore"]
      assert has_element?(view, "#work-items-explore #work-item-#{work_item.public_id}")
      refute has_element?(view, ".q-wl-fold")
    end

    test "past a page, a group counts its whole stage and the pager stays", %{
      conn: conn,
      scope: scope
    } do
      for _n <- 1..(WorkList.page_size() + 1), do: work_item_fixture(scope)
      {:ok, view, _html} = live(conn, list(scope))

      assert texts(view, ".q-wl-grp .q-band-n") == ["#{WorkList.page_size() + 1}"]
      assert has_element?(view, "#work-items-pager")
    end

    test "a row shows a title without invisible characters, and the mark Test", %{
      conn: conn,
      scope: scope
    } do
      {:ok, line} = WorkItems.take_in_test(scope, "Hello! Where are you running?")
      basket = work_item_fixture(scope, %{title: "Basket \u202Eflow"})

      {:ok, view, html} = live(conn, list(scope))
      item = &"#work-items-group-0 #work-item-#{&1.public_id}"

      refute html =~ "\u202E"
      assert has_element?(view, item.(basket), "Basket flow")
      refute has_element?(view, item.(basket) <> " .badge")
      assert has_element?(view, item.(line) <> " .badge", "Test")
      assert has_element?(view, ~s|#{item.(line)} a[href="#{page(scope, line.number)}"]|)
    end

    test "each group in the list's sort", %{conn: conn, scope: scope} do
      older = work_item_fixture(scope, %{title: "Fix the basket total"})
      newer = work_item_fixture(scope, %{title: "Show the delivery date"})
      now = DateTime.utc_now()

      for {work_item, created, updated} <- [{older, -60, 0}, {newer, 0, -60}] do
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [inserted_at: DateTime.add(now, created), updated_at: DateTime.add(now, updated)]
        )
      end

      order = fn view ->
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#work-items-group-0 li")
        |> LazyHTML.attribute("id")
      end

      ids = &Enum.map(&1, fn work_item -> "work-item-#{work_item.public_id}" end)

      {:ok, view, _html} = live(conn, list(scope))
      assert order.(view) == ids.([older, newer])

      {:ok, view, _html} = live(conn, list(scope) <> "?sort=created")
      assert order.(view) == ids.([newer, older])
    end

    test "a message of the workspace's work items reads the board and the groups again", %{
      conn: conn,
      scope: scope
    } do
      work_item = backfilled!(scope, @explore, :running)
      {:ok, view, _html} = live(conn, list(scope))

      assert texts(view, "#work-items-board .q-wl-st-n") == ["1", "0", "0", "0", "0"]
      assert has_element?(view, "#work-items-group-0 #work-item-#{work_item.public_id}")

      place!(work_item, Processes.current(scope.workspace), @shape, :at_gate)

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        WorkItems.topic(scope.workspace.id),
        {:work_items_changed, [work_item.public_id]}
      )

      assert has_element?(view, "#work-items-group-1 #work-item-#{work_item.public_id}")
      assert texts(view, "#work-items-board .q-wl-st-n") == ["0", "1", "0", "0", "0"]
    end
  end

  describe "no pool can take the queued run" do
    test "after a move back to Explore: the header and Explore's box", %{
      conn: conn,
      scope: scope
    } do
      work_item = moved_back!(scope)
      assert %{status: :shape} = WorkItems.explore(scope, work_item, DateTime.utc_now())

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert has_element?(
               view,
               "#work-item-head-stage-status",
               "Waiting: no pool can take the run"
             )

      assert has_element?(view, "#work-item-explore-no-pool-h", "No pool can take attempt")
      refute has_element?(view, "#work-item-explore-wait")
    end

    test "a later stage's run: the header alone, as no block shows a queued run there", %{
      conn: conn,
      scope: scope
    } do
      # A confirmed take in, approved at Shape: at Build, Explore's status is Ready for
      # Shape while Build's run waits.
      work_item = shape_gate_fixture(scope)
      {:ok, _work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      work_item = Repo.get!(WorkItem, work_item.id)
      assert work_item.stage_id == @build

      _build = stage_run!(work_item, @build)
      assert %{status: :shape} = WorkItems.explore(scope, work_item, DateTime.utc_now())

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert has_element?(
               view,
               "#work-item-head-stage-status",
               "Waiting: no pool can take the run"
             )

      refute has_element?(view, "#work-item-explore-no-pool")
      refute has_element?(view, "#work-item-step-no-pool")
      refute has_element?(view, "#work-item-stage-line")
    end
  end

  describe "the confirmation of a spend" do
    # The confirmation before an action that starts a run (`ApiaryWeb.SpendDialog`): the
    # click opens the dialog and starts nothing, Cancel and Escape start nothing, Confirm
    # starts one run with the dialog's note, and a second Confirm starts none. An action
    # that starts a run only in some states opens the dialog only where it starts one.

    defp spend_runs(work_item),
      do: Repo.aggregate(from(r in DispatchRun, where: r.work_item_id == ^work_item.id), :count)

    # The workspace's machine: no pool serves the test's workspace, so the line has none.
    defp machine(_scope), do: "a machine"

    defp another_round(view, note) do
      view
      |> form("#work-item-stage-escalation-form", %{"note" => note})
      |> render_submit(%{"how" => "another_round"})
    end

    test "Run another round: the dialog with the note; Cancel and Escape start nothing; Confirm starts one run",
         %{conn: conn, scope: scope} do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(nil, %{exit_state: "failed", outcome_state: "failed"})

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = spend_runs(work_item)

      another_round(view, "Read the export log first.")

      assert has_element?(view, "#spend-dialog-title", "Run another round?")

      assert line(view, "#spend-dialog-line") ==
               "Starts a run of explore-a-ticket on #{machine(scope)}. The run uses model tokens."

      assert has_element?(view, "#spend-dialog-note", "Read the export log first.")
      assert has_element?(view, "#spend-dialog-cancel", "Cancel")
      assert has_element?(view, "#spend-dialog-go", "Run another round")

      assert has_element?(
               view,
               ~s|#spend-dialog[data-return="work-item-stage-escalation-another"]|
             )

      assert has_element?(view, ~s|#spend-dialog[aria-describedby="spend-dialog-line"]|)

      assert spend_runs(work_item) == before
      assert %Escalation{resolution: nil} = escalation(work_item)

      view |> element("#spend-dialog-cancel") |> render_click()
      refute has_element?(view, "#spend-dialog")
      assert spend_runs(work_item) == before

      another_round(view, "Read the export log first.")
      view |> element("#spend-dialog") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#spend-dialog")
      assert spend_runs(work_item) == before
      assert %Escalation{resolution: nil} = escalation(work_item)

      another_round(view, "Read the export log first.")

      view
      |> form("#spend-dialog-form", %{"note" => "Read the export log, then retry."})
      |> render_submit()

      refute has_element?(view, "#spend-dialog")
      assert spend_runs(work_item) == before + 1

      assert %Escalation{resolution: :another_round, note: "Read the export log, then retry."} =
               escalation(work_item)

      # A second Confirm, as from a double click, finds no dialog open.
      render_hook(view, "spend_confirm", %{"note" => "Again"})
      assert spend_runs(work_item) == before + 1
    end

    test "Run another round: the dialog opens with focus on Cancel, not on the note or the confirm button",
         %{conn: conn, scope: scope} do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(nil, %{exit_state: "failed", outcome_state: "failed"})

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      another_round(view, "Read the export log first.")

      assert has_element?(view, ~s|#spend-dialog[data-focus="spend-dialog-cancel"]|)
      assert has_element?(view, "#spend-dialog-cancel", "Cancel")
    end

    test "Request changes: the dialog where the stage runs again; none at a stage with no workflow",
         %{conn: conn, scope: scope} do
      work_item = at_build(scope, :at_gate)
      push!({:person, scope}, work_item, "explainer", @build)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = spend_runs(work_item)

      view |> element("#work-item-stage-gate-ask-changes") |> render_click()

      view
      |> form("#work-item-stage-gate-changes", %{"note" => "Record the demo again"})
      |> render_submit()

      assert has_element?(view, "#spend-dialog-title", "Request changes?")

      assert line(view, "#spend-dialog-line") ==
               "Starts a run of capture-demo on #{machine(scope)}. The run uses model tokens."

      assert has_element?(view, "#spend-dialog-note", "Record the demo again")
      refute has_element?(view, "#spend-dialog", "(optional)")
      assert decisions(work_item, :request_changes) == []
      assert spend_runs(work_item) == before

      view
      |> form("#spend-dialog-form", %{"note" => "Record the demo with two cards"})
      |> render_submit()

      assert [%GateDecision{note: "Record the demo with two cards"}] =
               decisions(work_item, :request_changes)

      assert spend_runs(work_item) == before + 1

      # Shape has no workflow: Request changes acts at once.
      shape = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, shape.number))
      view |> element("#work-item-stage-gate-ask-changes") |> render_click()

      view
      |> form("#work-item-stage-gate-changes", %{"note" => "Split the plan in two"})
      |> render_submit()

      refute has_element?(view, "#spend-dialog")
      assert [%GateDecision{note: "Split the plan in two"}] = decisions(shape, :request_changes)
    end

    test "Approve: the dialog where the next stage starts a run; none where it waits", %{
      conn: conn,
      scope: scope
    } do
      # Shape's approval covers its acceptance criteria, which Build reads as its input.
      stages =
        for stage <- document("members")["stages"] do
          if stage["id"] == @shape,
            do: %{stage | "outputs" => [%{"type" => "acceptance-criteria", "required" => false}]},
            else: stage
        end

      save!(scope, %{document("members") | "stages" => stages})

      # Build waits for its acceptance criteria: Approve acts at once.
      waits = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, waits.number))
      view |> form("#work-item-stage-gate-approve") |> render_submit()
      refute has_element?(view, "#spend-dialog")

      assert [%GateDecision{}] =
               waits |> decisions(:approve) |> Enum.filter(&(&1.stage_id == @shape))

      assert Repo.get!(WorkItem, waits.id).stage_state == :waiting_inputs

      # With the criteria, Build starts implement.
      runs = shape_gate_fixture(scope)
      push!({:person, scope}, runs, "acceptance-criteria", @shape)
      {:ok, view, _html} = live(conn, page(scope, runs.number))
      before = spend_runs(runs)
      view |> form("#work-item-stage-gate-approve") |> render_submit()

      assert has_element?(view, "#spend-dialog-title", "Approve Shape?")
      assert has_element?(view, "#spend-dialog-go", "Approve Shape")

      assert line(view, "#spend-dialog-line") ==
               "Starts a run of implement on #{machine(scope)}. The run uses model tokens."

      refute has_element?(view, "#spend-dialog-note")
      assert runs |> decisions(:approve) |> Enum.filter(&(&1.stage_id == @shape)) == []

      view |> form("#spend-dialog-form") |> render_submit()

      assert [%GateDecision{}] =
               runs |> decisions(:approve) |> Enum.filter(&(&1.stage_id == @shape))

      assert spend_runs(runs) == before + 1
      assert %DispatchRun{workflow: "implement"} = newest_run(runs)
    end

    test "Confirm: no dialog where Shape has no workflow; the dialog where it has one", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      view |> element("#work-item-explore-gate-go", "Approve") |> render_click()
      refute has_element?(view, "#spend-dialog")
      assert [%GateDecision{stage_id: @explore}] = decisions(work_item, :approve)

      stages =
        for stage <- Processes.current(scope.workspace).document["stages"] do
          if stage["id"] == @shape,
            do: %{stage | "sequence" => [%{"workflow" => "plan-the-change"}]},
            else: stage
        end

      save!(scope, %{Processes.current(scope.workspace).document | "stages" => stages})
      work_item = explore_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      before = spend_runs(work_item)
      view |> element("#work-item-explore-gate-go", "Approve") |> render_click()

      assert has_element?(view, "#spend-dialog-title", "Confirm?")
      assert has_element?(view, ~s|#spend-dialog[data-return="work-item-explore-gate-go"]|)

      assert line(view, "#spend-dialog-line") ==
               "Starts a run of plan-the-change on #{machine(scope)}. The run uses model tokens."

      assert decisions(work_item, :approve) == []

      view |> form("#spend-dialog-form") |> render_submit()
      assert [%GateDecision{stage_id: @explore}] = decisions(work_item, :approve)
      assert spend_runs(work_item) == before + 1
    end

    test "Move back: the dialog to a stage that starts a run, with the note; none to one that waits",
         %{conn: conn, scope: scope} do
      version = save!(scope, document("members"))

      work_item =
        scope
        |> taken_in_fixture()
        |> place!(version, @build, :waiting_inputs, stage_round: 1, stage_entry: 1)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = spend_runs(work_item)

      view
      |> form("#work-item-stage-move", %{"stage" => @explore, "note" => "Explore the refund"})
      |> render_submit()

      assert has_element?(view, "#spend-dialog-title", "Move back?")
      assert has_element?(view, "#spend-dialog-note", "Explore the refund")

      assert line(view, "#spend-dialog-line") ==
               "Starts a run of explore-a-ticket on #{machine(scope)}. The run uses model tokens."

      assert decisions(work_item, :move) == []

      view |> element("#spend-dialog-cancel") |> render_click()
      assert Repo.get!(WorkItem, work_item.id).stage_id == @build

      view
      |> form("#work-item-stage-move", %{"stage" => @explore, "note" => "Explore the refund"})
      |> render_submit()

      view |> form("#spend-dialog-form") |> render_submit()
      assert [%GateDecision{note: "Explore the refund"}] = decisions(work_item, :move)
      assert Repo.get!(WorkItem, work_item.id).stage_id == @explore
      assert spend_runs(work_item) == before + 1

      # Shape has no workflow: Move back to it acts at once.
      shape =
        scope
        |> taken_in_fixture()
        |> place!(version, @build, :waiting_inputs, stage_round: 1, stage_entry: 1)

      {:ok, view, _html} = live(conn, page(scope, shape.number))
      before = spend_runs(shape)

      view
      |> form("#work-item-stage-move", %{"stage" => @shape, "note" => "Shape it again"})
      |> render_submit()

      refute has_element?(view, "#spend-dialog")
      assert [%GateDecision{note: "Shape it again"}] = decisions(shape, :move)
      assert Repo.get!(WorkItem, shape.id).stage_id == @shape
      assert spend_runs(shape) == before
    end

    test "Accept as it is: the dialog where the next workflow starts; none where the gate follows",
         %{conn: conn, scope: scope} do
      at_gate = at_build(scope, :escalated, round: 3)
      push!({:person, scope}, at_gate, "explainer", @build)
      escalate!(at_gate, :escalate, "Blocked")
      {:ok, view, _html} = live(conn, page(scope, at_gate.number))

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "accept"})

      refute has_element?(view, "#spend-dialog")
      assert %Escalation{resolution: :accept} = escalation(at_gate)

      # At implement, the first entry, Accept goes on to the loop's capture-demo.
      work_item = at_build(scope, :escalated)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: [stage_entry: 0])

      push!({:person, scope}, work_item, "explainer", @build)
      escalate!(work_item, :escalate, "Blocked")
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = spend_runs(work_item)

      view
      |> form("#work-item-stage-escalation-form", %{"note" => "Good enough"})
      |> render_submit(%{"how" => "accept"})

      assert has_element?(view, "#spend-dialog-title", "Accept as it is?")

      assert line(view, "#spend-dialog-line") ==
               "Starts a run of capture-demo on #{machine(scope)}. The run uses model tokens."

      assert has_element?(
               view,
               "#spend-dialog",
               "A note you add goes to the next run as work item data."
             )

      assert %Escalation{resolution: nil} = escalation(work_item)
      view |> form("#spend-dialog-form") |> render_submit()
      assert %Escalation{resolution: :accept, note: "Good enough"} = escalation(work_item)
      assert spend_runs(work_item) == before + 1
    end

    test "Check again: the dialog where the stage starts once the workflow is found; none where it waits for an input",
         %{conn: conn, scope: scope} do
      work_item = waiting_for_found_workflow(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = spend_runs(work_item)

      view |> form("#work-item-stage-check") |> render_submit()
      assert has_element?(view, "#spend-dialog-title", "Check again?")

      assert line(view, "#spend-dialog-line") ==
               "Starts a run of capture-demo on #{machine(scope)}. The run uses model tokens."

      render_async(view)
      assert spend_runs(work_item) == before

      view |> form("#spend-dialog-form") |> render_submit()
      render_async(view)
      assert spend_runs(work_item) == before + 1

      # Build needs its acceptance criteria: once the workflow is found, it waits for them.
      version = save!(scope, document("members"))

      waits =
        scope
        |> work_item_fixture()
        |> place!(version, @build, :waiting_workflow, stage_round: 1, stage_entry: 1)

      {:ok, view, _html} = live(conn, page(scope, waits.number))
      view |> form("#work-item-stage-check") |> render_submit()
      refute has_element?(view, "#spend-dialog")
      render_async(view)
      assert Repo.get!(WorkItem, waits.id).stage_state == :waiting_inputs
      assert spend_runs(waits) == 0
    end

    test "Add version: the dialog where the version starts the stage; none where it does not",
         %{conn: conn, scope: scope} do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "spend-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      previous = Application.get_env(:apiary, :artifacts_dir)
      Application.put_env(:apiary, :artifacts_dir, tmp)

      on_exit(fn ->
        Application.put_env(:apiary, :artifacts_dir, previous)
        File.rm_rf!(tmp)
      end)

      work_item = at_build(scope, :waiting_inputs)
      before = spend_runs(work_item)

      {:ok, view, _html} =
        live(conn, page(scope, work_item.number) <> "/artifacts/new?type=acceptance-criteria")

      add_criteria(view)

      assert has_element?(view, "#spend-dialog-title", "Add version?")
      assert has_element?(view, ~s|#spend-dialog[data-return="artifact-save"]|)

      assert line(view, "#spend-dialog-line") ==
               "Starts a run of capture-demo on #{machine(scope)}. The run uses model tokens."

      assert Artifacts.list(work_item) == []

      # Cancel keeps the uploaded file: Add version again opens the dialog with it.
      view |> element("#spend-dialog-cancel") |> render_click()
      refute has_element?(view, "#spend-dialog")
      assert Artifacts.list(work_item) == []

      submit_criteria(view)
      assert has_element?(view, "#spend-dialog-title", "Add version?")
      view |> form("#spend-dialog-form") |> render_submit()
      assert [_artifact] = Artifacts.list(work_item)
      assert spend_runs(work_item) == before + 1

      # A second version at the gate of a stage with workflows starts nothing.
      gate = at_build(scope, :at_gate)

      {:ok, view, _html} =
        live(conn, page(scope, gate.number) <> "/artifacts/new?type=acceptance-criteria")

      # No dialog: the version is added and the page goes to it.
      assert {:error, {:live_redirect, _to}} = add_criteria(view)
      assert [_artifact] = Artifacts.list(gate)
    end

    # The members' document with `changes`, a map of stage id to the keys it sets, put
    # over those stages.
    defp changed(changes) do
      stages =
        for stage <- document("members")["stages"],
            do: Map.merge(stage, Map.get(changes, stage["id"], %{}))

      %{document("members") | "stages" => stages}
    end

    # A stage with no workflow, a gate `none` and no outputs: entered, it passes on.
    @passes_on %{"sequence" => [], "outputs" => [], "gate" => %{"kind" => "none"}}

    test "Approve and Confirm: the dialog where the stage after a stage that passes on starts a run",
         %{conn: conn, scope: scope} do
      # Approve Shape: Build passes on, and Verify starts verify-change with the
      # acceptance criteria that the approval covers.
      save!(
        scope,
        changed(%{
          @shape => %{
            "outputs" => [%{"type" => "acceptance-criteria", "required" => false}]
          },
          @build => @passes_on,
          @verify => %{
            "inputs" => [%{"type" => "acceptance-criteria", "required" => true}],
            "sequence" => [%{"workflow" => "verify-change"}]
          }
        })
      )

      approve = shape_gate_fixture(scope)
      push!({:person, scope}, approve, "acceptance-criteria", @shape)
      {:ok, view, _html} = live(conn, page(scope, approve.number))
      before = spend_runs(approve)
      view |> form("#work-item-stage-gate-approve") |> render_submit()

      assert has_element?(view, "#spend-dialog-title", "Approve Shape?")

      assert line(view, "#spend-dialog-line") ==
               "Starts a run of verify-change on #{machine(scope)}. The run uses model tokens."

      assert spend_runs(approve) == before
      view |> form("#spend-dialog-form") |> render_submit()
      assert Repo.get!(WorkItem, approve.id).stage_id == @verify
      assert spend_runs(approve) == before + 1
      assert %DispatchRun{workflow: "verify-change"} = newest_run(approve)

      # Confirm at Explore's gate: Shape passes on, and Build starts plan-the-change with
      # the proposal that the confirmation covers.
      save!(
        scope,
        changed(%{
          @shape => @passes_on,
          @build => %{
            "inputs" => [%{"type" => "proposal", "required" => true}],
            "sequence" => [%{"workflow" => "plan-the-change"}]
          }
        })
      )

      confirm = explore_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, confirm.number) <> "/explore")
      before = spend_runs(confirm)
      view |> element("#work-item-explore-gate-go", "Approve") |> render_click()

      assert has_element?(view, "#spend-dialog-title", "Confirm?")

      assert line(view, "#spend-dialog-line") ==
               "Starts a run of plan-the-change on #{machine(scope)}. The run uses model tokens."

      assert spend_runs(confirm) == before
      view |> form("#spend-dialog-form") |> render_submit()
      assert Repo.get!(WorkItem, confirm.id).stage_id == @build
      assert spend_runs(confirm) == before + 1
      assert %DispatchRun{workflow: "plan-the-change"} = newest_run(confirm)
    end

    test "Move back from the escalation card: the dialog with the note to a stage that starts a run",
         %{conn: conn, scope: scope} do
      work_item = at_build(scope, :escalated, round: 3)
      escalate!(work_item, :escalate, "Blocked")
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = spend_runs(work_item)

      view
      |> form("#work-item-stage-escalation-form", %{
        "note" => "Explore again",
        "stage" => @explore
      })
      |> render_submit(%{"how" => "move_back"})

      assert has_element?(view, "#spend-dialog-title", "Move back?")
      assert has_element?(view, "#spend-dialog-go", "Move back")
      assert has_element?(view, ~s|#spend-dialog[data-return="work-item-stage-escalation-move"]|)
      assert has_element?(view, "#spend-dialog-note", "Explore again")

      assert has_element?(
               view,
               "#spend-dialog",
               "A note you add goes to the next run as work item data."
             )

      assert line(view, "#spend-dialog-line") ==
               "Starts a run of explore-a-ticket on #{machine(scope)}. The run uses model tokens."

      assert %Escalation{resolution: nil} = escalation(work_item)
      assert spend_runs(work_item) == before

      view
      |> form("#spend-dialog-form", %{"note" => "Explore the refund again"})
      |> render_submit()

      assert %Escalation{resolution: :move_back, note: "Explore the refund again"} =
               escalation(work_item)

      assert Repo.get!(WorkItem, work_item.id).stage_id == @explore
      assert spend_runs(work_item) == before + 1
    end

    test "Try again: after a check that failed, the dialog has the words Try again", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_for_found_workflow(scope)
      WorkflowFake.check_result(scope.workspace, {:error, {:unreadable, :address}})
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      view |> form("#work-item-stage-check") |> render_submit()
      assert has_element?(view, "#spend-dialog-title", "Check again?")
      view |> form("#spend-dialog-form") |> render_submit()
      render_async(view)
      assert has_element?(view, "#work-item-stage-check-go", "Try again")

      view |> form("#work-item-stage-check") |> render_submit()
      assert has_element?(view, "#spend-dialog-title", "Try again?")
      assert has_element?(view, "#spend-dialog-go", "Try again")
      assert has_element?(view, ~s|#spend-dialog[data-return="work-item-stage-check-go"]|)
      assert spend_runs(work_item) == 0
    end

    # Opens the dialog with `open`, closes it with Cancel, then again with Escape; after
    # each, `unchanged` checks that nothing was done.
    defp cancel_and_escape(view, open, unchanged) do
      open.()
      assert has_element?(view, "#spend-dialog")
      view |> element("#spend-dialog-cancel") |> render_click()
      refute has_element?(view, "#spend-dialog")
      unchanged.()

      open.()
      assert has_element?(view, "#spend-dialog")
      view |> element("#spend-dialog") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#spend-dialog")
      unchanged.()
    end

    test "Cancel and Escape start nothing: Confirm, Approve, Request changes, Accept as it is, Check again and Add version",
         %{conn: conn, scope: scope} do
      # Confirm, where Shape has a workflow.
      save!(
        scope,
        changed(%{@shape => %{"sequence" => [%{"workflow" => "plan-the-change"}]}})
      )

      confirm = explore_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, confirm.number) <> "/explore")
      before = spend_runs(confirm)

      cancel_and_escape(
        view,
        fn -> view |> element("#work-item-explore-gate-go", "Approve") |> render_click() end,
        fn ->
          assert decisions(confirm, :approve) == []
          assert spend_runs(confirm) == before
        end
      )

      # Approve Shape, where Build starts implement with the criteria.
      save!(
        scope,
        changed(%{
          @shape => %{"outputs" => [%{"type" => "acceptance-criteria", "required" => false}]}
        })
      )

      approve = shape_gate_fixture(scope)
      push!({:person, scope}, approve, "acceptance-criteria", @shape)
      {:ok, view, _html} = live(conn, page(scope, approve.number))
      before = spend_runs(approve)

      cancel_and_escape(
        view,
        fn -> view |> form("#work-item-stage-gate-approve") |> render_submit() end,
        fn ->
          assert approve |> decisions(:approve) |> Enum.filter(&(&1.stage_id == @shape)) == []
          assert spend_runs(approve) == before
        end
      )

      # Request changes at Build's gate.
      changes = at_build(scope, :at_gate)
      push!({:person, scope}, changes, "explainer", @build)
      {:ok, view, _html} = live(conn, page(scope, changes.number))
      view |> element("#work-item-stage-gate-ask-changes") |> render_click()
      before = spend_runs(changes)

      cancel_and_escape(
        view,
        fn ->
          view
          |> form("#work-item-stage-gate-changes", %{"note" => "Record the demo again"})
          |> render_submit()
        end,
        fn ->
          assert decisions(changes, :request_changes) == []
          assert spend_runs(changes) == before
        end
      )

      # Accept as it is at implement, which goes on to capture-demo.
      accept = at_build(scope, :escalated)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^accept.id), set: [stage_entry: 0])

      push!({:person, scope}, accept, "explainer", @build)
      escalate!(accept, :escalate, "Blocked")
      {:ok, view, _html} = live(conn, page(scope, accept.number))
      before = spend_runs(accept)

      cancel_and_escape(
        view,
        fn ->
          view
          |> form("#work-item-stage-escalation-form", %{"note" => "Good enough"})
          |> render_submit(%{"how" => "accept"})
        end,
        fn ->
          assert %Escalation{resolution: nil} = escalation(accept)
          assert spend_runs(accept) == before
        end
      )

      # Check again, where the harness lists the workflow.
      check = waiting_for_found_workflow(scope)
      {:ok, view, _html} = live(conn, page(scope, check.number))

      cancel_and_escape(
        view,
        fn -> view |> form("#work-item-stage-check") |> render_submit() end,
        fn ->
          render_async(view)
          assert Repo.get!(WorkItem, check.id).stage_state == :waiting_workflow
          assert spend_runs(check) == 0
        end
      )

      # Add version of the input that Build waits for.
      tmp =
        Path.join(
          System.tmp_dir!(),
          "spend-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      previous = Application.get_env(:apiary, :artifacts_dir)
      Application.put_env(:apiary, :artifacts_dir, tmp)

      on_exit(fn ->
        Application.put_env(:apiary, :artifacts_dir, previous)
        File.rm_rf!(tmp)
      end)

      add = at_build(scope, :waiting_inputs)

      {:ok, view, _html} =
        live(conn, page(scope, add.number) <> "/artifacts/new?type=acceptance-criteria")

      view
      |> file_input("#artifact-form", :files, [
        %{name: "criteria.md", content: "# Criteria", type: "text/markdown"}
      ])
      |> render_upload("criteria.md")

      cancel_and_escape(view, fn -> submit_criteria(view) end, fn ->
        assert Artifacts.list(add) == []
        assert spend_runs(add) == 0
      end)
    end

    test "Request changes with the note cleared in the dialog: no change, and the note's error under the page's form",
         %{conn: conn, scope: scope} do
      work_item = at_build(scope, :at_gate)
      push!({:person, scope}, work_item, "explainer", @build)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = spend_runs(work_item)

      view |> element("#work-item-stage-gate-ask-changes") |> render_click()

      view
      |> form("#work-item-stage-gate-changes", %{"note" => "Record the demo again"})
      |> render_submit()

      view |> form("#spend-dialog-form", %{"note" => ""}) |> render_submit()

      refute has_element?(view, "#spend-dialog")

      assert has_element?(
               view,
               "#work-item-stage-gate-changes",
               "Write what needs to change."
             )

      assert decisions(work_item, :request_changes) == []
      assert spend_runs(work_item) == before
    end

    defp add_criteria(view) do
      view
      |> file_input("#artifact-form", :files, [
        %{name: "criteria.md", content: "# Criteria", type: "text/markdown"}
      ])
      |> render_upload("criteria.md")

      submit_criteria(view)
    end

    defp submit_criteria(view) do
      view
      |> form("#artifact-form",
        artifact: %{type: "acceptance-criteria", name: "main", note: "First draft"}
      )
      |> render_submit()
    end
  end
end
