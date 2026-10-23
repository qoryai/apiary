defmodule Apiary.Contract.RecordedRunStepsTest do
  @moduledoc """
  Projects the contract's records of runs with steps, `fixtures/run/<id>/events.jsonl`,
  and the batch of a run whose fetch step failed, `fixtures/link/link-batch-step-failed.json`,
  and holds the projected steps to what the records say: one step per number, numbered
  from 1, each with its start's name and kind and its exit's state, exit code, duration and
  sequence, and the log lines of each step those with its number. Each record's events
  are stored as the receiver leaves them, by their sequence, without going through the
  receiver, which a record of a run with no server is never posted to.

  And folds the contract's invalid step events, `fixtures/invalid/event-step-*.json` and
  `event-log-step-zero.json`, which Qory stores as received, by the fold's rules.
  """
  use Apiary.DataCase, async: true

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [run_fixture: 1]

  alias Apiary.Runs.{Batch, Event, Fold, Projector, Record}

  @moduletag :contract

  @step_records Enum.filter(recorded_runs(), fn file ->
                  file |> File.read!() |> String.contains?("dev.qory.run.step_started")
                end)

  setup do
    %{scope: scope_fixture()}
  end

  # The events of a record, decoded, each with its sequence as an integer.
  defp wire(file) do
    file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp store!(run, events) do
    for event <- events do
      {:ok, time} = Batch.time(event["time"])

      Repo.insert!(%Event{
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id,
        run_id: run.id,
        sequence: String.to_integer(event["sequence"]),
        # One record is stored more than once in a workspace: a new id each time.
        node_event_id: Ecto.UUID.generate(),
        type: event["type"],
        time: time,
        data: event["data"],
        received_at: time
      })
    end
  end

  defp of_type(events, type), do: Enum.filter(events, &(&1["type"] == "dev.qory.run." <> type))

  # The steps a record says, as the projection keeps them.
  defp expected_steps(events) do
    exits = Map.new(of_type(events, "step_exited"), &{&1["data"]["step"], &1})

    for start <- of_type(events, "step_started") do
      exit = Map.fetch!(exits, start["data"]["step"])

      %{
        step: start["data"]["step"],
        name: start["data"]["name"],
        kind: start["data"]["kind"],
        state: exit["data"]["state"],
        exit_code: exit["data"]["exit_code"],
        duration_ms: exit["data"]["duration_ms"],
        started_sequence: String.to_integer(start["sequence"]),
        exited_sequence: String.to_integer(exit["sequence"])
      }
    end
  end

  defp projected_steps(scope, run) do
    for step <- Record.steps(scope, run) do
      Map.take(step, [
        :step,
        :name,
        :kind,
        :state,
        :exit_code,
        :duration_ms,
        :started_sequence,
        :exited_sequence
      ])
    end
  end

  test "two records of runs with steps or more are projected" do
    assert length(@step_records) >= 2
  end

  for file <- @step_records do
    @file_path file

    test "the steps of #{file |> Path.dirname() |> Path.basename()} are the record's", %{
      scope: scope
    } do
      events = wire(@file_path)
      run = run_fixture(scope)
      store!(run, events)
      {:ok, _run} = Projector.project(run)

      expected = expected_steps(events)
      assert projected_steps(scope, run) == expected
      assert Enum.map(expected, & &1.step) == Enum.to_list(1..length(expected))

      for %{step: step} <- expected do
        lines =
          for event <- of_type(events, "log"), event["data"]["step"] == step do
            %{
              sequence: String.to_integer(event["sequence"]),
              stream: event["data"]["stream"],
              bytes: Base.decode64!(event["data"]["bytes"])
            }
          end

        assert Record.step_log(scope, run, step) == lines
      end
    end

    test "the steps of #{file |> Path.dirname() |> Path.basename()} are the same in any order of arrival",
         %{scope: scope} do
      events = wire(@file_path)
      in_order = run_fixture(scope)
      store!(in_order, events)
      {:ok, _run} = Projector.project(in_order)
      expected = projected_steps(scope, in_order)

      for seed <- 1..8 do
        :rand.seed(:exsss, {seed, seed, seed})
        run = run_fixture(scope)

        events
        |> Enum.shuffle()
        |> Enum.chunk_every(Enum.random(1..4))
        |> Enum.each(fn batch ->
          store!(run, batch)
          {:ok, _run} = Projector.project(run)
        end)

        assert projected_steps(scope, run) == expected
      end
    end
  end

  test "the batch of a run whose fetch step failed projects a failed step and its line", %{
    scope: scope
  } do
    # The batch of a session's events has no sequence: the gateway numbers them.
    events =
      "link/link-batch-step-failed.json"
      |> contract_json!()
      |> Enum.with_index(2)
      |> Enum.map(fn {event, sequence} ->
        Map.put(event, "sequence", sequence |> Integer.to_string() |> String.pad_leading(10, "0"))
      end)

    run = run_fixture(scope)
    store!(run, events)
    {:ok, run} = Projector.project(run)

    assert [
             %{
               step: 1,
               name: "fetch git.example/example-org/app",
               kind: "fetch",
               state: "failed",
               exit_code: 128,
               duration_ms: 3750
             }
           ] = projected_steps(scope, run)

    assert [%{stream: "stderr", bytes: "fatal: could not read from" <> _}] =
             Record.step_log(scope, run, 1)

    assert %{state: "failed", reason: "no_session"} = run
  end

  test "the contract's invalid step events fold by the fold's rules" do
    dir = Path.join(contract_dir(), "fixtures/invalid")

    folded =
      for name <-
            Path.wildcard(Path.join(dir, "event-step-*.json")) ++
              [Path.join(dir, "event-log-step-zero.json")],
          into: %{} do
        event = name |> File.read!() |> Jason.decode!()
        {:ok, time} = Batch.time(event["time"])

        fold =
          Fold.fold(%{}, [
            %{sequence: 1, type: event["type"], time: time, data: event["data"]}
          ])

        {Path.basename(name, ".json"), fold}
      end

    assert map_size(folded) == 8

    assert folded["event-step-started-step-zero"].steps == %{}
    assert %{1 => %{kind: nil}} = folded["event-step-started-unknown-kind"].steps
    assert %{1 => %{name: nil, kind: "fetch"}} = folded["event-step-started-without-name"].steps
    assert %{1 => %{state: "failed"}} = folded["event-step-exited-unknown-state"].steps
    assert %{1 => %{state: "failed"}} = folded["event-step-exited-without-state"].steps
    assert %{1 => %{duration_ms: nil}} = folded["event-step-exited-without-duration"].steps

    assert %{1 => %{exit_code: -2}} =
             folded["event-step-exited-exit-code-below-minus-one"].steps

    assert [%{step: nil}] = folded["event-log-step-zero"].log_chunks
  end
end
