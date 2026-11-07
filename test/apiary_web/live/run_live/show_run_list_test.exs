defmodule ApiaryWeb.RunLive.ShowRunListTest do
  @moduledoc """
  The Run list on a run's Timeline tab (`ApiaryWeb.PreparationComponents.run_list/1`):
  the Timeline inside Session started, closed on a run that ended and open on a running
  run or for a `?seq=` link; the move of the Timeline into Session started when the
  session starts on an open page; and Session finished from the session's events.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.Projector

  @moduletag needs: :factory

  setup :register_and_log_in_user

  defp project!(run, events) do
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    run
  end

  defp prepared do
    [
      {1, "run.started", started_data()},
      {2, "run.step_started", %{"step" => 1, "name" => "join session 1", "kind" => "join"}},
      {3, "run.step_exited",
       %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 1_000}}
    ]
  end

  defp session do
    [
      {4, "session.started", session_started_data()},
      {5, "runtime.started", %{"session_id" => "session-0001", "model" => "model-large-1"}},
      {6, "runtime.notification", %{"kind" => "k", "message" => "working"}}
    ]
  end

  defp ended do
    [
      {7, "runtime.result",
       %{"outcome" => "success", "turns" => 14, "duration_ms" => 229_000, "cost_usd" => 0.84}},
      {8, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}},
      {9, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1_000}}
    ]
  end

  defp run_path(scope, run), do: ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

  defp open(conn, path) do
    {:ok, lv, _html} = live(conn, path)
    lv
  end

  test "a run that ended has Session started closed, with the Timeline inside it", ctx do
    run = ctx.scope |> run_fixture() |> project!(prepared() ++ session() ++ ended())
    lv = open(ctx.conn, run_path(ctx.scope, run))

    assert has_element?(lv, "#prepare-machine-session:not([open]) > .q-xb #timeline #e-6")
    # The Timeline is in the list alone, not after it too.
    assert lv
           |> render()
           |> LazyHTML.from_document()
           |> LazyHTML.query("#timeline")
           |> Enum.count() ==
             1
  end

  test "a link to an event inside it opens Session started on a run that ended", ctx do
    run = ctx.scope |> run_fixture() |> project!(prepared() ++ session() ++ ended())
    lv = open(ctx.conn, run_path(ctx.scope, run) <> "?seq=6")

    assert has_element?(lv, "#prepare-machine-session[open] #e-6")
  end

  test "a running run has Session started open", ctx do
    run = ctx.scope |> run_fixture() |> project!(prepared() ++ session())
    lv = open(ctx.conn, run_path(ctx.scope, run))

    assert has_element?(lv, "#prepare-machine-session[open][data-state='running'] #e-6")
    refute has_element?(lv, "#prepare-machine-session-finished")
  end

  test "Session finished has the result's words and the model", ctx do
    run = ctx.scope |> run_fixture() |> project!(prepared() ++ session() ++ ended())
    lv = open(ctx.conn, run_path(ctx.scope, run))

    row = lv |> element("#prepare-machine-session-finished") |> render()
    assert row =~ "exit 0 · success · 14 turns · 3 m 49 s · $0.84"
    assert row =~ "model-large-1"
  end

  test "the session's start on an open page moves the Timeline, with the items it shows, into it",
       ctx do
    # Before the session: the run's start, its step and the policies it applied.
    policies =
      for n <- 4..6, do: {n, "run.policy_applied", %{"harness_hosts" => ["registry#{n}.example"]}}

    run = ctx.scope |> run_fixture() |> project!(prepared() ++ policies)

    lv = open(ctx.conn, run_path(ctx.scope, run))
    refute has_element?(lv, "#prepare-machine-session")

    shown =
      lv
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#timeline li[id^='e-']")
      |> LazyHTML.attribute("id")

    assert length(shown) == 4
    # The reader is at the end of the page, so new events join the window.
    render_hook(element(lv, "#live-end"), "live_end", %{"at_end" => true})

    # A browser empties the Timeline's list where it was, so the flush must send the
    # items already shown again. The test client keeps them, so the test reads what the
    # page process sends.
    :erlang.trace(lv.pid, true, [:send])

    project!(run, [
      {7, "session.started", session_started_data()},
      {8, "runtime.notification", %{"kind" => "k", "message" => "working"}}
    ])

    send(lv.pid, :flush)
    render(lv)
    :erlang.trace(lv.pid, false, [:send])

    for id <- shown,
        do: assert(has_element?(lv, "#prepare-machine-session[open] #timeline ##{id}"))

    sent = sent_ids(lv.pid)
    for id <- shown, do: assert(~s("#{id}") in sent, id)
  end

  test "for a reader not at the end, the move keeps the count of new events", ctx do
    policies =
      for n <- 4..6, do: {n, "run.policy_applied", %{"harness_hosts" => ["registry#{n}.example"]}}

    run = ctx.scope |> run_fixture() |> project!(prepared() ++ policies)
    lv = open(ctx.conn, run_path(ctx.scope, run))
    render_hook(element(lv, "#live-end"), "live_end", %{"at_end" => false})

    # A new event before the session: the reader is not at the end, so it is counted.
    project!(run, [{7, "run.policy_applied", %{"harness_hosts" => ["registry7.example"]}}])
    send(lv.pid, :flush)
    render(lv)
    count = :sys.get_state(lv.pid).socket.assigns.new_count
    assert count > 0

    # The session's start makes no item, so the count after the move is the same.
    project!(run, [{8, "session.started", session_started_data()}])
    send(lv.pid, :flush)
    render(lv)

    assert has_element?(lv, "#prepare-machine-session #timeline")
    assert :sys.get_state(lv.pid).socket.assigns.new_count == count
    assert lv |> element("#new-events") |> render() =~ Integer.to_string(count)
  end

  test "a settled list is read again at the session's result and at its exit", ctx do
    run = ctx.scope |> run_fixture() |> project!(prepared() ++ session())
    lv = open(ctx.conn, run_path(ctx.scope, run))
    assert :sys.get_state(lv.pid).socket.assigns.preparation_settled
    refute has_element?(lv, "#prepare-machine-session-finished")

    project!(run, [
      {7, "runtime.result",
       %{"outcome" => "success", "turns" => 14, "duration_ms" => 229_000, "cost_usd" => 0.84}}
    ])

    send(lv.pid, :flush)
    assert has_element?(lv, "#prepare-machine-session-finished", "success · 14 turns")
    refute has_element?(lv, "#prepare-machine-session-finished", "exit 0")

    project!(run, [
      {8, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}}
    ])

    send(lv.pid, :flush)
    assert has_element?(lv, "#prepare-machine-session-finished", "exit 0 · success")
  end

  test "a version the run pushes with no push step reaches Outputs saved at once", ctx do
    pool = Apiary.NodesFixtures.pool_fixture(ctx.scope, name: "build-pool")
    %{access_key: key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, pool)

    %{run: run, dispatch_run: dispatch_run} =
      Apiary.DispatchedRunsFixtures.handed_over_fixture(ctx.scope, key)

    run = project!(run, prepared() ++ session())
    lv = open(ctx.conn, run_path(ctx.scope, run))
    assert :sys.get_state(lv.pid).socket.assigns.preparation_settled
    refute has_element?(lv, "#prepare-machine-outputs")

    dispatch_run = Apiary.Repo.get!(Apiary.Dispatches.DispatchRun, dispatch_run.id)
    work_item = Apiary.Repo.get!(Apiary.WorkItems.WorkItem, dispatch_run.work_item_id)
    file = %{filename: "proposal.md", content_type: "text/markdown", binary: "Plan\n"}

    {:ok, _version} =
      Apiary.Artifacts.push({:run, dispatch_run}, work_item, "proposal", [file], name: "main")

    assert has_element?(lv, "#prepare-machine-outputs dd", "Version 1")
  end

  test "a version the run pushed is a Pushed row among the Timeline's rows by time, and shows live",
       ctx do
    pool = Apiary.NodesFixtures.pool_fixture(ctx.scope, name: "build-pool")
    %{access_key: key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, pool)

    %{run: run, dispatch_run: dispatch_run} =
      Apiary.DispatchedRunsFixtures.handed_over_fixture(ctx.scope, key)

    now = DateTime.utc_now()
    at = &DateTime.add(now, &1, :second)

    run =
      project!(run, [
        {1, "run.started", started_data(), time: at.(-100)},
        {4, "session.started", session_started_data(), time: at.(-90)},
        {5, "runtime.started", %{"session_id" => "session-0001"}, time: at.(-80)},
        {6, "runtime.notification", %{"kind" => "k", "message" => "one"}, time: at.(-40)},
        {7, "runtime.notification", %{"kind" => "k", "message" => "two"}, time: at.(-10)}
      ])

    dispatch_run = Apiary.Repo.get!(Apiary.Dispatches.DispatchRun, dispatch_run.id)
    work_item = Apiary.Repo.get!(Apiary.WorkItems.WorkItem, dispatch_run.work_item_id)
    file = %{filename: "proposal.md", content_type: "text/markdown", binary: "Plan\n"}

    push = fn type, name, seconds ->
      {:ok, version} =
        Apiary.Artifacts.push({:run, dispatch_run}, work_item, type, [file], name: name)

      if seconds do
        {1, _rows} =
          Apiary.Repo.update_all(
            from(v in Apiary.Artifacts.Version, where: v.id == ^version.id),
            set: [inserted_at: at.(seconds)]
          )
      end

      version
    end

    # Pushed between the two notifications, and second before the first: they read in the
    # order of time.
    late = push.("proposal", "main", -20)
    early = push.("proposal", "main", -60)

    lv = open(ctx.conn, run_path(ctx.scope, run))

    assert timeline_ids(lv) ==
             ~w(e-1 e-5 push-#{early.public_id} e-6 push-#{late.public_id} e-7)

    assert has_element?(lv, "#push-#{early.public_id} .q-k", "Pushed")
    assert has_element?(lv, "#push-#{early.public_id}", "proposal/main version 2")
    assert has_element?(lv, "#push-#{late.public_id}", "proposal/main version 1")
    refute has_element?(lv, "#push-#{early.public_id} a[data-permalink]")
    refute has_element?(lv, ~s(#push-#{early.public_id} a[href*="/terminal"]))
    assert has_element?(lv, "#run-tab-timeline .q-tabs-n", "6")

    # Pushed while the page is open, at the live end: the row comes with no reload.
    render_hook(element(lv, "#live-end"), "live_end", %{"at_end" => true})
    live = push.("proposal", "checkout", nil)
    assert List.last(timeline_ids(lv)) == "push-#{live.public_id}"
    assert has_element?(lv, "#push-#{live.public_id}", "proposal/checkout version 1")
    assert has_element?(lv, "#run-tab-timeline .q-tabs-n", "7")
  end

  defp timeline_ids(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("ol#timeline > li")
    |> LazyHTML.attribute("id")
  end

  # The ids of the items in what the page process sent, as strings in quotes.
  defp sent_ids(pid) do
    receive do
      {:trace, ^pid, :send, message, _to} ->
        ids =
          Regex.scan(~r/"e-\d+"/, inspect(message, limit: :infinity, printable_limit: :infinity))

        List.flatten(ids) ++ sent_ids(pid)
    after
      0 -> []
    end
  end
end
