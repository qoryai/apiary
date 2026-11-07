defmodule ApiaryWeb.RunLive.ShowPreparationTest do
  @moduledoc """
  The Run list of a run's Timeline (`ApiaryWeb.PreparationComponents`): its rows in
  the order the steps ran, Start machine in Machine started, the steps in Prepare,
  a step's log lines with their numbers and times, a failed or running row open, a failed
  row with its cause line, and the machine log under Start machine for an instance admin
  alone. Not async: the instance admin's tests hide the instance's organisation and set
  the machine logs' folder.
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

      section = lv |> element("#prepare-machine") |> render()
      assert has_element?(lv, "#prepare-machine-h", "Run")

      rows =
        section
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".q-prep-name")
        |> Enum.map(&LazyHTML.text/1)

      assert rows == [
               "Queued",
               "Machine requested",
               "Machine started",
               "Start machine",
               "Prepare",
               "Clone repository",
               "Session started"
             ]

      assert has_element?(lv, "#prepare-machine-started #prepare-machine-start-machine")
      assert has_element?(lv, "#prepare-machine-prepare #prepare-machine-step-1")
      # The run goes on: Session started is open, with the Timeline inside it.
      assert has_element?(lv, "#prepare-machine-session[open] #timeline")
      refute has_element?(lv, "#prepare-machine details[open]:not(#prepare-machine-session)")
      refute has_element?(lv, "#prepare-machine-machine-log")
      refute render(lv) =~ @admin_only
      assert lv |> element("#prepare-machine-requested") |> render() =~ "build-pool"
      assert lv |> element("#prepare-machine-requested") |> render() =~ "pool default"

      assert lv |> element("#prepare-machine-step-1-output .q-log-x") |> render() =~
               "Cloning into &#39;shop&#39;..."

      refute has_element?(lv, "#prepare-machine-cause")
    end

    test "a run of a machine type: Machine requested has its spec, Details its name, the peak the type's memory",
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
      requested = lv |> element("#prepare-machine-requested") |> render()
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
      assert lv |> element("#prepare-machine-requested") |> render() =~ "pool default"
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

    test "Prepare groups the steps, in order, with their labels",
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
               "Clone repository",
               "Compose the harness",
               "Set up dev container",
               "Start agent"
             ]

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
      refute has_element?(lv, "#prepare-machine-start-machine[open]")
      assert lv |> element("#prepare-machine-step-2 > summary") |> render() =~ "Running"
      assert has_element?(lv, "#prepare-machine-prepare-clock[data-tick='duration']")
      refute has_element?(lv, "#prepare-machine-step-2-output-lines .q-log-n", "2")

      # A line arrives: the next flush shows it, numbered.
      events_fixture(run, [{6, "run.log", step_log_data(2, "added 1184 packages\n")}])
      {:ok, _run} = Projector.project(run)
      send(lv.pid, :flush)
      assert has_element?(lv, "#prepare-machine-step-2-output-lines .q-log-n", "2")
      assert has_element?(lv, "#prepare-machine-step-2-output-lines .q-log-x", "added 1184")

      # The step ends and the next starts: it is a row of the group, open while it runs.
      events_fixture(run, [
        {7, "run.step_exited",
         %{"step" => 2, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 48_000}},
        {8, "run.step_started", %{"step" => 3, "name" => "join session 1", "kind" => "join"}}
      ])

      {:ok, _run} = Projector.project(run)
      send(lv.pid, :flush)

      assert has_element?(
               lv,
               "#prepare-machine-prepare #prepare-machine-step-3[open]",
               "Start agent"
             )

      assert lv |> element("#prepare-machine-step-2 > summary") |> render() =~ "48 s"
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

    test "a machine step: its lines under Start machine, after create machine", ctx do
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
      lines = "#prepare-machine-start-machine #prepare-machine-start-machine-output-lines"

      # `has_element?/3` matches the text with its runs of spaces made one.
      assert has_element?(
               lv,
               "#{lines} .q-log-ln:nth-child(1) .q-log-x",
               "create machine 14.8 s"
             )

      assert has_element?(lv, "#{lines} .q-log-ln:nth-child(2) .q-log-x", "boot 14.8 s")
      assert has_element?(lv, "#{lines} .q-log-ln:nth-child(6) .q-log-x", "write run code 0.1 s")
      assert has_element?(lv, "#{lines} .q-log-ln:nth-child(6) .q-log-n", "6")
      assert has_element?(lv, "#prepare-machine-step-2", "Clone repository")
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

      # Session started has no duration: its second cell stays, so its time keeps its column.
      assert has_element?(lv, "#prepare-machine-session .q-t > .q-tc1 time")
      assert has_element?(lv, "#prepare-machine-session .q-t > .q-tc2")
      assert has_element?(lv, "#timeline .q-t > .q-t-at.q-tc1")
      assert has_element?(lv, "#timeline .q-t > .q-q.q-tc2")
    end

    test "a failed step is open, with its output and its cause line", ctx do
      %{run: run} = claimed_run(ctx.scope)
      run = project!(run, steps(true))
      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-step-1[open]")
      assert has_element?(lv, "#prepare-machine-prepare[open][data-state='failed']")
      refute has_element?(lv, "#prepare-machine-started[open]")
      refute has_element?(lv, "#prepare-machine-start-machine[open]")
      assert has_element?(lv, "#prepare-machine-step-1 #prepare-machine-step-1-output")

      assert lv |> element("#prepare-machine-step-1 #prepare-machine-cause") |> render() =~
               "Clone repository failed with exit code 128 (git.example.com/acme/shop). " <>
                 "An admin of " <>
                 "#{ctx.scope.workspace.name} reads the cause in the step&#39;s output."
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
               "Clone repository failed with exit code 128 (git.example.com/acme/shop). " <>
                 "The step&#39;s " <>
                 "output was deleted under the workspace&#39;s log retention, so the cause is " <>
                 "no longer shown."
    end

    test "a released run: Machine started is open with who fixes it, the header the cause",
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

      assert has_element?(lv, "#prepare-machine-started[open]")
      assert has_element?(lv, "#prepare-machine-start-machine[open]")
      refute has_element?(lv, "#prepare-machine-requested[open]")

      assert lv |> element("#prepare-machine-start-machine #prepare-machine-cause") |> render() =~
               ">An admin of #{ctx.scope.workspace.name} reads why in the log of build-pool on its host.</p>"

      assert render(lv) =~ "No machine was made: No capacity in the region."
      refute lv |> element("#prepare-machine") |> render() =~ "No machine was made"
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

    test "a stop on the Qory Pool links Contact support and has no line on a machine log",
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

      assert has_element?(
               lv,
               ~s(#prepare-machine a[href="https://help.example.com"]),
               "Contact support"
             )

      html = render(lv)
      assert html =~ "with run #{run.public_id}."
      refute has_element?(lv, "#prepare-machine-machine-log")
      refute html =~ "nstance admin"
    end

    test "a pending run with no event shows the section in place of the wait", ctx do
      %{run: run} = claimed_run(ctx.scope)

      run =
        run
        |> Ecto.Changeset.change(unattached())
        |> Apiary.Repo.update!()

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-requested")
      assert has_element?(lv, "#prepare-machine-started")
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

      row = lv |> element("#prepare-machine-started > summary") |> render()
      assert row =~ "Running"
      assert row =~ "q-prep-pulse"
      refute has_element?(lv, "#prepare-machine-started .q-tc1 time")

      # A run still starting: Machine started and Start machine run, both open.
      assert has_element?(lv, "#prepare-machine-started[open]")
      assert has_element?(lv, "#prepare-machine-start-machine[open][data-state='running']")
      assert lv |> element("#prepare-machine-start-machine > summary") |> render() =~ "Running"

      assert has_element?(
               lv,
               ~s(#prepare-machine-started-clock[phx-hook="Ticker"][data-tick="duration"][data-since="#{claimed_at}"])
             )

      # The heading counts from the start of Queued.
      assert has_element?(lv, ~s(#prepare-machine-queued .q-tc1 time[datetime="#{queued_at}"]))
      assert has_element?(lv, ~s(#prepare-machine-total[data-since="#{queued_at}"]))
      assert lv |> element(".q-prep-hd") |> render() =~ "so far"

      # Before `dispatched`, Machine requested has no time under Took.
      refute has_element?(lv, "#prepare-machine-requested .q-tc2 .q-d")

      # `dispatched` is broadcast on the run's topic: the page's next flush shows it, with
      # no quiet tick.
      :ok = Dispatches.dispatched(claimed.key, dispatch.public_id, %{external: nil})
      send(lv.pid, :flush)
      assert has_element?(lv, "#prepare-machine-started > summary .q-tc1 time")
      assert lv |> element("#prepare-machine-started > summary") |> render() =~ "Running"

      dispatch = Apiary.Repo.get!(Dispatch, dispatch.id)

      assert has_element?(
               lv,
               ~s(#prepare-machine-started-clock[data-since="#{DateTime.to_iso8601(dispatch.dispatched_at)}"])
             )

      took = DateTime.diff(dispatch.dispatched_at, dispatch.claimed_at, :millisecond)

      assert lv |> element("#prepare-machine-requested .q-tc2 .q-d") |> render() =~
               ApiaryWeb.RunComponents.format_duration_ms(took)

      # So is the redemption of the run's code: Start machine and Machine started end, with
      # their time, and no clock.
      redeem!(claimed)
      send(lv.pid, :flush)
      refute lv |> element("#prepare-machine-start-machine > summary") |> render() =~ "Running"
      refute lv |> element("#prepare-machine-started > summary") |> render() =~ "Running"

      assert has_element?(
               lv,
               "#prepare-machine-started[data-state='succeeded'] > summary .q-tc2 .q-d"
             )

      refute has_element?(lv, "#prepare-machine-started-clock")
      refute has_element?(lv, "#prepare-machine-start-machine-clock")
    end

    test "the quiet tick reads the machine's start on the Timeline tab alone", ctx do
      %{dispatch: dispatch, registered: run} = claimed(ctx.scope)
      path = ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/runs/#{run.number}"
      {:ok, lv, _html} = live(ctx.conn, path <> "/terminal")

      dispatched_quietly!(dispatch)
      send(lv.pid, :quiet_tick)
      render_patch(lv, path)
      refute has_element?(lv, "#prepare-machine-started .q-tc1 time")

      send(lv.pid, :quiet_tick)
      assert has_element?(lv, "#prepare-machine-started .q-tc1 time")
    end

    test "the quiet tick's note above the timeline is of the run it read", ctx do
      %{dispatch: dispatch, registered: run} = claimed(ctx.scope)
      lv = open(ctx.conn, ctx.scope, run)
      assert has_element?(lv, "#prepare-machine-started")

      # The run's row changes with no broadcast: the tick reads it with the machine's start.
      dispatched_quietly!(dispatch)
      run |> Ecto.Changeset.change(state: "running") |> Apiary.Repo.update!()
      send(lv.pid, :quiet_tick)

      html = render(lv)
      assert html =~ "q-run-tl"
      refute html =~ "first event has not arrived"
    end

    test "a running step ticks from its start, and the heading counts so far", ctx do
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
      assert has_element?(lv, "#prepare-machine-step-1-clock[data-tick='duration']")
      assert has_element?(lv, "#prepare-machine-total[data-tick='duration']")

      # A step's exit reaches the page as an event: its duration, no clock.
      events_fixture(run, [
        {3, "run.step_exited",
         %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 72_000}}
      ])

      {:ok, _run} = Projector.project(run)
      send(lv.pid, :flush)
      row = lv |> element("#prepare-machine-step-1 summary") |> render()
      assert row =~ "1 m 12 s"
      refute has_element?(lv, "#prepare-machine-step-1-clock")
      refute row =~ "q-prep-pulse"
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
      assert lv |> element("#prepare-machine-step-2 summary") |> render() =~ "48 s"
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

      # Once the next step starts, its row ticks.
      events_fixture(run, [
        {4, "run.step_started", %{"step" => 2, "name" => "join session 1", "kind" => "join"},
         time: DateTime.add(exited, 1, :second)}
      ])

      {:ok, _run} = Projector.project(run)
      send(lv.pid, :flush)
      assert has_element?(lv, "#prepare-machine-step-2-clock[data-tick='duration']")
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

    test "a walled run that stopped at a step before its session: the step, no wall note",
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

      assert limits_text(lv) ==
               "The run stopped before its session started, at the step Clone repository."
    end

    test "a released run: the step is Start machine", ctx do
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

      assert limits_text(lv) ==
               "The run stopped before its session started, at the step Start machine."
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

    test "Machine started shows the machine log", ctx do
      %{run: run, dispatch: dispatch, key: key} = claimed_run(ctx.scope)
      run = project!(run, steps(false))

      :ok =
        Dispatches.upload_machine_log(key, dispatch.public_id, %{
          log: @machine_log,
          truncated: false
        })

      lv = open(ctx.conn, ctx.scope, run)

      log =
        lv |> element("#prepare-machine-start-machine #prepare-machine-machine-log") |> render()

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

    test "Start machine shows the vendor's machine type above the machine log", ctx do
      %{run: run, dispatch: dispatch} = claimed_run(ctx.scope)
      vendor_type!(dispatch, "example-type")
      run = project!(run, steps(false))
      lv = open(ctx.conn, ctx.scope, run)

      started_as =
        lv |> element("#prepare-machine-start-machine #prepare-machine-started-as") |> render()

      assert started_as =~ "Started as (instance admins)"
      assert started_as =~ "example-type"

      html = lv |> element("#prepare-machine-start-machine") |> render()
      {at, _length} = :binary.match(html, "prepare-machine-started-as")
      {log_at, _length} = :binary.match(html, "prepare-machine-machine-log")
      assert at < log_at
    end

    test "with no machine type reported, Start machine has no Started as line", ctx do
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
end
