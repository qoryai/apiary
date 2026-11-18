defmodule Apiary.Stages.SharedRunTest do
  # The entries of a stage with `shared_run: true` run as sessions of one run: what the
  # claim keeps (`Apiary.Stages.claim_sessions!/2`), the step on each session's end
  # (`Apiary.Stages.next_session/2`), the sessions it records, and the run's end at the
  # first outcome that queues no workflow of the stage.
  # Not async: the artifact store is the application's setting.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Processes, Repo, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Runs.Run
  alias Apiary.Stages.{Escalation, Session}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:factory, :workflow_model]

  @build "st_6ns22c4pav"
  @verify "st_m1mqbeywdg"
  @no_verdict %{"text" => "The run stopped before its verdict.", "action" => "run_again"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp save!(scope, stages) do
    document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => stages}
    {:ok, version} = Processes.save(scope, scope.workspace, document)
    version
  end

  defp stage(id, name, sequence, extra \\ %{}) do
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

  defp build(sequence, extra \\ %{}),
    do: stage(@build, "Build", sequence, Map.merge(%{"shared_run" => true}, extra))

  defp loop(body, rounds \\ 3), do: %{"loop" => %{"rounds" => rounds, "body" => body}}

  defp workflows(names), do: Enum.map(names, &%{"workflow" => &1})

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  defp runs(work_item),
    do:
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item.id,
          order_by: [r.take_in, r.attempt]
      )

  defp sessions(run),
    do: Repo.all(from s in Session, where: s.dispatch_run_id == ^run.id, order_by: s.sequence)

  defp escalations(work_item),
    do: Repo.all(from e in Escalation, where: e.work_item_id == ^work_item.id)

  # The run stores the verdict `verdict` during its session, as a run does through the run API.
  defp verdict!(run, verdict) do
    {:ok, _version} =
      Stages.Artifacts.push_json(
        {:run, run},
        Repo.get!(WorkItem, run.work_item_id),
        "verdict",
        %{"verdict" => verdict},
        stage_id: run.stage_id
      )

    :ok
  end

  # The work item placed in the process version `version`, as a new version of the
  # workspace places it.
  defp move!(work_item, version) do
    {1, _rows} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [process_version_id: version.id]
      )

    :ok
  end

  defp report(run, session, state \\ "succeeded"),
    do: Stages.next_session(run, %{session: session, state: state, reason: nil})

  # What the claim of `run` keeps for its sessions, with the time limits as it read them
  # (`limits`, none to read them now), as `Apiary.Dispatches.Handover` calls it.
  defp claim!(run, limits \\ %{}) do
    {:ok, :ok} = Repo.transact(fn -> {:ok, Stages.claim_sessions!(run, limits)} end)
    run
  end

  defp session_settings(run),
    do: Repo.one!(from r in Run, where: r.dispatch_run_id == ^run.id, select: r.session_settings)

  # The work item taken in at the first stage, and its one run, not ended, claimed with the
  # access level `level`, the level its harness walk resolved.
  defp taken_in!(scope, level \\ :read) do
    work_item = taken_in_fixture(scope)
    run = newest_run(work_item)
    walk!(run, level)
    {work_item, claim!(run)}
  end

  defp walk!(run, level) do
    case Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^run.id),
           set: [access_level: level]
         ) do
      {0, _rows} ->
        Repo.insert!(%RunHarness{
          dispatch_run_id: run.id,
          state: :resolved,
          origin: :none,
          access_level: level
        })

      {1, _rows} ->
        :ok
    end
  end

  describe "a stage of four workflows and no loop" do
    test "runs as one run of four sessions, each started by the verdict of the one before", %{
      scope: scope
    } do
      names = ~w(plan-the-build write-acceptance-checks implement-changes review-changes)

      save!(scope, [
        build(workflows(names)),
        stage(@verify, "Verify", workflows(["verify-a-ticket"]))
      ])

      {work_item, run} = taken_in!(scope)
      assert %DispatchRun{workflow: "plan-the-build", stage_entry: 0} = run

      for {workflow, session} <- Enum.with_index(tl(names), 2) do
        :ok = verdict!(run, "passed")

        assert {:session, next} = report(run, session - 1)

        assert next == %{
                 session: session,
                 workflow: workflow,
                 model_choice: nil,
                 model_credential: nil,
                 time_limit_minutes: 180,
                 full_suite: false,
                 inputs: next.inputs
               }

        assert %{"version" => 1, "work_item" => %{}, "run" => %{}} = next.inputs
        assert %WorkItem{stage_id: @build, stage_state: :running} = reload(work_item)
        assert reload(work_item).stage_entry == session - 1
      end

      :ok = verdict!(run, "passed")
      assert report(run, 4) == :end

      assert %WorkItem{stage_id: @build, stage_state: :at_gate} = reload(work_item)
      assert runs(work_item) |> Enum.map(& &1.id) == [run.id]

      assert [
               {1, 1, "plan-the-build", "succeeded"},
               {2, 2, "write-acceptance-checks", "succeeded"},
               {3, 3, "implement-changes", "succeeded"},
               {4, 4, "review-changes", "succeeded"}
             ] = for(s <- sessions(run), do: {s.sequence, s.forager_session, s.workflow, s.state})
    end

    test "a session with no verdict escalates as a run of today with no verdict", %{scope: scope} do
      save!(scope, [
        build(workflows(~w(plan-the-build write-acceptance-checks implement-changes)))
      ])

      {work_item, run} = taken_in!(scope)

      :ok = verdict!(run, "passed")
      assert {:session, %{workflow: "write-acceptance-checks"}} = report(run, 1)

      # The verdict of the session before does not count again.
      assert report(run, 2) == :end

      assert %WorkItem{stage_state: :escalated, stage_entry: 1} = reload(work_item)
      assert [%Escalation{cause: :run_stopped, points: [@no_verdict]}] = escalations(work_item)
    end

    test "a failed session stops the run as a run of today that ended without a result", %{
      scope: scope
    } do
      save!(scope, [build(workflows(~w(plan-the-build write-acceptance-checks)))])
      {work_item, run} = taken_in!(scope)

      assert report(run, 1, "failed") == :end
      assert %WorkItem{stage_state: :escalated, stage_entry: 0} = reload(work_item)

      assert [
               %Escalation{
                 cause: :run_stopped,
                 points: [
                   %{
                     "text" => "The run stopped: it ended without a result.",
                     "action" => "run_again"
                   }
                 ]
               }
             ] = escalations(work_item)
    end
  end

  describe "a stage with a loop" do
    test "a session with no verdict in the loop runs the next workflow of the ring; changes requested run round 2, and round 3 ends the run with the escalation",
         %{scope: scope} do
      save!(scope, [
        build(
          workflows(~w(plan-the-build write-acceptance-checks)) ++
            [loop(workflows(~w(implement-changes review-changes)))]
        )
      ])

      {work_item, run} = taken_in!(scope, :write)

      :ok = verdict!(run, "passed")
      assert {:session, %{session: 2, full_suite: false}} = report(run, 1)
      :ok = verdict!(run, "passed")

      assert {:session, %{session: 3, workflow: "implement-changes", full_suite: true}} =
               report(run, 2)

      # implement-changes stores no verdict: the ring runs review-changes.
      assert {:session, %{session: 4, workflow: "review-changes", full_suite: true}} =
               report(run, 3)

      for {round, session} <- [{2, 5}, {3, 7}] do
        :ok = verdict!(run, "changes-requested")

        assert {:session, %{session: ^session, workflow: "implement-changes"}} =
                 report(run, session - 1)

        assert %WorkItem{stage_round: ^round, loop_entry: 0} = reload(work_item)

        assert {:session, %{workflow: "review-changes"}} = report(run, session)
      end

      :ok = verdict!(run, "changes-requested")
      assert report(run, 8) == :end

      assert %WorkItem{stage_state: :escalated, stage_round: 3} = reload(work_item)
      assert [%Escalation{cause: :round_limit}] = escalations(work_item)
      assert length(runs(work_item)) == 1
    end

    test "a session's time limit is its workflow's in the time limits", %{scope: scope} do
      save!(scope, [build(workflows(~w(plan-the-build write-acceptance-checks)))])

      {:ok, _limit} =
        Apiary.TimeLimits.put_limit(scope, :workspace, "write-acceptance-checks", 45)

      {_work_item, run} = taken_in!(scope)

      :ok = verdict!(run, "passed")
      assert {:session, %{time_limit_minutes: 45}} = report(run, 1)
    end

    test "a time limit saved after the claim changes nothing for the run", %{scope: scope} do
      save!(scope, [build(workflows(~w(plan-the-build write-acceptance-checks)))])

      {:ok, _limit} =
        Apiary.TimeLimits.put_limit(scope, :workspace, "write-acceptance-checks", 45)

      {_work_item, run} = taken_in!(scope)

      {:ok, _limit} =
        Apiary.TimeLimits.put_limit(scope, :workspace, "write-acceptance-checks", 300)

      :ok = verdict!(run, "passed")
      assert {:session, %{time_limit_minutes: 45}} = report(run, 1)
    end

    test "the claim keeps each entry's settings, by its place, and the run's first session, for a write run",
         %{scope: scope} do
      save!(scope, [
        build([
          %{"workflow" => "plan-the-build"},
          %{"workflow" => "implement-changes", "first_attempt" => true},
          loop(workflows(~w(implement-changes review-changes)))
        ])
      ])

      {:ok, _limit} = Apiary.TimeLimits.put_limit(scope, :workspace, "implement-changes", 60)
      {_work_item, run} = taken_in!(scope, :write)

      assert session_settings(run) == %{
               "0" => %{
                 "workflow" => "plan-the-build",
                 "time_limit_minutes" => 180,
                 "full_suite" => false
               },
               "1" => %{
                 "workflow" => "implement-changes",
                 "time_limit_minutes" => 60,
                 "full_suite" => true
               },
               "2.0" => %{
                 "workflow" => "implement-changes",
                 "time_limit_minutes" => 60,
                 "full_suite" => true
               },
               "2.1" => %{
                 "workflow" => "review-changes",
                 "time_limit_minutes" => 180,
                 "full_suite" => true
               }
             }

      assert [%Session{sequence: 1, forager_session: nil, stage_entry: 0, round: 1} = first] =
               sessions(run)

      assert first.workflow == "plan-the-build"
      assert Stages.shared_workflows(run) == ~w(plan-the-build implement-changes review-changes)
    end

    test "a second claim of the run replaces what the first kept", %{scope: scope} do
      save!(scope, [build(workflows(~w(plan-the-build write-acceptance-checks)))])
      {_work_item, run} = taken_in!(scope)
      [%Session{id: first_id}] = sessions(run)

      # The lease of the first claim lapsed, and the run is claimed again with other limits.
      claim!(run, %{"plan-the-build" => 30, "write-acceptance-checks" => 90})

      assert %{"0" => %{"time_limit_minutes" => 30}, "1" => %{"time_limit_minutes" => 90}} =
               session_settings(run)

      assert [%Session{sequence: 1, forager_session: nil} = again] = sessions(run)
      refute again.id == first_id

      :ok = verdict!(run, "passed")
      assert {:session, %{session: 2, time_limit_minutes: 90}} = report(run, 1)
    end

    test "an entry with first_attempt of a write run runs the full suite after its session",
         %{scope: scope} do
      save!(scope, [
        build([
          %{"workflow" => "plan-the-build"},
          %{"workflow" => "implement-changes", "first_attempt" => true}
        ])
      ])

      {_work_item, run} = taken_in!(scope, :write)
      :ok = verdict!(run, "passed")
      assert {:session, %{workflow: "implement-changes", full_suite: true}} = report(run, 1)
    end

    test "a run that reads or does not push runs no full suite after any session", %{
      scope: scope
    } do
      for level <- [:read, :write_no_push] do
        %{scope: scope} = if level == :read, do: %{scope: scope}, else: sign_up_fixture()

        save!(scope, [
          build([
            %{"workflow" => "plan-the-build"},
            %{"workflow" => "implement-changes", "first_attempt" => true},
            loop(workflows(~w(implement-changes review-changes)))
          ])
        ])

        {_work_item, run} = taken_in!(scope, level)

        assert session_settings(run) |> Map.values() |> Enum.map(& &1["full_suite"]) ==
                 [false, false, false, false]

        :ok = verdict!(run, "passed")
        assert {:session, %{workflow: "implement-changes", full_suite: false}} = report(run, 1)
      end
    end
  end

  describe "a repeat and the errors" do
    setup %{scope: scope} do
      save!(scope, [build(workflows(~w(plan-the-build write-acceptance-checks)))])
      {work_item, run} = taken_in!(scope)
      %{work_item: work_item, run: run}
    end

    test "a repeat for the same session returns the stored result and steps once", %{
      work_item: work_item,
      run: run
    } do
      :ok = verdict!(run, "passed")
      assert {:session, first} = report(run, 1)
      placed = Map.take(reload(work_item), [:stage_entry, :stage_state, :stage_round])

      assert report(run, 1) == {:session, first}
      assert Map.take(reload(work_item), [:stage_entry, :stage_state, :stage_round]) == placed
      assert length(sessions(run)) == 2

      # The second session stores no verdict: the stage escalates once.
      assert report(run, 2) == :end
      assert report(run, 2) == :end
      assert length(escalations(work_item)) == 1
      assert length(sessions(run)) == 2
    end

    test "a lower session is a mismatch, and a session after the end is an error", %{run: run} do
      :ok = verdict!(run, "passed")
      assert {:session, _next} = report(run, 3)
      assert report(run, 2) == {:error, :session_mismatch}
      assert report(run, 4) == :end
      assert report(run, 1) == {:error, :session_mismatch}
      assert report(run, 5) == {:error, :run_ended}
    end

    test "an ended run, and one a member cancelled, are an error", %{scope: scope, run: run} do
      Apiary.RunEventsFixtures.run_fixture(scope, %{
        dispatch_run_id: run.id,
        cancel_requested_at: DateTime.utc_now()
      })

      assert report(run, 1) == {:error, :run_cancelled}

      run |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended) |> Repo.update!()
      assert report(run, 1) == {:error, :run_ended}
      assert [%Session{sequence: 1, forager_session: nil, response: nil}] = sessions(run)
    end

    test "a work item placed in another version whose stage differs only in machine types goes on",
         %{scope: scope, work_item: work_item, run: run} do
      same =
        for name <- ~w(plan-the-build write-acceptance-checks),
            do: %{"workflow" => name, "machine" => "default"}

      other =
        save!(scope, [build(same), stage(@verify, "Verify", workflows(["verify-a-ticket"]))])

      move!(work_item, other)

      :ok = verdict!(run, "passed")
      assert {:session, %{session: 2, workflow: "write-acceptance-checks"}} = report(run, 1)
      assert %WorkItem{stage_entry: 1, stage_state: :running} = reload(work_item)
    end

    test "a work item placed in another version whose stage is reordered or shorter ends the run, and nothing is written",
         %{scope: scope, work_item: work_item, run: run} do
      :ok = verdict!(run, "passed")
      placed = Map.take(reload(work_item), [:stage_entry, :stage_state, :stage_round])

      for sequence <- [
            workflows(~w(plan-the-build review-changes write-acceptance-checks)),
            workflows(~w(plan-the-build))
          ] do
        move!(work_item, save!(scope, [build(sequence)]))

        assert report(run, 1) == {:error, :run_ended}
        assert [%Session{sequence: 1, forager_session: nil, response: nil}] = sessions(run)
        assert Map.take(reload(work_item), [:stage_entry, :stage_state, :stage_round]) == placed
        assert escalations(work_item) == []
      end
    end

    test "a next entry with no settings the claim kept ends the run, and nothing is written",
         %{work_item: work_item, run: run} do
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.dispatch_run_id == ^run.id),
          set: [session_settings: Map.delete(session_settings(run), "1")]
        )

      :ok = verdict!(run, "passed")

      assert report(run, 1) == {:error, :run_ended}
      assert [%Session{sequence: 1, forager_session: nil, response: nil}] = sessions(run)
      assert %WorkItem{stage_entry: 0, stage_state: :running} = reload(work_item)
      assert escalations(work_item) == []
    end

    test "a run that no claim of a shared stage registered is not found", %{scope: scope} do
      work_item = taken_in_fixture(scope)
      run = newest_run(work_item)

      :ok = verdict!(run, "passed")
      assert report(run, 1) == {:error, :not_found}
      assert sessions(run) == []
      assert reload(work_item).stage_entry == 0
    end

    test "a report of another form is an error", %{run: run} do
      assert Stages.next_session(run, %{session: 1, state: "paused", reason: nil}) ==
               {:error, :invalid_request}

      assert Stages.next_session(run, %{session: 0, state: "succeeded"}) ==
               {:error, :invalid_request}

      assert Stages.next_session(run, %{session: 1, state: "failed", reason: 3}) ==
               {:error, :invalid_request}
    end
  end

  describe "a run that pauses" do
    test "in its second session continues that session's entry, and its next session steps on",
         %{scope: scope} do
      save!(scope, [
        build(workflows(~w(plan-the-build write-acceptance-checks implement-changes)))
      ])

      {work_item, run} = taken_in!(scope)
      :ok = verdict!(run, "passed")
      assert {:session, %{session: 2, workflow: "write-acceptance-checks"}} = report(run, 1)

      # The run ends at its model keys' limit in session 2, and its continuation is queued
      # (`Apiary.Dispatches.requeue_for_pause/2`).
      {:ok, continuation} =
        Repo.transact(fn ->
          run
          |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended)
          |> Repo.update!()
          |> Apiary.Dispatches.requeue_for_pause(nil)
        end)

      assert %DispatchRun{
               workflow: "write-acceptance-checks",
               stage_entry: 1,
               loop_entry: nil,
               round: 1
             } = continuation

      walk!(continuation, :read)
      continuation = claim!(continuation)

      assert [%Session{sequence: 1, workflow: "write-acceptance-checks", stage_entry: 1}] =
               sessions(continuation)

      :ok = verdict!(continuation, "passed")

      assert {:session, %{session: 2, workflow: "implement-changes"}} =
               report(continuation, 1)

      assert %WorkItem{stage_entry: 2, stage_state: :running} = reload(work_item)
    end

    # The session ids of the run's sessions: each writes its transcript at a path of its id.
    @session_ids %{1 => "a1b2c3d4", 2 => "e5f6a7b8"}

    defp transcript_path(session),
      do: "~/.claude/projects/-workspace/#{@session_ids[session]}.jsonl"

    defp transcript(session, bytes),
      do: %{
        "session" => session,
        "session_id" => @session_ids[session],
        "path" => transcript_path(session),
        "offset" => 0,
        "bytes" => Base.encode64(bytes)
      }

    # The registered run of `run`, which ran a session for each of `ran`, each with a
    # transcript chunk unless it is one of `silent`, and paused at its model keys' limit in
    # the last of them; then its run of the queue ended and continued, as
    # `Apiary.Dispatches.RunEnd` does. The registered run and the continuation.
    defp paused_in!(scope, run, ran, silent \\ []) do
      registered =
        Apiary.RunEventsFixtures.run_fixture(scope, %{
          dispatch_run_id: run.id,
          node_run_id: run.run_id,
          registered_at: DateTime.utc_now(),
          registration_labels: %{},
          registration_about: %{},
          registration_digest: :crypto.hash(:sha256, "registration"),
          registration_interval_seconds: 30,
          registration_answer_digest: Apiary.Policy.Render.digest(~s({"version":1}))
        })

      paused = List.last(ran)

      # Each later session's chunk has a lower sequence than the chunk of the session
      # before it, so a chunk of an earlier session is the run's newest.
      chunks =
        for session <- ran,
            session not in silent,
            do: {10 - session, "session.transcript", transcript(session, ~s({"s":#{session}}\n))}

      exits =
        for session <- ran do
          state = if session == paused, do: "paused", else: "succeeded"
          reason = if session == paused, do: "model_key_limit"
          data = %{"session" => session, "state" => state, "exit_code" => 1, "reason" => reason}
          {10 + session, "session.exited", data}
        end

      exited = %{"state" => "paused", "reason" => "model_key_limit", "exit_code" => 143}
      Apiary.RunEventsFixtures.events_fixture(registered, chunks ++ exits)
      Apiary.RunEventsFixtures.event_fixture(registered, 20, "run.exited", exited)
      assert {:ok, %Run{state: "paused"}} = Apiary.Runs.Projector.project(registered)

      {:ok, continuation} =
        Repo.transact(fn ->
          run
          |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended)
          |> Repo.update!()
          |> Apiary.Dispatches.requeue_for_pause(nil)
        end)

      {Repo.get!(Run, registered.id), continuation}
    end

    test "in its second session of three resumes the second session", %{scope: scope} do
      save!(scope, [
        build(workflows(~w(plan-the-build write-acceptance-checks implement-changes)))
      ])

      {_work_item, run} = taken_in!(scope)
      :ok = verdict!(run, "passed")
      assert {:session, %{session: 2, workflow: "write-acceptance-checks"}} = report(run, 1)

      {paused, continuation} = paused_in!(scope, run, [1, 2])
      assert paused.paused_session == 2
      assert %{session_id: "a1b2c3d4"} = Apiary.Runs.Transcript.last(paused.id)

      # The continuation starts at session 2's entry, and resumes session 2's transcript.
      assert %DispatchRun{workflow: "write-acceptance-checks", stage_entry: 1} = continuation

      assert %{"session_id" => "e5f6a7b8", "path" => path} =
               Apiary.Runs.Transcript.resume_at_claim(continuation)

      assert path == transcript_path(2)

      walk!(continuation, :read)

      assert [%Session{sequence: 1, workflow: "write-acceptance-checks"}] =
               continuation |> claim!() |> sessions()
    end

    test "in a second session that wrote no transcript starts that session afresh", %{
      scope: scope
    } do
      save!(scope, [
        build(workflows(~w(plan-the-build write-acceptance-checks implement-changes)))
      ])

      {_work_item, run} = taken_in!(scope)
      :ok = verdict!(run, "passed")
      assert {:session, %{session: 2}} = report(run, 1)

      {paused, continuation} = paused_in!(scope, run, [1, 2], [2])
      assert paused.paused_session == 2

      # Session 1's transcript is there, but the continuation resumes no session: it runs
      # session 2's workflow in a new session.
      assert Apiary.Runs.Transcript.last(paused.id) != nil
      assert Apiary.Runs.Transcript.resume_at_claim(continuation) == nil
      assert %DispatchRun{workflow: "write-acceptance-checks", stage_entry: 1} = continuation
    end
  end

  describe "the end of a run after a session" do
    setup %{scope: scope} do
      save!(scope, [build(workflows(~w(plan-the-build write-acceptance-checks)))])
      {work_item, run} = taken_in!(scope)

      ended =
        run
        |> Ecto.Changeset.change(state: :ended, end_cause: :ticket_gone, result_outcome: :error)
        |> Repo.update!()

      %{work_item: work_item, run: ended}
    end

    test "is unknown for a run that registered no start, though an earlier claim kept its first session",
         %{work_item: work_item, run: run} do
      assert [%Session{sequence: 1}] = sessions(run)
      assert Stages.ended_after_session(run) == nil

      assert Apiary.Stages.StopCause.text(run, reload(work_item)) ==
               "The run did not start, because the work item's ticket is no longer in Qory Apiary.\n" <>
                 "Close the work item, or take the ticket in again."
    end

    test "is the newest session of a run that registered a start", %{
      work_item: work_item,
      run: run
    } do
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.dispatch_run_id == ^run.id),
          set: [started_at: DateTime.utc_now()]
        )

      assert Stages.ended_after_session(run) == 1

      assert Apiary.Stages.StopCause.text(run, reload(work_item)) ==
               "The work item's ticket is no longer in Qory Apiary, so the run ended after session 1.\n" <>
                 "Close the work item, or take the ticket in again."

      assert Apiary.Stages.StopCause.text(%{run | end_cause: :inputs_invalid}, reload(work_item)) ==
               "A value in the ticket or the work item breaks a rule for the input of the next session, such as its size limit, so the run ended after session 1.\n" <>
                 "Whoever can edit the ticket where it comes from shortens or corrects it, then takes it in again."
    end
  end

  test "a run of a stage without shared_run is not found, and runs one entry as today", %{
    scope: scope
  } do
    save!(scope, [
      stage(@build, "Build", workflows(~w(plan-the-build write-acceptance-checks)))
    ])

    {work_item, run} = taken_in!(scope)
    :ok = verdict!(run, "passed")
    assert report(run, 1) == {:error, :not_found}

    assert Stages.next_session(Ecto.UUID.generate(), %{session: 1, state: "succeeded"}) ==
             {:error, :not_found}

    assert reload(work_item).stage_entry == 0
    assert sessions(run) == []
    assert session_settings(run) == nil
  end

  # The registered run of `run`, claimed again after it, as a claim writes the run record
  # before it keeps what the sessions read.
  defp registered!(scope, run) do
    registered = Apiary.RunEventsFixtures.run_fixture(scope, %{dispatch_run_id: run.id})
    claim!(run)
    registered
  end

  # qory closes the run: its exit, settled as the projection settles it.
  defp exited!(run, registered) do
    now = DateTime.utc_now()

    registered
    |> Ecto.Changeset.change(
      state: "completed",
      exit_state: "completed",
      started_at: DateTime.add(now, -90, :second),
      exited_at: DateTime.add(now, -60, :second),
      outcome_state: "succeeded",
      outcome_time: DateTime.add(now, -60, :second),
      outcome_received_at: DateTime.add(now, -30, :second),
      outcome_digest: :crypto.strong_rand_bytes(32)
    )
    |> Repo.update!()

    run
    |> Repo.reload!()
    |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended)
    |> Repo.update!()

    run.id |> Apiary.Dispatches.Settle.settle() |> Apiary.Dispatches.broadcast()
  end

  describe "a run that ends with no report of its newest session" do
    setup %{scope: scope} do
      save!(scope, [
        build(workflows(~w(plan-the-build write-acceptance-checks implement-changes)))
      ])

      {work_item, run} = taken_in!(scope)
      registered = registered!(scope, run)

      :ok = verdict!(run, "passed")
      assert {:session, %{workflow: "write-acceptance-checks"}} = report(run, 1)
      %{work_item: work_item, run: run, registered_run: registered}
    end

    test "does not step again on the verdict that the last session's step used", ctx do
      # Session 2 stores no verdict, and qory closes the run with no report of it, as
      # after a failed push step.
      exited!(ctx.run, ctx.registered_run)

      assert %WorkItem{stage_state: :escalated, stage_entry: 1} = reload(ctx.work_item)

      assert [%Escalation{cause: :run_stopped, points: [@no_verdict]}] =
               escalations(ctx.work_item)

      assert runs(ctx.work_item) |> Enum.map(& &1.id) == [ctx.run.id]
    end

    test "steps on a verdict that the run stored after the last session's step", ctx do
      :ok = verdict!(ctx.run, "passed")
      exited!(ctx.run, ctx.registered_run)

      assert %WorkItem{stage_state: :running, stage_entry: 2} = reload(ctx.work_item)
      assert [_shared, %DispatchRun{workflow: "implement-changes"}] = runs(ctx.work_item)
      assert escalations(ctx.work_item) == []
    end
  end

  test "a last stage with gate none closes the work item at the end of the run's last session",
       %{scope: scope} do
    save!(scope, [
      build(workflows(~w(plan-the-build review-changes)), %{"gate" => %{"kind" => "none"}})
    ])

    {work_item, run} = taken_in!(scope)
    registered = registered!(scope, run)

    # A run that reports its sessions is handed over.
    run |> Ecto.Changeset.change(state: :handed_over) |> Repo.update!()

    :ok = verdict!(run, "passed")
    assert {:session, %{workflow: "review-changes"}} = report(run, 1)
    :ok = verdict!(run, "passed")
    assert report(run, 2) == :end

    # The work item closes while the run is still open, and the close leaves the run as it
    # is: only a run not yet handed over ends with its work item.
    assert %WorkItem{state: :closed, stage_state: :done} = reload(work_item)
    assert %DispatchRun{state: :handed_over, end_cause: nil} = Repo.get!(DispatchRun, run.id)

    # A repeat of the report returns the end again and steps nothing.
    assert report(run, 2) == :end

    # qory closes the run after the end: the stage runner steps no more.
    exited!(run, registered)

    assert %WorkItem{state: :closed, stage_state: :done} = reload(work_item)
    assert %DispatchRun{state: :ended, end_cause: :run_ended} = Repo.get!(DispatchRun, run.id)
    assert escalations(work_item) == []
    assert runs(work_item) |> Enum.map(& &1.id) == [run.id]
    assert length(sessions(run)) == 2
  end

  test "a member's answer to a question that Verify asked starts verify-a-ticket alone", %{
    scope: scope
  } do
    save!(scope, [
      build(workflows(~w(plan-the-build triage-review)), %{"gate" => %{"kind" => "none"}}),
      stage(@verify, "Verify", workflows(["verify-a-ticket"]), %{"shared_run" => true})
    ])

    {work_item, build_run} = taken_in!(scope)

    # Build's two sessions pass, and its gate none passes on: Verify's run is queued
    # through today's dispatch, and Build's run ends.
    :ok = verdict!(build_run, "passed")
    assert {:session, %{workflow: "triage-review"}} = report(build_run, 1)
    :ok = verdict!(build_run, "passed")
    assert report(build_run, 2) == :end

    assert %WorkItem{stage_id: @verify, stage_state: :running} = reload(work_item)
    verify_run = newest_run(work_item)
    assert %DispatchRun{workflow: "verify-a-ticket", stage_id: @verify} = verify_run
    build_run |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended) |> Repo.update!()

    # Build's run ends after its end: the stage runner steps no more.
    assert {:ok, []} = Repo.transact(fn -> {:ok, Stages.run_ended(build_run.id)} end)
    assert %WorkItem{stage_id: @verify, stage_state: :running} = reload(work_item)

    # Verify's session asks a question, and the stage waits for its answer.
    registered = Apiary.RunEventsFixtures.run_fixture(scope, %{dispatch_run_id: verify_run.id})
    claim!(verify_run)
    push_output!(verify_run, registered, questions_result(["Which browser?"]))
    assert report(verify_run, 1) == :end
    assert %WorkItem{stage_id: @verify, stage_state: :waiting_answers} = reload(work_item)

    # qory closes the run after the end: its exit, settled as the projection settles it.
    now = DateTime.utc_now()

    registered
    |> Ecto.Changeset.change(
      state: "completed",
      exit_state: "completed",
      started_at: DateTime.add(now, -90, :second),
      exited_at: DateTime.add(now, -60, :second),
      outcome_state: "succeeded",
      outcome_time: DateTime.add(now, -60, :second),
      outcome_received_at: DateTime.add(now, -30, :second),
      outcome_digest: :crypto.strong_rand_bytes(32)
    )
    |> Repo.update!()

    verify_run |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended) |> Repo.update!()
    verify_run.id |> Apiary.Dispatches.Settle.settle() |> Apiary.Dispatches.broadcast()
    assert %WorkItem{stage_id: @verify, stage_state: :waiting_answers} = reload(work_item)

    {:ok, _work_item} =
      WorkItems.answer(scope, reload(work_item), verify_run.attempt, %{"1" => "Firefox."})

    build_id = build_run.id
    verify_id = verify_run.id
    assert [%{id: ^build_id}, %{id: ^verify_id}, answered] = runs(work_item)

    assert %DispatchRun{workflow: "verify-a-ticket", stage_id: @verify, stage_entry: 0} =
             answered

    refute Enum.any?(runs(work_item), &(&1.workflow == "triage-review"))
    assert length(sessions(build_run)) == 2
    assert %WorkItem{stage_id: @verify, stage_state: :running} = reload(work_item)
  end
end
