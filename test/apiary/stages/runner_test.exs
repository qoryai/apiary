defmodule Apiary.Stages.RunnerTest do
  use ExUnit.Case, async: true

  alias Apiary.Stages.Runner

  @person %{"kind" => "person", "approvers" => "members"}

  defp stage(sequence, opts \\ []) do
    %{
      "id" => "st_0000000000",
      "name" => "Build",
      "inputs" => [],
      "sequence" => sequence,
      "outputs" => [],
      "gate" => Keyword.get(opts, :gate, @person)
    }
  end

  defp wf(name, extra \\ %{}), do: Map.merge(%{"workflow" => name}, extra)
  defp loop(body, rounds \\ 3), do: %{"loop" => %{"rounds" => rounds, "body" => body}}

  # Explore: a loop of explore-a-ticket, 3 rounds.
  defp explore, do: stage([loop([wf("explore-a-ticket")])])

  # Build (§ 4 Figure 2): implement, then a loop of capture-demo and fix-demo-findings.
  defp build, do: stage([wf("implement"), loop([wf("capture-demo"), wf("fix-demo-findings")])])

  defp pos(entry, loop_entry, round), do: %{entry: entry, loop_entry: loop_entry, round: round}

  defp queued(%{actions: [{:queue, spec}]}),
    do: {spec.workflow, spec.entry, spec.loop_entry, spec.round}

  # A point a run or Core writes, with the action run_again.
  # The point of a run outside a loop that ended with no verdict.
  @no_verdict %{"text" => "The run stopped before its verdict.", "action" => "run_again"}

  defp again(text), do: %{"text" => text, "action" => "run_again"}

  defp answer(text, question), do: %{"text" => text, "action" => "answer", "question" => question}

  describe "entering" do
    test "starts the sequence at once, a loop at its round 1" do
      outcome = Runner.step(explore(), nil, :enter)
      assert outcome.state == :running
      assert outcome.position == pos(0, 0, 1)
      assert queued(outcome) == {"explore-a-ticket", 0, 0, 1}

      outcome = Runner.step(build(), nil, :enter)
      assert queued(outcome) == {"implement", 0, nil, 1}
    end

    test "waits for a required input" do
      outcome = Runner.step(build(), nil, :enter, %{missing_inputs: ["acceptance-criteria"]})
      assert %{state: :waiting_inputs, position: %{entry: 0}, actions: []} = outcome
    end

    test "waits for a workflow the harness does not declare, anywhere in the sequence" do
      outcome = Runner.step(build(), nil, :enter, %{undeclared: ["capture-demo"]})
      assert %{state: :waiting_workflow, actions: []} = outcome
    end

    test "resumes once the input exists and the workflow is declared" do
      waiting = Runner.step(build(), nil, :enter, %{missing_inputs: ["mockup"]})

      assert Runner.step(build(), waiting.position, :resume, %{missing_inputs: ["mockup"]}).state ==
               :waiting_inputs

      assert queued(Runner.step(build(), waiting.position, :resume, %{})) ==
               {"implement", 0, nil, 1}

      assert Runner.step(build(), nil, :resume, %{undeclared: ["implement"]}).state ==
               :waiting_workflow
    end

    test "a stage with no workflow and a person gate starts at its gate" do
      assert %{state: :at_gate, actions: []} = Runner.step(stage([]), nil, :enter)
    end

    test "a stage with no workflow and no gate records its approval and passes through" do
      assert %{state: :done, actions: [:approve, :advance]} =
               Runner.step(stage([], gate: %{"kind" => "none"}), nil, :enter)
    end
  end

  describe "a stage with no workflow (§ 4)" do
    @none %{"kind" => "none"}

    test "with a missing required output waits at its gate and escalates nothing" do
      outcome = Runner.step(stage([]), nil, :enter, %{failed_checks: ["acceptance-criteria"]})
      assert outcome == %{state: :at_gate, position: pos(0, nil, 1), actions: []}
    end

    test "with gate none waits at its gate too while an output is missing" do
      outcome =
        Runner.step(stage([], gate: @none), nil, :enter, %{failed_checks: ["acceptance-criteria"]})

      assert %{state: :at_gate, actions: []} = outcome
    end

    test "a person's version runs the checks again: gate none passes once the outputs exist" do
      seq = stage([], gate: @none)
      missing = %{failed_checks: ["acceptance-criteria", "mockup"]}

      assert %{state: :at_gate, actions: []} =
               Runner.step(seq, pos(0, nil, 1), :version_added, missing)

      assert %{state: :at_gate, actions: []} =
               Runner.step(seq, pos(0, nil, 1), :version_added, %{failed_checks: ["mockup"]})

      assert %{state: :done, position: pos(0, nil, 1), actions: [:approve, :advance]} ==
               Runner.step(seq, pos(0, nil, 1), :version_added, %{})
    end

    test "a person's version keeps a person gate waiting, with or without the outputs" do
      assert %{state: :at_gate, actions: []} =
               Runner.step(stage([]), pos(0, nil, 1), :version_added, %{failed_checks: ["x"]})

      assert %{state: :at_gate, actions: []} =
               Runner.step(stage([]), pos(0, nil, 1), :version_added, %{})
    end

    test "a version at the gate of a stage with workflows escalates nothing" do
      seq = stage([wf("a")], gate: @none)

      assert %{state: :at_gate, position: pos(1, nil, 1), actions: []} ==
               Runner.step(seq, pos(1, nil, 1), :version_added, %{failed_checks: ["x"]})
    end

    test "request changes goes back to the gate while an output is missing" do
      assert %{state: :at_gate, actions: []} =
               Runner.step(stage([]), pos(0, nil, 1), :request_changes, %{failed_checks: ["x"]})
    end

    test "people?/1 is a stage with no workflow" do
      assert Runner.people?(stage([]))
      assert Runner.people?(Map.delete(stage([]), "sequence"))
      refute Runner.people?(stage([wf("a")]))
      refute Runner.people?(explore())
    end

    test "a stage that ran workflows still escalates a missing output, check_failed" do
      outcome =
        Runner.step(stage([wf("a")]), pos(0, nil, 1), {:run, {:verdict, :passed, nil}}, %{
          failed_checks: ["proposal"]
        })

      assert outcome == %{
               state: :escalated,
               position: pos(1, nil, 1),
               actions: [
                 {:escalate, :check_failed, [again("No proposal was stored in this stage.")]}
               ]
             }

      seq = stage([wf("a")], gate: @none)

      # One point for each failed check.
      assert %{state: :escalated, actions: [{:escalate, :check_failed, points}]} =
               Runner.step(seq, pos(0, nil, 1), {:run, {:verdict, :passed, nil}}, %{
                 failed_checks: ["proposal", "submission"]
               })

      assert points == [
               again("No proposal was stored in this stage."),
               again("No submission was stored in this stage.")
             ]
    end
  end

  describe "a run's end outside a loop" do
    test "the sequence goes on after passed and changes-requested" do
      for verdict <- [:passed, :changes_requested] do
        outcome = Runner.step(build(), pos(0, nil, 1), {:run, {:verdict, verdict, nil}})
        assert queued(outcome) == {"capture-demo", 1, 0, 1}
      end
    end

    test "a run with no verdict escalates run_stopped, with its point, at any entry" do
      seq = stage([wf("a"), wf("b")])

      for {position, points} <- [
            {pos(0, nil, 1), nil},
            {pos(1, nil, 1), nil},
            {pos(1, nil, 2), [again("x")]}
          ] do
        outcome = Runner.step(seq, position, {:run, {:verdict, nil, points}})

        assert outcome == %{
                 state: :escalated,
                 position: position,
                 actions: [{:escalate, :run_stopped, [@no_verdict]}]
               }
      end
    end

    test "a run with no verdict escalates before the checks read a failed output" do
      outcome =
        Runner.step(stage([wf("a")]), pos(0, nil, 1), {:run, {:verdict, nil, nil}}, %{
          failed_checks: ["submission"]
        })

      assert outcome.actions == [{:escalate, :run_stopped, [@no_verdict]}]
    end

    test "a test work item's run with no verdict goes on, as any other verdict" do
      facts = %{test: true}

      assert queued(Runner.step(build(), pos(0, nil, 1), {:run, {:verdict, nil, nil}}, facts)) ==
               {"capture-demo", 1, 0, 1}

      assert %{state: :at_gate, actions: []} =
               Runner.step(stage([wf("a")]), pos(0, nil, 1), {:run, {:verdict, nil, nil}}, facts)

      assert %{actions: [{:escalate, :check_failed, _points}]} =
               Runner.step(stage([wf("a")]), pos(0, nil, 1), {:run, {:verdict, nil, nil}}, %{
                 test: true,
                 failed_checks: ["proposal"]
               })
    end

    test "a run of Explore with a result and no verdict goes on; with no result it stops" do
      seq = stage([wf("a")])
      no_verdict = {:run, {:verdict, nil, nil}}

      assert %{state: :at_gate, actions: []} =
               Runner.step(seq, pos(0, nil, 1), no_verdict, %{explore_result: true})

      assert %{actions: [{:escalate, :run_stopped, [@no_verdict]}]} =
               Runner.step(seq, pos(0, nil, 1), no_verdict, %{explore_result: false})
    end

    test "a run of Explore that pushed passed or changes-requested goes on to the checks" do
      seq = stage([wf("a")])
      no_verdict = {:run, {:verdict, nil, nil}}

      assert %{state: :at_gate, actions: []} =
               Runner.step(seq, pos(0, nil, 1), no_verdict, %{explore_verdict: true})

      assert %{actions: [{:escalate, :check_failed, _points}]} =
               Runner.step(seq, pos(0, nil, 1), no_verdict, %{
                 explore_verdict: true,
                 failed_checks: ["proposal"]
               })
    end

    test "a test work item's run that gave escalate or stopped still escalates" do
      facts = %{test: true}
      blocked = [again("blocked")]
      lost = [again("lost")]

      assert %{actions: [{:escalate, :escalate, ^blocked}]} =
               Runner.step(build(), pos(0, nil, 1), {:run, {:verdict, :escalate, blocked}}, facts)

      assert %{actions: [{:escalate, :run_stopped, ^lost}]} =
               Runner.step(build(), pos(0, nil, 1), {:run, {:stopped, lost}}, facts)
    end

    test "escalate escalates with the verdict's points" do
      points = [answer("Which page shows the sale?", "q1"), again("The demo has no card.")]
      outcome = Runner.step(build(), pos(0, nil, 1), {:run, {:verdict, :escalate, points}})

      assert %{
               state: :escalated,
               position: %{entry: 0},
               actions: [{:escalate, :escalate, ^points}]
             } =
               outcome

      # A verdict file with no points still escalates, with none.
      outcome = Runner.step(build(), pos(0, nil, 1), {:run, {:verdict, :escalate, nil}})
      assert outcome.actions == [{:escalate, :escalate, []}]
    end

    test "a stopped run escalates run_stopped with the point of its cause" do
      points = [again("The run stopped: it was lost.")]
      outcome = Runner.step(build(), pos(0, nil, 1), {:run, {:stopped, points}})
      assert outcome.actions == [{:escalate, :run_stopped, points}]
    end

    test "the last workflow's end runs the checks, then the gate" do
      seq = stage([wf("a"), wf("b")])

      assert %{state: :at_gate} =
               Runner.step(seq, pos(1, nil, 1), {:run, {:verdict, :passed, nil}})

      outcome =
        Runner.step(seq, pos(1, nil, 1), {:run, {:verdict, :passed, nil}}, %{
          failed_checks: ["submission"]
        })

      assert %{state: :escalated, position: %{entry: 2}, actions: [{:escalate, :check_failed, _}]} =
               outcome
    end

    test "questions wait for answers, which rerun the same workflow" do
      outcome = Runner.step(build(), pos(0, nil, 1), {:run, {:questions, "Which page?", nil}})
      assert %{state: :waiting_answers, position: %{entry: 0}, actions: []} = outcome
      assert queued(Runner.step(build(), outcome.position, :answered)) == {"implement", 0, nil, 1}
    end

    test "questions with escalate wait for answers and keep the escalation with its points" do
      points = [answer("Which page shows the sale?", "q1")]

      outcome =
        Runner.step(build(), pos(0, nil, 1), {:run, {:questions, "Which page?", points}})

      assert outcome == %{
               state: :waiting_answers,
               position: pos(0, nil, 1),
               actions: [{:escalate, :escalate, points}]
             }

      # Questions with no escalate verdict, or with no points, keep nothing.
      for none <- [nil, []] do
        assert %{state: :waiting_answers, actions: []} =
                 Runner.step(build(), pos(0, nil, 1), {:run, {:questions, "Which page?", none}})
      end
    end
  end

  describe "a run's end in a loop" do
    test "passed from any workflow leaves the loop at once" do
      assert %{state: :at_gate} =
               Runner.step(build(), pos(1, 0, 1), {:run, {:verdict, :passed, nil}})

      assert %{state: :at_gate} =
               Runner.step(build(), pos(1, 1, 2), {:run, {:verdict, :passed, nil}})
    end

    test "passed leaves the loop for the next entry" do
      seq = stage([loop([wf("a")]), wf("b")])

      assert queued(Runner.step(seq, pos(0, 0, 2), {:run, {:verdict, :passed, nil}})) ==
               {"b", 1, nil, 2}
    end

    test "changes-requested runs the next workflow of the ring" do
      outcome = Runner.step(build(), pos(1, 0, 1), {:run, {:verdict, :changes_requested, nil}})
      assert queued(outcome) == {"fix-demo-findings", 1, 1, 1}
    end

    test "changes-requested with run_again points steps as changes-requested without them" do
      with_points = {:run, {:verdict, :changes_requested, [again("The demo has no card.")]}}
      without = {:run, {:verdict, :changes_requested, nil}}

      for {seq, position} <- [
            {build(), pos(1, 0, 1)},
            {build(), pos(1, 1, 3)},
            {explore(), pos(0, 0, 1)},
            {build(), pos(0, nil, 1)}
          ] do
        assert Runner.step(seq, position, with_points) == Runner.step(seq, position, without)
      end
    end

    test "after the last workflow the ring starts the next round from the first" do
      outcome = Runner.step(build(), pos(1, 1, 1), {:run, {:verdict, nil, nil}})
      assert queued(outcome) == {"capture-demo", 1, 0, 2}
    end

    test "a loop of one workflow reruns it as the next round" do
      outcome = Runner.step(explore(), pos(0, 0, 1), {:run, {:verdict, :changes_requested, nil}})
      assert queued(outcome) == {"explore-a-ticket", 0, 0, 2}
    end

    test "at the round limit the stage escalates with a point that says so" do
      outcome = Runner.step(build(), pos(1, 1, 3), {:run, {:verdict, :changes_requested, nil}})

      assert outcome.state == :escalated
      assert outcome.actions == [{:escalate, :round_limit, [again("3 of 3 rounds ran.")]}]
      assert outcome.position == pos(1, 1, 3)

      outcome = Runner.step(explore(), pos(0, 0, 3), {:run, {:verdict, nil, nil}})
      assert outcome.actions == [{:escalate, :round_limit, [again("3 of 3 rounds ran.")]}]
    end

    test "a loop of one round escalates at once" do
      seq = stage([loop([wf("a")], 1)])

      outcome = Runner.step(seq, pos(0, 0, 1), {:run, {:verdict, nil, nil}})
      assert outcome.state == :escalated
      assert outcome.actions == [{:escalate, :round_limit, [again("1 of 1 round ran.")]}]
    end

    test "questions wait; the answers run the same workflow as the next round" do
      outcome = Runner.step(explore(), pos(0, 0, 1), {:run, {:questions, "Which page?", nil}})
      assert outcome.state == :waiting_answers

      assert queued(Runner.step(explore(), outcome.position, :answered)) ==
               {"explore-a-ticket", 0, 0, 2}
    end

    test "questions in the loop's last round wait for answers too" do
      outcome = Runner.step(explore(), pos(0, 0, 3), {:run, {:questions, "Which page?", nil}})
      assert %{state: :waiting_answers, actions: []} = outcome
    end

    test "escalate and a stopped run escalate inside a loop too" do
      points = [again("The demo has no card.")]

      assert [{:escalate, :escalate, ^points}] =
               Runner.step(build(), pos(1, 0, 1), {:run, {:verdict, :escalate, points}}).actions

      assert [{:escalate, :run_stopped, ^points}] =
               Runner.step(build(), pos(1, 1, 2), {:run, {:stopped, points}}).actions
    end
  end

  describe "the checks at the sequence's end" do
    test "a failure starts another round of the last loop, with the failed checks as gaps" do
      outcome =
        Runner.step(build(), pos(1, 0, 1), {:run, {:verdict, :passed, nil}}, %{
          failed_checks: ["demo-video"]
        })

      assert [{:checks_failed, 2, "No demo-video was stored in this stage."} | queue] =
               outcome.actions

      assert queued(%{outcome | actions: queue}) == {"capture-demo", 1, 0, 2}
    end

    test "a failure that starts a round waiting for its workflow still keeps the gaps" do
      outcome =
        Runner.step(build(), pos(1, 0, 1), {:run, {:verdict, :passed, nil}}, %{
          failed_checks: ["demo-video"],
          undeclared: ["capture-demo"]
        })

      assert %{state: :waiting_workflow, position: %{round: 2}} = outcome
      assert [{:checks_failed, 2, "No demo-video was stored in this stage."}] = outcome.actions
    end

    test "a failure at the round limit escalates round_limit at the end" do
      outcome =
        Runner.step(build(), pos(1, 0, 3), {:run, {:verdict, :passed, nil}}, %{
          failed_checks: ["demo-video", "submission"]
        })

      assert outcome.state == :escalated
      assert outcome.position.entry == 2

      # The point of the rounds that ran, then one for each failed check.
      assert outcome.actions == [
               {:escalate, :round_limit,
                [
                  again("3 of 3 rounds ran."),
                  again("No demo-video was stored in this stage."),
                  again("No submission was stored in this stage.")
                ]}
             ]
    end

    test "a failure with the loop not last reruns the last loop" do
      seq = stage([loop([wf("a")]), wf("b")])

      outcome =
        Runner.step(seq, pos(1, nil, 1), {:run, {:verdict, :passed, nil}}, %{failed_checks: ["x"]})

      assert [{:checks_failed, 2, _gaps} | queue] = outcome.actions
      assert queued(%{outcome | actions: queue}) == {"a", 0, 0, 2}
    end

    test "passing checks go to a person gate, or record the approval and pass on with gate none" do
      assert %{state: :at_gate} =
               Runner.step(build(), pos(1, 0, 1), {:run, {:verdict, :passed, nil}})

      seq = stage([wf("a")], gate: %{"kind" => "none"})

      assert %{state: :done, actions: [:approve, :advance]} =
               Runner.step(seq, pos(0, nil, 1), {:run, {:verdict, :passed, nil}})
    end
  end

  describe "request changes" do
    test "runs again from the first loop, round 1" do
      assert queued(Runner.step(build(), pos(2, nil, 3), :request_changes)) ==
               {"capture-demo", 1, 0, 1}

      assert queued(Runner.step(explore(), pos(1, nil, 2), :request_changes)) ==
               {"explore-a-ticket", 0, 0, 1}
    end

    test "runs from the start with no loop" do
      seq = stage([wf("a"), wf("b")])
      assert queued(Runner.step(seq, pos(2, nil, 1), :request_changes)) == {"a", 0, nil, 1}
    end

    test "a stage with no workflow goes back to its gate" do
      assert %{state: :at_gate} = Runner.step(stage([]), pos(0, nil, 1), :request_changes)
    end
  end

  describe "resolving an escalation" do
    test "accept counts the loop as passed and goes on" do
      seq = stage([loop([wf("a")]), wf("b")])
      assert queued(Runner.step(seq, pos(0, 0, 3), {:accept, :round_limit})) == {"b", 1, nil, 3}
      assert %{state: :at_gate} = Runner.step(build(), pos(1, 1, 3), {:accept, :round_limit})

      # After the last loop, the gate opens without the checks; a failed one stays shown.
      assert %{state: :at_gate, actions: []} =
               Runner.step(build(), pos(1, 1, 3), {:accept, :round_limit}, %{
                 failed_checks: ["demo"]
               })
    end

    test "accept at the end goes to the gate without the checks" do
      outcome =
        Runner.step(build(), pos(2, nil, 3), {:accept, :round_limit}, %{failed_checks: ["x"]})

      assert %{state: :at_gate, actions: []} = outcome

      outcome = Runner.step(stage([wf("a")]), pos(1, nil, 1), {:accept, :check_failed})
      assert outcome.state == :at_gate
    end

    test "accept of a stopped run outside a loop goes on to the next workflow" do
      assert queued(Runner.step(build(), pos(0, nil, 1), {:accept, :run_stopped})) ==
               {"capture-demo", 1, 0, 1}
    end

    test "accept of a stopped run at the last entry goes to the gate, with no checks" do
      assert %{state: :at_gate, position: %{entry: 1}} =
               Runner.step(stage([wf("a")]), pos(0, nil, 1), {:accept, :run_stopped}, %{
                 failed_checks: ["submission"]
               })
    end

    test "accept of a stopped run at the last entry approves a gate none and passes on, with no checks" do
      assert %{state: :done, actions: [:approve, :advance]} =
               Runner.step(
                 stage([wf("a")], gate: %{"kind" => "none"}),
                 pos(0, nil, 1),
                 {:accept, :run_stopped},
                 %{failed_checks: ["submission"]}
               )
    end

    test "another round reruns a stopped run's workflow as the next round" do
      assert queued(Runner.step(build(), pos(1, 1, 2), {:another_round, :run_stopped})) ==
               {"fix-demo-findings", 1, 1, 3}
    end

    test "another round after the limit or an escalate starts the loop's first workflow" do
      assert queued(Runner.step(build(), pos(1, 1, 3), {:another_round, :round_limit})) ==
               {"capture-demo", 1, 0, 4}

      assert queued(Runner.step(build(), pos(1, 0, 1), {:another_round, :escalate})) ==
               {"capture-demo", 1, 0, 2}
    end

    test "another round at the end reruns the last loop, or the sequence with no loop" do
      assert queued(Runner.step(build(), pos(2, nil, 3), {:another_round, :round_limit})) ==
               {"capture-demo", 1, 0, 4}

      seq = stage([wf("a"), wf("b")])

      assert queued(Runner.step(seq, pos(2, nil, 1), {:another_round, :check_failed})) ==
               {"a", 0, nil, 1}
    end

    test "another round outside a loop reruns the same workflow" do
      assert queued(Runner.step(build(), pos(0, nil, 1), {:another_round, :run_stopped})) ==
               {"implement", 0, nil, 1}
    end

    test "another round waits for a workflow the harness no longer declares" do
      outcome =
        Runner.step(build(), pos(1, 0, 1), {:another_round, :escalate}, %{
          undeclared: ["capture-demo"]
        })

      assert outcome.state == :waiting_workflow
    end
  end

  describe "the when key (A-16)" do
    @demos %{"when" => %{"input" => "demo-scenarios"}}

    # Verify: capture-demos only with demo scenarios, then verify-a-ticket.
    defp verify(gate \\ @person),
      do: stage([wf("capture-demos", @demos), wf("verify-a-ticket")], gate: gate)

    defp skip(workflow, entry, loop_entry, round),
      do:
        {:skip,
         %{
           workflow: workflow,
           input: "demo-scenarios",
           track: nil,
           negated: false,
           entry: entry,
           loop_entry: loop_entry,
           round: round
         }}

    test "with no demo scenarios, capture-demos starts no run and verify-a-ticket starts" do
      outcome = Runner.step(verify(), nil, :enter, %{counted: []})

      capture = skip("capture-demos", 0, nil, 1)
      assert %{state: :running} = outcome
      assert outcome.position == pos(1, nil, 1)
      assert [^capture, {:queue, %{workflow: "verify-a-ticket"}}] = outcome.actions

      # With no facts on the input, the condition is not met either.
      assert [{:skip, _spec}, {:queue, _run}] = Runner.step(verify(), nil, :enter).actions
    end

    test "with demo scenarios, capture-demos runs first" do
      outcome = Runner.step(verify(), nil, :enter, %{counted: ["demo-scenarios"]})
      assert queued(outcome) == {"capture-demos", 0, nil, 1}
    end

    test "the gate waits after verify-a-ticket passes with no film; with demo scenarios the missing film fails its check" do
      film = Map.merge(%{"type" => "demo-video", "required" => true}, @demos)

      # The failed checks as `Apiary.Stages` reads them: each required output, missing.
      failed = fn counted -> for o <- [film], Runner.required?(o, counted), do: o["type"] end

      assert failed.([]) == []

      outcome =
        Runner.step(verify(), pos(1, nil, 1), {:run, {:verdict, :passed, nil}}, %{
          counted: [],
          failed_checks: failed.([])
        })

      assert outcome == %{state: :at_gate, position: pos(2, nil, 1), actions: []}

      assert failed.(["demo-scenarios"]) == ["demo-video"]

      outcome =
        Runner.step(verify(), pos(1, nil, 1), {:run, {:verdict, :passed, nil}}, %{
          counted: ["demo-scenarios"],
          failed_checks: failed.(["demo-scenarios"])
        })

      assert %{state: :escalated, actions: [{:escalate, :check_failed, _points}]} = outcome
    end

    test "a stage does not wait for an undeclared workflow whose condition is not met" do
      facts = %{counted: [], undeclared: ["capture-demos"]}
      outcome = Runner.step(verify(), nil, :enter, facts)

      assert %{state: :running} = outcome

      assert [{:skip, %{workflow: "capture-demos"}}, {:queue, %{workflow: "verify-a-ticket"}}] =
               outcome.actions

      assert %{state: :running} = Runner.step(verify(), pos(0, nil, 1), :resume, facts)

      # With demo scenarios, capture-demos runs, so the stage waits for it.
      assert %{state: :waiting_workflow, actions: []} =
               Runner.step(verify(), nil, :enter, %{facts | counted: ["demo-scenarios"]})

      assert Runner.workflows(verify(), []) == ["verify-a-ticket"]

      assert Runner.workflows(verify(), ["demo-scenarios"]) == [
               "capture-demos",
               "verify-a-ticket"
             ]
    end

    test "a skip at the sequence's end goes to the gate; a gate none passes on" do
      seq = stage([wf("verify-a-ticket"), wf("capture-demos", @demos)])

      capture = skip("capture-demos", 1, nil, 1)

      assert %{state: :at_gate, actions: [^capture]} =
               Runner.step(seq, pos(0, nil, 1), {:run, {:verdict, :passed, nil}}, %{})

      none = Map.put(seq, "gate", %{"kind" => "none"})

      assert %{state: :done, actions: [^capture, :approve, :advance]} =
               Runner.step(none, pos(0, nil, 1), {:run, {:verdict, :passed, nil}}, %{})
    end

    test "Request changes and Run another round pass over the entry again" do
      capture = skip("capture-demos", 0, nil, 1)

      assert [^capture, {:queue, %{workflow: "verify-a-ticket"}}] =
               Runner.step(verify(), pos(2, nil, 1), :request_changes, %{}).actions

      assert [^capture, {:queue, %{workflow: "verify-a-ticket"}}] =
               Runner.step(verify(), pos(2, nil, 1), {:another_round, :check_failed}, %{}).actions
    end

    test "in a loop, the ring goes on past a workflow whose condition is not met" do
      seq = stage([loop([wf("implement"), wf("capture-demos", @demos)])])

      outcome =
        Runner.step(seq, pos(0, 0, 1), {:run, {:verdict, :changes_requested, nil}}, %{})

      assert outcome.position == pos(0, 0, 2)

      capture = skip("capture-demos", 0, 1, 1)
      assert [^capture, {:queue, %{workflow: "implement"}}] = outcome.actions
    end

    test "a loop whose every workflow is passed over is passed over whole" do
      seq = stage([loop([wf("capture-demos", @demos), wf("fix", @demos)]), wf("verify-a-ticket")])
      outcome = Runner.step(seq, nil, :enter, %{})
      capture = skip("capture-demos", 0, 0, 1)

      assert outcome.position == pos(1, nil, 1)

      assert [
               ^capture,
               {:skip, %{workflow: "fix", loop_entry: 1}},
               {:queue, %{workflow: "verify-a-ticket"}}
             ] = outcome.actions
    end

    test "a loop passed over whole is passed over once: a failed check uses no round and escalates check_failed" do
      seq = stage([wf("verify-a-ticket"), loop([wf("capture-demos", @demos)], 2)])
      capture = skip("capture-demos", 1, 0, 1)
      facts = %{counted: [], failed_checks: ["explainer"]}

      outcome = Runner.step(seq, pos(0, nil, 1), {:run, {:verdict, :passed, nil}}, facts)

      assert %{state: :escalated, position: %{round: 1}} = outcome
      assert [^capture, {:escalate, :check_failed, _points}] = outcome.actions
      refute Enum.any?(outcome.actions, &match?({:checks_failed, _round, _gaps}, &1))

      # Run another round at the end runs the sequence from its start, as with no loop.
      outcome = Runner.step(seq, pos(2, nil, 1), {:another_round, :check_failed}, facts)
      assert [{:queue, %{workflow: "verify-a-ticket", round: 1}}] = outcome.actions

      # With demo scenarios, the loop runs, and a failed check at the end starts its next
      # round.
      facts = %{facts | counted: ["demo-scenarios"]}
      outcome = Runner.step(seq, pos(0, nil, 1), {:run, {:verdict, :passed, nil}}, facts)
      assert [{:queue, %{workflow: "capture-demos", round: 1}}] = outcome.actions

      outcome = Runner.step(seq, pos(1, 0, 1), {:run, {:verdict, :passed, nil}}, facts)

      assert [{:checks_failed, 2, _gaps}, {:queue, %{workflow: "capture-demos", round: 2}}] =
               outcome.actions
    end

    # Enters `seq` with `facts`, then ends each queued run `passed`, at most `limit` times:
    # the last outcome and the queued runs as `{workflow, round}`, in order.
    defp drive(seq, facts, limit) do
      first = Runner.step(seq, nil, :enter, facts)

      {last, outcomes} =
        Enum.reduce_while(1..limit, {first, [first]}, fn _step, {outcome, seen} ->
          if outcome.state == :running do
            next = Runner.step(seq, outcome.position, {:run, {:verdict, :passed, nil}}, facts)
            {:cont, {next, [next | seen]}}
          else
            {:halt, {outcome, seen}}
          end
        end)

      queued =
        for %{actions: actions} <- Enum.reverse(outcomes),
            {:queue, %{workflow: workflow, round: round}} <- actions,
            do: {workflow, round}

      {last, queued}
    end

    defp round_limit?(%{state: :escalated, actions: actions}),
      do: Enum.any?(actions, &match?({:escalate, :round_limit, _points}, &1))

    defp round_limit?(_outcome), do: false

    @failing %{counted: [], failed_checks: ["explainer"]}

    test "a loop passed over after a loop keeps that loop's round: a failing check ends in round_limit after round 3" do
      seq = stage([loop([wf("implement")], 3), loop([wf("capture-demos", @demos)])])
      {last, queued} = drive(seq, @failing, 10)

      assert queued == [{"implement", 1}, {"implement", 2}, {"implement", 3}]
      assert round_limit?(last)
      assert last.position.round == 3
    end

    test "a loop passed over before a loop: a failing check ends in round_limit after round 3" do
      seq = stage([loop([wf("capture-demos", @demos)]), loop([wf("implement")], 3)])
      {last, queued} = drive(seq, @failing, 10)

      assert queued == [{"implement", 1}, {"implement", 2}, {"implement", 3}]
      assert round_limit?(last)
    end

    test "a loop passed over between two loops: the last loop's rounds count, then round_limit" do
      seq =
        stage([
          loop([wf("plan")], 3),
          loop([wf("capture-demos", @demos)]),
          loop([wf("implement")], 3)
        ])

      {last, queued} = drive(seq, @failing, 10)

      assert queued == [{"plan", 1}, {"implement", 1}, {"implement", 2}, {"implement", 3}]
      assert round_limit?(last)
    end

    test "Request changes passes over a loop passed over whole, with no round counted" do
      seq = stage([loop([wf("capture-demos", @demos)], 2), wf("verify-a-ticket")])
      outcome = Runner.step(seq, pos(2, nil, 1), :request_changes, %{counted: []})

      assert outcome.position == pos(1, nil, 1)

      assert [
               {:skip, %{workflow: "capture-demos", round: 1}},
               {:queue, %{workflow: "verify-a-ticket"}}
             ] =
               outcome.actions
    end

    test "an output with a condition is required only while its input counts" do
      output = %{"type" => "demo-video", "required" => true} |> Map.merge(@demos)

      refute Runner.required?(output, [])
      assert Runner.required?(output, ["demo-scenarios"])
      assert Runner.required?(%{"type" => "verification", "required" => true}, [])
      refute Runner.required?(%{"type" => "explainer", "required" => false}, ["demo-scenarios"])
    end

    test "condition_inputs/1 lists the input types of the stage's conditions once" do
      seq =
        stage([wf("capture-demos", @demos), loop([wf("fix", @demos)]), wf("verify-a-ticket")])
        |> Map.put("outputs", [Map.merge(%{"type" => "demo-video", "required" => true}, @demos)])

      assert Runner.condition_inputs(seq) == ["demo-scenarios"]
      assert Runner.condition_inputs(build()) == []
    end
  end

  describe "tracks and unless (A-23)" do
    @fast %{"track" => "fast-track"}

    defp track_skip(workflow, track, negated, entry, loop_entry \\ nil),
      do:
        {:skip,
         %{
           workflow: workflow,
           input: nil,
           track: track,
           negated: negated,
           entry: entry,
           loop_entry: loop_entry,
           round: 1
         }}

    test "unmet/2 is the reason: a when held back while its condition is not met, an unless while it is met" do
      standard = %{track: "standard", counted: []}
      fast = %{track: "fast-track", counted: ["spec"]}
      none = %{counted: []}

      when_fast = %{"when" => @fast}
      unless_fast = %{"unless" => @fast}

      assert Runner.unmet(when_fast, standard) == %{
               kind: :track,
               value: "fast-track",
               negated: false
             }

      assert Runner.unmet(when_fast, none) == %{kind: :track, value: "fast-track", negated: false}
      assert Runner.unmet(when_fast, fast) == nil

      assert Runner.unmet(unless_fast, fast) == %{
               kind: :track,
               value: "fast-track",
               negated: true
             }

      assert Runner.unmet(unless_fast, standard) == nil
      assert Runner.unmet(unless_fast, none) == nil

      assert Runner.unmet(%{"unless" => %{"input" => "spec"}}, fast) ==
               %{kind: :input, value: "spec", negated: true}

      assert Runner.unmet(%{"when" => %{"input" => "spec"}}, standard) ==
               %{kind: :input, value: "spec", negated: false}

      assert Runner.unmet(%{"workflow" => "x"}, fast) == nil
    end

    test "a stage with a condition that holds it back is passed over when it is entered, before it waits" do
      shape = stage([wf("write-specs")]) |> Map.put("when", %{"track" => "standard"})
      facts = %{track: "fast-track", missing_inputs: ["proposal"], undeclared: ["write-specs"]}

      outcome = Runner.step(shape, nil, :enter, facts)

      assert %{state: :done, actions: [{:skip_stage, spec}, :advance]} = outcome
      assert spec == %{input: nil, track: "standard", negated: false}

      # With the condition met, it waits as before.
      assert %{state: :waiting_inputs, actions: []} =
               Runner.step(shape, nil, :enter, %{facts | track: "standard"})
    end

    test "an unless on a stage passes it over while its condition is met" do
      shape = stage([wf("write-specs")]) |> Map.put("unless", @fast)

      assert %{actions: [{:skip_stage, %{track: "fast-track", negated: true}}, :advance]} =
               Runner.step(shape, nil, :enter, %{track: "fast-track"})

      assert %{actions: [{:queue, %{workflow: "write-specs"}}]} =
               Runner.step(shape, nil, :enter, %{track: "standard"})
    end

    test "a person's move runs the stage whatever its condition (forced)" do
      shape = stage([wf("write-specs")]) |> Map.put("when", %{"track" => "standard"})

      assert %{state: :running, actions: [{:queue, %{workflow: "write-specs"}}]} =
               Runner.step(shape, nil, :enter, %{track: "fast-track", forced: true})
    end

    test "an entry with a track condition is passed over, and the next entry starts" do
      seq = stage([wf("write-specs", %{"when" => @fast}), wf("review")])
      outcome = Runner.step(seq, nil, :enter, %{track: "standard"})

      assert outcome.position == pos(1, nil, 1)
      assert [skip, {:queue, %{workflow: "review"}}] = outcome.actions
      assert skip == track_skip("write-specs", "fast-track", false, 0)

      assert [{:queue, %{workflow: "write-specs"}}] =
               Runner.step(seq, nil, :enter, %{track: "fast-track"}).actions

      outcome =
        Runner.step(stage([wf("a", %{"unless" => @fast}), wf("b")]), nil, :enter, %{
          track: "fast-track"
        })

      unless_skip = track_skip("a", "fast-track", true, 0)

      assert [^unless_skip, {:queue, %{workflow: "b"}}] =
               outcome.actions
    end

    test "a loop with a condition that holds it back is passed over whole, each entry with the reason" do
      seq =
        stage([
          Map.put(loop([wf("fix"), wf("check")], 2), "unless", @fast),
          wf("verify")
        ])

      outcome = Runner.step(seq, nil, :enter, %{track: "fast-track"})

      assert [
               {:skip, %{workflow: "fix", loop_entry: 0, track: "fast-track", negated: true}},
               {:skip, %{workflow: "check", loop_entry: 1, track: "fast-track", negated: true}},
               {:queue, %{workflow: "verify"}}
             ] = outcome.actions

      assert [{:queue, %{workflow: "fix", loop_entry: 0}}] =
               Runner.step(seq, nil, :enter, %{track: "standard"}).actions
    end

    test "a loop passed over by its condition is not run again by Request changes" do
      seq = stage([Map.put(loop([wf("fix")], 2), "when", @fast), wf("verify")])
      outcome = Runner.step(seq, pos(1, nil, 1), :request_changes, %{track: "standard"})

      assert outcome.position == pos(1, nil, 1)
      assert [{:skip, %{workflow: "fix"}}, {:queue, %{workflow: "verify"}}] = outcome.actions
    end

    test "a stage does not wait for an undeclared workflow that a track holds back" do
      seq = stage([wf("write-specs", %{"when" => @fast}), wf("review")])

      assert %{state: :running} =
               Runner.step(seq, nil, :enter, %{track: "standard", undeclared: ["write-specs"]})

      assert %{state: :waiting_workflow} =
               Runner.step(seq, nil, :enter, %{track: "fast-track", undeclared: ["write-specs"]})

      assert Runner.workflows(seq, [], "standard") == ["review"]
      assert Runner.workflows(seq, [], "fast-track") == ["write-specs", "review"]
    end

    test "an input is waited for only while its condition does not hold it back" do
      required = %{"type" => "spec", "required" => true}
      optional = %{"type" => "spec", "required" => false}
      held = Map.put(required, "when", %{"track" => "standard"})
      unless_fast = Map.put(required, "unless", @fast)

      assert Runner.input_required?(required, %{})
      refute Runner.input_required?(optional, %{})
      assert Runner.input_required?(held, %{track: "standard"})
      refute Runner.input_required?(held, %{track: "fast-track"})
      refute Runner.input_required?(unless_fast, %{track: "fast-track"})
      assert Runner.input_required?(unless_fast, %{track: "standard"})
    end

    test "condition_inputs/1 lists the input types of a stage, a loop and an input as well" do
      seq =
        stage([
          Map.put(loop([wf("fix")]), "unless", %{"input" => "a"}),
          wf("b", %{"when" => %{"input" => "b"}})
        ])
        |> Map.put("when", %{"input" => "c"})
        |> Map.put("inputs", [%{"type" => "d", "required" => true, "unless" => %{"input" => "d"}}])

      assert Enum.sort(Runner.condition_inputs(seq)) == ["a", "b", "c", "d"]
    end
  end

  describe "the queued run" do
    test "takes the entry's machine type, else the document's, else default" do
      seq = stage([wf("a", %{"machine" => "large"}), wf("b")])
      [{:queue, a}] = Runner.step(seq, nil, :enter, %{machine: "small"}).actions
      assert a.machine_type == "large"

      [{:queue, b}] =
        Runner.step(seq, pos(0, nil, 1), {:run, {:verdict, :passed, nil}}, %{machine: "small"}).actions

      assert b.machine_type == "small"

      [{:queue, c}] = Runner.step(seq, pos(0, nil, 1), {:run, {:verdict, :passed, nil}}).actions
      assert c.machine_type == "default"
    end

    test "takes the lower time limit and access level of the entry and the declaration" do
      seq = stage([wf("a", %{"time_limit" => "10m", "access" => "read"})])

      [{:queue, spec}] =
        Runner.step(seq, nil, :enter, %{
          declarations: %{"a" => %{time_limit: "1h", access: :write}}
        }).actions

      assert spec.time_limit == 600
      assert spec.access == :read

      [{:queue, spec}] =
        Runner.step(seq, nil, :enter, %{declarations: %{"a" => %{time_limit: "5m", access: nil}}}).actions

      assert spec.time_limit == 300

      seq = stage([wf("a")])

      [{:queue, spec}] =
        Runner.step(seq, nil, :enter, %{
          declarations: %{"a" => %{time_limit: nil, access: :write}}
        }).actions

      assert spec.time_limit == nil
      assert spec.access == :write

      [{:queue, spec}] =
        Runner.step(seq, nil, :enter, %{declarations: %{"a" => %{time_limit: nil, access: :read}}}).actions

      assert spec.access == :read
    end

    test "limits/3 is the lowered limits of the entry at a position" do
      seq = build()
      declaration = %{time_limit: "20m", access: :write}

      seq =
        put_in(seq, ["sequence"], [
          wf("implement", %{"time_limit" => "1h"}),
          loop([wf("capture-demo", %{"access" => "read"}), wf("fix-demo-findings")])
        ])

      assert Runner.limits(seq, pos(0, nil, 1), declaration) == %{
               time_limit: 1200,
               access: :write
             }

      assert Runner.limits(seq, pos(1, 0, 2), nil) == %{time_limit: nil, access: :read}
      assert Runner.limits(seq, pos(1, 1, 2), nil) == %{time_limit: nil, access: nil}
      assert Runner.limits(seq, pos(2, nil, 2), nil) == nil
    end

    test "limits/4 reads for a stage's run whose position has another workflow or no entry" do
      seq =
        put_in(build(), ["sequence"], [
          wf("implement", %{"time_limit" => "1h"}),
          loop([wf("capture-demo"), wf("fix-demo-findings")])
        ])

      declaration = %{time_limit: nil, access: :write}

      assert Runner.limits(seq, pos(0, nil, 1), declaration, "lint") == %{
               time_limit: 3600,
               access: :read
             }

      assert Runner.limits(seq, pos(1, 1, 1), declaration, "lint").access == :read

      for {position, stage} <- [{pos(2, nil, 1), seq}, {pos(0, nil, 1), %{}}] do
        assert Runner.limits(stage, position, declaration, "lint") == %{
                 time_limit: nil,
                 access: :read
               }
      end
    end

    test "limits/4 leaves a run alone at an entry of its workflow, or with no workflow" do
      seq = put_in(build(), ["sequence"], [wf("implement", %{"time_limit" => "1h"})])
      declaration = %{time_limit: nil, access: :write}
      limits = %{time_limit: 3600, access: :write}

      assert Runner.limits(seq, pos(0, nil, 1), declaration, "implement") == limits
      assert Runner.limits(seq, pos(0, nil, 1), declaration, nil) == limits
      assert Runner.limits(seq, pos(1, nil, 1), declaration, nil) == nil
      assert Runner.limits(%{}, pos(0, nil, 1), declaration, nil) == nil
    end

    test "reads durations" do
      assert Runner.seconds("1h30m") == 5400
      assert Runner.seconds("15m") == 900
      assert Runner.seconds("90s") == 90
      assert Runner.seconds("1h") == 3600
      assert Runner.seconds("1m5s") == 65
      assert Runner.seconds("") == nil
      assert Runner.seconds("0m") == nil
      assert Runner.seconds("soon") == nil
      assert Runner.seconds(nil) == nil
    end
  end

  test "the document's loops and rounds" do
    assert Runner.first_loop(build()) == 1
    assert Runner.last_loop(stage([loop([wf("a")]), wf("b"), loop([wf("c")], 5), wf("d")])) == 2
    assert Runner.last_loop(stage([wf("a")])) == nil
    assert Runner.rounds(build(), 1) == 3
    assert Runner.rounds(build(), 0) == nil
    assert Runner.rounds(stage([%{"loop" => %{"body" => [wf("a")]}}]), 0) == 3
    assert Runner.workflows(build()) == ["implement", "capture-demo", "fix-demo-findings"]
  end
end
