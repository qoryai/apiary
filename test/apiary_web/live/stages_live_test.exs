defmodule ApiaryWeb.StagesLiveTest do
  @moduledoc """
  Workspace settings › Stages (`ApiaryWeb.StagesLive.Index`) and the Workflow page's link
  to it: not found while the feature `workflow_model` is off; the canvas and the list of stages; adding, renaming,
  moving and removing a stage; a stage's sequence, loop, inputs, outputs and gate; the
  placement check; a save, a trial and the history; and a member's page, with no edit
  controls.

  Not async: each test sets the instance's features, which are the whole node's.
  """
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Processes
  alias Apiary.Repo
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.StagesLive.{Draft, Words}

  @moduletag with_features: Apiary.Features.all()

  setup :register_and_log_in_user

  setup %{scope: scope} do
    %{path: workspace_path(scope, "/settings/stages")}
  end

  # The id of the default process's stage `name`.
  defp id_of(name),
    do: Enum.find(Processes.default_document("software")["stages"], &(&1["name"] == name))["id"]

  defp card(view, name), do: Enum.find(canvas_view(view)["stages"], &(&1["name"] == name))

  # The status of a request the feature's gate answers, as a response or as an error.
  defp status(conn, path) do
    get(conn, path).status
  rescue
    _error -> elem(assert_error_sent(:not_found, fn -> get(conn, path) end), 0)
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
    @tag with_features: Apiary.Features.all() -- [:workflow_model]
    test "off: Stages is not found, and the Workflow page keeps its workflow choice", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      assert status(conn, path) == 404

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
      assert canvas["selected"] == id_of("Explore")

      assert [explore | _] = canvas["stages"]

      assert explore == %{
               "id" => id_of("Explore"),
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
      assert id =~ ~r/^st_[0-9a-hjkmnp-tv-z]{10}$/
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
      render_hook(view, "reorder", %{"ids" => [id_of("Explore")]})
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

      assert card(view, "Build")["loop"] == "Loop: at most 10 rounds"
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
         %{conn: conn, path: path, scope: scope} do
      # A version saved while the harness declared capture-demo.
      document =
        Draft.update_stage(
          Processes.default_document("software"),
          id_of("Build"),
          &Draft.add_entry(&1, "capture-demo", nil)
        )

      {:ok, _version} = Processes.save(scope, scope.workspace, document)

      {:ok, view, _html} = live(conn, path)
      view |> element(~s(button[aria-label="Edit Build"])) |> render_click()

      undeclared =
        "Build uses capture-demo, which the harness no longer declares. Add it to the harness, or choose another workflow for Build."

      assert has_element?(view, "#stage-panel [data-stage-alert]", undeclared)
      assert has_element?(view, ~s(#stages-check [data-problem="missing_workflow"]), undeclared)

      assert undeclared in card(view, "Build")["alerts"]

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

      assert card(view, "Explore")["gate"] == "Gate: a member approves"

      view
      |> form("#stage-form", stage: %{gate: %{kind: "person", approvers: "named"}})
      |> render_change()

      assert has_element?(view, "#stage-gate-named", scope.user.email)

      view
      |> form("#stage-form",
        stage: %{gate: %{kind: "person", approvers: "named", named: ["", scope.user.id]}}
      )
      |> render_change()

      gate = "Gate: #{scope.user.email} approves"
      assert card(view, "Explore")["gate"] == gate
      refute Jason.encode!(canvas_view(view)) =~ scope.user.id

      view |> form("#stage-form", stage: %{gate: %{kind: "none"}}) |> render_change()
      assert card(view, "Explore")["gate"] == "No gate"
      refute has_element?(view, "#stage-gate-named")
    end

    test "a named approver shows by name in the history, never by id", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#stage-form", stage: %{gate: %{kind: "person", approvers: "named"}})
      |> render_change()

      view
      |> form("#stage-form",
        stage: %{gate: %{kind: "person", approvers: "named", named: ["", scope.user.id]}}
      )
      |> render_change()

      view |> element("#stages-save") |> render_click()

      history = view |> element("#stages-history") |> render()
      assert history =~ "Changed the gate of Explore: #{scope.user.email} approves."
      refute history =~ scope.user.id
    end

    test "a type the workspace does not have links to the Artifact types section", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      document =
        Draft.update_stage(
          Processes.default_document("software"),
          id_of("Build"),
          &Draft.add_artifact(&1, "inputs", "brief")
        )

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
      {:ok, view, _html} = live(conn, path)

      assert has_element?(
               view,
               ~s(#stages-check [data-problem="missing_type"] a[href="#{workspace_path(scope, "/settings/artifact-types")}"]),
               "Define it"
             )
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

      assert has_element?(
               view,
               "[data-save-error]",
               "Give every stage a name of 1 to 60 characters."
             )

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

      assert has_element?(view, ~s(#stages-assign-form input[value="#{item.public_id}"][checked]))
      [trial] = for v <- Processes.list_versions(scope.workspace), v.status == :trial, do: v
      assert Repo.get!(WorkItem, item.id).process_version_id == trial.id

      view |> element("#stages-make-current") |> render_click()
      assert has_element?(view, "#stages-notice", "Version 2 is now current.")
      refute has_element?(view, "#stages-trial")
      assert has_element?(view, "#stages-version-2", "Renamed the stage Explore to Discover.")
    end

    test "a trial without the work item's stage keeps the work item, and a drop returns to current",
         %{conn: conn, path: path, scope: scope} do
      item = work_item_fixture(scope, %{title: "Web shop checkout"})

      Repo.update_all(WorkItem,
        set: [
          stage_id: id_of("Explore"),
          process_version_id: Processes.current(scope.workspace).id
        ]
      )

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

  describe "the words" do
    test "each change of a version reads in plain words" do
      old = Processes.default_document("software")

      new =
        old
        |> Map.put("machine", "large")
        |> Draft.update_stage(id_of("Shape"), &Map.put(&1, "name", "Plan"))
        |> Draft.move(id_of("Release"), -1)
        |> Draft.update_stage(id_of("Build"), &Draft.add_entry(&1, "explore-a-ticket", nil))

      lines = for change <- Processes.diff(old, new), do: Words.change(change, old, new)

      assert "Changed the default machine type from default to large." in lines
      assert "Renamed the stage Shape to Plan." in lines
      assert "Changed the sequence of Build." in lines
      assert Enum.any?(lines, &(&1 =~ ~r/^Moved (Release|Verify) from place \d to place \d\.$/))
    end

    test "a refused save says which stage and what to do" do
      doc = Processes.default_document("software")

      assert Words.refusal(%{path: "#/stages/2/name", error: :schema, detail: :pattern}, doc) ==
               "Give every stage a name of 1 to 60 characters."

      assert Words.refusal(
               %{path: "#/stages/1/name", error: :duplicate_stage_name, detail: nil},
               doc
             ) == "Two stages have the name Shape. Give each stage a different name."

      assert Words.refusal(
               %{path: "#/stages/0/sequence/0/loop/rounds", error: :schema, detail: :maximum},
               doc
             ) =~ "Explore: give every loop 1 to 10 rounds"
    end
  end
end
