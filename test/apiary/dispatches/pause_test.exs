defmodule Apiary.Dispatches.PauseTest do
  # A run of a work item whose exit says every model key of the run was at its limit
  # (`cancelled`, `model_key_limit`): the run is Paused, its run of the queue ends, and the
  # run that continues it is queued at its place, with one more attempt and the paused
  # run's place in the queue (`Apiary.Dispatches.RunEnd`,
  # `Apiary.Dispatches.requeue_for_pause/2`). The paused run's transcript is kept, and the
  # continuation's run configuration resumes it (`Apiary.Runs.Transcript`).
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Connections
  alias Apiary.Dispatches.{DispatchRun, Pause}
  alias Apiary.Runs.{Projector, Run, SessionChunk, Transcript}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:factory, :secrets]

  @paused %{
    "state" => "cancelled",
    "reason" => "model_key_limit",
    "exit_code" => -1,
    "signal" => "SIGTERM"
  }
  @path "~/.claude/projects/-workspace/5f2c9a1e.jsonl"

  setup do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)

    keys = for id <- ~w(main spare), do: %{value_id: id, value: "sk-ant-fixture-#{id}-0123456789"}
    {:ok, provider} = Connections.create_provider(scope, %{provider: "anthropic", keys: keys})

    # A run that took a key of the provider (`runs_provider_check`).
    given = %{
      provider_connection_id: provider.id,
      provider_secret_id: provider.secret_id,
      provider_chain: "organisation",
      provider_api: %{
        "format" => "anthropic-messages",
        "endpoint" => "https://api.model.example/anthropic",
        "auth" => %{"scheme" => "x-api-key"}
      },
      model_keys: [],
      run_settings: %{}
    }

    %{scope: scope, key: key, provider: provider, given: given}
  end

  defp exit!(run, data, sequence \\ 9) do
    event_fixture(run, sequence, "run.exited", data)
    assert {:ok, %Run{exited_at: %DateTime{}}} = Projector.project(run)
  end

  defp chunk(offset, bytes, session_id \\ "5f2c9a1e"),
    do: %{
      "session" => 1,
      "session_id" => session_id,
      "path" => @path,
      "offset" => offset,
      "bytes" => Base.encode64(bytes)
    }

  defp runs_of(work_item_id) do
    Repo.all(
      from d in DispatchRun,
        where: d.work_item_id == ^work_item_id,
        order_by: d.attempt,
        select: {d.attempt, d.state, d.end_cause}
    )
  end

  defp run_of(work_item_id, attempt),
    do:
      Repo.one!(
        from d in DispatchRun, where: d.work_item_id == ^work_item_id and d.attempt == ^attempt
      )

  defp registered(%DispatchRun{id: id}),
    do: Repo.one!(from r in Run, where: r.dispatch_run_id == ^id)

  test "pauses the run and queues the run that continues it at its place", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, @paused)

    assert %Run{state: "paused", exit_reason: "model_key_limit"} = paused = Repo.get!(Run, run.id)

    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}, {2, :waiting, nil}]

    next = run_of(dispatch_run.work_item_id, 2)
    of = dispatch_run.of + 1
    paused_id = dispatch_run.id

    assert %DispatchRun{continues_id: ^paused_id, of: ^of, image_requeue: false} = next
    assert next.take_in == dispatch_run.take_in
    assert next.queued_at == dispatch_run.queued_at
    assert Repo.get!(DispatchRun, dispatch_run.id).paused_until == nil

    # One key is not in cooldown: the line says a key reached its limit.
    continuation = registered(next)

    assert Pause.of_run(paused) == %{
             provider: ctx.provider.name,
             until: nil,
             number: continuation.number,
             workspace_id: ctx.scope.workspace.id
           }

    assert Pause.of_public_ids([paused.public_id]) == %{paused.public_id => Pause.of_run(paused)}
  end

  test "keeps the earliest end of a cooldown when every key of the provider cools", ctx do
    soon = in_seconds(3_600)
    key_state!(ctx.provider, "main", until: in_seconds(7_200))
    key_state!(ctx.provider, "spare", until: soon)

    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, @paused)

    assert DateTime.compare(Repo.get!(DispatchRun, dispatch_run.id).paused_until, soon) == :eq
    assert %{until: until} = Pause.of_run(Repo.get!(Run, run.id))
    assert DateTime.compare(until, soon) == :eq
  end

  test "a continuation that pauses is continued again", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, @paused)

    next = run_of(dispatch_run.work_item_id, 2)
    %{run: again} = handed_over(ctx.scope, ctx.key, next, ctx.given)
    exit!(again, @paused)

    assert runs_of(dispatch_run.work_item_id) == [
             {1, :ended, :run_ended},
             {2, :ended, :run_ended},
             {3, :waiting, nil}
           ]

    next_id = next.id
    assert %DispatchRun{continues_id: ^next_id} = run_of(dispatch_run.work_item_id, 3)
  end

  test "a paused run of a work item that left Explore is not continued", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

    {1, _rows} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^dispatch_run.work_item_id),
        set: [state: :closed, closed_at: DateTime.utc_now()]
      )

    exit!(run, @paused)

    assert %Run{state: "paused"} = paused = Repo.get!(Run, run.id)
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]
    assert Pause.of_run(paused) == nil
  end

  test "an outcome before the exit is refused, and the exit pauses the run", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

    # A run of the queue takes no outcome (`Apiary.Runs.Outcome`): its exit decides.
    assert give_outcome(ctx.key, run, "succeeded") == {:error, :not_found}
    exit!(run, @paused)

    assert %Run{state: "paused", outcome_state: nil} = Repo.get!(Run, run.id)
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}, {2, :waiting, nil}]
  end

  test "a run that pushed its result, then paused, is continued", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

    Apiary.WorkItemsFixtures.push_result!(
      dispatch_run,
      run,
      Apiary.WorkItemsFixtures.questions_result()
    )

    exit!(run, @paused)

    assert %Run{state: "paused"} = Repo.get!(Run, run.id)
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}, {2, :waiting, nil}]
    assert run_of(dispatch_run.work_item_id, 2).continues_id == dispatch_run.id
  end

  test "an exit with another reason is no pause", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, %{@paused | "reason" => "stopped"})

    assert %Run{state: "cancelled"} = Repo.get!(Run, run.id)
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]
  end

  describe "the transcript" do
    test "is kept by chunk, and the continuation's configuration resumes it", ctx do
      %{dispatch_run: dispatch_run, run: run} =
        handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      event_fixture(run, 3, "session.transcript", chunk(0, "{\"a\":1}\n"))
      event_fixture(run, 4, "session.transcript", chunk(8, "{\"b\":2}\n"))
      exit!(run, @paused)

      assert Repo.aggregate(from(c in SessionChunk, where: c.run_id == ^run.id), :count) == 2
      assert Transcript.last(run.id) == %{session_id: "5f2c9a1e", path: @path}

      whole = "{\"a\":1}\n{\"b\":2}\n"
      sha = :crypto.hash(:sha256, whole) |> Base.encode16(case: :lower)
      assert Transcript.file(run.id, @path) == {:ok, %{size: 16, sha256: sha}}
      assert run.id |> Transcript.stream(@path) |> Enum.join() == whole

      continuation = registered(run_of(dispatch_run.work_item_id, 2))

      assert Transcript.resume(continuation) == %{
               "run_id" => run.node_run_id,
               "session_id" => "5f2c9a1e",
               "path" => @path
             }

      # The paused run itself, and a run that continues nothing, resume nothing.
      assert Transcript.resume(Repo.get!(Run, run.id)) == nil
    end

    test "a gap in its offsets is never resumed, and the log line has no byte of it", ctx do
      %{dispatch_run: dispatch_run, run: run} =
        handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      event_fixture(run, 3, "session.transcript", chunk(0, "first-line-xq7\n"))
      event_fixture(run, 4, "session.transcript", chunk(99, "second-line-xq7\n"))
      exit!(run, @paused)

      continuation = registered(run_of(dispatch_run.work_item_id, 2))

      log =
        capture_log(fn ->
          assert Transcript.file(run.id, @path) == {:error, :gap}
          assert Transcript.resume(continuation) == nil
        end)

      assert log =~ "transcript not restorable run=#{run.id} reason=gap"
      refute log =~ "xq7"
    end

    test "a chunk that is not one is not kept, and its log line has no byte of it", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
      event_fixture(run, 3, "session.transcript", Map.delete(chunk(0, "hidden-zq9\n"), "path"))

      log = capture_log(fn -> assert {:ok, %Run{}} = Projector.project(run) end)

      assert Repo.aggregate(from(c in SessionChunk, where: c.run_id == ^run.id), :count) == 0
      refute log =~ "zq9"
      refute log =~ Base.encode64("hidden-zq9\n")
    end
  end
end
