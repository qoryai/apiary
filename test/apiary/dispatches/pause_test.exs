defmodule Apiary.Dispatches.PauseTest do
  # A run of a work item whose exit is `paused` with the reason `model_key_limit`, because
  # every model key of the run was at its limit: the run is Paused, its run of the queue
  # ends, and the run that continues it is queued at its place, with one more attempt and
  # the paused run's place in the queue (`Apiary.Dispatches.RunEnd`,
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
  import Apiary.WorkItemsFixtures, only: [work_item_fixture: 1]

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

  # The catalogue's runtime, read from the list rather than named here: a claim with no
  # model choice runs on it.
  @runtime hd(Apiary.Kinds.Runtimes.list()).name

  setup do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)

    keys = for id <- ~w(main spare), do: %{value_id: id, value: "sk-ant-fixture-#{id}-0123456789"}
    {:ok, provider} = Connections.create_provider(scope, %{provider: "anthropic", keys: keys})

    # A run claimed on the provider, with no key row: its sessions run on the provider
    # (`Apiary.Runs.Run.session_provider_ids/2`).
    given = %{provider_connection_id: provider.id, run_settings: %{"runtime" => @runtime}}

    %{scope: scope, key: key, provider: provider, given: given}
  end

  # The run exits with `data` after its session 1 started on the runtime of its run
  # settings, as Forager reports it (`runs.runtime`); with `started: false`, no session
  # started.
  defp exit!(run, data, opts \\ []) do
    started? =
      Repo.exists?(
        from(e in Apiary.Runs.Event,
          where: e.run_id == ^run.id and e.type == "dev.qory.session.started"
        )
      )

    if Keyword.get(opts, :started, true) and not started? do
      runtime = (run.run_settings || %{})["runtime"]
      event_fixture(run, 1, "session.started", session_started_data(%{"runtime" => runtime}))
    end

    event_fixture(run, 9, "run.exited", data)
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

  # `count` runs of the queue like `base`, each at another take in after `take_in` more
  # than base's, and each continuing the one before it, oldest first; the first continues
  # nothing.
  defp chain_of(%DispatchRun{} = base, count, take_in \\ 0) do
    fields = Map.take(base, DispatchRun.__schema__(:fields) -- [:id, :run_id, :continues_id])

    {entries, _previous} =
      Enum.map_reduce(1..count, nil, fn i, previous ->
        id = Ecto.UUID.generate()

        entry =
          Map.merge(fields, %{
            id: id,
            run_id: Ecto.UUID.generate(),
            continues_id: previous,
            take_in: base.take_in + take_in + i
          })

        {entry, id}
      end)

    {^count, nil} = Repo.insert_all(DispatchRun, entries)
    Enum.map(entries, &Map.take(&1, [:id, :run_id]))
  end

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

    # One key is not in cooldown, so the pause has no end time (`until: nil`).
    continuation = registered(next)

    # The run's organisation's provider is named, and is not the instance admin's.
    assert Pause.of_run(paused) == %{
             provider: ctx.provider.name,
             other_organisation: false,
             new_key: false,
             until: nil,
             number: continuation.number,
             workspace_id: ctx.scope.workspace.id
           }

    assert Pause.of_public_ids([paused.public_id]) == %{paused.public_id => Pause.of_run(paused)}
  end

  test "the continuation of a run paused with model_key_switch is claimed only once its report window ends",
       ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, %{@paused | "reason" => "model_key_switch"})

    assert %Run{state: "paused", exit_reason: "model_key_switch"} = Repo.get!(Run, run.id)
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}, {2, :waiting, nil}]

    # The window ends Report.after_exit_seconds/0 after the end of the paused run.
    next = run_of(dispatch_run.work_item_id, 2)
    assert %DateTime{} = wait = next.report_wait_until
    window = Apiary.ModelKeys.Report.after_exit_seconds()
    assert DateTime.diff(wait, DateTime.utc_now()) in (window - 10)..window

    # A claim one second before the window ends takes no run; a claim at its end takes the
    # continuation.
    assert {:ok, :none} = walked_claim(ctx.key, DateTime.add(wait, -1, :second))
    assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, next.id)

    assert {:ok, %{run: %DispatchRun{id: id}}} = walked_claim(ctx.key, wait)
    assert id == next.id
  end

  test "the continuation of a run paused at the limit has no report window", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, @paused)

    assert %DispatchRun{report_wait_until: nil} = run_of(dispatch_run.work_item_id, 2)
  end

  @tag needs: [:factory, :secrets, :observability]
  test "a paused run a member cancelled is not continued", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    {:ok, _cancelled} = Apiary.Runs.cancel(ctx.scope, Repo.get!(Run, run.id))
    exit!(run, @paused)

    assert %Run{state: "paused"} = Repo.get!(Run, run.id)
    assert runs_of(dispatch_run.work_item_id) == [{1, :ended, :run_ended}]
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
             "Paused: a key of #{ctx.provider.name} reached its limit or its Use up to percentage."
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
             "Paused: a key of #{ctx.provider.name} reached its limit or its Use up to percentage. It continues in run #{number}."
  end

  test "a key that needs a new key beside the cooldown is in the line", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, @paused)

    until = DateTime.add(DateTime.utc_now(), 3_600, :second)

    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^dispatch_run.id),
        set: [paused_until: until]
      )

    number = registered(run_of(dispatch_run.work_item_id, 2)).number
    time = ApiaryWeb.PreparationComponents.cooldown_time(until)

    line = fn pause ->
      pause |> ApiaryWeb.PauseWords.line(nil) |> ApiaryWeb.RichText.plain_text()
    end

    # No key needs a new key: the line is as it was.
    assert %{new_key: false} = pause = Pause.of_run(Repo.get!(Run, run.id))

    assert line.(pause) ==
             "Paused: every key of #{ctx.provider.name} is in cooldown until #{time}. It continues in run #{number}."

    # The provider rejected the value of `spare`.
    spare = key_value!(ctx.provider, "spare")

    {1, _rows} =
      Repo.insert_all("model_key_rejections", [
        %{
          organisation_id: Ecto.UUID.dump!(spare.organisation_id),
          secret_value_id: Ecto.UUID.dump!(spare.id),
          rejected_at: DateTime.utc_now(),
          value_set_at: spare.value_set_at,
          updated_at: DateTime.utc_now()
        }
      ])

    assert %{new_key: true} = pause = Pause.of_run(Repo.get!(Run, run.id))

    assert line.(pause) ==
             "Paused: every key of #{ctx.provider.name} is in cooldown until #{time} or needs a new key. It continues in run #{number}."

    # With no end time, the line is about the limit, as before.
    assert line.(%{pause | until: nil}) ==
             "Paused: a key of #{ctx.provider.name} reached its limit or its Use up to percentage. It continues in run #{number}."

    # A provider of another organisation than the run's has no name.
    assert line.(%{pause | provider: nil, other_organisation: true}) ==
             "Paused: every model key is in cooldown until #{time} or needs a new key. It continues in run #{number}."
  end

  test "a provider deleted since has no name in the line", ctx do
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, @paused)

    until = DateTime.add(DateTime.utc_now(), 3_600, :second)

    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^dispatch_run.id),
        set: [paused_until: until]
      )

    number = registered(run_of(dispatch_run.work_item_id, 2)).number
    # The pause as `Pause.of/1` reads it once the provider is deleted.
    pause = %{Pause.of_run(Repo.get!(Run, run.id)) | provider: nil}

    line = fn pause ->
      pause |> ApiaryWeb.PauseWords.line(nil) |> ApiaryWeb.RichText.plain_text()
    end

    # With no provider, the line has no cooldown end, while that time is to come too.
    assert line.(pause) ==
             "Paused: a model key reached its limit or its Use up to percentage. It continues in run #{number}."

    assert line.(%{pause | number: nil}) ==
             "Paused: a model key reached its limit or its Use up to percentage."

    refute line.(pause) =~ ctx.provider.name
  end

  test "a provider of another organisation has no name in the line", ctx do
    %{scope: other} = sign_up_fixture()
    keys = [%{value_id: "main", value: "sk-ant-other-main-0123456789"}]
    {:ok, theirs} = Connections.create_provider(other, %{provider: "anthropic", keys: keys})

    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
    exit!(run, @paused)

    # A run that took a key of another organisation's provider, left from when an
    # operator managed whole organisations.
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [provider_connection_id: theirs.id]
      )

    until = DateTime.add(DateTime.utc_now(), 3_600, :second)

    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^dispatch_run.id),
        set: [paused_until: until]
      )

    number = registered(run_of(dispatch_run.work_item_id, 2)).number

    assert %{provider: nil, other_organisation: true} =
             pause = Pause.of_run(Repo.get!(Run, run.id))

    line = fn pause ->
      pause |> ApiaryWeb.PauseWords.line(nil) |> ApiaryWeb.RichText.plain_text()
    end

    assert line.(pause) ==
             "Paused: every model key is in cooldown until " <>
               "#{ApiaryWeb.PreparationComponents.cooldown_time(until)}. It continues in run #{number}."

    # Once the cooldown has ended, and with no run that continues it.
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    assert line.(%{pause | until: past}) ==
             "Paused: a model key reached its limit or its Use up to percentage. It continues in run #{number}."

    assert line.(%{pause | number: nil}) ==
             "Paused: a model key reached its limit or its Use up to percentage."

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

      # One link: the paused run alone.
      resume = %{
        "run_id" => run.node_run_id,
        "session_id" => "5f2c9a1e",
        "path" => @path,
        "runs" => [run.node_run_id]
      }

      queued = run_of(dispatch_run.work_item_id, 2)
      assert Transcript.resume_at_claim(queued, @runtime) == resume

      # The claim stores it, and each run configuration reads what it stored.
      %{run: continuation} = handed_over(ctx.scope, ctx.key, queued, %{})
      assert continuation.resume == resume
      assert Transcript.resume(continuation) == resume

      # A chunk stored after the claim changes no run configuration of the run.
      event_fixture(run, 5, "session.transcript", chunk(16, "{\"c\":3}\n", "other"))
      {:ok, _run} = Projector.project(run)
      assert Transcript.resume(Repo.get!(Run, continuation.id)) == resume

      # A link added to the chain after the claim changes no run configuration of the run.
      [earlier] = chain_of(dispatch_run, 1)

      Repo.update_all(from(d in DispatchRun, where: d.id == ^dispatch_run.id),
        set: [continues_id: earlier.id]
      )

      assert Transcript.continued_runs(queued) == [earlier.run_id, run.node_run_id]
      assert Repo.get!(Run, continuation.id).resume == resume
      assert Transcript.resume(Repo.get!(Run, continuation.id)) == resume

      # The paused run itself, and a run that continues nothing, resume nothing.
      assert Transcript.resume(Repo.get!(Run, run.id)) == nil
      assert Transcript.resume_at_claim(dispatch_run, @runtime) == nil
    end

    test "is resumed only by a continuation on the runtime of the session that paused", ctx do
      %{dispatch_run: dispatch_run, run: run} =
        handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      # The run's settings have the catalogue's runtime, and the session that paused ran
      # on another one, as a later session of a shared stage can.
      other = @runtime <> "-second"
      event_fixture(run, 1, "session.started", session_started_data(%{"runtime" => other}))
      event_fixture(run, 3, "session.transcript", chunk(0, "{\"a\":1}\n"))
      exit!(run, @paused)
      assert %Run{runtime: ^other, run_settings: %{"runtime" => @runtime}} = Repo.reload(run)

      queued = run_of(dispatch_run.work_item_id, 2)

      # The runtime of the session that paused resumes the transcript.
      assert %{"run_id" => run_id, "session_id" => "5f2c9a1e", "path" => @path} =
               Transcript.resume_at_claim(queued, other)

      assert run_id == run.node_run_id

      # Another runtime, or none, starts a new session.
      assert Transcript.resume_at_claim(queued, @runtime) == nil
      assert Transcript.resume_at_claim(queued, nil) == nil

      # The claim of the continuation has no model choice, so it runs on the catalogue's
      # runtime: it stores no resume.
      %{run: continuation} = handed_over(ctx.scope, ctx.key, queued, %{})
      assert continuation.run_settings["runtime"] == @runtime
      assert continuation.resume == nil
      assert Transcript.resume(continuation) == nil
    end

    test "is not resumed when no session of the paused run reported its runtime", ctx do
      %{dispatch_run: dispatch_run, run: run} =
        handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      event_fixture(run, 3, "session.transcript", chunk(0, "{\"a\":1}\n"))
      exit!(run, @paused, started: false)
      assert %Run{runtime: nil} = Repo.reload(run)
      assert Transcript.last(run.id) == %{session_id: "5f2c9a1e", path: @path}

      queued = run_of(dispatch_run.work_item_id, 2)
      assert Transcript.resume_at_claim(queued, @runtime) == nil
      assert Transcript.resume_at_claim(queued, nil) == nil

      %{run: continuation} = handed_over(ctx.scope, ctx.key, queued, %{})
      assert continuation.run_settings["runtime"] == @runtime
      assert continuation.resume == nil
    end

    test "is not resumed by a continuation claimed on a fallback of another runtime, which keeps the pushed commits",
         ctx do
      release = Apiary.Kinds.Runtimes.list() |> Enum.find(&(&1.name == "claude"))

      # A runtime that takes only a bearer key, which OpenRouter's API has and Anthropic's
      # does not.
      bearer = %{
        release
        | name: release.name <> "-bearer",
          title: release.title <> " bearer",
          model_keys: Enum.filter(release.model_keys, &(&1["auth"] == %{"scheme" => "bearer"}))
      }

      :ok = Apiary.Kinds.Runtimes.put_test_list([release, bearer])

      {:ok, router} =
        Connections.create_provider(ctx.scope, %{
          provider: "openrouter",
          keys: [%{value_id: "main", value: "sk-or-fallback-0123456789"}]
        })

      tiers = Map.new(Apiary.ModelChoices.Resolution.tiers(), &{&1, "anthropic/claude-opus-5.5"})

      {:ok, _choice} =
        Apiary.ModelChoicesFixtures.put_choice(ctx.scope, :workspace, %{
          provider: ctx.provider.public_id,
          runtime: release.name,
          tiers: Map.new(Apiary.ModelChoices.Resolution.tiers(), &{&1, "claude-opus-5-5"}),
          fallbacks: [%{provider: router.public_id, runtime: bearer.name, tiers: tiers}]
        })

      # A run that takes model keys is claimed through a gateway that may receive secrets.
      %{key: key} = handover_place_fixture(ctx.scope, allow_secrets: true)
      %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(ctx.scope, key)
      assert run.run_settings["runtime"] == release.name
      assert run.provider_connection_id == ctx.provider.id

      # The paused run pushed a commit and kept a transcript of its session.
      work_item = Repo.get!(WorkItem, dispatch_run.work_item_id)
      commit = %{system: "forge", path: "acme/shop", commit: String.duplicate("a1", 20)}
      :ok = Apiary.Runs.PushedCommit.record(work_item, run, [commit])
      event_fixture(run, 3, "session.transcript", chunk(0, "{\"a\":1}\n"))
      exit!(run, @paused)
      assert %Run{runtime: "claude"} = Repo.reload(run)

      # Every key of the choice's provider is in cooldown, so the claim takes the fallback.
      for key <- ["main", "spare"], do: key_state!(ctx.provider, key, until: in_seconds(3600))
      queued = run_of(dispatch_run.work_item_id, 2)
      assert queued.continues_id == dispatch_run.id

      %{run: continuation} = handed_over(ctx.scope, key, queued, %{})
      assert continuation.provider_connection_id == router.id
      assert continuation.run_settings["runtime"] == bearer.name

      # It starts a new session, from the commits the paused run pushed.
      assert continuation.resume == nil
      assert Transcript.resume(continuation) == nil

      assert [%{commit: pushed, run_id: run_id}] =
               Apiary.Runs.PushedCommit.for_run(work_item, continuation)

      assert {pushed, run_id} == {commit.commit, run.node_run_id}
    end

    test "lists the paused runs a continuation continues, oldest first", ctx do
      %{dispatch_run: dispatch_run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      # Runs 1 <- 2 <- 3, and run 4 continues run 3.
      [one, two, three] = chain_of(dispatch_run, 3)
      four = %{dispatch_run | continues_id: three.id}

      assert Transcript.continued_runs(four) == [one.run_id, two.run_id, three.run_id]
      assert Transcript.continued_runs(%{four | continues_id: one.id}) == [one.run_id]
      assert Transcript.continued_runs(%{four | continues_id: nil}) == []

      # A run of another workspace is not followed.
      other = workspace_fixture(ctx.scope.organisation)
      assert Transcript.continued_runs(%{four | workspace_id: other.id}) == []
    end

    test "stops at a link of another workspace or organisation in the chain", ctx do
      %{dispatch_run: dispatch_run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)
      other_workspace = %{ctx.scope | workspace: workspace_fixture(ctx.scope.organisation)}
      %{scope: other_organisation} = sign_up_fixture()

      for {there, take_in} <- [{other_workspace, 0}, {other_organisation, 10}] do
        # Runs 1 <- 2 <- 3, with run 2 moved there, and run 4 continues run 3.
        [_one, two, three] = chain_of(dispatch_run, 3, take_in)

        Repo.update_all(from(d in DispatchRun, where: d.id == ^two.id),
          set: [
            organisation_id: there.organisation.id,
            workspace_id: there.workspace.id,
            work_item_id: work_item_fixture(there).id
          ]
        )

        four = %{dispatch_run | continues_id: three.id}
        assert Transcript.continued_runs(four) == [three.run_id]
      end
    end

    test "lists the newest 256 paused runs of a longer chain", ctx do
      %{dispatch_run: dispatch_run} = handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      chain = chain_of(dispatch_run, 300)
      continuation = %{dispatch_run | continues_id: List.last(chain).id}
      runs = Transcript.continued_runs(continuation)

      assert length(runs) == 256
      assert runs == chain |> Enum.take(-256) |> Enum.map(& &1.run_id)
      assert List.last(runs) == List.last(chain).run_id
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
      assert Transcript.resume_at_claim(%{queued | workspace_id: other.id}, @runtime) == nil
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
          assert Transcript.resume_at_claim(queued, @runtime) == nil
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

    test "a resume has its three strings and its runs, and no other member", ctx do
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
      assert set.(Map.put(whole, "runs", ["r0", "r"])) == :ok
      assert set.(Map.put(whole, "runs", Enum.map(1..256, &"r#{&1}"))) == :ok

      for runs <- [[], "r", ["r", 1], [["r"]], ["r", ["r0"]], Enum.map(1..257, &"r#{&1}")],
          do: assert(set.(Map.put(whole, "runs", runs)) == "runs_resume_check")

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

  describe "the session that paused" do
    # Each session of a run writes its transcript at a path of its session id.
    @session_ids %{1 => "a1b2c3d4", 2 => "e5f6a7b8"}

    defp session_path(session), do: "~/.claude/projects/-workspace/#{@session_ids[session]}.jsonl"

    defp session_chunk(session, offset, bytes),
      do: %{
        "session" => session,
        "session_id" => @session_ids[session],
        "path" => session_path(session),
        "offset" => offset,
        "bytes" => Base.encode64(bytes)
      }

    defp session_exited(session, state, reason \\ nil),
      do:
        %{"session" => session, "state" => state, "exit_code" => 1}
        |> Map.merge(if(reason, do: %{"reason" => reason}, else: %{}))

    test "is resumed when chunks of an earlier session arrive after its chunks", ctx do
      %{dispatch_run: dispatch_run, run: run} =
        handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      # Session 2 pauses after session 1; a chunk of session 1 has a higher sequence than
      # session 2's chunk.
      event_fixture(run, 3, "session.transcript", session_chunk(1, 0, "{\"s\":1}\n"))
      event_fixture(run, 4, "session.transcript", session_chunk(2, 0, "{\"s\":2}\n"))
      event_fixture(run, 5, "session.transcript", session_chunk(1, 8, "{\"t\":1}\n"))
      event_fixture(run, 6, "session.exited", session_exited(1, "succeeded"))
      event_fixture(run, 7, "session.exited", session_exited(2, "paused", "model_key_limit"))
      exit!(run, @paused)

      assert %Run{paused_session: 2} = Repo.get!(Run, run.id)
      assert Transcript.last(run.id) == %{session_id: @session_ids[1], path: session_path(1)}
      assert Transcript.last(run.id, 2) == %{session_id: @session_ids[2], path: session_path(2)}

      resume = %{
        "run_id" => run.node_run_id,
        "session_id" => @session_ids[2],
        "path" => session_path(2),
        "runs" => [run.node_run_id]
      }

      queued = run_of(dispatch_run.work_item_id, 2)
      assert Transcript.resume_at_claim(queued, @runtime) == resume

      %{run: continuation} = handed_over(ctx.scope, ctx.key, queued, %{})
      assert continuation.resume == resume

      # A rebuild clears a stale value and folds the same session again.
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [paused_session: 5])

      {:ok, rebuilt} = Projector.rebuild(Repo.get!(Run, run.id))
      assert rebuilt.paused_session == 2
    end

    test "with no chunk is not resumed: the continuation starts it afresh", ctx do
      %{dispatch_run: dispatch_run, run: run} =
        handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      event_fixture(run, 3, "session.transcript", session_chunk(1, 0, "{\"s\":1}\n"))
      event_fixture(run, 4, "session.exited", session_exited(1, "succeeded"))
      event_fixture(run, 5, "session.exited", session_exited(2, "paused", "model_key_limit"))
      exit!(run, @paused)

      assert %Run{paused_session: 2} = Repo.get!(Run, run.id)
      assert Transcript.last(run.id, 2) == nil

      queued = run_of(dispatch_run.work_item_id, 2)
      assert Transcript.resume_at_claim(queued, @runtime) == nil

      %{run: continuation} = handed_over(ctx.scope, ctx.key, queued, %{})
      assert continuation.resume == nil
    end

    test "decides the provider whose keys the paused run waits for", ctx do
      soon = in_seconds(3_600)
      key_state!(ctx.provider, "main", until: in_seconds(7_200))
      key_state!(ctx.provider, "spare", until: soon)

      %{dispatch_run: dispatch_run, run: run} =
        handed_over_fixture(ctx.scope, ctx.key, ctx.given)

      event_fixture(run, 4, "session.exited", session_exited(1, "succeeded"))
      event_fixture(run, 5, "session.exited", session_exited(2, "paused", "model_key_limit"))
      exit!(run, @paused)

      paused = Repo.get!(Run, run.id)

      # Each session runs on the run's one provider, so the paused session's is that one.
      assert Run.session_provider_ids(paused, paused.paused_session) == [ctx.provider.id]
      assert Run.session_provider_ids(paused, nil) == [ctx.provider.id]
      assert Run.session_provider_ids(%{paused | provider_connection_id: nil}, 2) == []

      assert DateTime.compare(Repo.get!(DispatchRun, dispatch_run.id).paused_until, soon) ==
               :eq
    end
  end
end
