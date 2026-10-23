defmodule Apiary.Runs.StepsTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.{LogChunk, Projector, Record, Run, Step}

  setup do
    scope = scope_fixture()
    %{scope: scope, run: run_fixture(scope)}
  end

  # What the run's steps are, in a shape two runs can be compared by.
  defp steps(scope, run) do
    for step <- Record.steps(scope, run) do
      Map.take(step, [
        :step,
        :name,
        :kind,
        :state,
        :exit_code,
        :duration_ms,
        :started_sequence,
        :started_at,
        :exited_sequence,
        :exited_at
      ])
    end
  end

  defp log_steps(run) do
    Repo.all(
      from l in LogChunk,
        where: l.run_id == ^run.id,
        order_by: l.sequence,
        select: {l.sequence, l.step}
    )
  end

  defp project!(run, events) do
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    run
  end

  defp started(sequence, step, name \\ "fetch git.example.com/acme/shop", kind \\ "fetch"),
    do: {sequence, "run.step_started", %{"step" => step, "name" => name, "kind" => kind}}

  defp exited(sequence, step, state \\ "succeeded", exit_code \\ 0),
    do:
      {sequence, "run.step_exited",
       %{"step" => step, "state" => state, "exit_code" => exit_code, "duration_ms" => 100}}

  defp run_exited(sequence),
    do:
      {sequence, "run.exited",
       %{"state" => "cancelled", "reason" => "stopped", "exit_code" => -1}}

  describe "the projection" do
    test "keeps each step: number, name, kind, state, exit code, duration and both sequences",
         %{scope: scope, run: run} do
      project!(run, steps_record())

      assert steps(scope, run) == [
               %{
                 step: 1,
                 name: "fetch git.example.com/acme/shop",
                 kind: "fetch",
                 state: "succeeded",
                 exit_code: 0,
                 duration_ms: 1840,
                 started_sequence: 2,
                 started_at: at(2),
                 exited_sequence: 4,
                 exited_at: at(4)
               },
               %{
                 step: 2,
                 name: "compose the harness",
                 kind: "compose",
                 state: "succeeded",
                 exit_code: 0,
                 duration_ms: 620,
                 started_sequence: 5,
                 started_at: at(5),
                 exited_sequence: 8,
                 exited_at: at(8)
               },
               %{
                 step: 3,
                 name: "join session 1",
                 kind: "join",
                 state: "succeeded",
                 exit_code: -1,
                 duration_ms: 15,
                 started_sequence: 9,
                 started_at: at(9),
                 exited_sequence: 10,
                 exited_at: at(10)
               }
             ]

      assert log_steps(run) == [{3, 1}, {6, 2}, {7, 2}, {12, nil}]
    end

    test "a step is running until its exit, which a later pass folds", %{scope: scope, run: run} do
      project!(run, [{1, "run.started", started_data()}, started(2, 1)])

      assert [%{state: "running", exit_code: nil, duration_ms: nil, exited_sequence: nil}] =
               steps(scope, run)

      project!(run, [exited(3, 1, "failed", 128)])

      assert [%{state: "failed", exit_code: 128, duration_ms: 100, exited_sequence: 3}] =
               steps(scope, run)
    end

    test "any order of arrival, in any batching, gives the same steps and log lines", %{
      scope: scope
    } do
      in_order = run_fixture(scope)
      project!(in_order, steps_record())
      expected = {steps(scope, in_order), log_steps(in_order)}

      for seed <- 1..12 do
        :rand.seed(:exsss, {seed, seed + 1, seed + 2})
        run = run_fixture(scope)

        steps_record()
        |> Enum.shuffle()
        |> Enum.chunk_every(Enum.random(1..4))
        |> Enum.each(&project!(run, &1))

        assert {steps(scope, run), log_steps(run)} == expected
      end
    end

    test "of two starts or two exits with one number, the lower sequence decides across passes",
         %{scope: scope, run: run} do
      project!(run, [started(5, 1, "second"), exited(9, 1, "cancelled", -1)])
      project!(run, [started(3, 1, "first", "compose"), exited(7, 1, "failed", 2)])
      project!(run, [started(4, 1, "third"), exited(8, 1, "succeeded", 0)])

      assert [
               %{
                 name: "first",
                 kind: "compose",
                 started_sequence: 3,
                 state: "failed",
                 exit_code: 2,
                 exited_sequence: 7
               }
             ] = steps(scope, run)
    end

    test "an exit folded before its start is kept, and the start fills the rest", %{
      scope: scope,
      run: run
    } do
      project!(run, [exited(4, 1, "failed", 128)])

      assert [%{name: nil, kind: nil, state: "failed", exit_code: 128, started_sequence: nil}] =
               steps(scope, run)

      project!(run, [started(2, 1)])

      assert [%{name: "fetch git.example.com/acme/shop", kind: "fetch", state: "failed"}] =
               steps(scope, run)
    end

    test "a step without an exit is cancelled once the run exits, and keeps no exit", %{
      scope: scope,
      run: run
    } do
      project!(run, [
        {1, "run.started", started_data()},
        started(2, 1),
        exited(3, 1),
        started(4, 2)
      ])

      assert [%{state: "succeeded"}, %{state: "running"}] = steps(scope, run)

      project!(run, [run_exited(5)])

      assert [
               %{step: 1, state: "succeeded", exit_code: 0, exited_sequence: 3},
               %{
                 step: 2,
                 state: "cancelled",
                 exit_code: nil,
                 duration_ms: nil,
                 exited_sequence: nil
               }
             ] = steps(scope, run)
    end

    test "after the run's exit, a start folded late is cancelled, and an exit folded late decides",
         %{scope: scope, run: run} do
      project!(run, [{1, "run.started", started_data()}, run_exited(9)])
      project!(run, [started(2, 1), started(4, 2)])

      assert [%{state: "cancelled"}, %{state: "cancelled"}] = steps(scope, run)

      project!(run, [exited(3, 1, "succeeded", 0)])

      assert [
               %{step: 1, state: "succeeded", exit_code: 0, exited_sequence: 3},
               %{step: 2, state: "cancelled", exited_sequence: nil}
             ] = steps(scope, run)
    end

    test "a run without an exit leaves its open step running, lost or not", %{
      scope: scope,
      run: run
    } do
      project!(run, [{1, "run.started", started_data()}, started(2, 1)])
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [state: "lost"])
      project!(run, [{3, "run.log", step_log_data(1, "still fetching\n")}])

      assert [%{state: "running"}] = steps(scope, run)
    end

    test "a rebuild folds the same steps and log lines again", %{scope: scope, run: run} do
      steps_record()
      |> Enum.chunk_every(3)
      |> Enum.each(&project!(run, &1))

      expected = {steps(scope, run), log_steps(run)}

      Repo.update_all(from(s in Step, where: s.run_id == ^run.id), set: [name: "elsewhere"])
      Repo.update_all(from(l in LogChunk, where: l.run_id == ^run.id), set: [step: 9])

      assert {:ok, %Run{}} = Projector.rebuild(run)
      assert {steps(scope, run), log_steps(run)} == expected
    end

    test "the database holds a step's number, state and kind to their lists", %{run: run} do
      row = fn attrs ->
        Repo.insert!(
          struct(
            %Step{
              organisation_id: run.organisation_id,
              workspace_id: run.workspace_id,
              run_id: run.id
            },
            attrs
          )
        )
      end

      assert_raise Ecto.ConstraintError, ~r/run_steps_step_check/, fn -> row.(%{step: 0}) end

      assert_raise Ecto.ConstraintError, ~r/run_steps_state_check/, fn ->
        row.(%{step: 1, state: "lost"})
      end

      assert_raise Ecto.ConstraintError, ~r/run_steps_kind_check/, fn ->
        row.(%{step: 1, kind: "deploy"})
      end

      for {kind, step} <- Enum.with_index(Step.kinds(), 1),
          do: assert(%Step{} = row.(%{step: step, kind: kind}))

      assert %Step{state: "running", kind: nil} = row.(%{step: 7})
    end

    test "the steps go with their run", %{scope: scope, run: run} do
      project!(run, steps_record())
      Repo.delete!(run)

      assert Repo.aggregate(from(s in Step, where: s.run_id == ^run.id), :count) == 0
      assert Record.steps(scope, run) == []
    end
  end

  describe "Record.step_log/4" do
    test "reads one step's log lines in sequence order", %{scope: scope, run: run} do
      project!(run, steps_record())

      assert Record.step_log(scope, run, 1) == [
               %{sequence: 3, stream: "stderr", bytes: "Cloning into 'shop'...\n"}
             ]

      assert Enum.map(Record.step_log(scope, run, 2), & &1.bytes) == [
               "composed 3 sources\n",
               "wrote the settings\n"
             ]

      assert Record.step_log(scope, run, 3) == []

      for step <- [4, 0, -1, 2_147_483_648],
          do: assert(Record.step_log(scope, run, step) == [])
    end

    test "reads a long step a page at a time", %{scope: scope, run: run} do
      lines = for n <- 1..5, do: {n + 2, "run.log", step_log_data(1, "line #{n}\n")}
      project!(run, [{1, "run.started", started_data()}, started(2, 1) | lines])

      assert [%{sequence: 3}, %{sequence: 4}] = Record.step_log(scope, run, 1, limit: 2)
      assert [%{sequence: 5}, %{sequence: 6}] = Record.step_log(scope, run, 1, after: 4, limit: 2)
      assert [%{sequence: 7}] = Record.step_log(scope, run, 1, after: 6, limit: 2)
      assert length(Record.step_log(scope, run, 1)) == 5
    end
  end

  describe "with a run of another workspace handed in" do
    test "steps/2 and step_log/4 read nothing", %{scope: scope, run: run} do
      project!(run, steps_record())
      other = scope_fixture()

      assert Record.steps(other, run) == []
      assert Record.step_log(other, run, 1) == []
      assert length(Record.steps(scope, run)) == 3
    end
  end
end
