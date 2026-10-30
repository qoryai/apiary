defmodule ApiaryWeb.RunLive.ShowPreparationTest do
  @moduledoc """
  The Prepare machine section of a run's Timeline (`ApiaryWeb.PreparationComponents`):
  its rows in the order the steps ran, a failed row open with its cause line, and the
  machine log for an instance admin alone. Not async: the instance admin's tests hide the
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

  alias Apiary.Dispatches
  alias Apiary.Runs.Projector
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
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}")

    lv
  end

  describe "for a member" do
    setup :register_and_log_in_user

    test "the rows in the order they ran, each closed, the machine log the admin's", ctx do
      %{run: run} = claimed_run(ctx.scope)
      run = project!(run, steps(false))
      lv = open(ctx.conn, ctx.scope, run)

      section = lv |> element("#prepare-machine") |> render()
      assert section =~ "Prepare machine"

      rows =
        section
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".q-prep-name, #prepare-machine-session .q-k")
        |> Enum.map(&LazyHTML.text/1)

      assert rows == [
               "Machine requested",
               "Machine started",
               "Fetch git.example.com/acme/shop",
               "Session started"
             ]

      refute has_element?(lv, "#prepare-machine details[open]")
      assert lv |> element("#prepare-machine-machine-log") |> render() =~ @admin_only
      assert lv |> element("#prepare-machine-requested") |> render() =~ "build-pool"
      assert lv |> element("#prepare-machine-requested") |> render() =~ "pool default"

      assert lv |> element("#prepare-machine-step-1-output pre") |> render() =~
               "Cloning into &#39;shop&#39;..."

      refute has_element?(lv, "#prepare-machine-cause")
    end

    test "a failed step is open, with its output and its cause line", ctx do
      %{run: run} = claimed_run(ctx.scope)
      run = project!(run, steps(true))
      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-step-1[open]")
      refute has_element?(lv, "#prepare-machine-started[open]")
      assert has_element?(lv, "#prepare-machine-step-1 #prepare-machine-step-1-output")

      assert lv |> element("#prepare-machine-step-1 #prepare-machine-cause") |> render() =~
               "Fetch git.example.com/acme/shop failed with exit code 128. An admin of " <>
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
               "Fetch git.example.com/acme/shop failed with exit code 128. The step&#39;s " <>
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

      {:ok, %{dispatch: dispatch, registered: run}} = Dispatches.claim(key, Dispatches.now())
      :ok = Dispatches.release(key, dispatch.public_id, %{reason: "No capacity in the region."})
      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-started[open]")
      refute has_element?(lv, "#prepare-machine-requested[open]")

      assert lv |> element("#prepare-machine-cause") |> render() =~
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

      {:ok, %{dispatch: dispatch, registered: run}} = Dispatches.claim(key, Dispatches.now())
      :ok = Dispatches.release(key, dispatch.public_id, %{reason: "Key #{run_key} refused."})
      run = Apiary.Repo.get!(Apiary.Runs.Run, run.id)

      # The Prepare machine section's cause and the header both have it filtered.
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
               "The run stopped before its session started, at the step Fetch git.example.com/acme/shop."
    end

    test "a released run: the step is Machine started", ctx do
      pool = pool_fixture(ctx.scope, name: "build-pool")
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      _gateway = gateway_for!(ctx.scope, pool)

      {:ok, _queued} =
        Apiary.Repo.transact(fn ->
          Dispatches.queue(Apiary.WorkItemsFixtures.work_item_fixture(ctx.scope), 1)
        end)

      {:ok, %{dispatch: dispatch, registered: run}} = Dispatches.claim(key, Dispatches.now())
      :ok = Dispatches.release(key, dispatch.public_id, %{reason: "No capacity in the region."})
      lv = open(ctx.conn, ctx.scope, run)

      assert limits_text(lv) ==
               "The run stopped before its session started, at the step Machine started."
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
      log = lv |> element("#prepare-machine-machine-log") |> render()

      assert log =~ "Machine log (instance admins)"
      assert log =~ "qory-machine-start: Docker started"
      refute log =~ @admin_only
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
