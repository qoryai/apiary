defmodule ApiaryWeb.StagesLiveTest do
  @moduledoc """
  Workspace settings › Stages (`ApiaryWeb.StagesLive.Index`), the sidebar's Stages entry
  and the Workflow page's link to it: not found while the feature `workflow_model` is off;
  the canvas, the editor, with the inspector of the selected stage; adding a stage at a
  place ("+"), renaming, moving and removing it; a stage's sequence, loop, inputs, outputs
  and gate; the placement check; a save, a trial and the history; a member's page, with
  the same canvas and a read-only inspector; the tabs Stages and Details, with one draft;
  the harness's workflows, read again from the workspace's harness choice against stub
  adapters (`Req.Test`); and a workflow's typed name, with its check or cross.

  Not async: each test sets the instance's features, which are the whole node's.
  """
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.HarnessReadsFixtures
  import Apiary.NodesFixtures
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

  # The adapter calls the stub adapters received (`Apiary.HarnessReadsFixtures`).
  defp calls do
    receive do
      {:harness_call, path, call} -> [{path, call} | calls()]
    after
      0 -> []
    end
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

  # The stages' names and ids, in the order the canvas draws them.
  defp names(view), do: Enum.map(canvas_view(view)["stages"], & &1["name"])
  defp ids(view), do: Enum.map(canvas_view(view)["stages"], & &1["id"])

  # A click or Enter on the card `name` on the canvas.
  defp select(view, name), do: render_hook(view, "select", %{"id" => card(view, name)["id"]})

  # The work items of the trial's assign form, in the order the page lists them.
  defp assign_order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#stages-assign-form input[type="checkbox"]))
    |> LazyHTML.attribute("value")
  end

  defp canvas_view(view), do: canvas_data(view, "data-view")

  # The Details tab, and back to the Stages tab: a patch, so the draft stays.
  defp details(view, path), do: render_patch(view, path <> "?tab=details")
  defp stages_tab(view, path), do: render_patch(view, path)

  defp canvas_data(view, attribute) do
    [json] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#stages-canvas")
      |> LazyHTML.attribute(attribute)

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
    test "sees the software type's five stages on the canvas, the inspector and the harness",
         %{conn: conn, path: path, scope: scope} do
      {:ok, view, _html} = live(conn, path)
      # The Qory harness's names, recorded when the page opens.
      render_async(view)

      assert has_element?(view, "#settings-section-title", "Stages")
      assert has_element?(view, ~s(#settings-tab-stages[href="#{path}"][aria-current="page"]))
      refute has_element?(view, "#settings-tab-workflow")
      assert names(view) == ~w(Explore Shape Build Verify Release)

      # No list and no form beside the canvas: the canvas is the editor.
      refute has_element?(view, "#stages-list")
      assert has_element?(view, "#stages-editor #stages-canvas")
      assert has_element?(view, "#stages-editor #stage-panel")

      # Stages opens first, at the page's address; the other settings are on Details.
      assert has_element?(view, ~s(#stages-tabs-stages[href="#{path}"][aria-current="page"]))
      assert has_element?(view, ~s(#stages-tabs-details[href="#{path}?tab=details"]))
      refute has_element?(view, "#stages-harness")
      refute has_element?(view, "#stages-history")

      details(view, path)
      assert has_element?(view, ~s(#stages-tabs-details[aria-current="page"]))
      refute has_element?(view, "#stages-canvas")

      assert has_element?(
               view,
               "#stages-details > p:first-child",
               "Every work item of #{scope.workspace.name} goes through these stages, in order."
             )

      assert has_element?(view, "#stages-harness", "Harness: Qory harness, stack software")

      assert has_element?(
               view,
               ~s(#stages-harness-change[href="#{workspace_path(scope, "/settings/workflow")}"]),
               "Change"
             )

      assert has_element?(view, "#stages-version", "Editing version 1, current.")
      assert has_element?(view, "#stages-check-clear")
      assert has_element?(view, "#stages-version-1", "The first version.")

      stages_tab(view, path)

      assert has_element?(
               view,
               ~s(#stages-canvas[phx-update="ignore"][data-script="/assets/js/canvas.js"])
             )

      canvas = canvas_view(view)
      assert canvas["editable"]
      assert canvas["selected"] == id_of("Explore")
      assert canvas["first"] == "Add a stage before Explore"

      # The canvas scrolls to cards out of view: no "more" control. Its buttons: the zoom,
      # Focus and Full screen.
      words = canvas_data(view, "data-words")
      refute Enum.any?(~w(left right left_label right_label fit), &Map.has_key?(words, &1))
      assert words["focus"] == "Focus"
      assert words["full_screen"] == "Full screen"

      assert words["node"] ==
               "Press Enter to open the stage beside the canvas. Move it with the up and down arrow keys."

      assert [explore | _] = canvas["stages"]

      assert explore == %{
               "id" => id_of("Explore"),
               "name" => "Explore",
               "label" => "Explore. explore-a-ticket. Gate: a member approves",
               "sequence" => [%{"workflow" => "explore-a-ticket"}],
               "gate" => "Gate: a member approves",
               "add" => "Add a stage after Explore",
               "alerts" => [],
               "marks" => %{
                 "explore-a-ticket" => %{
                   "listed" => true,
                   "label" => "explore-a-ticket: a stage can run it"
                 }
               }
             }

      assert has_element?(view, "#stage-panel-title", "Edit Explore")
      assert has_element?(view, "#stages-version", "Editing version 1, current.")
    end

    test "a switch of tabs keeps the draft, and Save is on both tabs", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, path)
      view |> form("#stage-form", stage: %{name: "Discover"}) |> render_change()

      details(view, path)
      assert has_element?(view, "#stages-dirty", "Unsaved changes")
      assert has_element?(view, "#stages-save:not([disabled])")
      view |> form("#stages-process-form", process: %{machine: "large"}) |> render_change()

      stages_tab(view, path)
      assert hd(names(view)) == "Discover"
      view |> element("#stages-save") |> render_click()

      assert %{document: %{"machine" => "large", "stages" => [%{"name" => "Discover"} | _]}} =
               Processes.current(scope.workspace)
    end

    test "adds a stage with a new id at a +, renames, moves and removes it", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)

      # The + before the first card.
      render_hook(view, "add_stage", %{"at" => "0"})
      assert names(view) == ["New stage", "Explore", "Shape", "Build", "Verify", "Release"]
      assert canvas_view(view)["first"] == "Add a stage before New stage"
      assert has_element?(view, "#stage-panel-title", "Edit New stage")
      view |> element("#stage-remove") |> render_click()

      # The + between Explore and Shape.
      render_hook(view, "add_stage", %{"at" => "1"})
      assert names(view) == ["Explore", "New stage", "Shape", "Build", "Verify", "Release"]
      assert has_element?(view, "#stage-panel-title", "Edit New stage")
      view |> element("#stage-remove") |> render_click()

      # The + after the last card.
      render_hook(view, "add_stage", %{"at" => "5"})
      assert names(view) == ["Explore", "Shape", "Build", "Verify", "Release", "New stage"]
      id = List.last(ids(view))
      assert id =~ ~r/^st_[0-9a-hjkmnp-tv-z]{10}$/
      assert has_element?(view, "#stage-panel-title", "Edit New stage")
      assert has_element?(view, "#stages-dirty")

      view |> form("#stage-form", stage: %{name: "Demo"}) |> render_change()
      assert List.last(names(view)) == "Demo"
      assert List.last(ids(view)) == id

      # The left arrow key on the card.
      render_hook(view, "move", %{"id" => id, "by" => "-1"})
      assert names(view) == ~w(Explore Shape Build Verify Demo Release)

      render_hook(view, "reorder", %{"ids" => [id | List.delete(ids(view), id)]})
      assert names(view) == ~w(Demo Explore Shape Build Verify Release)

      # An order that is not the same stages changes nothing.
      render_hook(view, "reorder", %{"ids" => [id_of("Explore")]})
      assert names(view) == ~w(Demo Explore Shape Build Verify Release)

      view |> element(~s(#stage-remove[aria-label="Remove Demo"])) |> render_click()
      assert names(view) == ~w(Explore Shape Build Verify Release)
      refute has_element?(view, "#stages-dirty")
    end

    test "edits a sequence: a workflow, a loop with its rounds, and a machine type", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      select(view, "Build")

      view |> element("#stage-add-entry") |> render_click()
      view |> element("#stage-add-loop") |> render_click()

      view
      |> form("#stage-form",
        stage: %{sequence: %{"0" => %{machine: "large"}, "1" => %{rounds: "40"}}}
      )
      |> render_change()

      # The form is novalidate: 40 is refused under the field, and the loop keeps 3.
      assert Enum.at(card(view, "Build")["sequence"], 1) == %{
               "loop" => "at most 3 rounds",
               "workflows" => ["explore-a-ticket"]
             }

      assert has_element?(view, "#stage-loop-1", "Give the loop 1 to 10 rounds.")

      view
      |> form("#stage-form", stage: %{sequence: %{"1" => %{rounds: "10"}}})
      |> render_change()

      assert Enum.at(card(view, "Build")["sequence"], 1)["loop"] == "at most 10 rounds"
      refute has_element?(view, "#stage-loop-1", "Give the loop 1 to 10 rounds.")
      assert has_element?(view, "#stage-entry-0-machine[value=large]")

      # The machine help text, once, under the default machine type only, on Details.
      hint =
        "Qory Apiary stores the machine type with each run of the workflow. It does not choose the machine that runs it."

      refute has_element?(view, "#stage-panel", "Qory Apiary stores the machine type")
      details(view, path)
      assert has_element?(view, "#stages-process-form", hint)
      stages_tab(view, path)

      view |> element(~s(#stage-loop-1 button[phx-click="remove_loop"])) |> render_click()
      refute has_element?(view, "#stage-loop-1")
      assert has_element?(view, "#stage-entry-1-workflow")
    end

    test "the placement check lists a workflow the harness does not declare and an input no earlier stage outputs",
         %{conn: conn, path: path, scope: scope} do
      # A version saved with capture-demo, which the Qory harness does not list.
      document =
        Draft.update_stage(
          Processes.default_document("software"),
          id_of("Build"),
          &Draft.add_entry(&1, "capture-demo", nil)
        )

      {:ok, _version} = Processes.save(scope, scope.workspace, document)

      # The page records the Qory harness's names when it opens.
      {:ok, view, _html} = live(conn, path)
      render_async(view)
      select(view, "Build")

      undeclared =
        "Choose another workflow for Build. To keep capture-demo, change the harness on the Details tab to one that lists it under workflows. The Qory harness does not list capture-demo, so Build waits and starts no run."

      assert has_element?(view, "#stage-panel [data-stage-alert]", undeclared)
      assert undeclared in card(view, "Build")["alerts"]

      details(view, path)
      assert has_element?(view, ~s(#stages-check [data-problem="missing_workflow"]), undeclared)
      stages_tab(view, path)

      # The entry's value, in a text field that suggests the names the harness lists.
      assert has_element?(view, ~s{#stage-entry-0-workflow[type="text"][value="capture-demo"]})
      assert has_element?(view, ~s{#stage-entry-0-workflow[list="stage-entry-0-workflow-names"]})

      assert has_element?(
               view,
               ~s{datalist#stage-entry-0-workflow-names option[value="explore-a-ticket"]}
             )

      refute has_element?(
               view,
               ~s{datalist#stage-entry-0-workflow-names option[value="capture-demo"]}
             )

      refute has_element?(view, "#stage-sequence select")

      view |> element("#stage-add-inputs") |> render_click()
      details(view, path)

      assert has_element?(
               view,
               ~s(#stages-check [data-problem="input_not_output"]),
               "Build needs acceptance-criteria as an input, and no stage before Build lists it as an output."
             )
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

      gate = "Gate: #{ApiaryWeb.People.short(scope.user.email)} approves"
      assert card(view, "Explore")["gate"] == gate
      refute Jason.encode!(canvas_view(view)) =~ scope.user.id

      # Any member and Named members sit under "A person approves", above "No gate".
      gate_html = view |> element("#stage-gate") |> render()

      [person, approvers, none] =
        for marker <- ["stage-gate-kind-0", "stage-gate-approvers", "stage-gate-kind-1"],
            do: :binary.match(gate_html, marker) |> elem(0)

      assert person < approvers and approvers < none

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
      details(view, path)

      history = view |> element("#stages-history") |> render()

      assert history =~
               "Changed the gate of Explore: #{ApiaryWeb.People.short(scope.user.email)} approves."

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
      {:ok, view, _html} = live(conn, path <> "?tab=details")

      assert has_element?(
               view,
               ~s(#stages-check [data-problem="missing_type"] a[href="#{workspace_path(scope, "/settings/artifact-types")}"]),
               "Define it"
             )
    end

    test "a hidden standard type is not offered, and a stage that has it is a missing type",
         %{conn: conn, path: path, scope: scope} do
      document =
        Draft.update_stage(
          Processes.default_document("software"),
          id_of("Explore"),
          &Draft.add_artifact(&1, "outputs", "explainer")
        )

      {:ok, _version} = Processes.save(scope, scope.workspace, document)

      {1, _rows} =
        Repo.update_all(
          from(w in Apiary.Organisations.Workspace, where: w.id == ^scope.workspace.id),
          set: [shown_standard_types: ["mockup"]]
        )

      {:ok, view, _html} = live(conn, path <> "?tab=details")

      assert has_element?(
               view,
               ~s(#stages-check [data-problem="missing_type"]),
               Words.missing_type("Explore", "explainer")
             )

      assert has_element?(
               view,
               ~s(#stages-check [data-problem="missing_type"] a[href="#{workspace_path(scope, "/settings/artifact-types")}"]),
               "Switch it on"
             )

      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, ~s(#stage-outputs-0-type option[value="mockup"]))
      assert has_element?(view, ~s(#stage-outputs-0-type option[value="verdict"]))
      refute has_element?(view, ~s(#stage-outputs-0-type option[value="screenshot"]))
    end

    test "a custom type of the workspace is a type the process may name", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      {:ok, _type} =
        Apiary.Artifacts.create_type(scope, scope.workspace, %{
          "name" => "brief",
          "base_view" => "document"
        })

      document =
        Draft.update_stage(
          Processes.default_document("software"),
          id_of("Build"),
          &Draft.add_artifact(&1, "inputs", "brief")
        )

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
      {:ok, view, _html} = live(conn, path <> "?tab=details")

      assert has_element?(view, "#stages-check")
      refute has_element?(view, ~s(#stages-check [data-problem="missing_type"]))
    end

    test "saves a version, with its changes in the history", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, path)
      render_hook(view, "add_stage", %{"at" => "5"})
      assert has_element?(view, "#stages-dirty.badge-warning", "Unsaved changes")
      select(view, "Release")
      view |> element("#stage-remove") |> render_click()

      view |> element("#stages-save") |> render_click()

      assert has_element?(view, "#stages-notice", "Saved as version 2.")
      assert has_element?(view, "#stages-version", "Editing version 2, current.")
      refute has_element?(view, "#stages-dirty")
      details(view, path)
      assert has_element?(view, "#stages-version-2", "Removed the stage Release.")
      assert has_element?(view, "#stages-version-2", "Added the stage New stage.")

      # The author by name, as the policy history shows people, not by address.
      author = ApiaryWeb.People.short(scope.user.email)
      assert has_element?(view, "#stages-version-2", author <> ", ")
      refute has_element?(view, "#stages-version-2", scope.user.email)

      # A later refusal replaces the notice: the document is now the saved one.
      render_hook(view, "save", %{"trial" => "false"})
      refute has_element?(view, "#stages-notice")
      assert has_element?(view, "#stages-save-note", "Nothing to save")
      assert has_element?(view, "#stages-version-1", "past")
    end

    test "a save of a stage without a name is refused", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      view |> form("#stage-form", stage: %{name: " "}) |> render_change()
      view |> element("#stages-save") |> render_click()

      # Next to the name, as the form is novalidate, and on the card.
      error = "Give every stage a name of 1 to 60 characters."
      assert error in Enum.at(canvas_view(view)["stages"], 0)["alerts"]
      assert has_element?(view, "#stage-form", error)
      refute has_element?(view, "[data-save-error]")

      assert has_element?(view, "#stages-version", "Editing version 1, current.")
    end

    test "a duplicate name shows next to the name of the stage it is in", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      select(view, "Shape")
      view |> form("#stage-form", stage: %{name: " explore "}) |> render_change()
      select(view, "Explore")

      view |> element("#stages-save") |> render_click()

      # Shape, the second stage named so, is selected, with the error next to its name and
      # on its card.
      [explore, shape | _] = canvas_view(view)["stages"]
      assert Enum.any?(shape["alerts"], &(&1 =~ "Two stages have the name"))
      assert explore["alerts"] == []
      assert has_element?(view, ~s(#stage-name[value=" explore "]))
      assert has_element?(view, "#stage-form", "Two stages have the name")
      assert has_element?(view, ~s(#stage-name[aria-invalid="true"]))
      refute has_element?(view, "[data-save-error]")
      assert has_element?(view, "#stages-version", "Editing version 1, current.")
    end

    test "an unchanged document shows next to Save", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_hook(view, "save", %{"trial" => "false"})

      assert has_element?(
               view,
               "#stages-save-note",
               "Nothing to save: the stages are the same as in the version you started from."
             )

      refute has_element?(view, "[data-save-error]")
    end

    test "saves a trial, assigns a work item to it and makes it current", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      item = work_item_fixture(scope, %{title: "Web shop checkout"})
      _other = work_item_fixture(scope, %{title: "Web shop search", external_ref: "acme/shop#13"})
      {:ok, view, _html} = live(conn, path)

      view |> form("#stage-form", stage: %{name: "Discover"}) |> render_change()
      view |> element("#stages-save-trial") |> render_click()
      details(view, path)

      assert has_element?(view, "#stages-trial-title", "Trial: version 2")
      assert has_element?(view, "#stages-assign-form", "Web shop checkout")
      order = assign_order(view)

      view |> form("#stages-assign-form", assign: %{items: [item.public_id]}) |> render_submit()
      refute has_element?(view, "[data-assign-error]")

      assert has_element?(
               view,
               "#stages-trial #stages-assigned",
               "Assigned 1 work item to version 2."
             )

      assert assign_order(view) == order

      assert has_element?(view, ~s(#stages-assign-form input[value="#{item.public_id}"][checked]))
      [trial] = for v <- Processes.list_versions(scope.workspace), v.status == :trial, do: v
      assert Repo.get!(WorkItem, item.id).process_version_id == trial.id

      view |> element("#stages-make-current") |> render_click()
      assert has_element?(view, "#stages-notice", "Version 2 is now current.")
      refute has_element?(view, "#stages-trial")
      assert has_element?(view, "#stages-version-2", "Renamed the stage Explore to Discover.")
    end

    test "a drop of a trial with work items puts them back on the current version", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      item = work_item_fixture(scope, %{title: "Web shop checkout"})
      {added, _id} = Draft.add_stage(Processes.current(scope.workspace).document, "Discover")
      {:ok, trial} = Processes.save(scope, scope.workspace, added, trial: true)
      {:ok, _item} = Processes.assign(scope, Repo.get!(WorkItem, item.id), trial)

      {:ok, view, _html} = live(conn, path <> "?tab=details")
      view |> element("#stages-drop-trial") |> render_click()

      assert has_element?(
               view,
               "#stages-notice",
               "Dropped version 2. Its work items are back on the current version."
             )
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

      view |> element(~s(#stage-remove[aria-label="Remove Explore"])) |> render_click()
      view |> element("#stages-save-trial") |> render_click()
      details(view, path)

      view |> form("#stages-assign-form", assign: %{items: [item.public_id]}) |> render_submit()

      assert has_element?(
               view,
               "[data-assign-error]",
               "its stage Explore is not in version 2"
             )

      view |> element("#stages-drop-trial") |> render_click()
      assert has_element?(view, "#stages-notice", "Dropped version 2.")
      # The work item stayed on version 1, so the trial had none to give back.
      refute has_element?(view, "#stages-notice", "Its work items")
      assert has_element?(view, "#stages-version-2", "dropped")
      assert has_element?(view, "#stages-version", "Editing version 1, current.")
    end

    test "a version lists its changes against the version its save started from", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      v1 = Processes.current(scope.workspace)
      {added, _id} = Draft.add_stage(v1.document, "Discover")
      {:ok, v2} = Processes.save(scope, scope.workspace, added, trial: true)
      {:ok, _v2} = Processes.drop_trial(scope, v2)

      renamed = Draft.update_stage(v1.document, id_of("Shape"), &Map.put(&1, "name", "Plan"))
      {:ok, _v3} = Processes.save(scope, scope.workspace, renamed, based_on: v1)

      {:ok, view, _html} = live(conn, path <> "?tab=details")

      assert has_element?(view, "#stages-version-3", "Renamed the stage Shape to Plan.")
      refute has_element?(view, "#stages-version-3", "Discover")
      assert has_element?(view, "#stages-version-2", "Added the stage Discover.")
    end

    test "a trial dropped in another tab: the page shows the versions again", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      item = work_item_fixture(scope, %{title: "Web shop checkout"})
      {renamed, _id} = Draft.add_stage(Processes.current(scope.workspace).document, "Discover")
      {:ok, trial} = Processes.save(scope, scope.workspace, renamed, trial: true)
      {:ok, view, _html} = live(conn, path <> "?tab=details")
      assert has_element?(view, "#stages-trial")

      {:ok, _trial} = Processes.drop_trial(scope, trial)
      view |> form("#stages-assign-form", assign: %{items: [item.public_id]}) |> render_submit()

      assert has_element?(
               view,
               "[data-save-error]",
               "The versions changed since this page loaded"
             )

      refute has_element?(view, "[data-save-error]", "Only owners and admins")
      refute has_element?(view, "#stages-trial")
      assert has_element?(view, "#stages-version-2", "dropped")
    end

    test "a trial made elsewhere: the page shows it, and a second trial is refused", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, path)
      {added, _id} = Draft.add_stage(Processes.current(scope.workspace).document, "Discover")
      {:ok, _trial} = Processes.save(scope, scope.workspace, added, trial: true)

      view |> form("#stage-form", stage: %{name: "Plan"}) |> render_change()
      view |> element("#stages-save-trial") |> render_click()

      assert has_element?(view, "[data-save-error]", "Version 2 is already a trial.")
      details(view, path)
      assert has_element?(view, "#stages-trial-title", "Trial: version 2")
      assert has_element?(view, "#stages-dirty")
      assert [2, 1] == Enum.map(Processes.list_versions(scope.workspace), & &1.number)
    end

    test "a trial with a work item in a stage only the trial has is not dropped", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      item = work_item_fixture(scope, %{title: "Web shop checkout"})
      {added, discover} = Draft.add_stage(Processes.current(scope.workspace).document, "Discover")
      {:ok, trial} = Processes.save(scope, scope.workspace, added, trial: true)
      Repo.update_all(WorkItem, set: [stage_id: discover, process_version_id: trial.id])

      {:ok, view, _html} = live(conn, path <> "?tab=details")
      view |> element("#stages-drop-trial") |> render_click()

      assert has_element?(
               view,
               "[data-assign-error]",
               "work item #{item.number}, Web shop checkout, is in the stage Discover"
             )

      refute has_element?(view, "[data-assign-error]", discover)
      assert has_element?(view, "#stages-trial-title", "Trial: version 2")
    end

    test "an admin edits too", %{scope: scope, path: path} do
      %{user: user} = member_fixture(scope, :admin)
      {:ok, view, _html} = live(log_in_user(build_conn(), user), path)
      assert has_element?(view, "#stage-form")
      assert has_element?(view, "#stage-remove")
      assert canvas_view(view)["editable"]
    end
  end

  describe "a workspace with no template" do
    test "the harness line shows the stack core", %{conn: conn, path: path, scope: scope} do
      {1, _rows} =
        Repo.update_all(
          from(w in Apiary.Organisations.Workspace, where: w.id == ^scope.workspace.id),
          set: [qory_stack: nil]
        )

      {:ok, view, _html} = live(conn, path)
      details(view, path)

      assert has_element?(view, "#stages-harness", "Harness: Qory harness, stack core")
    end
  end

  describe "Export process.yaml" do
    # The document of the workspace's current version, with a first stage whose gate
    # lists the person.
    defp listing_people(scope) do
      document = Processes.current(scope.workspace).document

      update_in(document["stages"], fn [first | rest] ->
        gate = %{"kind" => "person", "approvers" => %{"members" => [scope.user.id]}}
        [Map.put(first, "gate", gate) | rest]
      end)
    end

    test "an owner gets the button and the line, on both tabs", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      href = path <> "/process.yaml"
      assert has_element?(view, ~s(#stages-export-button[href="#{href}"][download]), "Export")
      assert has_element?(view, "#stages-export-button", "Export process.yaml")

      assert has_element?(
               view,
               "#stages-export-line",
               "Commit this file to a harness repository. Only new workspaces made from it use it."
             )

      refute has_element?(view, "#stages-export-people")

      details(view, path)
      assert has_element?(view, "#stages-export-button")
    end

    test "the line adds the people's gates when the current version lists people", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      {:ok, _version} = Processes.save(scope, scope.workspace, listing_people(scope))

      {:ok, view, _html} = live(conn, path)

      assert has_element?(
               view,
               "#stages-export-people",
               "Gates that list people export as all members."
             )
    end

    test "a trial that lists people adds nothing, since the file has the current version", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      {:ok, _trial} =
        Processes.save(scope, scope.workspace, listing_people(scope), trial: true)

      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "#stages-export-button")
      refute has_element?(view, "#stages-export-people")
    end

    test "a member gets no button and no line", %{path: path, scope: scope} do
      {:ok, _version} = Processes.save(scope, scope.workspace, listing_people(scope))
      %{user: user} = member_fixture(scope)

      {:ok, view, _html} = live(log_in_user(build_conn(), user), path)

      refute has_element?(view, "#stages-export")
      refute render(view) =~ "Export process.yaml"
      refute render(view) =~ "harness repository"
    end
  end

  describe "a member" do
    setup %{scope: scope} do
      %{user: user} = member_fixture(scope)
      %{member: log_in_user(build_conn(), user)}
    end

    test "reads the stages on the same canvas, with no edit control", %{
      member: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)

      # The sidebar's Stages entry, for a member too.
      assert has_element?(view, ~s(#settings-tab-stages[href="#{path}"][aria-current="page"]))

      details(view, path)
      assert has_element?(view, "#stages-harness", "Harness: Qory harness, stack software")
      refute has_element?(view, "#stages-harness-change")
      assert has_element?(view, "#stages-machine-read", "Default machine type: default")

      for selector <- ~w(#stages-process-form #stages-trial #stages-save) do
        refute has_element?(view, selector), selector
      end

      stages_tab(view, path)

      assert names(view) == ~w(Explore Shape Build Verify Release)
      refute canvas_view(view)["editable"]
      # Focus, for a member too.
      assert canvas_data(view, "data-words")["focus"] == "Focus"
      assert has_element?(view, "#stage-panel-title", "Explore")
      assert has_element?(view, "#stage-panel", "explore-a-ticket, machine type default")
      assert has_element?(view, "#stages-version", "Version 1, current.")
      refute has_element?(view, "#stages-version", "Editing")
      assert has_element?(view, "#stage-panel dd", "A member approves")
      refute has_element?(view, "#stage-panel", "Gate: a member approves")

      for selector <-
            ~w(#stage-form #stage-remove #stages-save #stages-save-trial #stages-process-form #stages-trial) do
        refute has_element?(view, selector), selector
      end

      refute has_element?(view, ~s(button[phx-click="remove_stage"]))

      # A click or Enter on a card opens it, read-only.
      select(view, "Build")
      assert has_element?(view, "#stage-panel-title", "Build")
    end

    test "a save, an assign, a make current and a drop are refused", %{
      member: conn,
      path: path,
      scope: scope
    } do
      item = work_item_fixture(scope, %{title: "Web shop checkout"})
      {added, _id} = Draft.add_stage(Processes.current(scope.workspace).document, "Discover")
      {:ok, trial} = Processes.save(scope, scope.workspace, added, trial: true)
      {:ok, view, _html} = live(conn, path)

      for {event, params} <- [
            {"save", %{"trial" => "false"}},
            {"save", %{"trial" => "true"}},
            {"assign", %{"assign" => %{"items" => [item.public_id]}}},
            {"make_current", %{}},
            {"drop_trial", %{}}
          ] do
        assert render_hook(view, event, params) =~ "Only owners and admins can change the stages.",
               event
      end

      assert Enum.map(Processes.list_versions(scope.workspace), &{&1.number, &1.status}) ==
               [{2, :trial}, {1, :current}]

      assert Repo.get!(WorkItem, item.id).process_version_id != trial.id
    end

    test "sends an edit, and nothing changes", %{member: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_hook(view, "add_stage", %{"at" => "1"})
      render_hook(view, "reorder", %{"ids" => Enum.reverse(ids(view))})
      render_hook(view, "move", %{"id" => hd(ids(view)), "by" => "1"})
      assert names(view) == ~w(Explore Shape Build Verify Release)
    end
  end

  describe "the harness's workflows" do
    @harness "https://code.example.com/acme/harness"
    @base %{"git" => @harness, "ref" => "HEAD", "stack" => "triage"}
    @stack "modules:\n  - name: core\n    source: {path: modules/core}\n"
    @files %{
      {"R_harness", "harness.yaml"} => "exports:\n  stacks: [triage, other]\n",
      {"R_harness", "stacks/triage/qory-stack.yaml"} =>
        @stack <> "workflows:\n  triage: {}\n  fix: {}\n",
      {"R_harness", "stacks/other/qory-stack.yaml"} => @stack <> "workflows:\n  review: {}\n"
    }

    # The workspace chooses the harness repository's stack `other`; its saved workflow
    # document extends the stack `triage`, which the page no longer reads.
    setup %{scope: scope} do
      adapter = call_adapter_fixture()
      {connection, _nonce} = connection_fixture(scope, adapter.adapter, :listed)
      live_grant_fixture(scope.organisation.id, adapter.adapter, connection, "G_acme")
      harness_collection_fixture(connection, @harness, "acme/harness")
      covered = %{adapter.adapter.id => %{@harness => {"G_acme", "R_harness"}}}
      {:ok, _stack} = Apiary.Stacks.Sources.save(scope, @base, "fix")
      # A branch is chosen at the commit it points to.
      versions = %{"R_harness" => String.duplicate("c3", 20)}
      serve_calls([adapter], covered: covered, files: @files, versions: versions)

      {:ok, _choice} =
        Apiary.Stacks.Sources.choose(
          scope,
          {:repository, %{git: @harness}, "other", {:branch, "main"}}
        )

      calls()
      %{adapter: adapter, covered: covered}
    end

    test "read when the page opens: the chosen harness's stack is recorded, as Check again reads it",
         %{conn: conn, path: path, scope: scope, adapter: adapter, covered: covered} do
      serve_calls([adapter], covered: covered, files: @files)
      {:ok, view, _html} = live(conn, path)
      render_async(view, 5_000)

      # The choice's stack, and not the stack the saved workflow document extends.
      assert %{names: ["review"]} = Processes.declared_snapshot(scope.workspace)

      # The field of Explore, the selected stage, suggests the harness's names, with fix, the
      # saved workflow, among them, and not the Qory harness's.
      for name <- ["fix", "review"] do
        assert has_element?(view, ~s(#stage-panel datalist option[value="#{name}"])), name
      end

      refute has_element?(view, ~s(#stage-panel datalist option[value="explore-a-ticket"]))

      # A name the harness repository does not list: list it in the stack, or choose another.
      view
      |> form("#stage-form",
        stage: %{sequence: %{"0" => %{workflow: "capture-demo"}}}
      )
      |> render_change()

      assert has_element?(
               view,
               "#stage-panel [data-stage-alert]",
               "List capture-demo under workflows in the harness's qory-stack.yaml, or choose another workflow for Explore. Until then, Explore waits and starts no run."
             )

      details(view, path)

      assert has_element?(
               view,
               "#stages-workflows-list",
               "Workflows the harness listed just now: review."
             )

      refute has_element?(view, "#stages-workflows-error")

      # The same read as Check again on a work item.
      assert Apiary.Stacks.Sources.chosen_workflows(scope, scope.workspace) == {:ok, ["review"]}
    end

    test "a read that fails keeps the list of the last read, with the cause",
         %{conn: conn, path: path, scope: scope, adapter: adapter, covered: covered} do
      :ok = Processes.record_declared(scope.workspace, ["triage"])
      snapshot = Processes.declared_snapshot(scope.workspace)
      serve_calls([adapter], covered: covered, files: @files, down: true)

      {:ok, view, _html} = live(conn, path)
      render_async(view, 5_000)

      assert Processes.declared_snapshot(scope.workspace) == snapshot

      # fix, the saved workflow, is not in the snapshot: the field suggests it, the line
      # leaves it out.
      assert has_element?(view, ~s(#stage-panel datalist option[value="fix"]))
      details(view, path)

      assert has_element?(
               view,
               "#stages-workflows-list",
               "Workflows the harness listed just now: triage."
             )

      refute has_element?(view, "#stages-workflows-list", "fix")

      assert has_element?(
               view,
               "#stages-workflows-error",
               "Reading the harness failed, so the list is from the read just now."
             )
    end

    test "a first read that fails: the line, no marks, and the cause", %{
      conn: conn,
      path: path,
      scope: scope,
      adapter: adapter,
      covered: covered
    } do
      serve_calls([adapter], covered: covered, files: @files, down: true)

      {:ok, view, _html} = live(conn, path)
      render_async(view, 5_000)

      assert Processes.declared_snapshot(scope.workspace) == nil
      assert Enum.all?(canvas_view(view)["stages"], &(&1["marks"] == %{}))
      refute has_element?(view, "#stage-panel [data-mark]")

      details(view, path)
      assert has_element?(view, "#stages-workflows-list", "The harness has not been read yet.")
      assert has_element?(view, "#stages-workflows-error", "Reading the harness failed.")
    end

    test "the page shows the stored list before the read ends", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      :ok = Processes.record_declared(scope.workspace, ["review"])
      test = self()
      {:ok, gate} = Agent.start_link(fn -> :held end)

      # The first call waits for the test; a call after it fails at once.
      Req.Test.stub(Apiary.Adapters.Calls, fn conn ->
        if Agent.get(gate, & &1) == :held do
          send(test, {:held, self()})

          receive do
            :go -> :ok
          after
            5_000 -> :ok
          end
        end

        Req.Test.transport_error(conn, :econnrefused)
      end)

      {:ok, view, _html} = live(conn, path <> "?tab=details")
      assert_receive {:held, call}, 2_000

      assert has_element?(view, "#stages-workflows-list", "listed just now: review.")
      refute has_element?(view, "#stages-workflows-error")

      Agent.update(gate, fn _held -> :open end)
      send(call, :go)
      render_async(view, 5_000)
      assert has_element?(view, "#stages-workflows-error")
    end

    test "a member sees the same list and time, and the page reads nothing", %{
      scope: scope,
      path: path,
      adapter: adapter,
      covered: covered
    } do
      :ok = Processes.record_declared(scope.workspace, ["review"])
      snapshot = Processes.declared_snapshot(scope.workspace)
      serve_calls([adapter], covered: covered, files: @files)
      %{user: user} = member_fixture(scope)

      {:ok, view, _html} = live(log_in_user(build_conn(), user), path <> "?tab=details")
      render_async(view, 5_000)

      refute_received {:harness_call, _path, _call}
      assert Processes.declared_snapshot(scope.workspace) == snapshot

      assert has_element?(
               view,
               "#stages-workflows-list",
               "Workflows the harness listed just now: review."
             )
    end

    test "a read that listed no workflows says so, with its time", %{scope: scope, path: path} do
      :ok = Processes.record_declared(scope.workspace, [])
      %{user: user} = member_fixture(scope)

      {:ok, view, _html} = live(log_in_user(build_conn(), user), path <> "?tab=details")

      assert has_element?(
               view,
               "#stages-workflows-list",
               "The harness listed no workflows just now."
             )
    end

    test "a harness chosen while the read runs keeps its snapshot", %{
      conn: conn,
      path: path,
      scope: scope,
      adapter: adapter,
      covered: covered
    } do
      test = self()
      {:ok, gate} = Agent.start_link(fn -> :held end)

      # The first call waits for the test, then fails; the retry reaches the stub below.
      Req.Test.stub(Apiary.Adapters.Calls, fn conn ->
        if Agent.get(gate, & &1) == :held do
          send(test, {:held, self()})

          receive do
            :go -> :ok
          after
            5_000 -> :ok
          end
        end

        Req.Test.transport_error(conn, :econnrefused)
      end)

      {:ok, view, _html} = live(conn, path <> "?tab=details")
      assert_receive {:held, call}, 2_000

      # The person chooses the stack triage while the read of other runs.
      Agent.update(gate, fn _held -> :open end)
      versions = %{"R_harness" => String.duplicate("c3", 20)}
      serve_calls([adapter], covered: covered, files: @files, versions: versions)

      {:ok, _choice} =
        Apiary.Stacks.Sources.choose(
          scope,
          {:repository, %{git: @harness}, "triage", {:branch, "main"}}
        )

      :ok = Processes.record_declared(scope.workspace, ["fix", "triage"])
      snapshot = Processes.declared_snapshot(scope.workspace)

      send(call, :go)
      render_async(view, 5_000)

      # The read of other ended, and its workflows are not recorded over the snapshot.
      assert Enum.any?(calls(), &match?({"read", _call}, &1))
      assert Processes.declared_snapshot(scope.workspace) == snapshot
      refute has_element?(view, "#stages-workflows-error")
    end
  end

  describe "a workspace on the Qory harness whose stack lists no workflows" do
    test "shows the cross, the harness's empty read, and no name of another stack", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      id = scope.workspace.id

      {1, _rows} =
        Repo.update_all(from(w in Apiary.Organisations.Workspace, where: w.id == ^id),
          set: [qory_stack: nil]
        )

      {:ok, view, _html} = live(conn, path)
      render_async(view, 5_000)

      assert Processes.declared_snapshot(scope.workspace).names == []

      assert card(view, "Explore")["marks"] == %{
               "explore-a-ticket" => %{
                 "listed" => false,
                 "label" => "explore-a-ticket: not in the harness"
               }
             }

      details(view, path)

      assert has_element?(view, "#stages-workflows-list", "The harness listed no workflows")
      refute has_element?(view, "#stages-workflows-list", "The Qory harness's workflows")
    end
  end

  describe "a harness repository with no workflows and no saved workflow" do
    test "a new entry starts with the Qory harness's first name", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      Repo.insert!(%Apiary.Stacks.Stack{
        organisation_id: scope.workspace.organisation_id,
        workspace_id: scope.workspace.id,
        choice: :repository,
        version_kind: :commit,
        version_name: String.duplicate("c3", 20),
        harness: "extends:\n  git: https://code.example.com/acme/harness\n  stack: core\n"
      })

      :ok = Processes.record_declared(scope.workspace, [])
      assert Processes.declared_workflows(scope.workspace) == []

      {:ok, view, _html} = live(conn, path)
      render_async(view, 5_000)
      select(view, "Shape")

      view |> element("#stage-add-entry") |> render_click()

      assert card(view, "Shape")["sequence"] == [%{"workflow" => "explore-a-ticket"}]
    end
  end

  describe "the workflow's name and its mark" do
    setup %{scope: scope} do
      # Build runs explore-a-ticket, then a loop of it, then capture-demo.
      document =
        Draft.update_stage(Processes.default_document("software"), id_of("Build"), fn stage ->
          stage
          |> Draft.add_entry("explore-a-ticket", nil)
          |> Draft.add_loop("explore-a-ticket")
          |> Draft.add_entry("capture-demo", nil)
        end)

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
      :ok
    end

    test "a typed name that matches the pattern is the entry's workflow; any other keeps it, with an error at the field",
         %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      select(view, "Build")

      view
      |> form("#stage-form", stage: %{sequence: %{"0" => %{workflow: "triage-bugs"}}})
      |> render_change()

      assert hd(card(view, "Build")["sequence"]) == %{"workflow" => "triage-bugs"}
      refute has_element?(view, "#stage-entry-0", "Write a workflow name")

      for refused <- ["Triage", "triage bugs", "-triage", "", String.duplicate("a", 65)] do
        view
        |> form("#stage-form", stage: %{sequence: %{"0" => %{workflow: refused}}})
        |> render_change()

        assert hd(card(view, "Build")["sequence"]) == %{"workflow" => "triage-bugs"}, refused

        assert has_element?(
                 view,
                 "#stage-entry-0",
                 "Write a workflow name of lower-case letters, digits and hyphens that starts with a letter, at most 64 characters."
               ),
               refused

        assert has_element?(view, ~s{#stage-entry-0-workflow[aria-invalid="true"]}), refused
      end

      # The same in a loop, by the loop's place and the workflow's.
      view
      |> form("#stage-form", stage: %{sequence: %{"1" => %{body: %{"0" => %{workflow: "Nope"}}}}})
      |> render_change()

      assert has_element?(view, "#stage-entry-1-0", "Write a workflow name")

      assert Enum.at(card(view, "Build")["sequence"], 1)["workflows"] == ["explore-a-ticket"]

      # A save sends the typed name, which no harness lists.
      view |> element("#stages-save") |> render_click()
      assert has_element?(view, "#stages-notice", "Saved as version 3.")
    end

    test "Add workflow and Add loop start with the first name a stage may run", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      render_async(view)
      select(view, "Shape")

      view |> element("#stage-add-entry") |> render_click()
      view |> element("#stage-add-loop") |> render_click()

      assert card(view, "Shape")["sequence"] == [
               %{"workflow" => "explore-a-ticket"},
               %{"loop" => "at most 3 rounds", "workflows" => ["explore-a-ticket"]}
             ]
    end

    test "on the Qory harness: no read and no failure line, the Qory names, and a check or a cross beside each workflow",
         %{conn: conn, path: path, scope: scope} do
      {:ok, view, _html} = live(conn, path)
      render_async(view)
      select(view, "Build")

      # The Qory harness is not read: its names are recorded.
      assert %{names: ["explore-a-ticket"]} = Processes.declared_snapshot(scope.workspace)

      # On the card: explore-a-ticket, of the Qory harness, has a check; capture-demo a
      # cross.
      assert card(view, "Build")["marks"] == %{
               "explore-a-ticket" => %{
                 "listed" => true,
                 "label" => "explore-a-ticket: a stage can run it"
               },
               "capture-demo" => %{
                 "listed" => false,
                 "label" => "capture-demo: not in the harness"
               }
             }

      assert card(view, "Explore")["marks"] == %{
               "explore-a-ticket" => %{
                 "listed" => true,
                 "label" => "explore-a-ticket: a stage can run it"
               }
             }

      # In the panel, beside each field.
      assert has_element?(
               view,
               ~s{#stage-entry-0-workflow-mark[data-mark="listed"]},
               "A stage can run it"
             )

      assert has_element?(
               view,
               ~s{#stage-entry-1-0-workflow-mark[data-mark="listed"]},
               "A stage can run it"
             )

      assert has_element?(
               view,
               ~s{#stage-entry-2-workflow-mark[data-mark="missing"]},
               "Not in the harness"
             )

      # A typed name a stage may run gets a check.
      view
      |> form("#stage-form", stage: %{sequence: %{"2" => %{workflow: "explore-a-ticket"}}})
      |> render_change()

      assert has_element?(view, ~s{#stage-entry-2-workflow-mark[data-mark="listed"]})
      assert card(view, "Build")["alerts"] == []

      # Details: the Qory harness's workflows, with no time of a read, and no read that
      # failed.
      details(view, path)
      assert has_element?(view, "#stages-workflows")
      refute has_element?(view, "#stages-workflows-error")

      assert has_element?(
               view,
               "#stages-workflows-list",
               "The Qory harness's workflows: explore-a-ticket."
             )

      refute render(element(view, "#stages-details")) =~ "listed"

      assert has_element?(view, "#stages-check-clear", "Every workflow is declared")

      # A member reads the same marks, beside each line of the sequence.
      %{user: user} = member_fixture(scope)
      {:ok, member, _html} = live(log_in_user(build_conn(), user), path)
      select(member, "Build")

      assert card(member, "Build")["marks"]["capture-demo"]["listed"] == false
      assert has_element?(member, ~s{#stage-panel dd [data-mark="missing"]}, "Not in the harness")
      assert has_element?(member, ~s{#stage-panel dd [data-mark="listed"]}, "A stage can run it")
    end

    test "on the Qory harness, before its workflows are recorded: no marks, the Qory line, and no workflow listed as missing",
         %{path: path, scope: scope} do
      # A member's page reads nothing, so the harness stays unread.
      %{user: user} = member_fixture(scope)
      {:ok, view, _html} = live(log_in_user(build_conn(), user), path)
      render_async(view)
      assert Processes.declared_snapshot(scope.workspace) == nil
      select(view, "Build")

      assert Enum.all?(canvas_view(view)["stages"], &(&1["marks"] == %{}))
      assert card(view, "Build")["alerts"] == []
      refute has_element?(view, "#stage-panel [data-mark]")
      refute has_element?(view, "#stage-panel [data-stage-alert]")

      # The Qory harness is never read: its workflows, and when they are checked.
      details(view, path)

      assert has_element?(
               view,
               "#stages-workflows-list",
               "The Qory harness's workflows: explore-a-ticket."
             )

      assert has_element?(view, "#stages-check")
      refute has_element?(view, ~s(#stages-check [data-problem="missing_workflow"]))

      assert has_element?(
               view,
               "#stages-check-clear",
               "Every type exists, and every input is an output of an earlier stage. The workflows are checked once an owner or admin opens this page."
             )

      refute render(element(view, "#stages-details")) =~ ~r/harness is read|been read/
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

    test "a person who left reads Former member at the start of a line, else a former member" do
      gone = %{
        "gate" => %{"kind" => "person", "approvers" => %{"members" => [Ecto.UUID.generate()]}}
      }

      assert Words.gate_value(gone, %{}) == "Former member approves"
      assert Words.gate_line(gone, %{}) == "Gate: a former member approves"
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
