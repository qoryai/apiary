defmodule Apiary.Stages.FindingsTest do
  # The gate of a stage with findings (`Apiary.Findings`): the passes that an open blocking
  # finding keeps from happening, the points of an escalation at a limit, and Accept as it
  # is.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Findings, Processes, Repo, Stages, WorkItems}
  alias Apiary.Findings.{Event, Finding}
  alias Apiary.Runs.Target
  alias Apiary.Stages.{Escalation, GateDecision}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @build "st_6ns22c4pav"
  @verify "st_m1mqbeywdg"
  @release "st_k9kpv17xmy"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp save!(scope, stages) do
    document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => stages}
    {:ok, version} = Processes.save(scope, scope.workspace, document)
    version
  end

  defp stage(id, name, sequence, extra) do
    Map.merge(
      %{
        "id" => id,
        "name" => name,
        "inputs" => [],
        "sequence" => sequence,
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      },
      extra
    )
  end

  # Explore, whose one workflow runs only for new feedback, with no gate. A process that
  # starts with it takes a work item in to the next stage, and that stage's run is not a
  # run of Explore.
  # shortcut: Explore comes first, as the take in's run of the first stage gets the Explore
  # gate whatever the stage. Put Build first once that gate follows a required proposal.
  defp explore_stage do
    sequence = [%{"workflow" => "triage-review", "when" => %{"feedback" => "new"}}]
    stage(@explore, "Explore", sequence, %{"gate" => gate("none")})
  end

  # Explore, then Build, a loop of 2 rounds with no gate, then Verify, which returns to
  # Build once, then Release, at a person's gate.
  defp loop_process!(scope, build_gate \\ "none") do
    loop = %{"loop" => %{"rounds" => 2, "body" => [%{"workflow" => "implement-changes"}]}}

    save!(scope, [
      explore_stage(),
      stage(@build, "Build", [loop], %{"gate" => gate(build_gate)}),
      stage(
        @verify,
        "Verify",
        [%{"workflow" => "verify-a-ticket", "return" => %{"stage" => @build, "limit" => 1}}],
        %{"gate" => gate("none")}
      ),
      stage(@release, "Release", [], %{})
    ])
  end

  # Explore, then Build, one run, at a person's gate or with none, then Release.
  defp entry_process!(scope, build_gate) do
    save!(scope, [
      explore_stage(),
      stage(@build, "Build", [%{"workflow" => "implement-changes"}], %{
        "gate" => gate(build_gate)
      }),
      stage(@release, "Release", [%{"workflow" => "release-a-change"}], %{})
    ])
  end

  defp gate("none"), do: %{"kind" => "none"}
  defp gate("person"), do: %{"kind" => "person", "approvers" => "members"}

  defp take_in!(scope) do
    work_item = taken_in_fixture(scope)

    :ok =
      Target.insert_new(work_item.organisation_id, work_item.workspace_id, [
        WorkItem.target(work_item)
      ])

    work_item
  end

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  # The end of a run that raises `findings`, each `{stage_id, severity, point}`, then pushes
  # the verdict `verdict` (nil for none), as `Apiary.StagesFixtures.end_run!/3` takes it.
  defp raising(findings, verdict) do
    fn run, registered ->
      {:ok, _answer} = post(run, registered.id, Enum.map(findings, &raise_event(run, &1)))
      if verdict, do: {:ok, _version} = push_verdict(run, verdict)
    end
  end

  defp closing(numbers, verdict) do
    fn run, registered ->
      target_id = Target.dispatched_id(run.workspace_id, run.id)

      events =
        for number <- numbers do
          %{
            kind: "close_fixed",
            by: "code-reviewer",
            number: number,
            target_id: target_id,
            reason: "Fixed."
          }
        end

      {:ok, _answer} = post(run, registered.id, events)
      {:ok, _version} = push_verdict(run, verdict)
    end
  end

  defp post(run, run_id, events) do
    Findings.post(
      Repo.get!(WorkItem, run.work_item_id),
      %{run_id: run_id, dispatch_run_id: run.id},
      %{bases: [], events: events}
    )
  end

  defp raise_event(run, {stage_id, severity, point}) do
    %{
      kind: "raise",
      by: "code-reviewer",
      ref: "r#{System.unique_integer([:positive])}",
      target_id: Target.dispatched_id(run.workspace_id, run.id),
      stage_id: stage_id,
      source_kind: "reviewer",
      source_name: "code-reviewer",
      severity: severity,
      place: %{"quote" => "total = price + tax - discount"},
      point: point,
      problem: "The tax is charged on the full price.",
      fix: "Subtract the discount first.",
      proof: "An order of 100.00 totals 110.00."
    }
  end

  defp push_verdict(run, verdict, points \\ nil) do
    document = %{"verdict" => verdict}
    document = if points, do: Map.put(document, "points", points), else: document

    Stages.Artifacts.push_json(
      {:run, run},
      Repo.get!(WorkItem, run.work_item_id),
      "verdict",
      document,
      stage_id: run.stage_id
    )
  end

  defp escalation(work_item),
    do:
      Repo.one(
        from e in Escalation, where: e.work_item_id == ^work_item.id and is_nil(e.resolved_at)
      )

  defp resolved(work_item),
    do:
      Repo.one!(
        from e in Escalation,
          where: e.work_item_id == ^work_item.id and not is_nil(e.resolved_at)
      )

  defp finding(work_item, number),
    do: Repo.get_by!(Finding, work_item_id: work_item.id, number: number)

  defp person_events(work_item, number) do
    %Finding{id: id} = finding(work_item, number)

    Repo.all(
      from e in Event,
        where: e.finding_id == ^id and e.actor_kind == "person",
        order_by: e.position,
        select: {e.kind, e.user_id, e.round}
    )
  end

  defp resolve(scope, work_item, resolution),
    do:
      Stages.resolve_escalation(scope, work_item, resolution, nil,
        expect_stage: reload(work_item).stage_id
      )

  defp approve(scope, work_item),
    do: Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id)

  # Each finding of the work item as a run's close leaves it.
  defp fixed!(work_item) do
    Repo.update_all(from(f in Finding, where: f.work_item_id == ^work_item.id),
      set: [state: "fixed"]
    )
  end

  # A work item at Build's round limit with the findings `findings` raised in round 1.
  defp at_limit!(scope, findings) do
    loop_process!(scope)

    work_item =
      take_in!(scope)
      |> end_run!(raising(findings, "changes-requested"))
      |> end_run!(fn run, _registered -> {:ok, _v} = push_verdict(run, "changes-requested") end)

    assert %WorkItem{stage_id: @build, stage_state: :escalated, stage_round: 2} = work_item
    assert %Escalation{cause: :round_limit} = escalation(work_item)
    work_item
  end

  describe "a passed verdict" do
    test "is refused while the stage owns an open blocking finding", %{scope: scope} do
      loop_process!(scope)
      work_item = take_in!(scope)

      end_run!(
        work_item,
        fn run, registered ->
          blocking = {@build, "blocking", "The discount is applied after the tax"}
          note = {@build, "non-blocking", "A name is too long"}
          {:ok, _} = post(run, registered.id, Enum.map([blocking, note], &raise_event(run, &1)))

          assert push_verdict(run, "passed") ==
                   {:error,
                    {:open_blocking_findings,
                     %{stage_id: @build, stage: "Build", findings: ["f1"], count: 1}}}

          # A verdict of another kind is stored.
          assert {:ok, _version} = push_verdict(run, "changes-requested")

          target_id = Target.dispatched_id(run.workspace_id, run.id)

          close = %{
            kind: "close_fixed",
            by: "suite",
            number: 1,
            target_id: target_id,
            reason: "Fixed."
          }

          assert {:ok, _answer} = post(run, registered.id, [close])
          assert {:ok, _version} = push_verdict(run, "passed")
        end
      )
    end

    test "is stored while a finding that Verify owns is open", %{scope: scope} do
      loop_process!(scope)

      work_item =
        take_in!(scope)
        |> end_run!(raising([{@verify, "blocking", "The total is not shown"}], "passed"))

      assert %WorkItem{stage_id: @verify, stage_state: :running} = work_item
      assert %Finding{state: "open"} = finding(work_item, 1)
    end
  end

  test "a changes-requested verdict with no points is stored and starts the next round", %{
    scope: scope
  } do
    loop_process!(scope)

    work_item =
      take_in!(scope)
      |> end_run!(raising([{@build, "blocking", "The total is wrong"}], "changes-requested"))

    assert %WorkItem{stage_id: @build, stage_state: :running, stage_round: 2} = work_item

    work_item =
      end_run!(work_item, fn run, _registered ->
        assert {:ok, _version} = push_verdict(run, "changes-requested")
      end)

    assert %WorkItem{stage_state: :escalated, stage_round: 2} = work_item
  end

  describe "the escalation at a limit" do
    test "lists the open findings of the stage in place of the verdict's points", %{scope: scope} do
      work_item =
        at_limit!(scope, [
          {@build, "non-blocking", "A name is too long"},
          {@build, "blocking", "The total is wrong"},
          {@verify, "blocking", "The page is blank"}
        ])

      assert [
               %{
                 "text" =>
                   "2 of 2 rounds ran, and 2 review findings are still open. " <>
                     "f2: The total is wrong. f1: A name is too long.",
                 "open_findings" => 2,
                 "fix" =>
                   "Read the 2 open findings, then pick Accept as it is or Run another round."
               }
             ] = escalation(work_item).points
    end

    test "lists the open findings at a return limit", %{scope: scope} do
      work_item = return_limit!(scope)

      assert [
               %{"return_stage" => "Build"},
               %{"text" => "f1: The page is blank.", "action" => "run_again"}
             ] =
               escalation(work_item).points
    end

    test "has the verdict's points where the stage has no finding", %{scope: scope} do
      loop_process!(scope)

      ended = fn run, _registered ->
        {:ok, _version} =
          push_verdict(run, "changes-requested", [
            %{"text" => "The demo has no card.", "action" => "run_again"}
          ])
      end

      work_item = take_in!(scope) |> end_run!(ended) |> end_run!(ended)

      assert [%{"text" => "2 of 2 rounds ran, and 1 review finding is still open. " <> text}] =
               escalation(work_item).points

      assert text == "The demo has no card."
    end
  end

  # A work item at Verify's return limit, with the blocking finding f1 that Verify owns.
  defp return_limit!(scope) do
    loop_process!(scope)

    work_item =
      take_in!(scope)
      |> end_run!(fn run, _registered -> {:ok, _v} = push_verdict(run, "passed") end)
      |> end_run!(raising([{@verify, "blocking", "The page is blank"}], "changes-requested"))
      |> end_run!(fn run, _registered -> {:ok, _v} = push_verdict(run, "passed") end)
      |> end_run!(fn run, _registered -> {:ok, _v} = push_verdict(run, "changes-requested") end)

    assert %WorkItem{stage_id: @verify, stage_state: :escalated} = work_item
    assert %Escalation{cause: :return_limit} = escalation(work_item)
    work_item
  end

  describe "Accept as it is" do
    test "accepts every open finding the stage owns, as the person, then passes", %{scope: scope} do
      work_item =
        at_limit!(scope, [
          {@build, "blocking", "The total is wrong"},
          {@build, "non-blocking", "A name is too long"},
          {@verify, "blocking", "The page is blank"}
        ])

      user_id = scope.user.id
      assert {:run, "verify-a-ticket"} = Stages.starts(work_item, :accept)

      # A run raises a blocking finding after the page loaded: it is accepted too.
      live = live_stage_run!(work_item, @build)
      event = raise_event(live, {@build, "blocking", "The tax is wrong"})
      assert {:ok, %{created: [{_ref, "f4"}]}} = post(live, Ecto.UUID.generate(), [event])

      assert {:ok, %WorkItem{stage_id: @verify}} = resolve(scope, work_item, :accept)

      for number <- [1, 2, 4] do
        assert %Finding{state: "accepted", closed_by_person: true} = finding(work_item, number)
        assert [{"accepted", ^user_id, 2}] = person_events(work_item, number)
      end

      assert %Finding{state: "open"} = finding(work_item, 3)
      assert person_events(work_item, 3) == []

      assert %Escalation{resolution: :accept, resolved_by_id: ^user_id} = resolved(work_item)

      assert [%GateDecision{kind: :approve, user_id: ^user_id}] =
               Repo.all(
                 from d in GateDecision,
                   where: d.work_item_id == ^work_item.id and d.stage_id == ^@build
               )
    end

    test "writes no event where the accept is refused", %{scope: scope} do
      # An escalated stage that needs an output its runs did not write.
      loop = %{"loop" => %{"rounds" => 1, "body" => [%{"workflow" => "implement-changes"}]}}

      save!(scope, [
        explore_stage(),
        stage(@build, "Build", [loop], %{
          "outputs" => [%{"type" => "walkthrough", "required" => true}]
        })
      ])

      work_item =
        take_in!(scope)
        |> end_run!(raising([{@build, "blocking", "The total is wrong"}], "changes-requested"))

      assert %WorkItem{stage_state: :escalated} = work_item
      assert resolve(scope, work_item, :accept) == {:error, :invalid}
      assert %Finding{state: "open"} = finding(work_item, 1)
      assert person_events(work_item, 1) == []
    end
  end

  test "the other choices at a limit stay", %{scope: scope} do
    findings = [{@build, "blocking", "The total is wrong"}]
    at_limit!(scope, findings) |> then(&assert {:ok, _} = resolve(scope, &1, :another_round))

    %{scope: scope} = sign_up_fixture()
    at_limit!(scope, findings) |> then(&assert {:ok, _} = resolve(scope, &1, :close))

    %{scope: scope} = sign_up_fixture()
    work_item = return_limit!(scope)
    assert {:ok, %WorkItem{stage_id: @build}} = resolve(scope, work_item, {:move_back, @build})
  end

  describe "a person's gate" do
    test "is not approved while the stage owns an open blocking finding", %{scope: scope} do
      entry_process!(scope, "person")

      work_item =
        take_in!(scope)
        |> end_run!(raising([{@build, "blocking", "The total is wrong"}], "changes-requested"))

      assert %WorkItem{stage_id: @build, stage_state: :at_gate} = work_item

      assert {:error, {:open_blocking_findings, %{findings: ["f1"]}}} = approve(scope, work_item)
      assert Stages.starts(work_item, :approve) == :none
      assert reload(work_item).stage_state == :at_gate

      # Request changes starts the run that closes the finding.
      {:ok, work_item} =
        Stages.request_changes(scope, work_item, "Fix the total.", nil, expect_stage: @build)

      work_item = end_run!(work_item, closing([1], "passed"))
      assert {:run, "release-a-change"} = Stages.starts(work_item, :approve)
      assert {:ok, %WorkItem{stage_id: @release}} = approve(scope, work_item)
    end

    test "is not confirmed while Explore owns an open blocking finding", %{scope: scope} do
      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          push_result!(run, registered, understood_result())
          event = raise_event(run, {@explore, "blocking", "The proposal is too wide"})
          {:ok, _answer} = post(run, registered.id, [event])
        end)

      assert %WorkItem{stage_state: :at_gate} = work_item

      assert {:error, {:open_blocking_findings, %{stage: "Explore"}}} =
               WorkItems.confirm(scope, work_item, 1)

      assert reload(work_item).stage_id == @explore
      fixed!(work_item)
      assert {:ok, _} = WorkItems.confirm(scope, work_item, 1)
    end
  end

  test "a gate none with an open blocking finding waits for a member's approval", %{scope: scope} do
    entry_process!(scope, "none")

    work_item =
      take_in!(scope)
      |> end_run!(raising([{@build, "blocking", "The total is wrong"}], "changes-requested"))

    assert %WorkItem{stage_id: @build, stage_state: :at_gate} = work_item

    refute Repo.exists?(
             from d in GateDecision,
               where: d.work_item_id == ^work_item.id and d.stage_id == ^@build
           )

    assert {:error, {:open_blocking_findings, %{findings: ["f1"]}}} = approve(scope, work_item)
    fixed!(work_item)
    assert {:ok, %WorkItem{stage_id: @release}} = approve(scope, work_item)
  end

  test "at a gate none, Run another round starts the run that closes the finding", ctx do
    entry_process!(ctx.scope, "none")

    work_item =
      take_in!(ctx.scope)
      |> end_run!(raising([{@build, "blocking", "The total is wrong"}], "changes-requested"))

    assert {:ok, work_item} =
             WorkItems.another_round(ctx.scope, work_item, newest_run(work_item).attempt, %{
               comment: "Fix the total."
             })

    assert %WorkItem{stage_id: @build, stage_state: :running} = reload(work_item)
    work_item = end_run!(work_item, closing([1], "passed"))
    assert %WorkItem{stage_id: @release} = work_item
  end

  describe "a move" do
    setup %{scope: scope} do
      loop_process!(scope, "person")

      work_item =
        take_in!(scope)
        |> end_run!(raising([{@build, "blocking", "The total is wrong"}], "changes-requested"))

      %{work_item: work_item}
    end

    test "forward is refused while the stage owns an open blocking finding", %{
      scope: scope,
      work_item: item
    } do
      assert {:error, {:open_blocking_findings, %{stage: "Build", findings: ["f1"]}}} =
               Stages.move(scope, item, @verify, nil, expect_stage: @build)

      assert Stages.starts(item, {:move, @verify}) == :none
      assert reload(item).stage_id == @build

      fixed!(item)

      assert {:ok, %WorkItem{stage_id: @verify}} =
               Stages.move(scope, item, @verify, nil, expect_stage: @build)
    end

    test "back is allowed", %{scope: scope, work_item: item} do
      fixed!(item)
      {:ok, item} = Stages.move(scope, item, @verify, nil, expect_stage: @build)

      item =
        end_run!(item, raising([{@verify, "blocking", "The page is blank"}], "changes-requested"))

      # The return took the work item to Build, so it is moved on and back again.
      assert %WorkItem{stage_id: @build} = item
      {:ok, item} = Stages.move(scope, item, @verify, nil, expect_stage: @build)
      assert [2] = Findings.open_blocking(item, @verify)

      assert {:ok, %WorkItem{stage_id: @build}} =
               Stages.move(scope, item, @build, nil, expect_stage: @verify)
    end
  end

  test "a finding of an earlier take in gates nothing", %{scope: scope} do
    loop_process!(scope)

    work_item =
      take_in!(scope)
      |> end_run!(raising([{@build, "blocking", "The total is wrong"}], "changes-requested"))

    {1, _} =
      Repo.update_all(from(f in Finding, where: f.work_item_id == ^work_item.id),
        set: [take_in: 0]
      )

    work_item =
      end_run!(work_item, fn run, _registered -> assert {:ok, _} = push_verdict(run, "passed") end)

    assert %WorkItem{stage_id: @verify} = work_item
  end

  test "a close of the findings lets the next run pass", %{scope: scope} do
    loop_process!(scope)

    work_item =
      take_in!(scope)
      |> end_run!(raising([{@build, "blocking", "The total is wrong"}], "changes-requested"))
      |> end_run!(closing([1], "passed"))

    assert %WorkItem{stage_id: @verify, stage_state: :running} = work_item
  end
end
