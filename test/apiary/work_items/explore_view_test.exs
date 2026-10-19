defmodule Apiary.WorkItems.ExploreViewTest do
  # Explore for one work item as the work item pages draw it (`Apiary.WorkItems.explore/3`)
  # and what happened there, in order, for the Thread (`explore_thread/3`): from its runs,
  # their results, the answers and the confirmation; nothing to a person who may not read
  # the work item.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.WorkItems.WorkItemEvent

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, work_item: work_item_fixture(scope)}
  end

  defp ago(now, minutes), do: DateTime.add(now, -minutes * 60, :second)

  # A registered run that started and ended `from` and `to` minutes before `now`.
  defp timed(now, from, to) do
    %{
      started_at: ago(now, from),
      exited_at: ago(now, to),
      outcome_time: ago(now, to),
      outcome_received_at: ago(now, to)
    }
  end

  defp at!(work_item, kind, at) do
    Repo.update_all(
      from(e in WorkItemEvent, where: e.work_item_id == ^work_item.id and e.kind == ^kind),
      set: [at: at]
    )
  end

  describe "explore/3" do
    test "a run that asked: its questions by position, then answered, its answers and who gave them",
         ctx do
      asked =
        Map.put(
          questions_result(),
          "understanding",
          "The basket keeps the price from before the sale."
        )

      %{run: run} = explore_run_fixture(ctx.work_item, result: asked)

      assert %{
               status: :questions,
               stage: nil,
               take_in: 1,
               run: %{
                 id: "rn_" <> _,
                 attempt: 1,
                 of: 3,
                 state: :completed,
                 place: :questions,
                 outcome: :questions,
                 proposal: nil,
                 understanding: "The basket keeps the price from before the sale.",
                 questions: [
                   %{public_id: "1", text: "Which basket?", answer: nil},
                   %{public_id: "2", text: "Which sale?", answer: nil}
                 ],
                 answered_by_id: nil
               },
               earlier_runs: [],
               earlier_take_ins: [],
               answers_by_ids: [],
               confirmed_by_id: nil,
               changes: %{}
             } = WorkItems.explore(ctx.scope, ctx.work_item)

      {:ok, answered} =
        WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => "At checkout.", "2" => "Spring."})

      user_id = ctx.scope.user.id
      run_id = run.public_id

      assert %{
               status: :queued,
               run: %{id: nil, attempt: 2, place: :queued, state: nil},
               earlier_runs: [
                 %{
                   id: ^run_id,
                   questions: [%{answer: "At checkout."}, %{answer: "Spring."}],
                   answered_by_id: ^user_id,
                   answered_at: %DateTime{}
                 }
               ],
               answers_by_ids: [^user_id]
             } = WorkItems.explore(ctx.scope, answered)
    end

    test "a confirmed proposal waits for Shape, read from its confirmation with the changes",
         ctx do
      %{run: run} = explore_run_fixture(ctx.work_item, result: understood_result())

      assert %{status: :confirm, run: %{place: :proposal, proposal: %{approach: approach}}} =
               WorkItems.explore(ctx.scope, ctx.work_item)

      assert approach == "Read the price from the catalogue each time."

      form = %{
        "complexity" => %{"level" => "standard", "reason" => "Two screens read the price."},
        "understanding" => "The basket keeps the price from before the sale.",
        "scope_in" => "Read the sale price in the basket",
        "scope_out" => "The invoice",
        "approach" => "Keep the price on the line."
      }

      {:ok, confirmed} = WorkItems.confirm(ctx.scope, ctx.work_item, 1, form)

      # The run's events pruned, its proposal is still the one confirmed.
      Repo.delete_all(from e in Apiary.Runs.Event, where: e.run_id == ^run.id)
      user_id = ctx.scope.user.id

      assert %{
               status: :shape,
               run: %{place: :proposal, outcome: :proposal, proposal: %{approach: ^approach}},
               confirmed_by_id: ^user_id,
               confirmed_at: %DateTime{},
               changes: %{approach: %{value: "Keep the price on the line.", by_id: ^user_id}}
             } = WorkItems.explore(ctx.scope, confirmed)
    end

    test "an ended work item: its state, and the stage its end recorded", ctx do
      explore_run_fixture(ctx.work_item, result: understood_result())
      {:ok, declined} = WorkItems.decline(ctx.scope, ctx.work_item)
      assert %{status: :declined, stage: :confirm} = WorkItems.explore(ctx.scope, declined)

      other = work_item_fixture(ctx.scope, external_ref: "acme/shop#14")
      explore_run_fixture(other, result: understood_result())
      {:ok, _confirmed} = WorkItems.confirm(ctx.scope, other, 1)
      {:ok, closed} = WorkItems.close(ctx.scope, other)
      assert %{status: :closed, stage: :shape} = WorkItems.explore(ctx.scope, closed)
    end

    test "the take ins before the current one, each with how it ended and its runs" do
      %{scope: scope} = sign_up_fixture()
      ticket = backlog_ticket_fixture(scope, connection: ticket_connection_fixture(scope))
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

      Repo.update_all(from(r in DispatchRun, where: r.work_item_id == ^work_item.id),
        set: [state: :ended, end_cause: :run_ended]
      )

      {:ok, _declined} = WorkItems.decline(scope, work_item)

      {:ok, again} =
        WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

      user_id = scope.user.id

      assert %{
               status: :queued,
               take_in: 2,
               run: %{attempt: 1, place: :queued},
               earlier_runs: [],
               earlier_take_ins: [
                 %{
                   take_in: 1,
                   taken_in_by_id: ^user_id,
                   ended: :declined,
                   ended_by_id: ^user_id,
                   ended_at: %DateTime{},
                   runs: [%{id: nil, attempt: 1, of: 3, state: :failed}]
                 }
               ]
             } = WorkItems.explore(scope, again)
    end

    test "nothing to a person who may not read it, or of another workspace", ctx do
      %{scope: stranger} = sign_up_fixture()
      assert WorkItems.explore(stranger, ctx.work_item) == nil
      assert WorkItems.explore_thread(stranger, ctx.work_item) == []

      elsewhere = workspace_scope(ctx.scope.user, workspace_fixture(ctx.scope.organisation))
      assert WorkItems.explore(elsewhere, ctx.work_item) == nil
      assert WorkItems.explore_thread(elsewhere, ctx.work_item) == []
    end

    test "another organisation's work item, its struct changed to name this workspace: nothing",
         ctx do
      %{scope: other} = sign_up_fixture()
      theirs = work_item_fixture(other)
      explore_run_fixture(theirs, result: questions_result(["Which basket?"]))
      {:ok, theirs} = WorkItems.answer(other, theirs, 1, %{"1" => "Their answer."})

      forged = %{
        theirs
        | organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id
      }

      assert WorkItems.explore(ctx.scope, forged) == nil
      assert WorkItems.explore_thread(ctx.scope, forged) == []
    end

    test "a work item that has since moved to another workspace: nothing from the old struct",
         ctx do
      explore_run_fixture(ctx.work_item, result: questions_result(["Which basket?"]))
      {:ok, answered} = WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => "At checkout."})
      there = workspace_fixture(ctx.scope.organisation)

      {1, _} =
        Repo.update_all(from(w in Apiary.WorkItems.WorkItem, where: w.id == ^answered.id),
          set: [workspace_id: there.id]
        )

      assert WorkItems.explore(ctx.scope, answered) == nil
      assert WorkItems.explore_thread(ctx.scope, answered) == []

      # Read in the workspace it is in now, it is drawn as the database holds it.
      assert %{take_in: 1} = WorkItems.explore(workspace_scope(ctx.scope.user, there), answered)
    end

    test "an id that is not a UUID, or none: nothing, and no raise", ctx do
      for id <- ["wi_0000000000000000", "not-a-uuid", nil] do
        work_item = %{ctx.work_item | id: id}
        assert WorkItems.explore(ctx.scope, work_item) == nil
        assert WorkItems.explore_thread(ctx.scope, work_item) == []
      end
    end

    test "the row is drawn as the database holds it, not as the struct says", ctx do
      explore_run_fixture(ctx.work_item, result: understood_result())
      stale = %{ctx.work_item | take_in: 7, state: :closed}

      assert %{status: :confirm, take_in: 1, stage: nil} = WorkItems.explore(ctx.scope, stale)
    end
  end

  describe "explore_thread/3" do
    test "the take in, each run's start and end, the answers and the confirmation, in order",
         ctx do
      now = DateTime.utc_now()
      item = ctx.work_item

      %{run: first} =
        explore_run_fixture(item,
          result: questions_result(["Which basket?"]),
          run: timed(now, 9, 8)
        )

      {:ok, _} = WorkItems.answer(ctx.scope, item, 1, %{"1" => "At checkout."})

      # The run the answers queued, as it ran.
      Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^item.id and r.attempt == 2)

      %{run: second} =
        explore_run_fixture(item, attempt: 2, result: understood_result(), run: timed(now, 6, 5))

      {:ok, _} = WorkItems.confirm(ctx.scope, item, 2)

      at!(item, :taken_in, ago(now, 10))
      at!(item, :answered, ago(now, 7))
      at!(item, :confirmed, ago(now, 4))

      user_id = ctx.scope.user.id
      here = ctx.scope.workspace.id
      first_ref = %{id: first.public_id, workspace_id: here, attempt: 1, of: 3}
      second_ref = %{id: second.public_id, workspace_id: here, attempt: 2, of: 3}
      first_instruction = item.first_instruction

      assert [
               %{
                 kind: :taken_in,
                 actor_id: ^user_id,
                 take_in: 1,
                 again: false,
                 owner_id: ^user_id
               } = taken_in,
               %{kind: :started, run: ^first_ref, start: nil},
               %{
                 kind: :asked,
                 run: ^first_ref,
                 duration_ms: 60_000,
                 questions: [%{public_id: "1", text: "Which basket?", answer: "At checkout."}]
               },
               %{
                 kind: :answered,
                 actor_id: ^user_id,
                 run: ^first_ref,
                 questions: [%{public_id: "1", text: "Which basket?", answer: "At checkout."}]
               },
               %{kind: :started, run: ^second_ref, start: :answers},
               %{kind: :proposed, run: ^second_ref, duration_ms: 60_000, owner_id: ^user_id},
               %{kind: :confirmed, actor_id: ^user_id, changed: false}
             ] = WorkItems.explore_thread(ctx.scope, item, now)

      assert taken_in.first_instruction == first_instruction
    end

    test "a run asked to run again, one without a result, and the stage a decline recorded",
         ctx do
      now = DateTime.utc_now()
      item = ctx.work_item
      %{run: first} = explore_run_fixture(item, run: timed(now, 9, 8))
      {:ok, _} = WorkItems.explore_again(ctx.scope, item, 1)
      second = Repo.get_by!(DispatchRun, work_item_id: item.id, attempt: 2)

      Repo.update_all(from(r in DispatchRun, where: r.id == ^second.id),
        set: [state: :ended, end_cause: :run_ended]
      )

      {:ok, declined} = WorkItems.decline(ctx.scope, item)

      at!(item, :taken_in, ago(now, 10))
      at!(item, :explore_again, ago(now, 7))
      at!(item, :declined, ago(now, 1))

      Repo.update_all(from(r in DispatchRun, where: r.id == ^second.id),
        set: [updated_at: ago(now, 2)]
      )

      first_ref = %{id: first.public_id, workspace_id: ctx.scope.workspace.id, attempt: 1, of: 3}

      assert [
               %{kind: :taken_in},
               %{kind: :started, run: ^first_ref, start: nil},
               %{kind: :no_result, run: ^first_ref, outcome: :none},
               %{kind: :explore_again, run: %{id: nil, attempt: 2, of: 3}},
               %{kind: :no_result, run: %{id: nil, attempt: 2}},
               %{kind: :declined, stage: :explore}
             ] = WorkItems.explore_thread(ctx.scope, declined, now)
    end

    test "a run that has not ended has no entry at its end", ctx do
      explore_run_fixture(ctx.work_item, state: :handed_over)
      at!(ctx.work_item, :taken_in, ago(DateTime.utc_now(), 10))

      assert [%{kind: :taken_in}, %{kind: :started, start: nil}] =
               WorkItems.explore_thread(ctx.scope, ctx.work_item)
    end
  end

  describe "what the work item page draws beside where Explore stands" do
    test "each run names the workspace it was queued in, which stays when its work item moves, and how long it took",
         ctx do
      now = DateTime.utc_now()
      here = ctx.scope.workspace.id
      explore_run_fixture(ctx.work_item, result: understood_result(), run: timed(now, 9, 8))

      assert %{run: %{workspace_id: ^here, duration_ms: 60_000}} =
               WorkItems.explore(ctx.scope, ctx.work_item, now)

      there = workspace_fixture(ctx.scope.organisation)

      Repo.update_all(from(w in Apiary.WorkItems.WorkItem, where: w.id == ^ctx.work_item.id),
        set: [workspace_id: there.id]
      )

      elsewhere = workspace_scope(ctx.scope.user, there)

      assert %{run: %{workspace_id: ^here}} = WorkItems.explore(elsewhere, ctx.work_item, now)

      assert %{run: %{workspace_id: ^here}} =
               Enum.find(
                 WorkItems.explore_thread(elsewhere, ctx.work_item, now),
                 &(&1.kind == :started)
               )
    end

    test "a run not ended has no duration yet", ctx do
      explore_run_fixture(ctx.work_item, state: :handed_over)

      assert %{run: %{duration_ms: nil, ended_at: nil, end_cause: nil}} =
               WorkItems.explore(ctx.scope, ctx.work_item)
    end

    test "each run has the end cause of its run of the queue, as its handover or its outcome wrote it",
         ctx do
      for {cause, n} <- Enum.with_index([:variables_invalid, :ticket_gone, :inputs_invalid], 20) do
        work_item = work_item_fixture(ctx.scope, external_ref: "acme/shop##{n}")
        explore_run_fixture(work_item, end_cause: cause)

        assert %{run: %{id: nil, place: :no_result, outcome: :error, end_cause: ^cause}} =
                 WorkItems.explore(ctx.scope, work_item)

        explore_run_fixture(work_item, result: understood_result())

        assert %{run: %{end_cause: :run_ended}, earlier_runs: [%{end_cause: ^cause}]} =
                 WorkItems.explore(ctx.scope, work_item)
      end
    end

    test "a take in again: how the work item had ended, the owner of each take in, and the earlier take in's runs as they were drawn" do
      %{scope: scope} = sign_up_fixture()
      %{user: member} = member_fixture(scope)
      ticket = backlog_ticket_fixture(scope, connection: ticket_connection_fixture(scope))
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)

      %{run: asked} =
        explore_run_fixture(work_item, attempt: 1, result: questions_result(["Which basket?"]))

      {:ok, answered} = WorkItems.answer(scope, work_item, 1, %{"1" => "At checkout."})

      Repo.update_all(from(r in DispatchRun, where: r.work_item_id == ^work_item.id),
        set: [state: :ended, end_cause: :run_ended]
      )

      {:ok, declined} = WorkItems.decline(scope, answered)
      assert %{previous: nil} = WorkItems.explore(scope, declined)

      {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: member.id})
      user_id = scope.user.id
      member_id = member.id
      asked_id = asked.public_id

      assert %{
               previous: :declined,
               earlier_take_ins: [
                 %{
                   take_in: 1,
                   ended: :declined,
                   ended_reason: nil,
                   runs: [
                     %{
                       id: ^asked_id,
                       outcome: :questions,
                       questions: [%{public_id: "1", answer: "At checkout."}],
                       answered_by_id: ^user_id
                     },
                     %{attempt: 2, state: :failed}
                   ]
                 }
               ]
             } = WorkItems.explore(scope, again)

      assert [
               %{take_in: 1, owner_id: ^user_id},
               %{take_in: 2, again: true, owner_id: ^member_id}
             ] =
               for(
                 %{kind: :taken_in} = entry <- WorkItems.explore_thread(scope, again),
                 do: entry
               )
    end

    test "a take in again undone gave its owner back, and no record keeps the one it had" do
      %{scope: scope} = sign_up_fixture()
      %{user: member} = member_fixture(scope)
      ticket = backlog_ticket_fixture(scope, connection: ticket_connection_fixture(scope))
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

      Repo.update_all(from(r in DispatchRun, where: r.work_item_id == ^work_item.id),
        set: [state: :ended, end_cause: :run_ended]
      )

      {:ok, _declined} = WorkItems.decline(scope, work_item)
      {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: member.id})
      {:ok, undone} = WorkItems.undo(scope, again)
      user_id = scope.user.id

      assert %{status: :declined} = WorkItems.explore(scope, undone)

      assert [%{take_in: 1, owner_id: ^user_id}, %{take_in: 2, owner_id: nil}] =
               for(
                 %{kind: :taken_in} = entry <- WorkItems.explore_thread(scope, undone),
                 do: entry
               )
    end

    test "a close by the instance names its reason; a person's close names none", ctx do
      explore_run_fixture(ctx.work_item, result: understood_result())
      closed = instance_close!(ctx.work_item, "adapter_removed")

      assert %{
               status: :closed,
               stage: :confirm,
               ended_reason: "adapter_removed",
               ended_by_id: nil,
               ended_at: %DateTime{}
             } = WorkItems.explore(ctx.scope, closed)

      assert %{kind: :closed, actor_id: nil, reason: "adapter_removed"} =
               List.last(WorkItems.explore_thread(ctx.scope, closed))

      other = work_item_fixture(ctx.scope, external_ref: "acme/shop#14")
      {:ok, by_person} = WorkItems.close(ctx.scope, other)
      user_id = ctx.scope.user.id

      assert %{ended_reason: nil, ended_by_id: ^user_id, ended_at: %DateTime{}} =
               WorkItems.explore(ctx.scope, by_person)

      live = work_item_fixture(ctx.scope, external_ref: "acme/shop#15")
      assert %{ended_by_id: nil, ended_at: nil} = WorkItems.explore(ctx.scope, live)

      assert %{kind: :closed, reason: nil} =
               List.last(WorkItems.explore_thread(ctx.scope, by_person))
    end
  end

  # `work_item` closed by the instance, for `reason`, as the removal of an adapter closes
  # one (`Apiary.WorkItems.close_locked/3`).
  defp instance_close!(work_item, reason) do
    {:ok, _queues} =
      Repo.transact(fn ->
        locked =
          Repo.one!(
            from w in Apiary.WorkItems.WorkItem, where: w.id == ^work_item.id, lock: "FOR UPDATE"
          )

        WorkItems.close_locked([locked], {:instance, reason}, DateTime.utc_now())
      end)

    Repo.get!(Apiary.WorkItems.WorkItem, work_item.id)
  end
end
