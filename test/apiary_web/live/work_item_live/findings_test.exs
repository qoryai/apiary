defmodule ApiaryWeb.WorkItemLive.FindingsTest do
  # The work item page after a click on Approve that an open blocking finding stops
  # (`Apiary.Findings`): the action the page offers there, then the rule, where the page
  # shows why a move was not made.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Findings, Processes, Repo, Stages}
  alias Apiary.Runs.Target
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @build "st_6ns22c4pav"

  setup :register_and_log_in_user

  # Explore, whose one workflow runs only for new feedback, then Build at a gate of `kind`,
  # then Release. A take in's run of Build is then not a run of Explore.
  # shortcut: Explore comes first, as the take in's run of the first stage gets the Explore
  # gate whatever the stage. Put Build first once that gate follows a required proposal.
  defp process!(scope, gate) do
    {:ok, _version} =
      Processes.save(scope, scope.workspace, %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "stages" => [
          %{
            "id" => @explore,
            "name" => "Explore",
            "inputs" => [],
            "sequence" => [%{"workflow" => "triage-review", "when" => %{"feedback" => "new"}}],
            "outputs" => [],
            "gate" => %{"kind" => "none"}
          },
          %{
            "id" => @build,
            "name" => "Build",
            "inputs" => [],
            "sequence" => [%{"workflow" => "implement-changes"}],
            "outputs" => [%{"type" => "acceptance-criteria", "required" => false}],
            "gate" => gate
          },
          %{
            "id" => "st_k9kpv17xmy",
            "name" => "Release",
            "inputs" => [],
            "sequence" => [],
            "outputs" => [],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          }
        ]
      })
  end

  # A taken in work item whose first run does `first`, raises `count` blocking findings that
  # the stage `stage_id` owns, and ends.
  defp raised!(scope, stage_id, count, first) do
    work_item = taken_in_fixture(scope)

    :ok =
      Target.insert_new(work_item.organisation_id, work_item.workspace_id, [
        WorkItem.target(work_item)
      ])

    end_run!(work_item, fn run, registered ->
      first.(run, registered)

      events =
        for number <- 1..count do
          %{
            kind: "raise",
            by: "code-reviewer",
            ref: "r#{number}",
            target_id: Target.dispatched_id(run.workspace_id, run.id),
            stage_id: stage_id,
            source_kind: "reviewer",
            source_name: "code-reviewer",
            severity: "blocking",
            place: %{"quote" => "total = price + tax - discount"},
            point: "The total is wrong",
            problem: "The tax is charged on the full price.",
            fix: "Subtract the discount first.",
            proof: "An order of 100.00 totals 110.00."
          }
        end

      {:ok, _answer} =
        Findings.post(
          Repo.get!(WorkItem, run.work_item_id),
          %{run_id: registered.id, dispatch_run_id: run.id},
          %{bases: [], events: events}
        )
    end)
  end

  defp verdict(verdict) do
    fn run, _registered ->
      {:ok, _version} =
        Stages.Artifacts.push_json(
          {:run, run},
          Repo.get!(WorkItem, run.work_item_id),
          "verdict",
          %{"verdict" => verdict},
          stage_id: run.stage_id
        )
    end
  end

  defp open!(conn, scope, work_item) do
    {:ok, view, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}")

    view
  end

  defp line(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  test "Approve at a person's gate: click Request changes, then the rule", ctx do
    process!(ctx.scope, %{"kind" => "person", "approvers" => "members"})
    work_item = raised!(ctx.scope, @build, 2, verdict("changes-requested"))
    assert %WorkItem{stage_id: @build, stage_state: :at_gate} = work_item

    view = open!(ctx.conn, ctx.scope, work_item)
    refute has_element?(view, "#work-item-stage-notice")
    view |> element("#work-item-stage-gate-approve") |> render_submit()

    assert line(view, "#work-item-stage-notice") ==
             "Click Request changes. 2 blocking findings are open. " <>
               "Build passes only when none is open."

    assert has_element?(view, "#work-item-stage-gate-ask-changes", "Request changes")
    assert Repo.reload!(work_item).stage_id == @build
  end

  test "Approve at a gate none: click Run another round, then the rule", ctx do
    process!(ctx.scope, %{"kind" => "none"})

    work_item =
      raised!(ctx.scope, @build, 1, fn run, registered ->
        {:ok, _version} =
          Artifacts.push(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "acceptance-criteria",
            [json_file("acceptance-criteria", criteria_document())],
            stage_id: run.stage_id
          )

        verdict("changes-requested").(run, registered)
      end)

    assert %WorkItem{stage_id: @build, stage_state: :at_gate} = work_item

    view = open!(ctx.conn, ctx.scope, work_item)
    refute has_element?(view, "#work-item-stage-gate-ask-changes")
    assert has_element?(view, "#work-item-tab-gate-send", "Run another round")
    view |> element("#work-item-stage-gate-approve") |> render_submit()

    assert line(view, "#work-item-stage-notice") ==
             "Click Run another round. 1 blocking finding is open. " <>
               "Build passes only when none is open."

    assert Repo.reload!(work_item).stage_id == @build
  end

  test "Approve at Explore's Confirm: click Run another round, then the rule", ctx do
    work_item =
      raised!(ctx.scope, @explore, 1, fn run, registered ->
        push_result!(run, registered, understood_result())
      end)

    assert %WorkItem{stage_id: @explore, stage_state: :at_gate} = work_item

    view = open!(ctx.conn, ctx.scope, work_item)
    refute has_element?(view, "#work-item-explore-gate-error")
    view |> element("#work-item-explore-gate-go") |> render_click()

    assert line(view, "#work-item-explore-gate-error") ==
             "Click Run another round. 1 blocking finding is open. " <>
               "Explore passes only when none is open."

    # Nothing told the page that the work item changed, so the line stays.
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#work-item-explore-gate-error")
    assert has_element?(view, "#work-item-explore-gate button", "Run another round")
    assert Repo.reload!(work_item).stage_id == @explore
  end
end
