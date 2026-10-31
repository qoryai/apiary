defmodule ApiaryWeb.StagesLiveTest do
  @moduledoc """
  Workspace settings › Stages (`ApiaryWeb.StagesLive.Index`) and the Workflow page's link
  to it, against the temporary calls of `ApiaryWeb.StagesLive.Calls`: not found while the
  feature `workflow_model` is off; the canvas and the list of stages; adding, renaming,
  moving and removing a stage; a stage's sequence, loop, inputs, outputs and gate; the
  placement check; a save, a trial and the history; and a member's page, with no edit
  controls.

  Not async: the feature's switch is the application's environment until piece F adds
  the feature.
  """
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias ApiaryWeb.StagesLive.{Calls, Draft}

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup %{scope: scope} do
    Application.put_env(:apiary, :stages_stub_flag, true)
    on_exit(fn -> Application.delete_env(:apiary, :stages_stub_flag) end)
    %{path: workspace_path(scope, "/settings/stages")}
  end

  defp names(view) do
    view
    |> element("#stages-list ol")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("li span.font-medium")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#stages-list li")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "stage-row-", ""))
  end

  defp canvas_view(view) do
    [json] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#stages-canvas")
      |> LazyHTML.attribute("data-view")

    Jason.decode!(json)
  end

  describe "the feature" do
    test "off: Stages is not found, and the Workflow page keeps its workflow choice", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      Application.put_env(:apiary, :stages_stub_flag, false)
      assert_raise ApiaryWeb.Features.NotFound, fn -> live(conn, path) end

      {:ok, view, _html} = live(conn, workspace_path(scope, "/settings/workflow"))
      assert has_element?(view, "#workflow-form")
      refute has_element?(view, "#workflow-stages")
    end

    test "on: the Workflow page keeps the harness, drops the workflow choice and links to Stages",
         %{conn: conn, path: path, scope: scope} do
      {:ok, view, _html} = live(conn, workspace_path(scope, "/settings/workflow"))
      assert has_element?(view, "#workflow-harness")
      refute has_element?(view, "#workflow-form")
      refute has_element?(view, "#workflow-what")
      assert has_element?(view, ~s(#workflow-stages-link[href="#{path}"]))
    end
  end

  describe "an owner" do
    test "sees the software type's five stages, on the canvas and in the list", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "#settings-section-title", "Stages")
      assert names(view) == ~w(Explore Shape Build Verify Release)

      assert has_element?(
               view,
               ~s(#stages-canvas[phx-update="ignore"][data-script="/assets/js/canvas.js"])
             )

      canvas = canvas_view(view)
      assert canvas["editable"]
      assert canvas["selected"] == "st_explore"

      assert [explore | _] = canvas["stages"]

      assert explore == %{
               "id" => "st_explore",
               "name" => "Explore",
               "workflows" => ["explore-a-ticket"],
               "loop" => "Loop: at most 3 rounds",
               "gate" => "Gate: a member approves",
               "alerts" => []
             }

      assert has_element?(view, "#stage-panel-title", "Edit Explore")
      assert has_element?(view, "#stages-version", "Editing version 1, current.")
      assert has_element?(view, "#stages-check-clear")
      assert has_element?(view, "#stages-version-1", "The first version.")
    end

    test "adds a stage with a new id, renames, moves and removes it", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      view |> element("#stages-add") |> render_click()
      assert names(view) == ["Explore", "Shape", "Build", "Verify", "Release", "New stage"]
      id = List.last(ids(view))
      assert Apiary.PublicId.valid?("st", id)
      assert has_element?(view, "#stage-panel-title", "Edit New stage")
      assert has_element?(view, "#stages-dirty")

      view |> form("#stage-form", stage: %{name: "Demo"}) |> render_change()
      assert List.last(names(view)) == "Demo"
      assert List.last(ids(view)) == id

      view |> element(~s(button[aria-label="Move Demo earlier"])) |> render_click()
      assert names(view) == ~w(Explore Shape Build Verify Demo Release)

      render_hook(view, "reorder", %{"ids" => [id | List.delete(ids(view), id)]})
      assert names(view) == ~w(Demo Explore Shape Build Verify Release)

      # An order that is not the same stages changes nothing.
      render_hook(view, "reorder", %{"ids" => ["st_explore"]})
      assert names(view) == ~w(Demo Explore Shape Build Verify Release)

      view |> element(~s(button[aria-label="Remove Demo"])) |> render_click()
      assert names(view) == ~w(Explore Shape Build Verify Release)
      refute has_element?(view, "#stages-dirty")
    end

    test "edits a sequence: a workflow, a loop with its rounds, and a machine type", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      view |> element(~s(button[aria-label="Edit Build"])) |> render_click()

      view |> element("#stage-add-entry") |> render_click()
      view |> element("#stage-add-loop") |> render_click()

      view
      |> form("#stage-form",
        stage: %{sequence: %{"0" => %{machine: "large"}, "1" => %{rounds: "40"}}}
      )
      |> render_change()

      build = Enum.find(canvas_view(view)["stages"], &(&1["id"] == "st_build"))
      assert build["loop"] == "Loop: at most 10 rounds"
      assert has_element?(view, "#stage-entry-0-machine[value=large]")

      assert has_element?(
               view,
               "#stage-sequence",
               "Qory Apiary stores the machine type with each run of the workflow. It does not choose the machine that runs it."
             )

      view |> element(~s(#stage-loop-1 button[phx-click="remove_loop"])) |> render_click()
      refute has_element?(view, "#stage-loop-1")
      assert has_element?(view, "#stage-entry-1-workflow")
    end

    test "the placement check lists a workflow the harness does not declare and an input no earlier stage outputs",
         %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      view |> element(~s(button[aria-label="Edit Build"])) |> render_click()
      view |> element("#stage-add-entry") |> render_click()

      view
      |> form("#stage-form", stage: %{sequence: %{"0" => %{workflow: "capture-demo"}}})
      |> render_change()

      undeclared =
        "Build uses capture-demo, which the harness no longer declares. Add it to the harness, or choose another workflow for Build."

      assert has_element?(view, "#stage-panel [data-stage-alert]", undeclared)
      assert has_element?(view, ~s(#stages-check [data-problem="missing_workflow"]), undeclared)

      assert undeclared in Enum.find(canvas_view(view)["stages"], &(&1["id"] == "st_build"))[
               "alerts"
             ]

      view |> element("#stage-add-inputs") |> render_click()

      assert has_element?(
               view,
               ~s(#stages-check [data-problem="input_not_output"]),
               "Build needs acceptance-criteria as an input, and no stage before Build lists it as an output."
             )

      refute render(view) =~ "output_not_written"
    end

    test "the gate: none, any member, or named members", %{conn: conn, path: path, scope: scope} do
      {:ok, view, _html} = live(conn, path)

      view |> form("#stage-form", stage: %{gate: %{kind: "none"}}) |> render_change()
      assert hd(canvas_view(view)["stages"])["gate"] == "No gate"

      view
      |> form("#stage-form", stage: %{gate: %{kind: "person", approvers: "named"}})
      |> render_change()

      assert has_element?(view, "#stage-gate-named", scope.user.email)

      view
      |> form("#stage-form",
        stage: %{gate: %{kind: "person", approvers: "named", named: ["", scope.user.id]}}
      )
      |> render_change()

      assert hd(canvas_view(view)["stages"])["gate"] == "Gate: 1 named member approves"
    end

    test "saves a version, with its changes in the history", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      view |> element("#stages-add") |> render_click()
      view |> element(~s(button[aria-label="Remove Release"])) |> render_click()

      view |> element("#stages-save") |> render_click()

      assert has_element?(view, "#stages-notice", "Saved as version 2.")
      assert has_element?(view, "#stages-version", "Editing version 2, current.")
      refute has_element?(view, "#stages-dirty")
      assert has_element?(view, "#stages-version-2", "Removed the stage Release.")
      assert has_element?(view, "#stages-version-2", "Added the stage New stage.")
      assert has_element?(view, "#stages-version-1", "past")
    end

    test "a save of a stage without a name is refused", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      view |> form("#stage-form", stage: %{name: " "}) |> render_change()
      view |> element("#stages-save") |> render_click()

      assert has_element?(view, "[data-save-error]", "Give every stage a name.")
      assert has_element?(view, "#stages-version", "Editing version 1, current.")
    end

    test "saves a trial, assigns a work item to it and makes it current", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      item = work_item_fixture(scope, %{title: "Web shop checkout"})
      {:ok, view, _html} = live(conn, path)

      view |> form("#stage-form", stage: %{name: "Discover"}) |> render_change()
      view |> element("#stages-save-trial") |> render_click()

      assert has_element?(view, "#stages-trial-title", "Trial: version 2")
      assert has_element?(view, "#stages-assign-form", "Web shop checkout")

      view |> form("#stages-assign-form", assign: %{items: [item.public_id]}) |> render_submit()
      refute has_element?(view, "[data-assign-error]")

      view |> element("#stages-make-current") |> render_click()
      assert has_element?(view, "#stages-notice", "Version 2 is now current.")
      refute has_element?(view, "#stages-trial")
      assert has_element?(view, "#stages-version-2", "Renamed the stage Explore to Discover.")
    end

    test "a trial without the work item's stage keeps the work item, and a drop returns to current",
         %{conn: conn, path: path, scope: scope} do
      item = work_item_fixture(scope, %{title: "Web shop checkout"})
      {:ok, view, _html} = live(conn, path)

      view |> element(~s(button[aria-label="Remove Explore"])) |> render_click()
      view |> element("#stages-save-trial") |> render_click()

      view |> form("#stages-assign-form", assign: %{items: [item.public_id]}) |> render_submit()

      assert has_element?(
               view,
               "[data-assign-error]",
               "its stage Explore is not in version 2"
             )

      view |> element("#stages-drop-trial") |> render_click()
      assert has_element?(view, "#stages-notice", "Dropped version 2.")
      assert has_element?(view, "#stages-version-2", "dropped")
      assert has_element?(view, "#stages-version", "Editing version 1, current.")
    end

    test "an admin edits too", %{scope: scope, path: path} do
      %{user: user} = member_fixture(scope, :admin)
      {:ok, view, _html} = live(log_in_user(build_conn(), user), path)
      assert has_element?(view, "#stage-form")
      assert has_element?(view, "#stages-add")
    end
  end

  describe "a member" do
    setup %{scope: scope} do
      %{user: user} = member_fixture(scope)
      %{member: log_in_user(build_conn(), user)}
    end

    test "reads the stages, with no edit control", %{member: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      assert names(view) == ~w(Explore Shape Build Verify Release)
      refute canvas_view(view)["editable"]
      assert has_element?(view, "#stage-panel-title", "Explore")
      assert has_element?(view, "#stage-panel", "explore-a-ticket, machine type default")

      for selector <-
            ~w(#stage-form #stages-add #stages-save #stages-save-trial #stages-process-form #stages-trial) do
        refute has_element?(view, selector), selector
      end

      refute has_element?(view, ~s(button[phx-click="move"]))
      refute has_element?(view, ~s(button[phx-click="remove_stage"]))

      view |> element(~s(button[aria-label="Show Build"])) |> render_click()
      assert has_element?(view, "#stage-panel-title", "Build")
    end

    test "sends an edit, and nothing changes", %{member: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_hook(view, "add_stage", %{})
      render_hook(view, "reorder", %{"ids" => Enum.reverse(ids(view))})
      assert names(view) == ~w(Explore Shape Build Verify Release)
    end
  end

  describe "the calls until Apiary.Processes lands" do
    test "the placement check reports a missing type, and no output nobody writes" do
      doc = Calls.default_document("software")

      doc =
        Draft.update_stage(doc, "st_shape", fn s ->
          s |> Map.put("outputs", [%{"type" => "mockup", "required" => true}])
        end)

      doc =
        Draft.update_stage(doc, "st_build", fn s ->
          Map.put(s, "inputs", [
            %{"type" => "mockup", "required" => false},
            %{"type" => "brief", "required" => true}
          ])
        end)

      assert Calls.placement_check(
               doc,
               ["explore-a-ticket"],
               Calls.types(%Apiary.Organisations.Workspace{})
             ) == [
               {:missing_type, "st_build", "brief"},
               {:input_not_output, "st_build", "brief"}
             ]
    end

    test "the diff names each kind of change" do
      old = Calls.default_document("software")

      new =
        old
        |> Map.put("machine", "large")
        |> Draft.update_stage("st_shape", &Map.put(&1, "name", "Plan"))
        |> Draft.move("st_release", -1)
        |> Draft.update_stage("st_build", &Draft.add_entry(&1, "explore-a-ticket", nil))

      kinds = for {kind, id, _detail} <- Calls.diff(old, new), do: {kind, id}

      assert {:machine_changed, nil} in kinds
      assert {:stage_renamed, "st_shape"} in kinds
      assert {:stage_moved, "st_release"} in kinds
      assert {:sequence_changed, "st_build"} in kinds
    end
  end
end
