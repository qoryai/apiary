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
  alias Apiary.Explore.Questions
  alias Apiary.Harnesses.RunHarness
  alias Apiary.WorkItems.{Explore, ExploreView, WorkItemEvent}

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
    test "a run's recommended option has recommended true, the others false", ctx do
      asked =
        questions_result([
          %{
            "question" => "Which basket?",
            "options" => [
              %{"title" => "At checkout", "explanation" => "The page reads it."},
              %{"title" => "On the shop", "explanation" => "Why.", "recommended" => true},
              %{"title" => "In the mail", "explanation" => "Why not.", "recommended" => false}
            ]
          }
        ])

      explore_run_fixture(ctx.work_item, result: asked)
      explore = WorkItems.explore(ctx.scope, ctx.work_item)

      marks = fn question -> Enum.map(question.options, &{&1.title, &1.recommended}) end

      expected = [{"At checkout", false}, {"On the shop", true}, {"In the mail", false}]

      # The questions the page draws (`questions_frame`), and the run's questions.
      assert [question] = explore.questions
      assert marks.(question) == expected

      assert [question] = explore.run.questions
      assert marks.(question) == expected
    end

    test "a run with questions: its questions by position, then answered, its answers and who gave them",
         ctx do
      asked =
        questions_result([
          %{
            "question" => "Which basket?",
            "options" => [%{"title" => "At checkout", "explanation" => "The page reads it."}]
          },
          "Which sale?"
        ])

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
                 version: nil,
                 questions: [
                   %{
                     public_id: "1",
                     text: "Which basket?",
                     options: [
                       %{
                         title: "At checkout",
                         explanation: "The page reads it.",
                         recommended: false
                       }
                     ],
                     answer: nil,
                     custom: nil
                   },
                   %{public_id: "2", text: "Which sale?", options: [], answer: nil, custom: nil}
                 ],
                 answered_by_id: nil
               },
               earlier_runs: [],
               earlier_take_ins: [],
               answers_by_ids: [],
               confirmed_by_id: nil,
               review_comments: []
             } = WorkItems.explore(ctx.scope, ctx.work_item)

      {:ok, answered} =
        WorkItems.answer(ctx.scope, ctx.work_item, 1, %{
          "1" => %{"option" => "At checkout"},
          "2" => "Spring."
        })

      user_id = ctx.scope.user.id
      run_id = run.public_id

      assert %{
               status: :queued,
               run: %{id: nil, attempt: 2, place: :queued, state: nil},
               earlier_runs: [
                 %{
                   id: ^run_id,
                   questions: [
                     %{answer: "At checkout", custom: false},
                     %{answer: "Spring.", custom: true}
                   ],
                   answered_by_id: ^user_id,
                   answered_at: %DateTime{}
                 }
               ],
               answers_by_ids: [^user_id]
             } = WorkItems.explore(ctx.scope, answered)
    end

    test "a confirmed proposal waits for Shape, read from its confirmation", ctx do
      %{run: run} = explore_run_fixture(ctx.work_item, result: understood_result())
      message = understood_result()["message"]

      assert %{
               status: :confirm,
               run: %{place: :proposal, proposal: %{message: ^message}, version: 1}
             } = WorkItems.explore(ctx.scope, ctx.work_item)

      {:ok, confirmed} = WorkItems.confirm(ctx.scope, ctx.work_item, 1)

      # The run's events pruned, its proposal is still the one confirmed.
      Repo.delete_all(from e in Apiary.Runs.Event, where: e.run_id == ^run.id)
      user_id = ctx.scope.user.id

      assert %{
               status: :shape,
               run: %{place: :proposal, outcome: :proposal, proposal: %{message: ^message}},
               confirmed_by_id: ^user_id,
               confirmed_at: %DateTime{},
               review_comments: []
             } = WorkItems.explore(ctx.scope, confirmed)
    end

    test "an ended work item: its state, and the stage its end recorded", ctx do
      explore_run_fixture(ctx.work_item, result: understood_result())
      {:ok, at_confirm} = WorkItems.close(ctx.scope, ctx.work_item)
      assert %{status: :closed, stage: :confirm} = WorkItems.explore(ctx.scope, at_confirm)

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

      {:ok, _closed} = WorkItems.close(scope, work_item)

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
                   ended: :closed,
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

    test "a harness walk that could not reach an adapter names it by its title, else by the name the walk kept",
         ctx do
      adapter =
        Apiary.NodesFixtures.adapter_fixture(%{
          name: "tracker-#{System.unique_integer([:positive])}"
        })

      %{dispatch_run: dispatch_run} =
        explore_run_fixture(ctx.work_item, end_cause: :harness_unresolved)

      walk =
        Repo.insert!(%RunHarness{
          dispatch_run_id: dispatch_run.id,
          state: :failed,
          failure: "adapter_unavailable",
          failure_adapter: adapter.name,
          failure_adapter_id: adapter.id
        })

      adapter_shown = fn ->
        %{run: %{harness_failure: %{adapter: shown}}} =
          WorkItems.explore(ctx.scope, ctx.work_item)

        shown
      end

      # No title yet: the adapter's name.
      assert adapter_shown.() == adapter.name

      Apiary.NodesFixtures.describe_title(adapter, "Acme Tracker")
      assert adapter_shown.() == "Acme Tracker"

      # A walk kept before the adapter was, or once its row is gone: the name it kept.
      walk |> Ecto.Changeset.change(failure_adapter_id: nil) |> Repo.update!()
      assert adapter_shown.() == adapter.name
    end

    test "a read-only run qory closed: the reason, on a pool that is not the instance's", ctx do
      node_run = fn node ->
        %{
          state: "failed",
          exit_state: "failed",
          reason: "read_needs_wall",
          node_id: node && node.id,
          outcome_state: nil,
          outcome_time: nil,
          outcome_received_at: nil,
          outcome_digest: nil
        }
      end

      %{run: run} = explore_run_fixture(ctx.work_item, run: node_run.(nil))

      assert %{run: %{read_needs: facts}} = WorkItems.explore(ctx.scope, ctx.work_item)
      assert facts == %{code: "read_needs_wall", installed: false}

      pool = Apiary.NodesFixtures.pool_fixture(ctx.scope)
      run |> Ecto.Changeset.change(node_id: pool.id) |> Repo.update!()

      assert %{run: %{read_needs: %{code: "read_needs_wall", installed: false}}} =
               WorkItems.explore(ctx.scope, ctx.work_item)
    end

    test "any other run has no read_needs", ctx do
      explore_run_fixture(ctx.work_item, run: %{state: "failed", reason: "no_longer_needed"})

      assert %{run: %{read_needs: nil}} = WorkItems.explore(ctx.scope, ctx.work_item)
    end

    test "a run whose harness has no skill for its workflow: the workflow and the harness file of the target",
         ctx do
      failed = %{
        state: "failed",
        exit_state: "failed",
        reason: "workflow_not_in_harness",
        outcome_state: nil,
        outcome_time: nil,
        outcome_received_at: nil,
        outcome_digest: nil
      }

      %{dispatch_run: dispatch_run} = explore_run_fixture(ctx.work_item, run: failed)

      Repo.insert!(%RunHarness{
        dispatch_run_id: dispatch_run.id,
        state: :resolved,
        origin: :file,
        workflow: "explore-a-ticket"
      })

      assert %{run: %{workflow_gap: gap}} = WorkItems.explore(ctx.scope, ctx.work_item)
      assert gap == %{workflow: "explore-a-ticket", source: {:target, "acme/shop"}}

      # Any other reason: no gap.
      Repo.update_all(from(r in Apiary.Runs.Run, where: r.dispatch_run_id == ^dispatch_run.id),
        set: [reason: "no_session"]
      )

      assert %{run: %{workflow_gap: nil}} = WorkItems.explore(ctx.scope, ctx.work_item)
    end

    test "a question reopened twice: the run map of each run that wrote or reopened it counts it in `asked` and lists it in `questions`, with the answer given at that run",
         ctx do
      item = reopened_twice!(ctx.scope, ctx.work_item)
      %{earlier_runs: earlier, run: latest} = WorkItems.explore(ctx.scope, item)

      assert for(run <- earlier ++ [latest], do: {run.attempt, run.asked, frame(run)}) == [
               {1, 1, [{"Which basket?", "The main one"}]},
               {2, 1, [{"Which basket?", "The other one"}]},
               {3, 1, [{"Which basket?", nil}]}
             ]
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

      first_ref = %{
        id: first.public_id,
        number: first.number,
        workspace_id: here,
        stage_id: nil,
        attempt: 1,
        of: 3
      }

      second_ref = %{
        id: second.public_id,
        number: second.number,
        workspace_id: here,
        stage_id: nil,
        attempt: 2,
        of: 3
      }

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

    test "a run that wrote a proposal while an earlier run's question stays open: a proposal with no owner",
         ctx do
      now = DateTime.utc_now()
      item = ctx.work_item

      explore_run_fixture(item,
        result: questions_result(["Which basket?", "Which sale?"]),
        run: timed(now, 9, 8)
      )

      {:ok, _} = WorkItems.answer(ctx.scope, item, 1, %{"1" => "At checkout."})
      Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^item.id and r.attempt == 2)

      %{run: second} =
        explore_run_fixture(item, attempt: 2, result: understood_result(), run: timed(now, 6, 5))

      # The second question, which the first run asked, is still open.
      assert %{status: :questions} = WorkItems.explore(ctx.scope, item)

      entries =
        for %{run: %{id: id}} = entry <- WorkItems.explore_thread(ctx.scope, item, now),
            id == second.public_id,
            do: Map.take(entry, [:kind, :owner_id])

      assert entries == [%{kind: :started}, %{kind: :proposed, owner_id: nil}]
    end

    test "a run that wrote neither a proposal nor a question while an earlier run's question stays open: no result",
         ctx do
      now = DateTime.utc_now()
      item = ctx.work_item

      explore_run_fixture(item,
        result: questions_result(["Which basket?", "Which sale?"]),
        run: timed(now, 9, 8)
      )

      {:ok, _} = WorkItems.answer(ctx.scope, item, 1, %{"1" => "At checkout."})
      Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^item.id and r.attempt == 2)
      %{run: second} = explore_run_fixture(item, attempt: 2, run: timed(now, 6, 5))

      # The second question, which the first run asked, is still open, so the run waits.
      assert %{status: :questions} = WorkItems.explore(ctx.scope, item)

      entries =
        for %{run: %{id: id}} = entry <- WorkItems.explore_thread(ctx.scope, item, now),
            id == second.public_id,
            do: Map.take(entry, [:kind, :outcome, :wrote])

      assert entries == [%{kind: :started}, %{kind: :no_result, outcome: :none, wrote: nil}]
    end

    test "a waiting run that wrote a question while an earlier run's question stays open: only its question",
         ctx do
      now = DateTime.utc_now()
      item = ctx.work_item

      explore_run_fixture(item,
        result: questions_result(["Which basket?", "Which sale?"]),
        run: timed(now, 9, 8)
      )

      {:ok, _} = WorkItems.answer(ctx.scope, item, 1, %{"1" => "At checkout."})
      Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^item.id and r.attempt == 2)

      %{run: second} =
        explore_run_fixture(item,
          attempt: 2,
          result: questions_result(["Which price?"]),
          run: timed(now, 6, 5)
        )

      # The first run's second question and the second run's question are open.
      assert %{status: :questions} = WorkItems.explore(ctx.scope, item)

      asked =
        for %{kind: :asked, run: %{id: id}} = entry <-
              WorkItems.explore_thread(ctx.scope, item, now),
            id == second.public_id,
            do: Enum.map(entry.questions, &{&1.public_id, &1.text, &1.answer})

      assert asked == [[{"1", "Which price?", nil}]]
    end

    test "a question reopened twice: the Thread line of each run that reopened it lists it, with the answer given at that run",
         ctx do
      item = reopened_twice!(ctx.scope, ctx.work_item)

      ends =
        for %{kind: kind, run: %{attempt: attempt}} = entry <-
              WorkItems.explore_thread(ctx.scope, item),
            kind in [:asked, :proposed, :no_result],
            do:
              {attempt, kind,
               entry[:questions] && Enum.map(entry.questions, &{&1.text, &1.answer})}

      assert Enum.sort(ends) == [
               {1, :asked, [{"Which basket?", "The main one"}]},
               {2, :asked, [{"Which basket?", "The other one"}]},
               {3, :asked, [{"Which basket?", nil}]}
             ]
    end

    test "a run asked to run again, one without a result, and the stage a close recorded",
         ctx do
      now = DateTime.utc_now()
      item = ctx.work_item
      %{run: first} = explore_run_fixture(item, run: timed(now, 9, 8))
      {:ok, _} = WorkItems.explore_again(ctx.scope, item, 1)
      second = Repo.get_by!(DispatchRun, work_item_id: item.id, attempt: 2)

      # Ended by its exit and settled with nothing pushed (`Apiary.Dispatches.Settle`).
      Repo.update_all(from(r in DispatchRun, where: r.id == ^second.id),
        set: [state: :ended, end_cause: :run_ended, result_outcome: :none]
      )

      {:ok, closed} = WorkItems.close(ctx.scope, item)

      at!(item, :taken_in, ago(now, 10))
      at!(item, :explore_again, ago(now, 7))
      at!(item, :closed, ago(now, 1))

      Repo.update_all(from(r in DispatchRun, where: r.id == ^second.id),
        set: [updated_at: ago(now, 2)]
      )

      first_ref = %{
        id: first.public_id,
        number: first.number,
        workspace_id: ctx.scope.workspace.id,
        stage_id: nil,
        attempt: 1,
        of: 3
      }

      assert [
               %{kind: :taken_in},
               %{kind: :started, run: ^first_ref, start: nil},
               %{kind: :no_result, run: ^first_ref, outcome: :none},
               %{kind: :explore_again, run: %{id: nil, attempt: 2, of: 3}},
               %{kind: :no_result, run: %{id: nil, attempt: 2}},
               %{kind: :closed, stage: :explore}
             ] = WorkItems.explore_thread(ctx.scope, closed, now)
    end

    test "a run that has not ended has no entry at its end", ctx do
      explore_run_fixture(ctx.work_item, state: :handed_over)
      at!(ctx.work_item, :taken_in, ago(DateTime.utc_now(), 10))

      assert [%{kind: :taken_in}, %{kind: :started, start: nil}] =
               WorkItems.explore_thread(ctx.scope, ctx.work_item)
    end
  end

  describe "a version of the proposal (Explore.proposal/2)" do
    @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0>>
    @svg ~s(<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>)

    test "is its Markdown file's text, its id and its images, never sources.json", ctx do
      # The run's end kept version 1; a run that ended pushes nothing, so a person adds
      # version 2.
      explore_run_fixture(ctx.work_item, result: understood_result())

      files = [
        %{filename: "a-cart.png", content_type: "image/png", binary: @png},
        %{filename: "proposal.md", content_type: "text/markdown", binary: "# Gift cards\n"},
        %{filename: "checkout.svg", content_type: "image/svg+xml", binary: @svg},
        %{filename: "sources.json", content_type: "application/json", binary: ~s({"sources":[]})}
      ]

      {:ok, version} =
        Apiary.Artifacts.push({:person, ctx.scope}, ctx.work_item, "proposal", files)

      assert version.number == 2
      version_id = version.public_id

      assert %{text: "# Gift cards\n", version_id: ^version_id, images: images} =
               Explore.proposal(ctx.work_item.id, 2)

      assert images == ["a-cart.png", "checkout.svg"]

      assert %{text: "## What this is\n" <> _, images: []} =
               Explore.proposal(ctx.work_item.id, 1)

      assert Explore.proposal(ctx.work_item.id, 3) == nil
      assert Explore.proposal(ctx.work_item.id, nil) == nil
    end
  end

  describe "the store reads of the Explore tab" do
    # What `fun` returned, and the files `Apiary.Artifacts.open_file/1` opened in this
    # process while it ran, oldest first, each an `Apiary.Artifacts.ArtifactFile`. The
    # trace pattern stays set after the call: only a traced process sends trace
    # messages, and another test may trace the same function at the same time.
    defp opened(fun) do
      me = self()
      mfa = {Apiary.Artifacts, :open_file, 1}
      collector = spawn_link(fn -> collect(me, []) end)
      Code.ensure_loaded!(Apiary.Artifacts)
      assert :erlang.trace_pattern(mfa, true, [:local]) > 0
      :erlang.trace(me, true, [:call, {:tracer, collector}])

      try do
        result = fun.()
        {result, collected(me, collector)}
      after
        :erlang.trace(me, false, [:call])
      end
    end

    defp collected(me, collector) do
      ref = :erlang.trace_delivered(me)
      receive do: ({:trace_delivered, ^me, ^ref} -> :ok)
      send(collector, {:done, me})
      receive do: ({:opened, files} -> files)
    end

    defp collect(me, files) do
      receive do
        {:trace, ^me, :call, {Apiary.Artifacts, :open_file, [file]}} ->
          collect(me, [file | files])

        {:done, ^me} ->
          send(me, {:opened, Enum.reverse(files)})
      end
    end

    defp markdown(files),
      do: Enum.filter(files, &String.starts_with?(&1.content_type, "text/markdown"))

    test "three runs that each wrote a proposal: the newest one's text is read once; opening an earlier run's fold reads its text once",
         ctx do
      for n <- 1..3 do
        message = "Version #{n} of #{System.unique_integer([:positive])}."
        explore_run_fixture(ctx.work_item, result: understood_result(%{"message" => message}))
      end

      {explore, files} = opened(fn -> ExploreView.explore(ctx.work_item, DateTime.utc_now()) end)

      assert [_newest] = markdown(files)
      assert %{version: 3, message: "Version 3 of " <> _} = explore.proposal

      assert [
               %{wrote: 1, wrote_proposal: %{unread: 1}},
               %{wrote: 2, wrote_proposal: %{unread: 2}}
             ] =
               explore.earlier_runs

      {texts, files} = opened(fn -> ExploreView.proposals(ctx.work_item, [1]) end)
      assert [_run_1] = markdown(files)
      assert %{1 => %{message: "Version 1 of " <> _}} = texts

      {shown, files} = opened(fn -> ExploreView.with_proposals(explore, texts) end)
      assert files == []

      assert [
               %{wrote_proposal: %{message: "Version 1 of " <> _}},
               %{wrote_proposal: %{unread: 2}}
             ] =
               shown.earlier_runs
    end
  end

  describe "the queries of the Explore tab" do
    # What `fun` returned, and how many queries this process ran on the table `source`
    # while it ran.
    defp queries_on(source, fun) do
      handler = "explore-view-versions-#{System.unique_integer([:positive])}"
      me = self()

      :ok =
        :telemetry.attach(
          handler,
          [:apiary, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == me and meta[:source] == source, do: send(me, :query)
          end,
          nil
        )

      try do
        result = fun.()
        {result, count_queries(0)}
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

    test "the versions of the runs' proposals are read in one query, for one run as for three",
         ctx do
      one = work_item_fixture(ctx.scope)
      explore_run_fixture(one, result: understood_result())

      for _n <- 1..3, do: explore_run_fixture(ctx.work_item, result: understood_result())

      {_explore, for_one} =
        queries_on("artifact_versions", fn -> ExploreView.explore(one, DateTime.utc_now()) end)

      {explore, for_three} =
        queries_on("artifact_versions", fn ->
          ExploreView.explore(ctx.work_item, DateTime.utc_now())
        end)

      assert length(explore.earlier_runs) == 2
      assert for_three == for_one
    end

    test "why the runs paused is read in one query, for one paused run as for three", ctx do
      one = work_item_fixture(ctx.scope)
      explore_run_fixture(one, result: understood_result())

      for _n <- 1..3, do: explore_run_fixture(ctx.work_item, result: understood_result())

      for work_item <- [one, ctx.work_item] do
        Repo.update_all(
          from(r in Apiary.Runs.Run,
            join: d in DispatchRun,
            on: d.id == r.dispatch_run_id,
            where: d.work_item_id == ^work_item.id
          ),
          set: [state: "paused"]
        )
      end

      {_explore, for_one} = pause_reads(fn -> ExploreView.explore(one, DateTime.utc_now()) end)

      {explore, for_three} =
        pause_reads(fn -> ExploreView.explore(ctx.work_item, DateTime.utc_now()) end)

      assert length(explore.earlier_runs) == 2
      assert for_one == 1
      assert for_three == 1
    end

    # What `fun` returned, and how many reads of why a run paused
    # (`Apiary.Dispatches.Pause`, which joins a run of the queue on `continues_id`) this
    # process ran while it ran.
    defp pause_reads(fun) do
      handler = "explore-view-pauses-#{System.unique_integer([:positive])}"
      me = self()

      :ok =
        :telemetry.attach(
          handler,
          [:apiary, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == me and meta[:source] == "runs" and
                 String.contains?(meta[:query] || "", ~s(."continues_id" = )),
               do: send(me, :query)
          end,
          nil
        )

      try do
        result = fun.()
        {result, count_queries(0)}
      after
        :telemetry.detach(handler)
      end
    end
  end

  describe "the confirmations of the earlier take ins" do
    test "are read in one query, for three earlier take ins", %{scope: scope} do
      ticket = backlog_ticket_fixture(scope, connection: ticket_connection_fixture(scope))
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

      work_item =
        Enum.reduce(1..3, work_item, fn _n, work_item ->
          Repo.update_all(from(r in DispatchRun, where: r.work_item_id == ^work_item.id),
            set: [state: :ended, end_cause: :run_ended]
          )

          {:ok, _closed} = WorkItems.close(scope, work_item)

          {:ok, again} =
            WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

          again
        end)

      {explore, confirmations} =
        queries_on("work_item_confirmations", fn ->
          ExploreView.explore(work_item, DateTime.utc_now())
        end)

      assert length(explore.earlier_take_ins) == 3
      assert confirmations == 1
    end
  end

  describe "a version of the proposal with no Markdown file" do
    test "is no proposal of its run, and is not left for a fold to read", ctx do
      for n <- 1..2 do
        explore_run_fixture(ctx.work_item,
          result: understood_result(%{"message" => "Version #{n}."})
        )
      end

      Repo.delete_all(
        from f in Apiary.Artifacts.ArtifactFile,
          join: v in Apiary.Artifacts.Version,
          on: v.id == f.version_id,
          join: a in Apiary.Artifacts.Artifact,
          on: a.id == v.artifact_id,
          where: a.work_item_id == ^ctx.work_item.id and a.type == "proposal" and v.number == 1
      )

      explore = ExploreView.explore(ctx.work_item, DateTime.utc_now())
      assert [%{wrote: 1, wrote_proposal: nil}] = explore.earlier_runs

      shown = ExploreView.with_proposals(explore, ExploreView.proposals(ctx.work_item, [1]))
      assert [%{wrote: 1, wrote_proposal: nil}] = shown.earlier_runs
    end
  end

  describe "the store reads of the Explore tab, after a send of review comments" do
    test "the newest questions and review comments are each read once", ctx do
      explore_run_fixture(ctx.work_item, result: understood_result())
      {:ok, _} = WorkItems.review_comment(ctx.scope, ctx.work_item, 1, "Name the field.")
      {:ok, _} = WorkItems.send_review_comments(ctx.scope, ctx.work_item, 1)
      explore_run_fixture(ctx.work_item, result: questions_result([%{"question" => "Which?"}]))

      {_explore, files} =
        opened(fn -> ExploreView.explore(ctx.work_item, DateTime.utc_now()) end)

      assert Enum.frequencies_by(files, & &1.filename)
             |> Map.take(["questions.json", "review-comments.json"]) == %{
               "questions.json" => 1,
               "review-comments.json" => 1
             }
    end
  end

  describe "two answers to one question in the same second" do
    test "each shows with the member who gave it", ctx do
      %{user: member} = member_fixture(ctx.scope)
      member_scope = workspace_scope(member, ctx.scope.workspace)

      # The owner answers q1 at attempt 1; run 2 reopens q1, and the member answers it.
      explore_run_fixture(ctx.work_item, result: questions_result(["Which basket?"]))
      {:ok, _} = WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => "The main one"})
      item = Apiary.StagesFixtures.end_run!(reload(ctx.work_item), &reopen!(&1, &2, "q1"))
      {:ok, _} = WorkItems.answer(member_scope, item, 2, %{"1" => "The other one"})

      # Both answers' events in one second, in their order.
      second = DateTime.utc_now() |> DateTime.truncate(:second)

      answered =
        Repo.all(
          from e in WorkItemEvent,
            where: e.work_item_id == ^item.id and e.kind == :answered,
            order_by: [asc: e.at, asc: e.id]
        )

      for {event, n} <- Enum.with_index(answered, 1) do
        at = second |> DateTime.add(n * 100, :microsecond) |> DateTime.to_unix(:microsecond)

        Repo.update_all(from(e in WorkItemEvent, where: e.id == ^event.id),
          set: [at: DateTime.from_unix!(at, :microsecond)]
        )
      end

      owner_id = ctx.scope.user.id
      member_id = member.id

      assert [%{history: [%{by_id: ^owner_id}], answer: %{by_id: ^member_id}}] =
               WorkItems.explore(ctx.scope, reload(item)).questions
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

      {:ok, closed} = WorkItems.close(scope, answered)
      assert %{previous: nil} = WorkItems.explore(scope, closed)

      {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: member.id})
      user_id = scope.user.id
      member_id = member.id
      asked_id = asked.public_id

      assert %{
               previous: :closed,
               earlier_take_ins: [
                 %{
                   take_in: 1,
                   ended: :closed,
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

    test "a take in again: the questions and the waiting run's questions are those its runs wrote; the earlier take in's run has its question" do
      %{scope: scope} = sign_up_fixture()
      ticket = backlog_ticket_fixture(scope, connection: ticket_connection_fixture(scope))
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)
      explore_run_fixture(work_item, result: questions_result(["Which basket?"]))
      {:ok, _closed} = WorkItems.close(scope, work_item)

      {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

      Repo.delete_all(
        from r in DispatchRun, where: r.work_item_id == ^again.id and r.take_in == 2
      )

      %{run: %{number: asked_2}} =
        explore_run_fixture(again, take_in: 2, result: questions_result(["Which sale?"]))

      assert %{
               status: :questions,
               questions: [
                 %{id: "q2", number: 1, text: "Which sale?", state: :open, asked_run: ^asked_2}
               ],
               run: %{questions: [%{public_id: "1", text: "Which sale?"}]},
               earlier_take_ins: [
                 %{take_in: 1, runs: [%{questions: [%{text: "Which basket?"}], asked: 1}]}
               ]
             } = WorkItems.explore(scope, again)
    end

    test "a take in again undone gave its owner back, and no record keeps the one it had" do
      %{scope: scope} = sign_up_fixture()
      %{user: member} = member_fixture(scope)
      ticket = backlog_ticket_fixture(scope, connection: ticket_connection_fixture(scope))
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

      Repo.update_all(from(r in DispatchRun, where: r.work_item_id == ^work_item.id),
        set: [state: :ended, end_cause: :run_ended]
      )

      {:ok, _closed} = WorkItems.close(scope, work_item)
      {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: member.id})
      {:ok, undone} = WorkItems.undo(scope, again)
      user_id = scope.user.id

      assert %{status: :closed} = WorkItems.explore(scope, undone)

      assert [%{take_in: 1, owner_id: ^user_id}, %{take_in: 2, owner_id: nil}] =
               for(
                 %{kind: :taken_in} = entry <- WorkItems.explore_thread(scope, undone),
                 do: entry
               )
    end

    test "a question reopened in take in 2 and again in take in 3: the fold of each take in lists it at each run that wrote or reopened it, and at the run it was answered at",
         ctx do
      scope = ctx.scope
      ticket = backlog_ticket_fixture(scope, connection: ticket_connection_fixture(scope))
      {:ok, item} = WorkItems.take_in(scope, ticket.public_id)
      Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^item.id)
      explore_run_fixture(item, result: questions_result(["Which basket?"]))
      {:ok, _} = WorkItems.answer(scope, item, 1, %{"1" => "The main one"})
      {:ok, _closed} = WorkItems.close(scope, reload(item))

      # Take in 2's run 1 reopens q1 and writes q2, and only q2 is answered at it; its
      # run 2 pushes nothing, and q1 is answered at it.
      {:ok, item} = WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})
      item = Apiary.StagesFixtures.end_run!(reload(item), &reopen!(&1, &2, "q1", ["Which sale?"]))
      {:ok, _} = WorkItems.answer(scope, item, 1, %{"2" => "The spring sale"})
      item = Apiary.StagesFixtures.end_run!(reload(item), nil)
      {:ok, _} = WorkItems.answer(scope, item, 2, %{"1" => "The other one"})
      {:ok, _closed} = WorkItems.close(scope, reload(item))

      # Take in 3's run reopens q1 again; take in 4 follows.
      {:ok, item} = WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})
      item = Apiary.StagesFixtures.end_run!(reload(item), &reopen!(&1, &2, "q1"))
      {:ok, _closed} = WorkItems.close(scope, item)
      {:ok, item} = WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

      folds =
        for %{take_in: take_in, runs: runs} <- WorkItems.explore(scope, item).earlier_take_ins,
            do: {take_in, for(run <- runs, do: {run.attempt, run.outcome, run.asked, frame(run)})}

      assert folds == [
               {1, [{1, :questions, 1, [{"Which basket?", "The main one"}]}, {2, nil, 0, []}]},
               {2,
                [
                  {1, :questions, 2,
                   [{"Which basket?", nil}, {"Which sale?", "The spring sale"}]},
                  {2, :questions, 0, [{"Which basket?", "The other one"}]},
                  {3, nil, 0, []}
                ]},
               {3, [{1, :questions, 1, [{"Which basket?", nil}]}]}
             ]
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

      for reason <- ["last_stage_done", "ticket_closed"] do
        other = work_item_fixture(ctx.scope, external_ref: "acme/shop#" <> reason)
        closed = instance_close!(other, reason)

        assert %{status: :closed, ended_reason: ^reason, ended_by_id: nil} =
                 WorkItems.explore(ctx.scope, closed)
      end

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

  defp reload(work_item), do: Repo.get!(Apiary.WorkItems.WorkItem, work_item.id)

  # A run map's questions, each with the answer given at the run.
  defp frame(run), do: Enum.map(run.questions, &{&1.text, &1.answer})

  # `work_item` after run 1 asked q1, answered at it; run 2, queued by the answer,
  # reopened q1, answered at it; and run 3, queued by that answer, reopened q1 again.
  defp reopened_twice!(scope, work_item) do
    explore_run_fixture(work_item, result: questions_result(["Which basket?"]))
    {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "The main one"})
    work_item = Apiary.StagesFixtures.end_run!(reload(work_item), &reopen!(&1, &2, "q1"))
    {:ok, _} = WorkItems.answer(scope, work_item, 2, %{"1" => "The other one"})
    Apiary.StagesFixtures.end_run!(reload(work_item), &reopen!(&1, &2, "q1"))
  end

  # Pushes, as the run `registered` of the run of the queue `run`, the newest questions
  # with the answered question `id` reopened by the run: its answer moved to the end of
  # its history; and the questions `added`, by their texts, which the run wrote.
  defp reopen!(run, registered, id, added \\ []) do
    work_item = reload(%{id: run.work_item_id})
    {_version, document} = Questions.newest(work_item)
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    questions =
      Enum.map(document["questions"], fn
        %{"id" => ^id, "answer" => answer} = question ->
          reopened = Map.put(answer, "reopened", %{"run" => registered.number, "at" => at})

          question
          |> Map.delete("answer")
          |> Map.put("state", "open")
          |> Map.put("history", (question["history"] || []) ++ [reopened])

        question ->
          question
      end)

    added =
      for {text, n} <- Enum.with_index(added, length(questions) + 1) do
        %{
          "id" => "q#{n}",
          "question" => text,
          "options" => [],
          "state" => "open",
          "asked" => %{"run" => registered.number, "at" => at}
        }
      end

    {:ok, _version} =
      Apiary.Artifacts.push(
        {:run, run},
        work_item,
        "questions",
        [Questions.file(%{"questions" => questions ++ added})],
        name: "main",
        stage_id: run.stage_id
      )
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

  describe "a run's decisions in the Thread" do
    @decision %{
      "question" => "Which currency does the invoice show?",
      "options" => [
        %{"title" => "The order's currency", "explanation" => "What the customer paid."},
        %{"title" => "The shop's currency", "explanation" => "What the books keep."}
      ],
      "option" => "The order's currency",
      "reason" => "The customer pays in the order's currency."
    }

    test "a run with one open question and two decided questions wrote one question", ctx do
      now = DateTime.utc_now()

      %{run: run} =
        explore_run_fixture(ctx.work_item,
          result: questions_result(["Which basket?"]),
          decisions: [@decision, %{@decision | "question" => "Which date does it show?"}],
          run: timed(now, 9, 8)
        )

      assert %{run: %{asked: 1}} = WorkItems.explore(ctx.scope, ctx.work_item)

      asked =
        for %{kind: :asked, run: %{id: id}} = entry <-
              WorkItems.explore_thread(ctx.scope, ctx.work_item, now),
            id == run.public_id,
            do: Enum.map(entry.questions, & &1.text)

      assert asked == [["Which basket?"]]
    end

    test "a run with a proposal and a decided question wrote no question", ctx do
      now = DateTime.utc_now()

      %{run: run} =
        explore_run_fixture(ctx.work_item,
          result: understood_result(),
          decisions: [@decision],
          run: timed(now, 9, 8)
        )

      assert %{run: %{asked: 0}} = WorkItems.explore(ctx.scope, ctx.work_item)

      kinds =
        for %{run: %{id: id}, kind: kind} <-
              WorkItems.explore_thread(ctx.scope, ctx.work_item, now),
            id == run.public_id,
            do: kind

      assert :asked not in kinds
      assert :proposed in kinds
    end

    test "a run that reopens a changed decision wrote one question", ctx do
      now = DateTime.utc_now()

      explore_run_fixture(ctx.work_item,
        result: understood_result(),
        decisions: [@decision],
        run: timed(now, 9, 8)
      )

      {:ok, _work_item} =
        WorkItems.another_round(ctx.scope, ctx.work_item, 1, %{
          answers: [%{"id" => "q1", "option" => "The shop's currency", "note" => nil}],
          comment: nil
        })

      item = Apiary.StagesFixtures.end_run!(reload(ctx.work_item), &reopen!(&1, &2, "q1"))

      assert %{status: :questions, run: %{asked: 1}} = WorkItems.explore(ctx.scope, item)

      asked =
        for %{kind: :asked} = entry <- WorkItems.explore_thread(ctx.scope, item, now),
            do: Enum.map(entry.questions, & &1.text)

      assert asked == [[@decision["question"]]]
    end

    defp numbers(scope, work_item) do
      for question <- WorkItems.explore(scope, work_item).questions,
          into: %{},
          do: {question.id, question.number}
    end

    defp send_note(scope, work_item, id) do
      {:ok, _work_item} =
        WorkItems.another_round(scope, work_item, 1, %{
          answers: [%{"id" => id, "option" => nil, "note" => "The main one"}],
          comment: nil
        })
    end

    test "with an open question: the numbers read closed, decisions, then open", ctx do
      explore_run_fixture(ctx.work_item,
        result: questions_result(["Which basket?", "Which shelf?"]),
        decisions: [@decision]
      )

      assert numbers(ctx.scope, ctx.work_item) == %{"q3" => 1, "q1" => 2, "q2" => 3}

      send_note(ctx.scope, ctx.work_item, "q1")

      assert numbers(ctx.scope, ctx.work_item) == %{"q1" => 1, "q3" => 2, "q2" => 3}
    end

    test "a changed decision stays among the decisions, above a closed question", ctx do
      explore_run_fixture(ctx.work_item,
        result: questions_result(["Which basket?"]),
        decisions: [@decision]
      )

      {:ok, _work_item} =
        WorkItems.another_round(ctx.scope, ctx.work_item, 1, %{
          answers: [
            %{"id" => "q1", "option" => nil, "note" => "The main one"},
            %{"id" => "q2", "option" => "The shop's currency", "note" => nil}
          ],
          comment: nil
        })

      assert numbers(ctx.scope, ctx.work_item) == %{"q2" => 1, "q1" => 2}
    end

    test "with no open question: the numbers read decisions, then closed", ctx do
      explore_run_fixture(ctx.work_item,
        result: questions_result(["Which basket?"]),
        decisions: [@decision]
      )

      assert numbers(ctx.scope, ctx.work_item) == %{"q2" => 1, "q1" => 2}

      send_note(ctx.scope, ctx.work_item, "q1")

      assert numbers(ctx.scope, ctx.work_item) == %{"q2" => 1, "q1" => 2}
    end
  end
end
