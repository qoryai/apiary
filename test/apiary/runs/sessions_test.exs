defmodule Apiary.Runs.SessionsTest do
  # The record of each session of a run (`Apiary.Runs.Sessions`, `Apiary.Runs.SessionRecord`):
  # what is read from the events of a run, and the rows the projector writes from them,
  # kept when the run is projected again.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, except: [at: 1]
  import Apiary.RunListFixtures, only: [queue_run!: 3]

  alias Apiary.Dispatches.{DispatchRun, RunEnd}
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.{Event, Projector, Run, SessionKeyWindow, SessionRecord, Sessions}
  alias Apiary.Stages.Session

  @t0 ~U[2026-11-18 09:00:00.000000Z]
  @build "st_6ns22c4pav"
  @key_id "5d7e3a10-2f4b-4c6d-8e90-1a2b3c4d5e6f"

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  defp event(sequence, type, data, seconds \\ nil),
    do: %{
      type: "dev.qory." <> type,
      sequence: sequence,
      time: at(seconds || sequence),
      data: data
    }

  defp result(sequence, session, attrs),
    do: event(sequence, "runtime.result", Map.merge(%{"session" => session}, Map.new(attrs)))

  defp read(events), do: Sessions.read(events)

  describe "read/1" do
    test "takes the cost, the tokens and the time of a session from its last result line" do
      events = [
        event(1, "session.started", %{"session" => 1, "runtime" => "claude"}, 0),
        event(2, "runtime.started", %{"session" => 1, "model" => "model-large"}),
        result(3, 1, %{
          "line" => 4,
          "outcome" => "success",
          "turns" => 2,
          "duration_ms" => 9_501,
          "cost_usd" => 0.0043,
          "usage" => %{"input" => 14, "output" => 600, "cache_read" => 100, "cache_write" => 50}
        }),
        result(4, 1, %{
          "line" => 9,
          "outcome" => "success",
          "turns" => 1,
          "duration_ms" => 1_490,
          "cost_usd" => 0.0086,
          "usage" => %{
            "input" => 14,
            "output" => 656,
            "cache_read" => 136_111,
            "cache_write" => 68
          }
        }),
        result(5, 1, %{
          "line" => 11,
          "outcome" => "success",
          "turns" => 0,
          "duration_ms" => 3,
          "cost_usd" => 0.0129,
          "usage" => %{
            "input" => 14,
            "output" => 656,
            "cache_read" => 136_111,
            "cache_write" => 68_908
          }
        }),
        event(6, "session.exited", %{"session" => 1, "state" => "succeeded"}, 90)
      ]

      assert [session] = read(events)

      assert %{
               session_number: 1,
               started_at: @t0,
               ended_at: ended_at,
               model: "model-large",
               cost_usd: cost,
               input_tokens: 14,
               output_tokens: 656,
               cache_read_tokens: 136_111,
               cache_write_tokens: 68_908,
               # The turns and the time of each line are its own: they are summed.
               turns: 3,
               duration_ms: 10_994,
               error: false
             } = session

      assert ended_at == at(90)
      assert Decimal.equal?(cost, Decimal.new("0.0129"))
    end

    test "a line that is an error marks the session, and the last line is by its line number" do
      events = [
        result(1, 1, %{"line" => 7, "cost_usd" => 0.02, "is_error" => true}),
        result(2, 1, %{"line" => 3, "cost_usd" => 0.01, "is_error" => false})
      ]

      assert [%{error: true, cost_usd: cost}] = read(events)
      # Line 7 is the later line of the output, though its event came first.
      assert Decimal.equal?(cost, Decimal.new("0.02"))

      # With no line numbers the sequence decides.
      events = [
        result(1, 1, %{"cost_usd" => 0.02}),
        result(2, 1, %{"cost_usd" => 0.01})
      ]

      assert [%{cost_usd: cost}] = read(events)
      assert Decimal.equal?(cost, Decimal.new("0.01"))
    end

    test "the lines without a line number come after those with one, in any mix" do
      events = [
        result(1, 1, %{"line" => 9, "cost_usd" => 0.1}),
        result(2, 1, %{"cost_usd" => 0.2}),
        result(3, 1, %{"line" => 4, "cost_usd" => 0.3})
      ]

      # Line 4, line 9, then the one with none: by `line` and not by arrival.
      assert [%{cost_usd: cost}] = read(events)
      assert Decimal.equal?(cost, Decimal.new("0.2"))

      events = [
        result(1, 1, %{"cost_usd" => 0.5}),
        result(2, 1, %{"line" => 5, "cost_usd" => 0.01}),
        result(3, 1, %{"line" => 2, "cost_usd" => 0.03}),
        result(4, 1, %{"cost_usd" => 0.7})
      ]

      # Of the two with none, the later event is the last.
      assert [%{cost_usd: cost}] = read(events)
      assert Decimal.equal?(cost, Decimal.new("0.7"))
      assert Decimal.equal?(Sessions.cost(events), Decimal.new("0.7"))
    end

    test "turns and time are summed over the lines that have them, to the column's bound" do
      assert [%{turns: 5, duration_ms: 12}] =
               read([
                 result(1, 1, %{"turns" => 2, "duration_ms" => 5}),
                 result(2, 1, %{"outcome" => "success"}),
                 result(3, 1, %{"turns" => 3, "duration_ms" => 7})
               ])

      assert [%{turns: 2_147_483_647, duration_ms: 9_223_372_036_854_775_807}] =
               read([
                 result(1, 1, %{
                   "turns" => 2_147_483_647,
                   "duration_ms" => 9_223_372_036_854_775_807
                 }),
                 result(2, 1, %{"turns" => 4, "duration_ms" => 5})
               ])
    end

    test "a value no result carries is unknown, never 0" do
      assert [session] = read([result(1, 1, %{"outcome" => "success"})])

      assert %{
               cost_usd: nil,
               turns: nil,
               duration_ms: nil,
               input_tokens: nil,
               output_tokens: nil,
               cache_read_tokens: nil,
               cache_write_tokens: nil,
               error: false,
               model: nil,
               started_at: nil,
               ended_at: nil
             } = session

      # A value outside its bounds is absent too.
      assert [%{cost_usd: nil, turns: nil, input_tokens: nil}] =
               read([
                 result(1, 1, %{
                   "cost_usd" => -1,
                   "turns" => -2,
                   "usage" => %{"input" => -3, "output" => "many"}
                 })
               ])
    end

    test "a result with no session is of session 1, and a subagent's start is not the model" do
      events = [
        event(1, "runtime.started", %{"model" => "model-large"}),
        event(2, "runtime.started", %{
          "session" => 1,
          "agent_id" => "a1",
          "model" => "model-small"
        }),
        event(3, "runtime.result", %{"cost_usd" => 0.5})
      ]

      assert [%{session_number: 1, model: "model-large", cost_usd: cost}] = read(events)
      assert Decimal.equal?(cost, Decimal.new("0.5"))
    end

    test "has a session that started, or that has a result, and not a bare one or a refused join" do
      events = [
        event(1, "session.started", %{"session" => 1, "bare" => true}),
        event(2, "session.exited", %{"session" => 1, "state" => "succeeded"}),
        # A refused join has an exit and no start.
        event(3, "session.exited", %{"session" => 2, "state" => "failed", "reason" => "refused"}),
        event(4, "session.started", %{"session" => 3, "runtime" => "claude"}),
        event(5, "session.exited", %{"session" => 3, "state" => "failed"}),
        result(6, 4, %{"cost_usd" => 1})
      ]

      assert read(events) |> Enum.map(& &1.session_number) == [3, 4]
    end

    test "costs a run once for each session's last line" do
      results = [
        result(4, 1, %{"cost_usd" => 0.0043}),
        result(5, 1, %{"cost_usd" => 0.0086}),
        result(6, 1, %{"cost_usd" => 0.0129}),
        result(9, 2, %{"cost_usd" => 0.005}),
        # No cost: the session keeps the cost of the line before it.
        result(10, 2, %{"outcome" => "success"})
      ]

      assert Decimal.equal?(Sessions.cost(results), Decimal.new("0.0179"))
      assert Sessions.cost([result(1, 1, %{"outcome" => "success"})]) == nil
      assert Sessions.cost([]) == nil
    end
  end

  describe "the projector" do
    setup do
      %{scope: scope_fixture()}
    end

    defp session_events(session, cost, extra \\ %{}) do
      base = session * 100

      [
        {base + 1, "session.started", %{"session" => session, "runtime" => "claude"},
         [time: at(base)]},
        {base + 2, "runtime.started", %{"session" => session, "model" => "model-large"},
         [time: at(base + 1)]},
        {base + 3, "runtime.result", result_data(session, cost, extra), [time: at(base + 50)]},
        {base + 4, "session.exited", %{"session" => session, "state" => "succeeded"},
         [time: at(base + 60)]}
      ]
    end

    defp records(run),
      do:
        Repo.all(from r in SessionRecord, where: r.run_id == ^run.id, order_by: r.session_number)

    test "a run of one session, with no run of the queue, has one record", %{scope: scope} do
      run = run_fixture(scope)
      events_fixture(run, session_events(1, 0.0129))
      {:ok, run} = Projector.project(run)

      assert [record] = records(run)

      assert %{
               session_number: 1,
               started_at: started_at,
               ended_at: ended_at,
               turns: 4,
               duration_ms: 60_000,
               input_tokens: 10,
               output_tokens: 2_000,
               cache_read_tokens: 3_000,
               cache_write_tokens: 400,
               model: "model-large",
               error: false,
               dispatch_run_id: nil,
               work_item_id: nil,
               attempt: nil,
               stage_id: nil,
               workflow: nil
             } = record

      assert started_at == at(100)
      assert ended_at == at(160)
      assert record.organisation_id == run.organisation_id
      assert record.workspace_id == run.workspace_id
      assert Decimal.equal?(record.cost_usd, Decimal.new("0.0129"))
      assert Decimal.equal?(run.cost_usd, Decimal.new("0.0129"))
    end

    test "a launch with three result lines costs its last, for the record and for the run", %{
      scope: scope
    } do
      run = run_fixture(scope)

      events_fixture(run, [
        {1, "session.started", %{"session" => 1, "runtime" => "claude"}},
        {2, "runtime.result", %{"session" => 1, "line" => 3, "cost_usd" => 0.0043}},
        {3, "runtime.result", %{"session" => 1, "line" => 5, "cost_usd" => 0.0086}},
        {4, "runtime.result", %{"session" => 1, "line" => 8, "cost_usd" => 0.0129}}
      ])

      {:ok, run} = Projector.project(run)

      assert [record] = records(run)
      assert Decimal.equal?(record.cost_usd, Decimal.new("0.0129"))
      assert Decimal.equal?(run.cost_usd, Decimal.new("0.0129"))
      assert record.ended_at == nil
    end

    test "two sessions cost the sum of their last lines, in one pass or in two", %{scope: scope} do
      first = [
        {1, "runtime.result", %{"session" => 1, "cost_usd" => 0.0043}},
        {2, "runtime.result", %{"session" => 1, "cost_usd" => 0.0129}}
      ]

      second = [{3, "runtime.result", %{"session" => 2, "cost_usd" => 0.005}}]

      run = run_fixture(scope)
      events_fixture(run, first)
      {:ok, run} = Projector.project(run)
      assert Decimal.equal?(run.cost_usd, Decimal.new("0.0129"))

      # The late line of session 1 is a higher total, and the next pass reads the lines
      # of the one before.
      events_fixture(
        run,
        second ++ [{4, "runtime.result", %{"session" => 1, "cost_usd" => 0.02}}]
      )

      {:ok, run} = Projector.project(run)
      assert Decimal.equal?(run.cost_usd, Decimal.new("0.025"))

      assert [one, two] = records(run)
      assert Decimal.equal?(one.cost_usd, Decimal.new("0.02"))
      assert Decimal.equal?(two.cost_usd, Decimal.new("0.005"))

      other = run_fixture(scope)
      events_fixture(other, first ++ second)
      {:ok, other} = Projector.project(other)
      assert Decimal.equal?(other.cost_usd, Decimal.new("0.0179"))
    end

    # A run of the queue at a stage with `shared_run: true`, with a session row for each
    # of the six workflows, the first five reported, as the stage runner leaves them.
    defp shared_run!(scope, opts \\ []) do
      run = run_fixture(scope)

      queued =
        queue_run!(
          scope,
          run,
          Keyword.merge(
            [queued: [stage_id: @build, workflow: "plan-the-build", round: 1, stage_entry: 0]],
            opts
          )
        )

      workflows =
        ~w(plan-the-build write-acceptance-checks implement-changes review-changes
           implement-changes review-changes)

      rows =
        for {workflow, index} <- Enum.with_index(workflows, 1) do
          Repo.insert!(%Session{
            organisation_id: run.organisation_id,
            workspace_id: run.workspace_id,
            dispatch_run_id: queued.id,
            sequence: index,
            # The last session is the one a report has not ended.
            forager_session: if(index < 6, do: index),
            stage_entry: index - 1,
            round: 1,
            workflow: workflow
          })
        end

      {run, queued, rows}
    end

    test "a run of six sessions has six records with their fields", %{scope: scope} do
      {run, queued, _rows} = shared_run!(scope)

      events =
        for session <- 1..6, event <- session_events(session, session / 100), do: event

      # The run's target is the repository its `run.started` names.
      events_fixture(run, [{1, "run.started", started_data()} | events])
      {:ok, run} = Projector.project(run)
      assert is_binary(run.target_id)

      # The reports of the gateway at the start and the end of two sessions.
      for {session, minute, utilization} <- [{2, 0, 10}, {2, 30, 30}, {5, 0, 50}, {5, 20, 20}] do
        observed = DateTime.add(@t0, minute * 60, :second)

        assert :ok =
                 Sessions.record_windows(run, session, [
                   %{
                     secret_value_id: @key_id,
                     window: "five_hour",
                     utilization: utilization,
                     observed_at: observed
                   }
                 ])
      end

      records = records(run)
      assert Enum.map(records, & &1.session_number) == [1, 2, 3, 4, 5, 6]

      assert Enum.map(records, & &1.workflow) ==
               ~w(plan-the-build write-acceptance-checks implement-changes review-changes
                  implement-changes review-changes)

      for record <- records do
        assert %{
                 dispatch_run_id: dispatch_run_id,
                 work_item_id: work_item_id,
                 stage_id: @build,
                 attempt: 1,
                 turns: 4,
                 duration_ms: 60_000,
                 input_tokens: 10,
                 output_tokens: 2_000,
                 cache_read_tokens: 3_000,
                 cache_write_tokens: 400,
                 model: "model-large",
                 error: false
               } = record

        assert dispatch_run_id == queued.id
        assert work_item_id == queued.work_item_id
        assert record.target_id == run.target_id
        assert record.started_at == at(record.session_number * 100)
        assert record.ended_at == at(record.session_number * 100 + 60)
        assert Decimal.equal?(record.cost_usd, Decimal.from_float(record.session_number / 100))
      end

      # 0.01 + ... + 0.06
      assert Decimal.equal?(run.cost_usd, Decimal.new("0.21"))

      windows =
        Repo.all(
          from w in SessionKeyWindow,
            join: r in SessionRecord,
            on: r.id == w.session_record_id,
            where: r.run_id == ^run.id,
            order_by: r.session_number,
            select:
              {r.session_number, w.key_id, w.window, w.first_utilization, w.last_utilization,
               w.share}
        )
        |> Enum.map(fn {n, key, window, first, last, share} ->
          {n, key, window, Decimal.to_integer(first), Decimal.to_integer(last),
           Decimal.to_integer(share)}
        end)

      # The second session's window rose by 20; the fifth's reset, and fell by 30.
      assert windows == [
               {2, @key_id, "five_hour", 10, 30, 20},
               {5, @key_id, "five_hour", 50, 20, -30}
             ]
    end

    # The records of a run of the queue that is handed over are refused, as a write that
    # fails for a reason that is over once the end of the run has committed.
    defp refuse_records_before_the_end! do
      Repo.query!("""
      CREATE FUNCTION refuse_before_the_end() RETURNS trigger AS $$
      BEGIN
        IF EXISTS (SELECT 1 FROM dispatch_runs WHERE id = NEW.dispatch_run_id
                   AND state = 'handed_over') THEN
          RAISE EXCEPTION 'the run of the queue is not over';
        END IF;
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER refuse_before_the_end BEFORE INSERT OR UPDATE ON session_records
      FOR EACH ROW EXECUTE FUNCTION refuse_before_the_end()
      """)
    end

    test "a write that failed before the end of the run is made again after it", %{
      scope: scope
    } do
      {run, queued, _rows} = shared_run!(scope)

      refuse_records_before_the_end!()

      events =
        for session <- 1..3, event <- session_events(session, session / 100), do: event

      exit_event = {1_000, "run.exited", %{"state" => "succeeded", "exit_code" => 0}}
      events_fixture(run, events ++ [exit_event])

      log =
        ExUnit.CaptureLog.capture_log(fn -> assert {:ok, run} = Projector.project(run) end)

      # The first write failed and was logged; the end committed; the second write took.
      assert log =~ "session records not written"
      refute Repo.get!(DispatchRun, queued.id).state == :handed_over

      records = records(run)
      assert Enum.map(records, & &1.session_number) == [1, 2, 3]

      assert Enum.map(records, &Decimal.to_float(&1.cost_usd)) == [0.01, 0.02, 0.03]
      assert Decimal.equal?(Repo.get!(Run, run.id).cost_usd, Decimal.new("0.06"))
    end

    test "a write that failed is made again after the lost-run check ends the run", %{
      scope: scope
    } do
      {run, queued, _rows} = shared_run!(scope)
      refuse_records_before_the_end!()

      events = for session <- 1..2, event <- session_events(session, session / 100), do: event
      events_fixture(run, events)

      # No exit: the pass does not end the run, and its write is refused and logged.
      log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, run} = Projector.project(run) end)
      assert log =~ "session records not written"
      assert records(run) == []

      # The run was released, as a cancel after the hand-over records it: the check loses the
      # run of the queue.
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [released_at: DateTime.utc_now(), state: "cancelled", reason: "released"]
      )

      assert [_ | _] = RunEnd.lose(DateTime.utc_now())
      refute Repo.get!(DispatchRun, queued.id).state == :handed_over

      assert Enum.map(records(run), & &1.session_number) == [1, 2]
      assert Enum.map(records(run), &Decimal.to_float(&1.cost_usd)) == [0.01, 0.02]
      assert Decimal.equal?(Repo.get!(Run, run.id).cost_usd, Decimal.new("0.03"))
    end

    test "a session of a run the queue started takes its place from the run of the queue", %{
      scope: scope
    } do
      run = run_fixture(scope)

      queued =
        queue_run!(scope, run, queued: [stage_id: @build, workflow: "plan-the-build", round: 2])

      events_fixture(run, session_events(1, 1))
      {:ok, run} = Projector.project(run)

      assert [%{stage_id: @build, workflow: "plan-the-build", attempt: 1} = record] = records(run)
      assert record.dispatch_run_id == queued.id
    end

    test "a continuation adds attempt 2 and the paused run keeps its attempt 1", %{scope: scope} do
      work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
      paused = run_fixture(scope)
      continued = run_fixture(scope)
      queue_run!(scope, paused, work_item: work_item, attempt: 1, queued: [])
      queue_run!(scope, continued, work_item: work_item, attempt: 2, queued: [])

      events_fixture(paused, session_events(1, 0.01))
      events_fixture(continued, session_events(1, 0.02))
      {:ok, paused} = Projector.project(paused)
      {:ok, continued} = Projector.project(continued)

      assert [%{attempt: 1, session_number: 1}] = records(paused)
      assert [%{attempt: 2, session_number: 1}] = records(continued)
    end

    test "projecting again writes the same rows, and a rebuild keeps the records", %{scope: scope} do
      {run, _queued, _rows} = shared_run!(scope)
      events = for session <- 1..6, event <- session_events(session, session / 100), do: event
      events_fixture(run, events)
      {:ok, run} = Projector.project(run)

      before = records(run)
      assert length(before) == 6

      {:ok, rebuilt} = Projector.rebuild(run)
      assert records(rebuilt) |> Enum.map(&comparable/1) == Enum.map(before, &comparable/1)
      assert Enum.map(records(rebuilt), & &1.id) == Enum.map(before, & &1.id)
      assert Decimal.equal?(rebuilt.cost_usd, Decimal.new("0.21"))
    end

    defp comparable(record), do: Map.drop(record, [:updated_at, :__meta__, :run])

    test "a cost keeps every digit the runtime reported, and the smallest one", %{scope: scope} do
      run = run_fixture(scope)

      events_fixture(run, [
        {1, "runtime.result", %{"session" => 1, "cost_usd" => 0.012915135}},
        {2, "runtime.result", %{"session" => 2, "cost_usd" => 1.0e-20}},
        {3, "runtime.result", %{"session" => 3, "cost_usd" => 999_999_999.5}},
        {4, "runtime.result", %{"session" => 4, "cost_usd" => 1_000_000_000}}
      ])

      {:ok, run} = Projector.project(run)

      assert [one, two, three, four] = records(run)
      assert Decimal.equal?(one.cost_usd, Decimal.new("0.012915135"))
      assert Decimal.equal?(two.cost_usd, Decimal.new("1.0e-20"))
      assert Decimal.equal?(three.cost_usd, Decimal.new("999999999.5"))
      # A billion dollars is no bill: it is read as absent.
      assert four.cost_usd == nil
    end

    test "a session's model is what its runtime.started said, and nil with none", %{
      scope: scope
    } do
      run = run_fixture(scope)
      queue_run!(scope, run, queued: [])

      # The settings are not proof of what ran: no session takes its model from them.
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [run_settings: %{"model" => "model-from-settings"}]
      )

      run = Repo.get!(Run, run.id)

      events_fixture(run, [
        {1, "runtime.result", %{"session" => 1, "cost_usd" => 0.1}},
        {2, "runtime.result", %{"session" => 2, "cost_usd" => 0.2}},
        {3, "runtime.started", %{"session" => 3, "model" => "model-large"}},
        {4, "runtime.result", %{"session" => 3, "cost_usd" => 0.3}}
      ])

      {:ok, run} = Projector.project(run)
      assert records(run) |> Enum.map(& &1.model) == [nil, nil, "model-large"]
    end

    # The run's events, the way retention leaves them: a run with one projected session
    # whose record and cost are what is left, and a later result line that arrives for it.
    defp late_result(scope, left) do
      run = run_fixture(scope)
      events_fixture(run, session_events(1, 0.0129))
      {:ok, run} = Projector.project(run)
      assert Decimal.equal?(run.cost_usd, Decimal.new("0.0129"))

      left.(run)

      events_fixture(run, [{500, "runtime.result", result_data(1, 0.5)}])
      assert {:ok, run} = Projector.project(run)

      assert Repo.aggregate(
               from(e in Event, where: e.run_id == ^run.id and is_nil(e.projected_at)),
               :count
             ) == 0

      run
    end

    test "a run whose events are pruned keeps its record and its cost", %{scope: scope} do
      run =
        late_result(scope, fn run ->
          Repo.update_all(from(r in Run, where: r.id == ^run.id),
            set: [events_pruned_at: DateTime.utc_now()]
          )
        end)

      assert Decimal.equal?(run.cost_usd, Decimal.new("0.0129"))
      assert [record] = records(run)
      assert Decimal.equal?(record.cost_usd, Decimal.new("0.0129"))
      assert record.output_tokens == 2_000
    end

    test "a run that retention is due to prune keeps its record and its cost", %{scope: scope} do
      run =
        late_result(scope, fn run ->
          Repo.update_all(from(w in Workspace, where: w.id == ^run.workspace_id),
            set: [events_retention_days: 30]
          )

          Repo.update_all(from(r in Run, where: r.id == ^run.id),
            set: [state: "completed", last_event_at: DateTime.add(DateTime.utc_now(), -90, :day)]
          )
        end)

      assert Apiary.Retention.due_or_pruned?(run)
      assert Decimal.equal?(run.cost_usd, Decimal.new("0.0129"))
      assert [record] = records(run)
      assert Decimal.equal?(record.cost_usd, Decimal.new("0.0129"))

      # And `write/1` itself leaves such a run alone.
      events_fixture(run, [{600, "runtime.result", %{"session" => 2, "cost_usd" => 1}}])
      assert :ok = Sessions.write(run.id)

      assert [_one] = records(run)
    end

    test "a rerun's kept step has no session and so no record", %{scope: scope} do
      # A step a rerun keeps is not run again: no session.started, no result.
      run = run_fixture(scope)

      events_fixture(run, [
        {1, "run.started", %{"opened_by" => "run"}},
        {2, "run.step_started", %{"step" => 1, "name" => "fetch", "kind" => "fetch"}},
        {3, "run.step_exited", %{"step" => 1, "state" => "succeeded", "exit_code" => 0}}
      ])

      {:ok, run} = Projector.project(run)
      assert records(run) == []
      assert %Run{cost_usd: nil} = run
    end
  end
end
