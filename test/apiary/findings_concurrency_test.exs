defmodule Apiary.FindingsConcurrencyTest do
  # Two writes of findings for one work item at the same time (`Apiary.Findings.post/3` and
  # Accept as it is), and an accept that dies in its transaction, on real transactions on
  # real connections: the sandbox would run them one after the other on one connection and
  # prove nothing. What the test commits goes with its organisation and its user when it
  # ends.
  use ExUnit.Case, async: false

  @before_compile Apiary.TestSetup

  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures
  import Ecto.Query

  alias Apiary.{Findings, Processes, Repo, Stages}
  alias Apiary.Findings.{Event, Finding}
  alias Apiary.Runs.Target
  alias Apiary.Stages.{Escalation, GateDecision}
  alias Apiary.WorkItems.WorkItem
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: [:factory, :workflow_model]

  # How long the second raise is given to show it waits for the lock.
  @blocked_ms 300

  @build "st_6ns22c4pav"
  @verify "st_m1mqbeywdg"

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    %{scope: scope, user: user} = sign_up_fixture()

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      # The findings and their events go with the organisation.
      Repo.delete_all(
        from o in Apiary.Organisations.Organisation, where: o.id == ^scope.organisation.id
      )

      Repo.delete_all(from n in Apiary.Nodes.Node, where: n.created_by_id == ^user.id)
      Repo.delete_all(from u in Apiary.Accounts.User, where: u.id == ^user.id)
      Sandbox.mode(Repo, :manual)
    end)

    # Build, a loop of 1 round with no gate, then Verify.
    {:ok, _version} =
      Processes.save(scope, scope.workspace, %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "stages" => [
          %{
            "id" => @build,
            "name" => "Build",
            "inputs" => [],
            "sequence" => [
              %{"loop" => %{"rounds" => 1, "body" => [%{"workflow" => "implement-changes"}]}}
            ],
            "outputs" => [],
            "gate" => %{"kind" => "none"}
          },
          %{
            "id" => "st_m1mqbeywdg",
            "name" => "Verify",
            "inputs" => [],
            "sequence" => [%{"workflow" => "verify-a-ticket"}],
            "outputs" => [],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          }
        ]
      })

    work_item = taken_in_fixture(scope)
    queued = newest_run(work_item)

    :ok =
      Target.insert_new(work_item.organisation_id, work_item.workspace_id, [
        WorkItem.target(work_item)
      ])

    %{
      scope: scope,
      work_item: work_item,
      run: %{run_id: Ecto.UUID.generate(), dispatch_run_id: queued.id},
      target_id: Target.dispatched_id(work_item.workspace_id, queued.id)
    }
  end

  defp raise_batch(ctx, severity \\ "blocking"),
    do: %{
      bases: [],
      events: [
        %{
          kind: "raise",
          by: "code-reviewer",
          ref: "r1",
          target_id: ctx.target_id,
          stage_id: @build,
          source_kind: "reviewer",
          source_name: "code-reviewer",
          severity: severity,
          place: %{"quote" => "total = price + tax"},
          point: "The tax is applied first",
          problem: "The tax is charged on the full price.",
          fix: "Subtract the discount first.",
          proof: "An order of 100.00 totals 110.00."
        }
      ]
    }

  # The work item at Build's round limit, with one blocking finding and one that is not.
  defp at_limit!(ctx) do
    work_item =
      end_run!(ctx.work_item, fn run, registered ->
        run = %{run_id: registered.id, dispatch_run_id: run.id}

        for severity <- ["blocking", "non-blocking"],
            do: {:ok, _answer} = Findings.post(ctx.work_item, run, raise_batch(ctx, severity))

        {:ok, _version} =
          Stages.Artifacts.push_json(
            {:run, newest_run(ctx.work_item)},
            Repo.get!(WorkItem, ctx.work_item.id),
            "verdict",
            %{"verdict" => "changes-requested"},
            stage_id: @build
          )
      end)

    assert %WorkItem{stage_id: @build, stage_state: :escalated} = work_item
    work_item
  end

  defp accept(ctx, work_item),
    do: Stages.resolve_escalation(ctx.scope, work_item, :accept, nil, expect_stage: @build)

  # The state of each finding of the work item and the kinds of its person events, by number.
  defp findings(work_item) do
    for finding <-
          Repo.all(from f in Finding, where: f.work_item_id == ^work_item.id, order_by: f.number) do
      {finding.number, finding.state,
       Repo.all(
         from e in Event,
           where: e.finding_id == ^finding.id and e.actor_kind == "person",
           select: {e.kind, e.user_id}
       )}
    end
  end

  test "an accept waits for a raise's lock and accepts the finding it raised", ctx do
    work_item = at_limit!(ctx)
    live = live_stage_run!(work_item, @build)
    run = %{run_id: Ecto.UUID.generate(), dispatch_run_id: live.id}
    test = self()

    # A blocking finding, raised and not committed: the work item stays locked.
    holder =
      Task.async(fn ->
        Repo.transact(fn ->
          result = Findings.post(work_item, run, raise_batch(ctx))
          send(test, {:held, result})

          receive do
            :commit -> result
          end
        end)
      end)

    assert_receive {:held, {:ok, %{created: [{"r1", "f3"}]}}}, 10_000

    accept = Task.async(fn -> accept(ctx, work_item) end)
    assert Task.yield(accept, @blocked_ms) == nil

    send(holder.pid, :commit)
    assert {:ok, _result} = Task.await(holder)
    assert {:ok, %WorkItem{stage_id: "st_m1mqbeywdg"}} = Task.await(accept, 10_000)

    accepted = [{"accepted", ctx.scope.user.id}]

    assert findings(work_item) ==
             for(number <- 1..3, do: {number, "accepted", accepted})
  end

  test "an approval waits for a raise's lock and is refused for the finding it raised", ctx do
    {:ok, work_item} = accept(ctx, at_limit!(ctx))

    work_item =
      end_run!(work_item, fn run, _registered ->
        {:ok, _version} =
          Stages.Artifacts.push_json(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "verdict",
            %{"verdict" => "passed"},
            stage_id: @verify
          )
      end)

    assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item
    live = live_stage_run!(work_item, @verify)
    run = %{run_id: Ecto.UUID.generate(), dispatch_run_id: live.id}
    batch = put_in(raise_batch(ctx), [:events, Access.at(0), :stage_id], @verify)
    test = self()

    # A blocking finding of Verify, raised and not committed: the work item stays locked.
    holder =
      Task.async(fn ->
        Repo.transact(fn ->
          result = Findings.post(work_item, run, batch)
          send(test, {:held, result})

          receive do
            :commit -> result
          end
        end)
      end)

    assert_receive {:held, {:ok, %{created: [{"r1", "f3"}]}}}, 10_000

    approve =
      Task.async(fn -> Stages.approve(ctx.scope, work_item, nil, expect_stage: @verify) end)

    assert Task.yield(approve, @blocked_ms) == nil

    send(holder.pid, :commit)
    assert {:ok, _result} = Task.await(holder)

    assert {:error, {:open_blocking_findings, %{stage_id: @verify, findings: ["f3"]}}} =
             Task.await(approve, 10_000)

    assert %WorkItem{stage_id: @verify, stage_state: :at_gate} =
             Repo.get!(WorkItem, work_item.id)
  end

  # The pool logs each connection that the dead processes held.
  @tag :capture_log
  test "an accept that fails in its transaction leaves no event and no stage change", ctx do
    work_item = at_limit!(ctx)
    before = findings(work_item)
    assert [{1, "open", []}, {2, "open", []}] = before

    # The write after which the accept dies: each event and state of the two findings, the
    # escalation's resolution, the stage's approval, its change and the trail's entry.
    for {source, command, count} <- [
          {"finding_events", "INSERT", 1},
          {"finding_events", "INSERT", 2},
          {"findings", "UPDATE", 2},
          {"escalations", "UPDATE", 1},
          {"gate_decisions", "INSERT", 1},
          {"work_items", "UPDATE", 1},
          {"audit_entries", "INSERT", 1}
        ] do
      dies_after(source, command, count, fn -> accept(ctx, work_item) end)

      # The lock waits until the database rolled the dead transaction back.
      held = Repo.one!(from w in WorkItem, where: w.id == ^work_item.id, lock: "FOR UPDATE")
      assert %WorkItem{stage_id: @build, stage_state: :escalated} = held
      assert findings(work_item) == before, "after #{command} #{source} #{count}"
      assert Repo.get_by!(Escalation, work_item_id: work_item.id).resolved_at == nil
      refute Repo.exists?(from d in GateDecision, where: d.work_item_id == ^work_item.id)
    end

    assert {:ok, %WorkItem{stage_id: "st_m1mqbeywdg"}} = accept(ctx, work_item)
    accepted = [{"accepted", ctx.scope.user.id}]
    assert findings(work_item) == [{1, "accepted", accepted}, {2, "accepted", accepted}]
  end

  # Runs `act` in a process that dies right after its query `count` that writes `source`
  # with `command`, as a machine that stops there.
  defp dies_after(source, command, count, act) do
    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :go -> act.()
        end
      end)

    handler = {__MODULE__, pid}
    seen = :counters.new(1, [])

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measures, meta, _config ->
        if self() == pid and meta.source == source and
             String.starts_with?(meta.query, command) do
          :counters.add(seen, 1, 1)
          if :counters.get(seen, 1) == count, do: Process.exit(pid, :kill)
        end
      end,
      nil
    )

    send(pid, :go)
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 10_000
    :telemetry.detach(handler)
    assert {reason, source, command, count} == {:killed, source, command, count}
  end

  test "a raise waits for the other's lock and takes the next number", ctx do
    test = self()

    # The first raise, written and not committed: the work item stays locked.
    holder =
      Task.async(fn ->
        Repo.transact(fn ->
          result = Findings.post(ctx.work_item, ctx.run, raise_batch(ctx))
          send(test, {:held, result})

          receive do
            :commit -> result
          end
        end)
      end)

    assert_receive {:held, {:ok, %{created: [{"r1", "f1"}]}}}, 10_000

    second = Task.async(fn -> Findings.post(ctx.work_item, ctx.run, raise_batch(ctx)) end)
    assert Task.yield(second, @blocked_ms) == nil

    send(holder.pid, :commit)
    assert {:ok, %{created: [{"r1", "f1"}]}} = Task.await(holder)
    assert {:ok, %{created: [{"r1", "f2"}]}} = Task.await(second)

    assert Findings.open_blocking(Repo.get!(WorkItem, ctx.work_item.id), @build) ==
             [1, 2]
  end
end
