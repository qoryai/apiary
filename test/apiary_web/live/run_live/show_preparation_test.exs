defmodule ApiaryWeb.RunLive.ShowPreparationTest do
  @moduledoc """
  The Run list of a run's Timeline (`ApiaryWeb.PreparationComponents`): its heading, its
  rows in the order the steps ran, on every pool, the steps before the first session in
  Prepare the machine and a session's join and wall in its Prepare the session, a step's
  log lines with their numbers and times, a failed or running row open, a failed row with
  its cause line of what happened, and Started as and the machine log under Start the
  machine for an instance admin alone. Not async: the instance admin's tests hide the
  instance's organisation and set the machine logs' folder.
  """
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.Midnight
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias Apiary.Dispatches
  alias Apiary.Dispatches.Dispatch
  alias Apiary.Runs.{Projector, RunCode}
  alias ApiaryWeb.Format

  @moduletag needs: :factory
  @moduletag :tmp_dir

  @admin_only "The instance admin can read the machine&#39;s log."
  @machine_log "qory-machine-start: Docker started\n"

  # The rows of `pool_run/2`, on every pool.
  @pool_rows [
    "Queue the run",
    "Request a machine",
    "Start the machine",
    "Prepare the machine",
    "Clone the repository",
    "Pull the images",
    "Agent session 1",
    "Prepare the session",
    "Start the agent",
    "Start the wall",
    "Run the agent",
    "Remove the machine"
  ]

  setup %{tmp_dir: tmp_dir} do
    before = Application.fetch_env(:apiary, :machine_logs_dir)
    Application.put_env(:apiary, :machine_logs_dir, Path.join(tmp_dir, "machine-logs"))

    on_exit(fn ->
      case before do
        {:ok, value} -> Application.put_env(:apiary, :machine_logs_dir, value)
        :error -> Application.delete_env(:apiary, :machine_logs_dir)
      end
    end)
  end

  defp claimed_run(scope) do
    pool = pool_fixture(scope, name: "build-pool")
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    scope |> handed_over_fixture(key) |> Map.put(:key, key)
  end

  defp project!(run, events) do
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    run
  end

  defp steps(failed?) do
    [
      {1, "run.started", started_data()},
      {2, "run.step_started",
       %{"step" => 1, "name" => "fetch git.example.com/acme/shop", "kind" => "fetch"}},
      {3, "run.log", step_log_data(1, "Cloning into 'shop'...\n")},
      {4, "run.step_exited",
       %{
         "step" => 1,
         "state" => if(failed?, do: "failed", else: "succeeded"),
         "exit_code" => if(failed?, do: 128, else: 0),
         "duration_ms" => 6000
       }}
    ] ++ if(failed?, do: [], else: [{5, "session.started", session_started_data()}])
  end

  defp open(conn, scope, run) do
    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

    lv
  end

  # A run of a fresh work item, claimed by a pool through its gateway: the claim's answer,
  # with the dispatch, the registered run and its code, the pool's key and the gateway. The
  # machine has not started: no `dispatched`, the code not redeemed.
  defp claimed(scope) do
    pool = pool_fixture(scope, name: "build-pool")
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    gateway = gateway_for!(scope, pool)

    {:ok, _queued} =
      Apiary.Repo.transact(fn ->
        Dispatches.queue(Apiary.WorkItemsFixtures.work_item_fixture(scope), 1)
      end)

    {:ok, claimed} = Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now())
    Map.merge(claimed, %{key: key, gateway: gateway})
  end

  # The machine redeems the run's code through the gateway, as at its enrolment.
  defp redeem!(claimed) do
    pair = ed25519_key_pair()
    now = DateTime.utc_now()
    timestamp = DateTime.to_unix(now)
    message = SignedMessage.enrolment(claimed.run_code, pair.encoded, "run-01", timestamp)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519]) |> Ed25519.encode()

    {:ok, request} =
      Enrolment.decode(
        Jason.encode!(%{
          version: 1,
          code: claimed.run_code,
          name: "run-01",
          public_key: pair.encoded,
          timestamp: timestamp,
          proof: proof
        })
      )

    {:ok, _answer} = RunCode.redeem(request, now: now, relayed_by: claimed.gateway.id)
  end

  # The vendor's machine type, as the first `dispatched` reports it.
  defp vendor_type!(%Dispatch{id: id}, type) do
    {1, _rows} =
      Apiary.Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set: [vendor_machine_type: type]
      )
  end

  # The dispatch of a claimed run moved to `pool`.
  defp on_pool!(%Dispatch{id: id}, pool) do
    {1, _rows} =
      Apiary.Repo.update_all(from(d in Dispatch, where: d.id == ^id), set: [pool_id: pool.id])
  end

  # A run that ended on `pool`: a fetch and an image step before its session, the join of
  # its session, and the session's wall after its start.
  defp pool_run(ctx, pool) do
    %{run: run, dispatch: dispatch} = claimed_run(ctx.scope)
    on_pool!(dispatch, pool)

    exited = fn sequence, step ->
      {sequence, "run.step_exited",
       %{"step" => step, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
    end

    run =
      project!(run, [
        {1, "run.started", started_data()},
        {2, "run.step_started",
         %{"step" => 1, "name" => "fetch git.example.com/acme/shop", "kind" => "fetch"}},
        exited.(3, 1),
        {4, "run.step_started",
         %{"step" => 2, "name" => "registry.example.com/shop:1", "kind" => "image"}},
        exited.(5, 2),
        {6, "run.step_started", %{"step" => 3, "name" => "join session 1", "kind" => "join"}},
        exited.(7, 3),
        {8, "session.started", session_started_data()},
        {9, "run.step_started", %{"step" => 4, "name" => "start the wall", "kind" => "wall"}},
        exited.(10, 4),
        {11, "runtime.result", %{"session" => 1, "outcome" => "success", "turns" => 2}},
        {12, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}},
        {13, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
      ])

    %{run: run, dispatch: dispatch}
  end

  # The names of the list's rows, the rows inside a row included, in the page's order.
  defp row_names(lv) do
    lv
    |> element("#prepare-machine")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".q-prep-name")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # Every row of `pool_run/2`, each step in its place.
  defp assert_pool_rows(lv) do
    assert row_names(lv) == @pool_rows
    assert has_element?(lv, "#prepare-machine-prepare #prepare-machine-step-2", "Pull the images")

    for {step, name} <- [{3, "Start the agent"}, {4, "Start the wall"}] do
      assert has_element?(
               lv,
               "#prepare-machine-session #prepare-machine-session-prepare #prepare-machine-step-#{step}",
               name
             )
    end

    assert has_element?(lv, "#prepare-machine-session-agent #timeline")
    assert has_element?(lv, "#prepare-machine-remove[data-clean-up]")
  end

  # Written with no broadcast, as when the broadcast after the commit failed.
  defp dispatched_quietly!(%Dispatch{id: id}) do
    {1, _rows} =
      Apiary.Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set: [dispatched_at: DateTime.utc_now()]
      )
  end

  describe "for a member" do
    setup :register_and_log_in_user

    test "the rows in the order they ran, each closed, the machine log the admin's", ctx do
      %{run: run} = claimed_run(ctx.scope)
      run = project!(run, steps(false))
      lv = open(ctx.conn, ctx.scope, run)

      assert row_names(lv) == [
               "Queue the run",
               "Request a machine",
               "Start the machine",
               "Prepare the machine",
               "Clone the repository",
               "Agent session 1",
               "Run the agent"
             ]

      assert has_element?(lv, "#prepare-machine-start")
      refute has_element?(lv, "#prepare-machine-started")
      refute has_element?(lv, "#prepare-machine-start-machine")
      assert has_element?(lv, "#prepare-machine-prepare #prepare-machine-step-1")

      # The run goes on: Agent session 1 and its Run the agent are open, with the Timeline
      # inside them.
      assert has_element?(
               lv,
               "#prepare-machine-session[open] #prepare-machine-session-agent[open] #timeline"
             )

      refute has_element?(
               lv,
               "#prepare-machine details[open]:not(#prepare-machine-session):not(#prepare-machine-session-agent)"
             )

      refute has_element?(lv, "#prepare-machine-machine-log")
      refute render(lv) =~ @admin_only
      assert lv |> element("#prepare-machine-request") |> render() =~ "build-pool"
      assert lv |> element("#prepare-machine-request") |> render() =~ "pool default"

      assert lv |> element("#prepare-machine-step-1-output .q-log-x") |> render() =~
               "Cloning into &#39;shop&#39;..."

      refute has_element?(lv, "#prepare-machine-cause")
    end

    test "a run on the Qory Pool shows every row of the pool to a member, with no Started as and no machine log",
         ctx do
      %{run: run, dispatch: dispatch} =
        pool_run(ctx, instance_pool_fixture(%{name: "qory-pool"}))

      vendor_type!(dispatch, "example-type")
      lv = open(ctx.conn, ctx.scope, run)

      assert_pool_rows(lv)
      assert lv |> element("#prepare-machine-request") |> render() =~ "qory-pool"
      refute has_element?(lv, "#prepare-machine-started-as")
      refute has_element?(lv, "#prepare-machine-machine-log")
      refute render(lv) =~ "example-type"
    end

    test "the heading has the pool and the run's state: Running while it is alive, then Completed",
         ctx do
      heading = fn lv ->
        lv
        |> element("#prepare-machine-h")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
      end

      %{run: run} = claimed_run(ctx.scope)
      run = project!(run, steps(false))
      assert heading.(open(ctx.conn, ctx.scope, run)) == "Run on build-pool · Running"

      run =
        project!(run, [
          {6, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      assert run.state == "completed"
      assert heading.(open(ctx.conn, ctx.scope, run)) == "Run on build-pool · Completed"
    end

    test "a run of a machine type: Request a machine has its spec, Details its name, the peak the type's memory",
         ctx do
      %{run: run, dispatch: dispatch} = claimed_run(ctx.scope)

      {1, _rows} =
        Apiary.Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
          set: [machine_type: "large", machine_spec: Apiary.MachineTypesFixtures.spec()]
        )

      run =
        project!(
          run,
          steps(false) ++
            [
              {6, "session.exited",
               %{
                 "session" => 1,
                 "state" => "succeeded",
                 "exit_code" => 0,
                 "duration_ms" => 900,
                 "peak_memory_bytes" => 10_522_669_875
               }}
            ]
        )

      lv = open(ctx.conn, ctx.scope, run)
      requested = lv |> element("#prepare-machine-request") |> render()
      assert requested =~ "large (4 vCPUs, 16 GiB, 60 GiB disk)"
      refute requested =~ "pool default"

      assert has_element?(lv, "#rail-machine-type", "large")
      assert has_element?(lv, "#rail-peak-memory", "9.8 of 16 GiB")
    end

    test "a run with no machine type in its claim answer has no Machine type in Details", ctx do
      %{run: run} = claimed_run(ctx.scope)
      run = project!(run, steps(false))
      lv = open(ctx.conn, ctx.scope, run)

      refute has_element?(lv, "#rail-machine-type")
      assert lv |> element("#prepare-machine-request") |> render() =~ "pool default"
    end

    test "the vendor's machine type is not shown to a member", ctx do
      %{run: run, dispatch: dispatch} = claimed_run(ctx.scope)
      vendor_type!(dispatch, "example-type")
      run = project!(run, steps(false))
      lv = open(ctx.conn, ctx.scope, run)

      refute has_element?(lv, "#prepare-machine-started-as")
      refute render(lv) =~ "example-type"
      refute render(lv) =~ "Started as"
    end

    test "Prepare the machine groups the steps before the session, in order, with their labels; the join is the session's",
         ctx do
      zone = reader_at_noon(ctx.scope.user)
      %{run: run} = claimed_run(ctx.scope)
      t = ~U[2026-11-06 00:33:07.600000Z]

      run =
        project!(run, [
          {1, "run.started", started_data()},
          {2, "run.step_started",
           %{"step" => 1, "name" => "fetch git.example.com/acme/shop", "kind" => "fetch"}},
          {3, "run.step_exited",
           %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 4000}},
          {4, "run.step_started",
           %{"step" => 2, "name" => "compose the harness", "kind" => "compose"}},
          {5, "run.step_exited",
           %{"step" => 2, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {6, "run.step_started",
           %{"step" => 3, "name" => "setup postCreateCommand: npm ci", "kind" => "setup"}},
          {7, "run.log", step_log_data(3, "> npm ci\n"), time: t},
          {8, "run.log", step_log_data(3, "found 0 vulnerabilities\n"),
           time: DateTime.add(t, 36_200, :millisecond)},
          {9, "run.step_exited",
           %{"step" => 3, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 48_000}},
          {10, "run.step_started", %{"step" => 4, "name" => "join session 1", "kind" => "join"}},
          {11, "run.step_exited",
           %{"step" => 4, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}},
          {12, "session.started", session_started_data()}
        ])

      lv = open(ctx.conn, ctx.scope, run)

      grouped =
        lv
        |> element("#prepare-machine-prepare")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".q-prep-steps .q-prep-name")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert grouped == [
               "Clone the repository",
               "Compose the harness",
               "Set up the dev container"
             ]

      assert has_element?(
               lv,
               "#prepare-machine-session #prepare-machine-session-prepare #prepare-machine-step-4",
               "Start the agent"
             )

      lines = "#prepare-machine-step-3-output-lines"
      assert has_element?(lv, "#{lines} .q-log-ln:nth-child(1) .q-log-n", "1")
      assert has_element?(lv, "#{lines} .q-log-ln:nth-child(1) .q-log-x", "> npm ci")
      assert has_element?(lv, "#{lines} .q-log-ln:nth-child(2) .q-log-n", "2")

      for {n, time} <- [{1, t}, {2, DateTime.add(t, 36_200, :millisecond)}] do
        shown = Format.with_time_zone(zone, fn -> Format.time(time, tenths: true) end)

        assert has_element?(
                 lv,
                 ~s|#{lines} .q-log-ln:nth-child(#{n}) .q-log-t time[datetime="#{DateTime.to_iso8601(time)}"]|,
                 shown
               )
      end
    end

    test "a live run: the running step is open, and its lines and the next step arrive",
         ctx do
      %{run: run} = claimed_run(ctx.scope)

      run =
        project!(run, [
          {1, "run.started", started_data()},
          {2, "run.step_started",
           %{"step" => 1, "name" => "fetch git.example.com/acme/shop", "kind" => "fetch"}},
          {3, "run.step_exited",
           %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 4000}},
          {4, "run.step_started",
           %{"step" => 2, "name" => "setup postCreateCommand: npm ci", "kind" => "setup"},
           time: DateTime.utc_now()},
          {5, "run.log", step_log_data(2, "> npm ci\n")}
        ])

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-prepare[open][data-state='running']")
      assert has_element?(lv, "#prepare-machine-step-2[open][data-state='running']")
      refute has_element?(lv, "#prepare-machine-step-1[open]")
      refute has_element?(lv, "#prepare-machine-start[open]")
      assert lv |> element("#prepare-machine-step-2 > summary") |> render() =~ "Running"
      assert has_element?(lv, "#prepare-machine-prepare-clock[data-tick='duration']")
      refute has_element?(lv, "#prepare-machine-step-2-output-lines .q-log-n", "2")

      # A line arrives: the next flush shows it, numbered.
      events_fixture(run, [{6, "run.log", step_log_data(2, "added 1184 packages\n")}])
      {:ok, _run} = Projector.project(run)
      send(lv.pid, :flush)
      assert has_element?(lv, "#prepare-machine-step-2-output-lines .q-log-n", "2")
      assert has_element?(lv, "#prepare-machine-step-2-output-lines .q-log-x", "added 1184")

      # The step ends and the session's join starts: it is a row of Agent session 1, open
      # while it runs, and Prepare the machine has ended.
      events_fixture(run, [
        {7, "run.step_exited",
         %{"step" => 2, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 48_000}},
        {8, "run.step_started", %{"step" => 3, "name" => "join session 1", "kind" => "join"}}
      ])

      {:ok, _run} = Projector.project(run)
      send(lv.pid, :flush)

      assert has_element?(
               lv,
               "#prepare-machine-session[open] #prepare-machine-session-prepare #prepare-machine-step-3[open]",
               "Start the agent"
             )

      assert has_element?(lv, "#prepare-machine-step-2[data-state='succeeded']")
      assert has_element?(lv, "#prepare-machine-prepare[data-state='succeeded']")
    end

    test "a step of 5,000 lines shows its last 2,500, numbered, in one scrolled box", ctx do
      %{run: run} = claimed_run(ctx.scope)

      lines = for n <- 1..5_000, do: {n + 2, "run.log", step_log_data(1, "line #{n}\n")}

      run =
        project!(
          run,
          [
            {1, "run.started", started_data()},
            {2, "run.step_started",
             %{"step" => 1, "name" => "setup postCreateCommand: npm ci", "kind" => "setup"}}
          ] ++
            lines ++
            [
              {5_003, "run.step_exited",
               %{"step" => 1, "state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
            ]
        )

      lv = open(ctx.conn, ctx.scope, run)
      box = "#prepare-machine-step-1-output-lines"

      assert has_element?(lv, "#prepare-machine-step-1[open]")
      assert has_element?(lv, "#{box}.q-log .q-log-ln:first-child .q-log-n", "2501")
      assert has_element?(lv, "#{box}.q-log .q-log-ln:first-child .q-log-x", "line 2501")
      assert has_element?(lv, "#{box} .q-log-ln:last-child .q-log-n", "5000")
      assert has_element?(lv, "#{box} .q-log-ln:last-child .q-log-x", "line 5000")

      assert has_element?(
               lv,
               "#prepare-machine-step-1-output > p",
               "The output is cut: these are its last 2,500 lines."
             )
    end

    test "a machine step: its lines under Start the machine, after create machine", ctx do
      %{run: run, dispatch: dispatch} = claimed_run(ctx.scope)
      started = DateTime.add(dispatch.dispatched_at, 14_800, :millisecond)

      # The code redeemed 41 s after `dispatched`, after the step's start.
      run =
        run
        |> Ecto.Changeset.change(
          run_key_issued_at: DateTime.add(dispatch.dispatched_at, 41, :second)
        )
        |> Apiary.Repo.update!()

      run =
        project!(
          run,
          [{1, "run.started", started_data()}] ++
            machine_step_events(2, 1, started) ++
            [
              {9, "run.step_started",
               %{"step" => 2, "name" => "fetch git.example.com/acme/shop", "kind" => "fetch"}}
            ]
        )

      assert [%{kind: "machine"}, %{kind: "fetch"}] = Apiary.Runs.Record.steps(ctx.scope, run)
      lv = open(ctx.conn, ctx.scope, run)

      refute has_element?(lv, "#prepare-machine-step-1")
      lines = "#prepare-machine-start #prepare-machine-start-machine-output-lines"

      # `has_element?/3` matches the text with its runs of spaces made one.
      assert has_element?(
               lv,
               "#{lines} .q-log-ln:nth-child(1) .q-log-x",
               "create machine 14.8 s"
             )

      assert has_element?(lv, "#{lines} .q-log-ln:nth-child(2) .q-log-x", "boot 14.8 s")
      assert has_element?(lv, "#{lines} .q-log-ln:nth-child(6) .q-log-x", "write run code 0.1 s")
      assert has_element?(lv, "#{lines} .q-log-ln:nth-child(6) .q-log-n", "6")
      assert has_element?(lv, "#prepare-machine-step-2", "Clone the repository")
      refute has_element?(lv, "#prepare-machine-machine-log")
    end

    test "the time columns: a legend over each list, every row with both cells", ctx do
      %{run: run} = claimed_run(ctx.scope)
      run = project!(run, steps(false))
      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#run-timeline.q-run-tl")
      assert has_element?(lv, "#prepare-machine > .q-tlegend .q-tc1", "Started")
      assert has_element?(lv, "#prepare-machine > .q-tlegend .q-tc2", "Took")
      assert has_element?(lv, "#run-timeline .q-tlegend .q-tc1", "Since run start")
      assert has_element?(lv, "#run-timeline .q-tlegend .q-tc2", "Event")

      # Agent session 1 runs, with no duration: its second cell stays, so its time keeps its
      # column.
      assert has_element?(lv, "#prepare-machine-session .q-t > .q-tc1 time")
      assert has_element?(lv, "#prepare-machine-session .q-t > .q-tc2")
      assert has_element?(lv, "#timeline .q-t > .q-t-at.q-tc1")
      assert has_element?(lv, "#timeline .q-t > .q-q.q-tc2")
    end

    test "a failed step is open, with its output and its cause line of what happened", ctx do
      %{run: run} = claimed_run(ctx.scope)
      run = project!(run, steps(true))
      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-step-1[open]")
      assert has_element?(lv, "#prepare-machine-prepare[open][data-state='failed']")
      refute has_element?(lv, "#prepare-machine-start[open]")
      assert has_element?(lv, "#prepare-machine-step-1 #prepare-machine-step-1-output")

      assert lv |> element("#prepare-machine-step-1 #prepare-machine-cause") |> render() =~
               ">Clone the repository failed with exit code 128 (git.example.com/acme/shop).</p>"
    end

    test "a step whose output retention deleted shows when it was pruned", ctx do
      zone = reader_at_noon(ctx.scope.user)
      {:ok, workspace} = Apiary.Retention.update_retention(ctx.scope, %{log_retention_days: 7})
      %{run: run} = claimed_run(ctx.scope)

      run =
        project!(
          run,
          steps(true) ++
            [
              {5, "run.exited",
               %{"state" => "failed", "exit_code" => 128, "duration_ms" => 7_000}}
            ]
        )

      now = DateTime.add(DateTime.utc_now(), 10 * 86_400, :second)
      assert %{runs_pruned: 1} = Apiary.Retention.prune_workspace(workspace, now: now)
      lv = open(ctx.conn, ctx.scope, run)
      date = Format.with_time_zone(zone, fn -> Format.date(DateTime.utc_now()) end)

      output = lv |> element("#prepare-machine-step-1-output") |> render()
      refute output =~ "No output."

      assert output =~
               "This run&#39;s log output was pruned on #{date}, under the workspace&#39;s " <>
                 "retention. The timeline and the connections are whole."

      assert lv |> element("#prepare-machine-cause") |> render() =~
               ">Clone the repository failed with exit code 128 (git.example.com/acme/shop).</p>"
    end

    test "a released run: Start the machine is open with what happened, the header the cause",
         ctx do
      pool = pool_fixture(ctx.scope, name: "build-pool")
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      _gateway = gateway_for!(ctx.scope, pool)

      {:ok, _queued} =
        Apiary.Repo.transact(fn ->
          Dispatches.queue(Apiary.WorkItemsFixtures.work_item_fixture(ctx.scope), 1)
        end)

      {:ok, %{dispatch: dispatch, registered: run}} =
        Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now())

      :ok = Dispatches.release(key, dispatch.public_id, %{reason: "No capacity in the region."})
      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-start[open][data-state='failed']")
      refute has_element?(lv, "#prepare-machine-request[open]")

      assert lv |> element("#prepare-machine-start #prepare-machine-cause") |> render() =~
               ">No machine was made: No capacity in the region.</p>"

      assert lv |> element("#run-reason") |> render() =~
               "No machine was made: No capacity in the region."

      refute render(lv) =~ "reads why"
    end

    test "a release reason's run key is filtered on the page, and kept in the diagnostics",
         ctx do
      run_key = "qrk_eyJ2ZXJzaW9uIjoxfQ.c2lnbmF0dXJlLWJ5dGVz"
      pool = pool_fixture(ctx.scope, name: "build-pool")
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      _gateway = gateway_for!(ctx.scope, pool)

      {:ok, _queued} =
        Apiary.Repo.transact(fn ->
          Dispatches.queue(Apiary.WorkItemsFixtures.work_item_fixture(ctx.scope), 1)
        end)

      {:ok, %{dispatch: dispatch, registered: run}} =
        Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now())

      :ok = Dispatches.release(key, dispatch.public_id, %{reason: "Key #{run_key} refused."})
      run = Apiary.Repo.get!(Apiary.Runs.Run, run.id)

      # The Run list's cause and the header both have it filtered.
      assert %{stopped: %{text: text}} = Apiary.Runs.Preparation.read(ctx.scope, run)
      assert text =~ "No machine was made: Key [FILTERED] refused."
      html = ctx.conn |> open(ctx.scope, run) |> render()
      assert html =~ "[FILTERED]"
      refute html =~ "qrk_" or html =~ "c2lnbmF0"

      # The diagnostics document keeps the text as stored.
      document = Apiary.Runs.Diagnostics.document(run, :instance)
      assert [%{"release_reason" => "Key " <> _ = reason}] = document["dispatches"]
      assert reason =~ run_key

      assert document["preparation"]["stopped"]["text"] =~
               "No machine was made: Key #{run_key} refused"
    end

    test "a stop on the Qory Pool shows the pool's rows, no note, and no advice",
         ctx do
      before = Application.get_env(:apiary, :support_address)
      Application.put_env(:apiary, :support_address, "https://help.example.com")
      on_exit(fn -> Application.put_env(:apiary, :support_address, before) end)

      %{run: run, dispatch: dispatch} = claimed_run(ctx.scope)
      qory_pool = instance_pool_fixture(%{name: "qory-pool"})

      {1, _rows} =
        Apiary.Repo.update_all(
          from(d in Apiary.Dispatches.Dispatch, where: d.id == ^dispatch.id),
          set: [pool_id: qory_pool.id]
        )

      run =
        run
        |> Ecto.Changeset.change(unattached())
        |> Ecto.Changeset.change(
          state: "lost",
          lost_at: run.run_code_expires_at,
          run_code_public_key: nil,
          run_key_payload: nil,
          run_key_signature: nil,
          run_key_issued_at: dispatch.claimed_at,
          attach_by: run.run_code_expires_at
        )
        |> Apiary.Repo.update!()

      lv = open(ctx.conn, ctx.scope, run)

      # The pool's rows are shown, as on any pool, with no note above the Timeline, and
      # the page shows no line about who fixes the cause.
      assert has_element?(lv, "#prepare-machine-request")

      assert lv |> element("#prepare-machine-start[open] #prepare-machine-cause") |> render() =~
               ">The machine did not start the run within 15 minutes of the request.</p>"

      refute has_element?(lv, ".q-limits")

      html = render(lv)
      refute html =~ "Contact support"
      refute html =~ "nstance admin"
      assert lv |> element("#run-reason") |> render() =~ "15 minutes"
    end

    # A run whose wall failed to start, on `pool` or the claim's pool, in the contract's
    # order: the join, the session's start, then the wall.
    defp wall_failed(ctx, pool \\ nil) do
      %{run: run, dispatch: dispatch} = claimed_run(ctx.scope)

      if pool, do: on_pool!(dispatch, pool)

      project!(run, [
        {1, "run.started", started_data(%{"wall" => "docker"})},
        {2, "run.step_started", %{"step" => 1, "name" => "join session 1", "kind" => "join"}},
        {3, "run.step_exited",
         %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
        {4, "session.started", session_started_data()},
        {5, "run.step_started", %{"step" => 2, "name" => "start the wall", "kind" => "wall"}},
        {6, "run.step_exited",
         %{"step" => 2, "state" => "failed", "exit_code" => 125, "duration_ms" => 100}},
        {7, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
      ])
    end

    # The failed wall's row in Agent session 1, its cause line and How it ended: what
    # happened alone, with no advice; Run the agent and Save the outputs Skipped, as the
    # agent never ran, with the Timeline after the list; and no note above the Timeline.
    defp assert_wall_failed(lv) do
      what = "Start the wall failed with exit code 125."

      assert lv
             |> element(
               "#prepare-machine-session-prepare #prepare-machine-step-2[open] #prepare-machine-cause"
             )
             |> render() =~ ">#{what}</p>"

      assert has_element?(lv, "#prepare-machine-session-agent[data-state=skipped]")
      assert has_element?(lv, "#prepare-machine-session-outputs[data-state=skipped]")
      refute has_element?(lv, "#prepare-machine-session-agent dl")
      refute has_element?(lv, "#prepare-machine #timeline")
      assert has_element?(lv, "#timeline")

      assert lv |> element("#run-why .q-run-why-whole") |> render() =~ ">#{what}</span>"
      refute has_element?(lv, "#run-why-jump")

      refute has_element?(lv, ".q-limits")

      html = render(lv)
      refute html =~ "Contact support"
      refute html =~ "reads the cause"
    end

    test "a failed step of the workspace's pool: its row and How it ended state what happened alone",
         ctx do
      assert_wall_failed(open(ctx.conn, ctx.scope, wall_failed(ctx)))
    end

    test "a failed step of the Qory Pool: its row and How it ended state what happened alone",
         ctx do
      before = Application.get_env(:apiary, :support_address)
      Application.put_env(:apiary, :support_address, "https://help.example.com")
      on_exit(fn -> Application.put_env(:apiary, :support_address, before) end)

      lv = open(ctx.conn, ctx.scope, wall_failed(ctx, instance_pool_fixture(%{name: "qory"})))
      assert_wall_failed(lv)
    end

    test "a wall that fails after an agent session ran keeps the note about that session's events",
         ctx do
      %{run: run} = claimed_run(ctx.scope)

      run =
        project!(run, [
          {1, "run.started", started_data(%{"wall" => "docker"})},
          {2, "run.step_started", %{"step" => 1, "name" => "join session 1", "kind" => "join"}},
          {3, "run.step_exited",
           %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {4, "session.started", session_started_data()},
          {5, "run.step_started", %{"step" => 2, "name" => "start the wall", "kind" => "wall"}},
          {6, "run.step_exited",
           %{"step" => 2, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {7, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}},
          {8, "run.step_started", %{"step" => 3, "name" => "join session 2", "kind" => "join"}},
          {9, "run.step_exited",
           %{"step" => 3, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {10, "session.started", session_started_data(%{"session" => 2})},
          {11, "run.step_started", %{"step" => 4, "name" => "start the wall", "kind" => "wall"}},
          {12, "run.step_exited",
           %{"step" => 4, "state" => "failed", "exit_code" => 125, "duration_ms" => 100}},
          {13, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
        ])

      lv = open(ctx.conn, ctx.scope, run)

      # Session 1 ran behind the wall with no hook events, so the wall's note stays; session
      # 2 never ran its agent.
      assert has_element?(lv, ".q-limits")
      assert has_element?(lv, "#prepare-machine-session-agent[data-state=succeeded]")
      assert has_element?(lv, "#prepare-machine-session-2-agent[data-state=skipped]")
    end

    test "the items of a session whose wall failed are in the Timeline after the list, not in session 1's",
         ctx do
      %{run: run} = claimed_run(ctx.scope)

      run =
        project!(run, [
          {1, "run.started", started_data(%{"wall" => "docker"})},
          {2, "run.step_started", %{"step" => 1, "name" => "join session 1", "kind" => "join"}},
          {3, "run.step_exited",
           %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {4, "session.started", session_started_data()},
          {5, "run.step_started", %{"step" => 2, "name" => "start the wall", "kind" => "wall"}},
          {6, "run.step_exited",
           %{"step" => 2, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {7, "runtime.started", %{"session" => 1, "session_id" => "session-0001"}},
          {8, "runtime.ended", %{"session" => 1, "reason" => "other"}},
          {9, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}},
          {10, "run.step_started", %{"step" => 3, "name" => "join session 2", "kind" => "join"}},
          {11, "run.step_exited",
           %{"step" => 3, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {12, "session.started", session_started_data(%{"session" => 2})},
          {13, "run.step_started", %{"step" => 4, "name" => "start the wall", "kind" => "wall"}},
          {14, "run.step_exited",
           %{"step" => 4, "state" => "failed", "exit_code" => 125, "duration_ms" => 100}},
          # An item with session 2's number, as any event of that session makes one.
          {15, "runtime.ended", %{"session" => 2, "reason" => "other"}},
          {16, "session.exited", %{"session" => 2, "state" => "failed", "exit_code" => -1}},
          {17, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
        ])

      lv = open(ctx.conn, ctx.scope, run)

      # Session 1's Timeline, inside its Run the agent, has its items and none of session 2's.
      assert has_element?(lv, "#prepare-machine-session-agent #timeline #e-7")
      refute has_element?(lv, "#timeline #e-15")

      # Session 2's item is in the Timeline after the list.
      refute has_element?(lv, "#prepare-machine #timeline-after-list")
      assert has_element?(lv, "#timeline-after-list #e-15")
      refute has_element?(lv, "#timeline-after-list #e-7")
      assert has_element?(lv, "#prepare-machine-session-2-agent[data-state=skipped]")
    end

    test "a live session's items move from its Timeline to the one after the list when its wall fails",
         ctx do
      %{run: run} = claimed_run(ctx.scope)

      run =
        project!(run, [
          {1, "run.started", started_data(%{"wall" => "docker"})},
          {2, "run.step_started", %{"step" => 1, "name" => "join session 1", "kind" => "join"}},
          {3, "run.step_exited",
           %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {4, "session.started", session_started_data()},
          {5, "run.step_started", %{"step" => 2, "name" => "start the wall", "kind" => "wall"}},
          {6, "run.step_exited",
           %{"step" => 2, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {7, "runtime.started", %{"session" => 1, "session_id" => "session-0001"}},
          {8, "runtime.ended", %{"session" => 1, "reason" => "other"}},
          {9, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}},
          {10, "run.step_started", %{"step" => 3, "name" => "join session 2", "kind" => "join"}},
          {11, "run.step_exited",
           %{"step" => 3, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}}
        ])

      lv = open(ctx.conn, ctx.scope, run)
      refute has_element?(lv, "#timeline-2")
      # The reader is at the live end, so the items that arrive are inserted.
      render_hook(element(lv, "#live-end"), "live_end", %{"at_end" => true})

      # Session 2 starts and its wall starts: its item is in its Timeline.
      events_fixture(run, [
        {12, "session.started", session_started_data(%{"session" => 2})},
        {13, "run.step_started", %{"step" => 4, "name" => "start the wall", "kind" => "wall"}},
        {14, "runtime.notification", %{"session" => 2, "kind" => "idle"}}
      ])

      {:ok, _run} = Projector.project(run)
      send(lv.pid, :flush)
      assert has_element?(lv, "#prepare-machine-session-2-agent #timeline-2 #e-14")
      refute has_element?(lv, "#timeline-after-list")

      # The wall fails: session 2 never ran its agent, and its item moves after the list.
      events_fixture(run, [
        {15, "run.step_exited",
         %{"step" => 4, "state" => "failed", "exit_code" => 125, "duration_ms" => 100}}
      ])

      {:ok, _run} = Projector.project(run)
      send(lv.pid, :flush)
      refute has_element?(lv, "#timeline-2")
      refute has_element?(lv, "#timeline #e-14")

      after_list =
        lv |> element("#timeline-after-list") |> render() |> LazyHTML.from_fragment()

      assert after_list |> LazyHTML.query("#e-14") |> Enum.count() == 1
      assert has_element?(lv, "#prepare-machine-session-agent #timeline #e-7")
    end

    test "a pending run with no event shows the section in place of the wait", ctx do
      %{run: run} = claimed_run(ctx.scope)

      run =
        run
        |> Ecto.Changeset.change(unattached())
        |> Apiary.Repo.update!()

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-request")
      assert has_element?(lv, "#prepare-machine-start")
      refute has_element?(lv, "#prepare-machine-session")
    end

    test "a machine before `dispatched` ticks from the claim, and its start shows at once",
         ctx do
      %{dispatch: dispatch, registered: run} = claimed = claimed(ctx.scope)
      claimed_at = DateTime.to_iso8601(dispatch.claimed_at)

      queued_at =
        Apiary.Repo.get!(Apiary.Dispatches.DispatchRun, dispatch.dispatch_run_id).queued_at
        |> DateTime.to_iso8601()

      lv = open(ctx.conn, ctx.scope, run)

      row = lv |> element("#prepare-machine-start > summary") |> render()
      assert row =~ "Running"
      assert row =~ "q-prep-pulse"
      refute has_element?(lv, "#prepare-machine-start > summary .q-tc1 time")

      # A run still starting: Start the machine runs, open.
      assert has_element?(lv, "#prepare-machine-start[open][data-state='running']")

      assert has_element?(
               lv,
               ~s(#prepare-machine-start-clock[phx-hook="Ticker"][data-tick="duration"][data-since="#{claimed_at}"])
             )

      # The heading counts from the start of Queue the run.
      assert has_element?(
               lv,
               ~s(#prepare-machine-queue > summary .q-tc1 time[datetime="#{queued_at}"])
             )

      assert has_element?(lv, ~s(#prepare-machine-total[data-since="#{queued_at}"]))
      assert lv |> element(".q-prep-hd") |> render() =~ "so far"

      # Before `dispatched`, Request a machine has no time under Took.
      refute has_element?(lv, "#prepare-machine-request .q-tc2 .q-d")

      # `dispatched` is broadcast on the run's topic: the page's next flush shows it, with
      # no quiet tick.
      :ok = Dispatches.dispatched(claimed.key, dispatch.public_id, %{external: nil})
      send(lv.pid, :flush)
      assert has_element?(lv, "#prepare-machine-start > summary .q-tc1 time")
      assert lv |> element("#prepare-machine-start > summary") |> render() =~ "Running"

      dispatch = Apiary.Repo.get!(Dispatch, dispatch.id)

      assert has_element?(
               lv,
               ~s(#prepare-machine-start-clock[data-since="#{DateTime.to_iso8601(dispatch.dispatched_at)}"])
             )

      took = DateTime.diff(dispatch.dispatched_at, dispatch.claimed_at, :millisecond)

      assert lv |> element("#prepare-machine-request .q-tc2 .q-d") |> render() =~
               ApiaryWeb.RunComponents.format_duration_ms(took)

      # So is the redemption of the run's code: Start the machine ends, with its time, and
      # no clock.
      redeem!(claimed)
      send(lv.pid, :flush)
      refute lv |> element("#prepare-machine-start > summary") |> render() =~ "Running"

      assert has_element?(
               lv,
               "#prepare-machine-start[data-state='succeeded'] > summary .q-tc2 .q-d"
             )

      refute has_element?(lv, "#prepare-machine-start-clock")
    end

    test "the quiet tick reads the machine's start on the Timeline tab alone", ctx do
      %{dispatch: dispatch, registered: run} = claimed(ctx.scope)
      path = ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/runs/#{run.number}"
      {:ok, lv, _html} = live(ctx.conn, path <> "/terminal")

      dispatched_quietly!(dispatch)
      send(lv.pid, :quiet_tick)
      render_patch(lv, path)
      refute has_element?(lv, "#prepare-machine-start > summary .q-tc1 time")

      send(lv.pid, :quiet_tick)
      assert has_element?(lv, "#prepare-machine-start > summary .q-tc1 time")
    end

    test "the quiet tick's note above the timeline is of the run it read", ctx do
      %{dispatch: dispatch, registered: run} = claimed(ctx.scope)
      lv = open(ctx.conn, ctx.scope, run)
      assert has_element?(lv, "#prepare-machine-start")

      # The run's row changes with no broadcast: the tick reads it with the machine's start.
      dispatched_quietly!(dispatch)
      run |> Ecto.Changeset.change(state: "running") |> Apiary.Repo.update!()
      send(lv.pid, :quiet_tick)

      html = render(lv)
      assert html =~ "q-run-tl"
      refute html =~ "first event has not arrived"
    end

    test "a running step pulses, Prepare the machine ticks from its start, and the heading counts so far",
         ctx do
      %{run: run} = claimed_run(ctx.scope)
      started = DateTime.utc_now()

      run =
        project!(run, [
          {1, "run.started", started_data()},
          {2, "run.step_started",
           %{"step" => 1, "name" => "fetch git.example.com/acme/shop", "kind" => "fetch"},
           time: started}
        ])

      lv = open(ctx.conn, ctx.scope, run)
      row = lv |> element("#prepare-machine-step-1 summary") |> render()

      assert row =~ "Running"
      assert row =~ "q-prep-pulse"
      # A step inside a step shows no time: the clock is Prepare the machine's.
      refute has_element?(lv, "#prepare-machine-step-1-clock")

      assert has_element?(lv, "#prepare-machine-prepare-clock[data-tick='duration']")
      assert has_element?(lv, "#prepare-machine-total[data-tick='duration']")

      # A step's exit reaches the page as an event: no pulse, no clock.
      events_fixture(run, [
        {3, "run.step_exited",
         %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 72_000}}
      ])

      {:ok, _run} = Projector.project(run)
      send(lv.pid, :flush)
      row = lv |> element("#prepare-machine-step-1 summary") |> render()
      assert has_element?(lv, "#prepare-machine-step-1[data-state='succeeded']")
      refute row =~ "q-prep-pulse"
      refute has_element?(lv, "#prepare-machine-prepare-clock")
    end

    test "a lost run's step stays running, with no clock and no pulse", ctx do
      %{run: run} = claimed_run(ctx.scope)

      run =
        project!(run, [
          {1, "run.started", started_data()},
          {2, "run.step_started",
           %{"step" => 1, "name" => "fetch git.example.com/acme/shop", "kind" => "fetch"}}
        ])

      run = run |> Ecto.Changeset.change(state: "lost") |> Apiary.Repo.update!()
      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-step-1[data-state='running']")
      refute lv |> element("#prepare-machine-step-1 summary") |> render() =~ "q-prep-pulse"
      refute has_element?(lv, "#prepare-machine time[data-tick]")
    end

    test "nothing ticks once the run has ended, a step left open included", ctx do
      %{run: run} = claimed_run(ctx.scope)

      run =
        project!(run, [
          {1, "run.started", started_data()},
          {2, "run.step_started",
           %{"step" => 1, "name" => "fetch git.example.com/acme/shop", "kind" => "fetch"}},
          {3, "run.step_started", %{"step" => 2, "name" => "join session 1", "kind" => "join"}},
          {4, "run.step_exited",
           %{"step" => 2, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 48_000}},
          {5, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
        ])

      lv = open(ctx.conn, ctx.scope, run)

      # The run's exit closes a step without an exit as cancelled.
      assert has_element?(lv, "#prepare-machine-step-1[data-state='cancelled']")
      refute lv |> element("#prepare-machine-step-1 summary") |> render() =~ "Running"
      refute has_element?(lv, "#prepare-machine-step-1-clock")
      refute has_element?(lv, "#prepare-machine time[data-tick]")

      assert has_element?(
               lv,
               "#prepare-machine-session-prepare #prepare-machine-step-2[data-state='succeeded']"
             )
    end

    test "a live run between two steps: no row ticks, and the heading counts up", ctx do
      %{run: run, dispatch: dispatch} = claimed_run(ctx.scope)
      exited = DateTime.add(dispatch.claimed_at, 90, :second)

      run =
        project!(run, [
          {1, "run.started", started_data()},
          {2, "run.step_started",
           %{"step" => 1, "name" => "fetch git.example.com/acme/shop", "kind" => "fetch"},
           time: DateTime.utc_now()},
          {3, "run.step_exited",
           %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000},
           time: exited}
        ])

      lv = open(ctx.conn, ctx.scope, run)
      refute has_element?(lv, "#prepare-machine .q-prep-steps time[data-tick]")

      # The heading counts up while the run is alive.
      assert has_element?(lv, "#prepare-machine-total[data-tick='duration']")
      assert lv |> element(".q-prep-hd") |> render() =~ "so far"

      # Once the session's join starts, its Agent session ticks.
      events_fixture(run, [
        {4, "run.step_started", %{"step" => 2, "name" => "join session 1", "kind" => "join"},
         time: DateTime.add(exited, 1, :second)}
      ])

      {:ok, _run} = Projector.project(run)
      send(lv.pid, :flush)
      assert has_element?(lv, "#prepare-machine-session-clock[data-tick='duration']")
      refute has_element?(lv, "#prepare-machine-step-2-clock")
      assert has_element?(lv, "#prepare-machine-total[data-tick='duration']")
    end

    test "a run with no dispatch and no step has no section", ctx do
      run =
        ctx.scope
        |> run_fixture(%{state: "running"})
        |> project!([{1, "run.started", started_data()}])

      lv = open(ctx.conn, ctx.scope, run)
      refute has_element?(lv, "#prepare-machine")
    end
  end

  describe "the note above the timeline" do
    setup :register_and_log_in_user

    defp limits_text(lv) do
      lv
      |> element(".q-limits")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")
    end

    test "a walled run that stopped at a step before its session: no note, no wall note",
         ctx do
      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          {1, "run.started", started_data(%{"wall" => "docker"})},
          {2, "run.step_started",
           %{"step" => 1, "name" => "fetch git.example.com/acme/shop", "kind" => "fetch"}},
          {3, "run.step_exited",
           %{"step" => 1, "state" => "failed", "exit_code" => 128, "duration_ms" => 100}},
          {4, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
        ])

      lv = open(ctx.conn, ctx.scope, run)

      refute has_element?(lv, ".q-limits")
    end

    test "a released run: no note, its row Start the machine states the cause", ctx do
      pool = pool_fixture(ctx.scope, name: "build-pool")
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      _gateway = gateway_for!(ctx.scope, pool)

      {:ok, _queued} =
        Apiary.Repo.transact(fn ->
          Dispatches.queue(Apiary.WorkItemsFixtures.work_item_fixture(ctx.scope), 1)
        end)

      {:ok, %{dispatch: dispatch, registered: run}} =
        Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now())

      :ok = Dispatches.release(key, dispatch.public_id, %{reason: "No capacity in the region."})
      lv = open(ctx.conn, ctx.scope, run)

      refute has_element?(lv, ".q-limits")
      assert has_element?(lv, "#prepare-machine-start[data-state=failed] #prepare-machine-cause")
    end

    test "a walled run whose session never started has no wall note", ctx do
      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          {1, "run.started", started_data(%{"wall" => "docker"})},
          {2, "run.exited", %{"state" => "cancelled", "exit_code" => -1, "duration_ms" => 1000}}
        ])

      lv = open(ctx.conn, ctx.scope, run)
      refute render(lv) =~ "virtual machine"
    end

    test "a walled run whose session started and sent no session event: the wall note",
         ctx do
      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          {1, "run.started", started_data(%{"wall" => "docker"})},
          {2, "session.started", session_started_data()},
          {3, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      lv = open(ctx.conn, ctx.scope, run)

      assert limits_text(lv) ==
               "This run's session events could not be recorded: the wall it ran behind runs " <>
                 "inside a virtual machine. The run has a terminal and connections, and no " <>
                 "session timeline."
    end
  end

  describe "the note on a session's runtime" do
    setup :register_and_log_in_user

    @runtime_note "Only Claude Code sends session events. This session ran qory: its output " <>
                    "is under Terminal, and its connections under Network access."

    defp note_text(lv, selector) do
      lv
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")
    end

    defp note_count(lv),
      do:
        lv |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(".q-limits") |> Enum.count()

    # Agent session `n`, from the sequence `seq`, on `runtime`: its join, its start, its
    # wall, a prompt for Claude Code, whose hooks send it unless `hooks` is false, and its
    # exit. Ten sequences.
    defp agent_session(seq, n, runtime, hooks \\ true) do
      step = 2 * n - 1

      prompt =
        if runtime == "claude" and hooks,
          do: [
            {seq + 5, "runtime.prompt_submitted",
             %{"session" => n, "session_id" => "s#{n}", "prompt" => "fix the build"}}
          ],
          else: []

      [
        {seq, "run.step_started",
         %{"step" => step, "name" => "join session #{n}", "kind" => "join"}},
        {seq + 1, "run.step_exited",
         %{"step" => step, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
        {seq + 2, "session.started",
         session_started_data(%{"session" => n, "runtime" => runtime, "command" => runtime})},
        {seq + 3, "run.step_started",
         %{"step" => step + 1, "name" => "start the wall", "kind" => "wall"}},
        {seq + 4, "run.step_exited",
         %{"step" => step + 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}}
      ] ++
        prompt ++
        [{seq + 6, "session.exited", %{"session" => n, "state" => "succeeded", "exit_code" => 0}}]
    end

    # A run of agent sessions on `runtimes`, in order. `opts`: `wall`, the run's wall, none
    # by default; `hooks`, false for Claude Code sessions whose hooks sent nothing.
    defp sessions_run(scope, runtimes, opts \\ []) do
      sessions =
        for {runtime, n} <- Enum.with_index(runtimes, 1),
            event <- agent_session(10 * n, n, runtime, Keyword.get(opts, :hooks, true)),
            do: event

      started =
        case Keyword.get(opts, :wall) do
          nil -> started_data()
          wall -> started_data(%{"wall" => wall})
        end

      exited =
        {10 * length(runtimes) + 10, "run.exited",
         %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}

      scope
      |> run_fixture()
      |> project!([{1, "run.started", started}] ++ sessions ++ [exited])
    end

    @wall_note "This run's session events could not be recorded: the wall it ran behind " <>
                 "runs inside a virtual machine. The run has a terminal and connections, and " <>
                 "no session timeline."

    # Whether the text `first` comes before the text `second` in the page's HTML.
    defp before?(lv, first, second) do
      html = render(lv)
      {first_at, _} = :binary.match(html, first)
      {second_at, _} = :binary.match(html, second)
      first_at < second_at
    end

    test "a Claude Code session behind a wall that sent no hook events: the wall note in its Run the agent",
         ctx do
      lv =
        open(
          ctx.conn,
          ctx.scope,
          sessions_run(ctx.scope, ["claude"], wall: "docker", hooks: false)
        )

      assert note_text(lv, "#prepare-machine-session-agent .q-limits") == @wall_note
      refute has_element?(lv, "#run-timeline > .q-limits")
      assert note_count(lv) == 1

      agent = lv |> element("#prepare-machine-session-agent") |> render()
      {note_at, _} = :binary.match(agent, "q-limits")
      {timeline_at, _} = :binary.match(agent, ~s(id="timeline"))
      assert note_at < timeline_at
    end

    test "a Claude Code session with no wall whose hooks sent nothing: the hooks note in its Run the agent",
         ctx do
      lv = open(ctx.conn, ctx.scope, sessions_run(ctx.scope, ["claude"], hooks: false))

      assert note_text(lv, "#prepare-machine-session-agent .q-limits") =~
               "No session events arrived."

      refute has_element?(lv, "#run-timeline > .q-limits")
      assert note_count(lv) == 1
    end

    test "sessions on claude and codex behind a wall: each note in its session's Run the agent",
         ctx do
      run = sessions_run(ctx.scope, ["claude", "codex"], wall: "docker", hooks: false)
      lv = open(ctx.conn, ctx.scope, run)

      assert note_text(lv, "#prepare-machine-session-agent .q-limits") == @wall_note

      assert note_text(lv, "#prepare-machine-session-2-agent .q-limits") ==
               String.replace(@runtime_note, "qory", "codex")

      refute has_element?(lv, "#run-timeline > .q-limits")
      assert note_count(lv) == 2
    end

    test "two Claude Code sessions behind a wall: each has the wall note", ctx do
      run = sessions_run(ctx.scope, ["claude", "claude"], wall: "docker", hooks: false)
      lv = open(ctx.conn, ctx.scope, run)

      assert note_text(lv, "#prepare-machine-session-agent .q-limits") == @wall_note
      assert note_text(lv, "#prepare-machine-session-2-agent .q-limits") == @wall_note
      assert note_count(lv) == 2
    end

    test "a run whose session ran no agent: the runtime note after the list, above the Timeline",
         ctx do
      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          {1, "run.started", started_data()},
          {2, "run.step_started",
           %{"step" => 1, "name" => "fetch git.example.com/acme/shop", "kind" => "fetch"}},
          {3, "run.step_exited",
           %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {4, "session.started",
           session_started_data(%{"runtime" => "codex", "command" => "codex", "bare" => true})},
          {5, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}},
          {6, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      lv = open(ctx.conn, ctx.scope, run)

      assert note_text(lv, "#run-timeline > .q-limits") ==
               String.replace(@runtime_note, "qory", "codex")

      assert note_count(lv) == 1
      refute has_element?(lv, "#prepare-machine .q-limits")
      assert before?(lv, ~s(id="prepare-machine"), "q-limits")
      assert before?(lv, "q-limits", ~s(id="timeline"))
    end

    test "with no Run list, sessions on claude and codex: both notes above the Timeline", ctx do
      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}},
          {4, "session.started",
           session_started_data(%{"session" => 2, "runtime" => "codex", "command" => "codex"})},
          {5, "session.exited", %{"session" => 2, "state" => "succeeded", "exit_code" => 0}},
          {6, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      lv = open(ctx.conn, ctx.scope, run)

      refute has_element?(lv, "#prepare-machine")
      assert note_count(lv) == 2
      assert render(lv) =~ "No session events arrived."
      assert has_element?(lv, ".q-limits code.q-rule", "codex")
      assert before?(lv, "q-limits", ~s(id="timeline"))
    end

    test "a session on another runtime: the note is in its Run the agent, above its Timeline, and none is above the steps",
         ctx do
      lv = open(ctx.conn, ctx.scope, sessions_run(ctx.scope, ["qory"]))

      assert note_text(lv, "#prepare-machine-session-agent .q-limits") == @runtime_note
      assert has_element?(lv, "#prepare-machine-session-agent .q-limits code.q-rule", "qory")
      refute has_element?(lv, "#run-timeline > .q-limits")
      assert note_count(lv) == 1

      agent = lv |> element("#prepare-machine-session-agent") |> render()
      {note_at, _} = :binary.match(agent, "q-limits")
      {timeline_at, _} = :binary.match(agent, ~s(id="timeline"))
      assert note_at < timeline_at
    end

    test "for a reader without the Terminal, the note in Run the agent leaves the Terminal out",
         ctx do
      run = sessions_run(ctx.scope, ["qory"])
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)

      :ok = Apiary.EditionStubs.HidesNamed.put([:"observability.terminal"])
      lv = open(ctx.conn, ctx.scope, run)

      assert note_text(lv, "#prepare-machine-session-agent .q-limits") ==
               "Only Claude Code sends session events. This session ran qory: its " <>
                 "connections are under Network access."

      :ok = Apiary.EditionStubs.HidesNamed.put([])
      lv = open(ctx.conn, ctx.scope, run)
      assert note_text(lv, "#prepare-machine-session-agent .q-limits") == @runtime_note
    end

    test "on a live run, a session on another runtime that starts gets the note in its Run the agent",
         ctx do
      %{run: run} = claimed_run(ctx.scope)

      run =
        project!(run, [
          {1, "run.started", started_data()},
          {2, "run.step_started", %{"step" => 1, "name" => "join session 1", "kind" => "join"}},
          {3, "run.step_exited",
           %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}}
        ])

      lv = open(ctx.conn, ctx.scope, run)
      assert note_count(lv) == 0

      events_fixture(run, [
        {4, "session.started",
         session_started_data(%{"session" => 1, "runtime" => "qory", "command" => "qory"})}
      ])

      {:ok, _run} = Projector.project(run)
      send(lv.pid, :flush)

      assert note_text(lv, "#prepare-machine-session-agent .q-limits") == @runtime_note
      refute has_element?(lv, "#run-timeline > .q-limits")
      assert note_count(lv) == 1
    end

    test "a Claude Code session has no note", ctx do
      lv = open(ctx.conn, ctx.scope, sessions_run(ctx.scope, ["claude"]))

      assert has_element?(lv, "#prepare-machine-session-agent #timeline")
      assert note_count(lv) == 0
      refute render(lv) =~ "Only Claude Code sends session events."
    end

    for runtimes <- [["qory", "claude"], ["claude", "qory"]] do
      test "sessions on #{Enum.join(runtimes, " and ")}: the note is in the qory session's Run the agent alone",
           ctx do
        runtimes = unquote(runtimes)
        lv = open(ctx.conn, ctx.scope, sessions_run(ctx.scope, runtimes))

        [qory, claude] =
          if runtimes == ["qory", "claude"],
            do: ["#prepare-machine-session-agent", "#prepare-machine-session-2-agent"],
            else: ["#prepare-machine-session-2-agent", "#prepare-machine-session-agent"]

        assert note_text(lv, "#{qory} .q-limits") == @runtime_note
        refute has_element?(lv, "#{claude} .q-limits")
        assert note_count(lv) == 1
      end
    end

    @tag needs: [:factory, :registry]
    test "a prebuild on another runtime: the note is in Build the image", ctx do
      pool = pool_fixture(ctx.scope, name: "build-pool")
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      _gateway = gateway_for!(ctx.scope, pool)
      %{run: run} = prebuild_handed_over!(ctx.scope, key)

      run =
        project!(run, [
          {1, "run.started", started_data()},
          {2, "run.step_started", %{"step" => 1, "name" => "join session 1", "kind" => "join"}},
          {3, "run.step_exited",
           %{"step" => 1, "state" => "succeeded", "exit_code" => -1, "duration_ms" => 100}},
          {4, "session.started",
           session_started_data(%{"runtime" => "qory", "command" => "qory", "bare" => true})},
          {5, "run.step_started", %{"step" => 2, "name" => "start the wall", "kind" => "wall"}},
          {6, "run.step_exited",
           %{"step" => 2, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {7, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}},
          {8, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      lv = open(ctx.conn, ctx.scope, run)

      assert note_text(lv, "#prepare-machine-build .q-limits") == @runtime_note
      assert has_element?(lv, "#prepare-machine-build #timeline")
      refute has_element?(lv, "#run-timeline > .q-limits")
      assert note_count(lv) == 1
    end
  end

  describe "for an instance admin" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    # The machine logs' retention, as `MACHINE_LOG_RETENTION_DAYS` sets it.
    defp put_retention_days(days) do
      before = Application.fetch_env(:apiary, :machine_log_retention_days)
      Application.put_env(:apiary, :machine_log_retention_days, days)

      on_exit(fn ->
        case before do
          {:ok, value} -> Application.put_env(:apiary, :machine_log_retention_days, value)
          :error -> Application.delete_env(:apiary, :machine_log_retention_days)
        end
      end)
    end

    # The dispatch, claimed `hours` hours ago.
    defp claimed!(dispatch, hours) do
      at = DateTime.add(DateTime.utc_now(), -hours * 3_600, :second)

      {1, _} =
        Apiary.Repo.update_all(
          from(d in Apiary.Dispatches.Dispatch, where: d.id == ^dispatch.id),
          set: [claimed_at: at]
        )
    end

    setup :register_and_log_in_user

    test "a run on the Qory Pool shows every row of the pool, and Start the machine has Started as and the machine log",
         ctx do
      %{run: run, dispatch: dispatch} =
        pool_run(ctx, instance_pool_fixture(%{name: "qory-pool"}))

      vendor_type!(dispatch, "example-type")
      lv = open(ctx.conn, ctx.scope, run)

      assert_pool_rows(lv)

      assert lv |> element("#prepare-machine-start #prepare-machine-started-as") |> render() =~
               "example-type"

      assert has_element?(lv, "#prepare-machine-start #prepare-machine-machine-log")
    end

    test "Start the machine shows the machine log", ctx do
      %{run: run, dispatch: dispatch, key: key} = claimed_run(ctx.scope)
      run = project!(run, steps(false))

      :ok =
        Dispatches.upload_machine_log(key, dispatch.public_id, %{
          log: @machine_log,
          truncated: false
        })

      lv = open(ctx.conn, ctx.scope, run)

      log = lv |> element("#prepare-machine-start #prepare-machine-machine-log") |> render()

      assert log =~ "Machine log (instance admins)"
      refute log =~ @admin_only

      # Each line has its number and no time.
      assert has_element?(lv, "#prepare-machine-machine-log-lines .q-log-n", "1")

      assert has_element?(
               lv,
               "#prepare-machine-machine-log-lines .q-log-x",
               "qory-machine-start: Docker started"
             )

      refute has_element?(lv, "#prepare-machine-machine-log-lines .q-log-t")
    end

    test "Start the machine shows the vendor's machine type above the machine log", ctx do
      %{run: run, dispatch: dispatch} = claimed_run(ctx.scope)
      vendor_type!(dispatch, "example-type")
      run = project!(run, steps(false))
      lv = open(ctx.conn, ctx.scope, run)

      started_as =
        lv |> element("#prepare-machine-start #prepare-machine-started-as") |> render()

      assert started_as =~ "Started as (instance admins)"
      assert started_as =~ "example-type"

      html = lv |> element("#prepare-machine-start") |> render()
      {at, _length} = :binary.match(html, "prepare-machine-started-as")
      {log_at, _length} = :binary.match(html, "prepare-machine-machine-log")
      assert at < log_at
    end

    test "with no machine type reported, Start the machine has no Started as line", ctx do
      %{run: run} = claimed_run(ctx.scope)
      run = project!(run, steps(false))
      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-machine-log")
      refute has_element?(lv, "#prepare-machine-started-as")
      refute render(lv) =~ "Started as"
    end

    test "before the machine log arrives, says so", ctx do
      %{run: run} = claimed_run(ctx.scope)
      run = project!(run, steps(false))
      lv = open(ctx.conn, ctx.scope, run)

      assert lv |> element("#prepare-machine-machine-log") |> render() =~
               "No machine log has arrived."
    end

    test "with no machine log, shows it may still arrive until the least retention passed",
         ctx do
      put_retention_days(14)
      %{run: run, dispatch: dispatch} = claimed_run(ctx.scope)
      run = project!(run, steps(false))

      claimed!(dispatch, 23)

      log =
        ctx.conn |> open(ctx.scope, run) |> element("#prepare-machine-machine-log") |> render()

      assert log =~ "No machine log has arrived."

      claimed!(dispatch, 25)

      log =
        ctx.conn |> open(ctx.scope, run) |> element("#prepare-machine-machine-log") |> render()

      assert log =~ "Machine logs are kept for 14 days. This machine has none."
      refute log =~ "No machine log has arrived."
    end

    # A prune under a 1-day setting deleted the log on day 2; the setting is 30 days on
    # day 5.
    test "with no machine log after the setting was raised, never shows it may arrive", ctx do
      put_retention_days(30)
      %{run: run, dispatch: dispatch} = claimed_run(ctx.scope)
      run = project!(run, steps(false))
      claimed!(dispatch, 5 * 24)

      log =
        ctx.conn |> open(ctx.scope, run) |> element("#prepare-machine-machine-log") |> render()

      assert log =~ "Machine logs are kept for 30 days. This machine has none."
      refute log =~ "No machine log has arrived."
    end
  end

  describe "a prebuild whose image was not saved" do
    setup :register_and_log_in_user

    # A report that fails its check is logged as a warning (`Apiary.Dispatches.Built`).
    @describetag :capture_log
    @describetag needs: [:factory, :registry]

    @digest String.duplicate("4c1e", 16)

    # A prebuild on a pool of the workspace whose build session exited 0, with `report`
    # as its `dev.qory.run.built`, if any, and its run's exit.
    defp prebuild!(ctx, report, exited) do
      pool = pool_fixture(ctx.scope, name: "build-pool")
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      _gateway = gateway_for!(ctx.scope, pool)
      %{run: run} = prebuild_handed_over!(ctx.scope, key)

      report =
        case report do
          nil -> []
          report -> [{8, "run.built", report.(run)}]
        end

      project!(
        run,
        [
          {1, "run.started", started_data()},
          {2, "run.step_started", %{"step" => 1, "name" => "join session 1", "kind" => "join"}},
          {3, "run.step_exited",
           %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {4, "session.started",
           session_started_data(%{"runtime" => "qory", "command" => "qory", "bare" => true})},
          {5, "run.step_started", %{"step" => 2, "name" => "start the wall", "kind" => "wall"}},
          {6, "run.step_exited",
           %{"step" => 2, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
          {7, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}}
        ] ++ report ++ [{9, "run.exited", Map.put(exited, "duration_ms", 1000)}]
      )
    end

    test "a build that sent no image: Save the outputs failed, and How it ended", ctx do
      run = prebuild!(ctx, nil, %{"state" => "failed", "exit_code" => -1})
      lv = open(ctx.conn, ctx.scope, run)
      what = "The image was not saved: the build finished, but no image arrived."

      assert has_element?(lv, "#prepare-machine-build[data-state=succeeded]")
      assert has_element?(lv, "#prepare-machine-outputs[data-state=failed]")

      cause = lv |> element("#prepare-machine-outputs-cause") |> render()

      assert cause |> LazyHTML.from_fragment() |> LazyHTML.text() ==
               "#{what} Read the cause in the log of build-pool on its host."

      assert has_element?(lv, "#prepare-machine-outputs-cause b", "build-pool")

      assert lv |> element("#run-why .q-run-why-whole") |> render() =~ ">#{what}</span>"
      refute has_element?(lv, "#run-why-jump")
    end

    test "a completed run whose report is away from its destination: the line in How it ended",
         ctx do
      run =
        prebuild!(
          ctx,
          &%{
            "image" => sent(&1, "image_destination") <> "-x@sha256:" <> @digest,
            "size" => 1_048_576,
            "commit" => String.duplicate("a1", 20),
            "environment_ref" => "env-1"
          },
          %{"state" => "succeeded", "exit_code" => 0}
        )

      destination = sent(run, "image_destination")
      lv = open(ctx.conn, ctx.scope, run)

      what =
        "The image was not saved: the run reported it at #{destination}-x, but this run " <>
          "saves images only under #{destination}."

      assert has_element?(lv, "#run-state", "Completed")
      assert has_element?(lv, "#prepare-machine-outputs[data-state=failed]")
      refute render(lv) =~ "Outputs saved"

      cause = lv |> element("#prepare-machine-outputs-cause") |> render()
      assert cause =~ "<code"
      assert cause |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim() == what

      assert lv |> element("#run-why .q-run-why-whole") |> render() =~ ">#{what}</span>"
    end

    test "a prebuild lost or cancelled after its build: How it ended has the image line only with no other line",
         ctx do
      lost =
        "The image was not saved: the build finished, but the run was lost before an " <>
          "image arrived."

      run = prebuild!(ctx, nil, %{"state" => "cancelled", "exit_code" => -1})
      lv = open(ctx.conn, ctx.scope, run)
      assert has_element?(lv, "#prepare-machine-outputs[data-state=failed]")

      assert lv |> element("#run-why .q-run-why-whole") |> render() =~
               ">The image was not saved: the build finished, but the run was cancelled " <>
                 "before an image arrived.</span>"

      lost_at = DateTime.add(run.exited_at, 30, :second)

      {1, _rows} =
        Apiary.Repo.update_all(from(r in Apiary.Runs.Run, where: r.id == ^run.id),
          set: [state: "lost", lost_at: lost_at]
        )

      lv = open(ctx.conn, ctx.scope, run)
      assert lv |> element("#run-why .q-run-why-whole") |> render() =~ ">#{lost}</span>"

      # A lost run with a reason beside its state keeps that line alone.
      {1, _rows} =
        Apiary.Repo.update_all(from(r in Apiary.Runs.Run, where: r.id == ^run.id),
          set: [reason: "session_lost"]
        )

      lv = open(ctx.conn, ctx.scope, run)
      assert has_element?(lv, "#run-reason", "stopped responding")
      refute has_element?(lv, "#run-why")
      assert lv |> element("#prepare-machine-outputs-cause") |> render() =~ lost
    end
  end
end
