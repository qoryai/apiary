defmodule ApiaryWeb.RunLive.ShowPreparationTest do
  @moduledoc """
  The Prepare machine section of a run's Timeline (`ApiaryWeb.PreparationComponents`):
  its rows in the order the steps ran, a failed row open with its cause line, and the
  machine log for an instance admin alone. Not async: the instance admin's tests hide the
  instance's organisation and set the machine logs' folder.
  """
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Dispatches
  alias Apiary.Runs.Projector

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

  describe "for an instance admin" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
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
  end
end
