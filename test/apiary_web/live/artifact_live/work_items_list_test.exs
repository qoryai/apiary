defmodule ApiaryWeb.ArtifactLive.WorkItemsListTest do
  # The Work items list (`ApiaryWeb.WorkItemLive.Index`) listens on the workspace's work
  # items topic; a push sends its message on the work item's artifacts topic
  # (`Apiary.Artifacts.topic/1`), so the list page gets none and keeps running.
  use ApiaryWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  @moduletag :tmp_dir
  @moduletag needs: :workflow_model

  test "the Work items list survives an artifact push", %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    %{user: user, scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)
    %{dispatch_run: run} = explore_run_fixture(work_item)
    conn = log_in_user(build_conn(), user)

    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/work")
    Process.flag(:trap_exit, true)
    ref = Process.monitor(view.pid)

    {:ok, _v} =
      Apiary.Artifacts.push({:run, run}, work_item, "explainer", [
        %{filename: "a.md", binary: "# A"}
      ])

    receive do
      {:DOWN, ^ref, :process, _pid, reason} -> flunk("list page crashed: #{inspect(reason)}")
    after
      500 -> :ok
    end

    assert render(view) =~ "Work items"
  end
end
