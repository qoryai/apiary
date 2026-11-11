defmodule Apiary.Dispatches.PauseTest do
  # A run of a work item whose exit says every model key of the run was at its limit
  # (`paused`, `model_key_limit`): the run is Paused, its run of the queue ends, and the
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
    "state" => "paused",
    "reason" => "model_key_limit",
    "exit_code" => 143
  }
  # The same end from a gateway of the earlier contract.
  @cancelled_paused %{
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

    # The run's organisation's provider is named, and is no operator's.
    assert Pause.of_run(paused) == %{
             provider: ctx.provider.name,
             operator: false,
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

    # No run continues it: its line has the provider and no run.
    assert %{provider: provider, number: nil} = pause = Pause.of_run(paused)
    assert provider == ctx.provider.name

    assert pause |> ApiaryWeb.PauseWords.line(nil) |> ApiaryWeb.RichText.plain_text() ==
             "Paused: a key of #{ctx.provider.name} reached its limit."
  end

  test "a cooldown that has ended leaves the line without its time", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, @paused)

    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^dispatch_run.id),
        set: [paused_until: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

    number = registered(run_of(dispatch_run.work_item_id, 2)).number
    pause = Pause.of_run(Repo.get!(Run, run.id))
    assert %{until: %DateTime{}, number: ^number} = pause

    assert pause
           |> ApiaryWeb.PauseWords.line("/runs/#{number}")
           |> ApiaryWeb.RichText.plain_text() ==
             "Paused: a key of #{ctx.provider.name} reached its limit. It continues in run #{number}."
  end

  test "an operator's provider has no name in the line", ctx do
    %{scope: operator} = sign_up_fixture()
    keys = [%{value_id: "main", value: "sk-ant-operator-main-0123456789"}]
    {:ok, theirs} = Connections.create_provider(operator, %{provider: "anthropic", keys: keys})

    given = %{
      ctx.given
      | provider_connection_id: theirs.id,
        provider_secret_id: theirs.secret_id,
        provider_chain: "operator"
    }

    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, given)
    exit!(run, @paused)

    until = DateTime.add(DateTime.utc_now(), 3_600, :second)

    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^dispatch_run.id),
        set: [paused_until: until]
      )

    number = registered(run_of(dispatch_run.work_item_id, 2)).number
    assert %{provider: nil, operator: true} = pause = Pause.of_run(Repo.get!(Run, run.id))

    line = fn pause ->
      pause |> ApiaryWeb.PauseWords.line(nil) |> ApiaryWeb.RichText.plain_text()
    end

    assert line.(pause) ==
             "Paused: every model key is in cooldown until " <>
               "#{ApiaryWeb.PreparationComponents.cooldown_time(until)}. It continues in run #{number}."

    # Once the cooldown has ended, and with no run that continues it.
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    assert line.(%{pause | until: past}) ==
             "Paused: a model key reached its limit. It continues in run #{number}."

    assert line.(%{pause | number: nil}) == "Paused: a model key reached its limit."
    refute line.(pause) =~ theirs.name
  end

  test "an outcome before the exit is refused, and the exit pauses the run", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

    # A run of the queue takes no outcome (`Apiary.Runs.Outcome`): its exit decides.
    assert give_outcome(ctx.key, run, "succeeded") == {:error, :not_found}
    exit!(run, @paused)

    assert %Run{state: "paused", outcome_state: nil} = Repo.get!(Run, run.id)
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}, {2, :waiting, nil}]
  end

  test "a run that pushed its questions, then reached the limit, finished", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

    Apiary.WorkItemsFixtures.push_result!(
      dispatch_run,
      run,
      Apiary.WorkItemsFixtures.questions_result()
    )

    exit!(run, @paused)

    assert %Run{state: "completed", reason: nil} = finished = Repo.get!(Run, run.id)
    assert {finished.exit_state, finished.exit_reason} == {"paused", "model_key_limit"}
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]
    assert %DispatchRun{result_outcome: :questions} = Repo.get!(DispatchRun, dispatch_run.id)
    # No Paused line.
    assert Pause.of_run(finished) == nil

    # A rebuild of the projection gives the same run.
    assert {:ok, %Run{state: "completed", reason: nil}} = Projector.rebuild(finished)
  end

  test "a run that pushed a proposal, then reached the limit, finished, in both shapes",
       ctx do
    for exit <- [@paused, @cancelled_paused] do
      %{dispatch_run: dispatch_run, run: run} =
        handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      Apiary.WorkItemsFixtures.push_output!(
        dispatch_run,
        run,
        Apiary.WorkItemsFixtures.understood_result()
      )

      exit!(run, exit)

      assert %Run{state: "completed"} = Repo.get!(Run, run.id)
      assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]
      assert %DispatchRun{result_outcome: :proposal} = Repo.get!(DispatchRun, dispatch_run.id)
    end
  end

  @tag needs: [:factory, :secrets, :workflow_model]
  test "the stage of a run that pushed its questions, then reached the limit, waits", ctx do
    work_item = Apiary.StagesFixtures.taken_in_fixture(ctx.scope)
    queued = Apiary.StagesFixtures.newest_run(work_item)
    %{run: run} = handed_over(ctx.scope, ctx.key, queued, ctx.given)
    dispatch_run = Repo.get!(DispatchRun, queued.id)

    Apiary.WorkItemsFixtures.push_result!(
      dispatch_run,
      run,
      Apiary.WorkItemsFixtures.questions_result()
    )

    exit!(run, @paused)

    assert %Run{state: "completed"} = Repo.get!(Run, run.id)
    assert runs_of(work_item.id) == [{1, :ended, :run_ended}]
    assert %WorkItem{stage_state: :waiting_answers} = Repo.get!(WorkItem, work_item.id)
  end

  @tag needs: [:factory, :secrets, :workflow_model]
  test "the stage of a run that pushed a proposal, then reached the limit, moves on", ctx do
    work_item = Apiary.StagesFixtures.taken_in_fixture(ctx.scope)
    queued = Apiary.StagesFixtures.newest_run(work_item)
    %{run: run} = handed_over(ctx.scope, ctx.key, queued, ctx.given)
    dispatch_run = Repo.get!(DispatchRun, queued.id)

    Apiary.WorkItemsFixtures.push_output!(
      dispatch_run,
      run,
      Apiary.WorkItemsFixtures.understood_result()
    )

    exit!(run, @paused)

    assert %Run{state: "completed"} = Repo.get!(Run, run.id)
    assert runs_of(work_item.id) == [{1, :ended, :run_ended}]
    assert %WorkItem{stage_state: :at_gate} = Repo.get!(WorkItem, work_item.id)
  end

  test "a proposal of an earlier run alone leaves the run paused", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, @paused)

    next = run_of(dispatch_run.work_item_id, 2)
    %{run: again} = handed_over(ctx.scope, ctx.key, next, ctx.given)

    version =
      Apiary.WorkItemsFixtures.push_output!(
        Repo.get!(DispatchRun, next.id),
        again,
        Apiary.WorkItemsFixtures.understood_result()
      )

    # The proposal is the first run's, pushed before it paused.
    {1, _rows} =
      Repo.update_all(from(v in Apiary.Artifacts.Version, where: v.id == ^version.id),
        set: [run_id: dispatch_run.id]
      )

    exit!(again, @paused)

    assert %Run{state: "paused"} = Repo.get!(Run, again.id)
    assert %DispatchRun{continues_id: continues_id} = run_of(dispatch_run.work_item_id, 3)
    assert continues_id == next.id
  end

  test "a paused run whose questions cannot be read has no warning of its outcome", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

    # A question no other test asks, so no other test stores the same file.
    Apiary.WorkItemsFixtures.push_result!(
      dispatch_run,
      run,
      Apiary.WorkItemsFixtures.questions_result([
        "Which basket #{System.unique_integer([:positive])}?"
      ])
    )

    work_item = Repo.get!(WorkItem, dispatch_run.work_item_id)
    {version, _document} = Apiary.Explore.Questions.newest(work_item)
    [file] = version.files

    # The questions are an earlier run's, gone since: this run pushed nothing, and pauses.
    {1, _rows} =
      Repo.update_all(from(v in Apiary.Artifacts.Version, where: v.id == ^version.id),
        set: [run_id: nil]
      )

    {:ok, path} = Apiary.Artifacts.open_file(file)
    File.rename!(path, path <> ".away")
    on_exit(fn -> File.rename(path <> ".away", path) end)

    log = capture_log(fn -> exit!(run, @paused) end)

    assert %Run{state: "paused"} = Repo.get!(Run, run.id)
    assert %DispatchRun{result_outcome: nil} = Repo.get!(DispatchRun, dispatch_run.id)
    refute log =~ "run outcome not stored"
  end

  test "the continuation's input counts the paused run once: attempt 1", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    target = %{system: "forge.example.com", path: "acme/shop"}
    work_item = Repo.get!(WorkItem, dispatch_run.work_item_id)

    attempt = fn queued ->
      {:ok, inputs} =
        Apiary.Dispatches.Inputs.explore(work_item, queued, %{domain: "software", target: target})

      (inputs |> Jason.encode!() |> Jason.decode!())["run"]
    end

    assert attempt.(dispatch_run) == %{"attempt" => 1}
    exit!(run, @paused)

    next = run_of(dispatch_run.work_item_id, 2)
    assert %DispatchRun{attempt: 2} = next
    assert attempt.(next) == %{"attempt" => 1}
  end

  test "the contract's batch of a run paused at the limit pauses the run", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    path = "test/fixtures/forager-contract/link/link-batch-exited-model-key-limit.json"
    assert path in Apiary.ContractFixtures.vendored()

    events = path |> File.read!() |> Jason.decode!()
    [exited] = for %{"type" => "dev.qory.run.exited", "data" => data} <- events, do: data
    assert {exited["state"], exited["reason"]} == {"paused", "model_key_limit"}

    for {%{"type" => "dev.qory." <> type, "data" => data}, sequence} <-
          Enum.with_index(events, 5),
        type != "run.exited",
        do: event_fixture(run, sequence, type, data)

    log = capture_log(fn -> exit!(run, exited) end)

    assert %Run{state: "paused", exit_reason: "model_key_limit"} = Repo.get!(Run, run.id)
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}, {2, :waiting, nil}]
    refute log =~ "model_key_limit"
  end

  test "the earlier contract's cancelled exit at the limit pauses the run too", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, @cancelled_paused)

    assert %Run{state: "paused", exit_reason: "model_key_limit"} = Repo.get!(Run, run.id)
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}, {2, :waiting, nil}]
    assert run_of(dispatch_run.work_item_id, 2).continues_id == dispatch_run.id
  end

  test "an exit with another reason is no pause", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, %{@cancelled_paused | "reason" => "stopped"})

    assert %Run{state: "cancelled"} = Repo.get!(Run, run.id)
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]
  end

  test "an exit paused without model_key_limit is no pause, with one log line", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    log = capture_log(fn -> exit!(run, Map.delete(@paused, "reason")) end)

    assert %Run{state: "failed", exit_reason: nil} = Repo.get!(Run, run.id)
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]
    assert [_line] = Regex.scan(~r/the state paused without the reason model_key_limit/, log)
  end

  # The data of each event of the contract's invalid fixture `file`, vendored.
  defp invalid_fixture(file) do
    path = "test/fixtures/forager-contract/invalid/" <> file
    assert path in Apiary.ContractFixtures.vendored()

    case path |> File.read!() |> Jason.decode!() do
      events when is_list(events) ->
        for %{"type" => type, "data" => data} <- events, do: {type, data}

      %{"type" => type, "data" => data} ->
        [{type, data}]
    end
  end

  test "model_key_limit with a state other than paused is no pause, with one log line",
       ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

    [{"dev.qory.session.exited", session}] =
      invalid_fixture("event-session-exited-model-key-limit-failed.json")

    assert invalid_fixture("link-batch-session-exited-model-key-limit-failed.json") ==
             [{"dev.qory.session.exited", session}]

    [{"dev.qory.run.exited", exited}] =
      invalid_fixture("link-batch-exited-model-key-limit-failed.json")

    assert {session["state"], session["reason"]} == {"failed", "model_key_limit"}
    assert {exited["state"], exited["reason"]} == {"failed", "model_key_limit"}

    event_fixture(run, 8, "session.exited", session)

    log =
      capture_log(fn ->
        exit!(run, exited)
      end)

    assert %Run{state: "failed", exit_reason: "model_key_limit"} = Repo.get!(Run, run.id)
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]

    assert [_line] =
             Regex.scan(~r/the reason model_key_limit with a state other than paused/, log)
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
      assert Transcript.check(run.id, @path) == {:ok, %{size: 16, max_sequence: 4}}
      assert Transcript.digest(run.id, @path, 4) == sha
      assert run.id |> Transcript.stream(@path, 4) |> Enum.join() == whole
      # Only the chunks the check covered are sent, and signed.
      assert run.id |> Transcript.stream(@path, 3) |> Enum.join() == "{\"a\":1}\n"

      resume = %{"run_id" => run.node_run_id, "session_id" => "5f2c9a1e", "path" => @path}
      queued = run_of(dispatch_run.work_item_id, 2)
      assert Transcript.resume_at_claim(queued) == resume

      # The claim stores it, and each run configuration reads what it stored.
      %{run: continuation} = handed_over(ctx.scope, ctx.key, queued, %{})
      assert continuation.resume == resume
      assert Transcript.resume(continuation) == resume

      # A chunk stored after the claim changes no run configuration of the run.
      event_fixture(run, 5, "session.transcript", chunk(16, "{\"c\":3}\n", "other"))
      {:ok, _run} = Projector.project(run)
      assert Transcript.resume(Repo.get!(Run, continuation.id)) == resume

      # The paused run itself, and a run that continues nothing, resume nothing.
      assert Transcript.resume(Repo.get!(Run, run.id)) == nil
      assert Transcript.resume_at_claim(dispatch_run) == nil
    end

    test "is read only for a continuation of the same workspace", ctx do
      %{dispatch_run: dispatch_run, run: run} =
        handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      event_fixture(run, 3, "session.transcript", chunk(0, "{\"a\":1}\n"))
      exit!(run, @paused)

      queued = run_of(dispatch_run.work_item_id, 2)
      assert %Run{} = Transcript.paused_run(queued)
      other = workspace_fixture(ctx.scope.organisation)
      assert Transcript.paused_run(%{queued | workspace_id: other.id}) == nil
      assert Transcript.resume_at_claim(%{queued | workspace_id: other.id}) == nil
    end

    test "a gap in its offsets is never resumed, and the log line has no byte of it", ctx do
      %{dispatch_run: dispatch_run, run: run} =
        handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      event_fixture(run, 3, "session.transcript", chunk(0, "first-line-xq7\n"))
      event_fixture(run, 4, "session.transcript", chunk(99, "second-line-xq7\n"))
      exit!(run, @paused)

      queued = run_of(dispatch_run.work_item_id, 2)

      log =
        capture_log(fn ->
          assert Transcript.check(run.id, @path) == {:error, :gap}
          assert Transcript.resume_at_claim(queued) == nil
        end)

      assert log =~ "transcript not restorable run=#{run.id} reason=gap"
      refute log =~ "xq7"
    end

    test "chunks after a gap are not kept, and the log line has no byte of them", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      count = fn ->
        Repo.aggregate(from(c in SessionChunk, where: c.run_id == ^run.id), :count)
      end

      # The run registered: its sequence 1 is in, and these follow it.
      event_fixture(run, 2, "session.transcript", chunk(0, "first-line-gq4\n"))
      event_fixture(run, 3, "session.transcript", chunk(99, "second-line-gq4\n"))
      assert {:ok, %Run{}} = Projector.project(run)
      assert count.() == 2

      # Every event up to the gap is in: no chunk that arrives later can fill it.
      event_fixture(run, 4, "session.transcript", chunk(114, "third-line-gq4\n"))
      log = capture_log(fn -> assert {:ok, %Run{}} = Projector.project(run) end)

      assert count.() == 2
      assert log =~ "transcript chunks not kept run=#{run.id} count=1 reason=gap"
      refute log =~ "gq4"
    end

    test "chunks that arrive out of order across two passes are kept whole", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      # The middle chunk's event comes in a later pass: the first pass stores a gap above
      # the projected sequence, which the second fills.
      event_fixture(run, 2, "session.transcript", chunk(0, "{\"a\":1}\n"))
      event_fixture(run, 4, "session.transcript", chunk(16, "{\"c\":3}\n"))
      assert {:ok, %Run{}} = Projector.project(run)

      event_fixture(run, 3, "session.transcript", chunk(8, "{\"b\":2}\n"))
      assert {:ok, %Run{}} = Projector.project(run)

      assert Repo.aggregate(from(c in SessionChunk, where: c.run_id == ^run.id), :count) == 3
      assert {:ok, %{size: 24, max_sequence: 4}} = Transcript.check(run.id, @path)

      assert run.id |> Transcript.stream(@path, 4) |> Enum.join() ==
               "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n"
    end

    test "a gap paired with an overlap of the same length stops the chunks after it", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      # [0, 8), [4, 12) and [16, 20): 20 bytes, as many as the furthest end, but the second
      # chunk starts at 4, not 8.
      event_fixture(run, 2, "session.transcript", chunk(0, "{\"a\":1}\n"))
      event_fixture(run, 3, "session.transcript", chunk(4, "{\"b\":2}\n"))
      event_fixture(run, 4, "session.transcript", chunk(16, "c:3\n"))
      assert {:ok, %Run{}} = Projector.project(run)

      event_fixture(run, 5, "session.transcript", chunk(20, "{\"d\":4}\n"))

      log =
        capture_log(fn -> assert {:ok, %Run{}} = Projector.project(Repo.get!(Run, run.id)) end)

      assert log =~ "transcript chunks not kept run=#{run.id} count=1 reason=gap"

      assert Repo.all(from(c in SessionChunk, where: c.run_id == ^run.id, select: c.sequence))
             |> Enum.sort() ==
               [2, 3, 4]
    end

    test "a resume has its three members, each a string, and no other", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      set = fn resume ->
        try do
          Repo.transaction(fn ->
            Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [resume: resume])
          end)

          :ok
        rescue
          error in Postgrex.Error -> error.postgres[:constraint]
        end
      end

      whole = %{"run_id" => "r", "session_id" => "s", "path" => "p"}
      assert set.(whole) == :ok
      assert set.(nil) == :ok

      for missing <- Map.keys(whole),
          do: assert(set.(Map.delete(whole, missing)) == "runs_resume_check")

      assert set.(Map.put(whole, "other", "x")) == "runs_resume_check"
      assert set.(%{whole | "path" => 1}) == "runs_resume_check"
    end

    test "a chunk whose path is not under the resume prefix is refused, with one log line",
         ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      refused = [
        "~/.claude/projects/../../.bashrc",
        "~/.claude/projects/-workspace/../5f2c9a1e.jsonl",
        "/etc/cron.d/5f2c9a1e.jsonl",
        "/home/agent/.claude/projects/-workspace/5f2c9a1e.jsonl",
        "~/.claude/projects//5f2c9a1e.jsonl",
        "~/.claude/projects/./-workspace/5f2c9a1e.jsonl",
        "~/-workspace/5f2c9a1e.jsonl",
        "~/.claude/projects/-work space/5f2c9a1e.jsonl",
        "~/.claude/projects/-workspace/5f2c9a1e.txt",
        "~/.claude/projects/-workspace/.jsonl",
        "~/.claude/projects/-workspace/6a3d0b2f.jsonl",
        "projects/-workspace/5f2c9a1e.jsonl"
      ]

      for {path, n} <- Enum.with_index(refused, 3) do
        event_fixture(run, n, "session.transcript", %{chunk(0, "line\n") | "path" => path})
      end

      log = capture_log(fn -> assert {:ok, %Run{}} = Projector.project(run) end)

      assert Repo.aggregate(from(c in SessionChunk, where: c.run_id == ^run.id), :count) == 0

      assert [_line] =
               Regex.scan(
                 ~r/transcript chunks refused run=#{run.id} count=#{length(refused)} reason=path_not_under_prefix/,
                 log
               )

      assert Transcript.resumable_path?(@path, "5f2c9a1e")
      assert Transcript.resumable_path?("~/.resumer/x/-w0rk-1/s.jsonl", "s")
      refute Transcript.resumable_path?(@path, "6a3d0b2f")
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
