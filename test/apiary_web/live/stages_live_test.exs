defmodule ApiaryWeb.StagesLiveTest do
  @moduledoc """
  Workspace settings › Workflows (`ApiaryWeb.StagesLive.Index`), the sidebar's Workflows entry
  and the Harness page's link to it: not found while the feature `workflow_model` is off;
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
  import Apiary.MachineTypesFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Processes
  alias Apiary.Repo
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.StagesLive.{Draft, Words}

  @moduletag with_features: Apiary.Features.all()

  @harness_process "modules/software-factory/process.yaml"

  setup :register_and_log_in_user

  setup %{scope: scope} do
    %{path: workspace_path(scope, "/settings/workflows")}
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
    test "off: Workflows is not found, and the Harness page keeps its workflow choice", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      assert status(conn, path) == 404

      {:ok, view, _html} = live(conn, workspace_path(scope, "/settings/harness"))
      assert has_element?(view, "#workflow-form")
      refute has_element?(view, "#workflow-stages")
    end

    test "on: the Harness page keeps the harness, drops the workflow choice and links to Workflows",
         %{conn: conn, path: path, scope: scope} do
      {:ok, view, _html} = live(conn, workspace_path(scope, "/settings/harness"))
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

      assert has_element?(view, "#settings-section-title", "Workflows")

      assert has_element?(
               view,
               ~s(#settings-tab-workflows[href="#{path}"][aria-current="page"]),
               "Workflows"
             )

      assert has_element?(view, "#settings-tab-harness", "Harness")
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
               ~s(#stages-harness-open[href="#{workspace_path(scope, "/settings/harness")}"]),
               "Open Harness"
             )

      # The commit version 1 was copied from.
      assert has_element?(
               view,
               "#stages-harness",
               "commit #{String.slice(Apiary.QoryHarnessFixture.commit(), 0, 7)}"
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
               "description" => nil,
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
      machine_type_fixture(key: "large")
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

    test "the entries under Sequence, Inputs and Outputs sit in their box's body, apart from its heading",
         %{
           conn: conn,
           path: path
         } do
      {:ok, view, _html} = live(conn, path)

      # Shape has no workflow and no input: "No workflow" and "None" are in the bodies.
      select(view, "Shape")
      assert has_element?(view, "#stage-sequence > div > p", "No workflow")
      assert has_element?(view, "#stage-inputs > div > p", "None")

      # A workflow, a loop, an input and an output are in the bodies too.
      view |> element("#stage-add-entry") |> render_click()
      view |> element("#stage-add-loop") |> render_click()
      view |> element("#stage-add-inputs") |> render_click()
      view |> element("#stage-add-outputs") |> render_click()

      assert has_element?(view, "#stage-sequence > div > #stage-entry-0")
      assert has_element?(view, "#stage-sequence > div > #stage-loop-1")
      assert has_element?(view, "#stage-inputs > div > #stage-inputs-0")
      assert has_element?(view, "#stage-outputs > div > #stage-outputs-0")

      # The headings and the Add buttons stay in the box's header, outside the body.
      for key <- ~w(sequence inputs outputs) do
        assert has_element?(view, "#stage-#{key} > header h3")
        refute has_element?(view, "#stage-#{key} > div [id^=stage-add-]")
      end

      assert has_element?(view, "#stage-sequence > header #stage-add-entry")
      assert has_element?(view, "#stage-sequence > header #stage-add-loop")
      assert has_element?(view, "#stage-inputs > header #stage-add-inputs")
      assert has_element?(view, "#stage-outputs > header #stage-add-outputs")
    end

    test "keeps an entry's machine type default, shown as Default (Standard)", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      document =
        put_in(
          Processes.current(scope.workspace).document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          "default"
        )

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
      {:ok, view, _html} = live(conn, path)

      selected = "select#stage-entry-0-machine option[value=default][selected]"
      assert has_element?(view, selected, "Default (Standard)")

      assert has_element?(
               view,
               "select#stage-entry-0-machine option[value='']",
               "Workspace default (Standard)"
             )

      view
      |> form("#stage-form", stage: %{sequence: %{"0" => %{machine: "default"}}})
      |> render_change()

      assert has_element?(view, selected, "Default (Standard)")
    end

    test "edits a sequence: a workflow, a loop with its rounds, and a machine type", %{
      conn: conn,
      path: path
    } do
      machine_type_fixture(key: "large")
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
      assert has_element?(view, "select#stage-entry-0-machine option[value=large][selected]")

      # The machine help text, once, under the default machine type only, on Details.
      hint =
        "Workflows that pick no machine type run on this one. The people who run this Qory Apiary add machine types."

      refute has_element?(view, "#stage-panel", "Workflows that pick no machine type")
      details(view, path)
      assert has_element?(view, "#stages-process-form", hint)
      refute render(view) =~ "It does not choose the machine that runs it."
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
        "Choose another workflow for Build. To keep capture-demo, change the harness in Workspace settings › Harness to one that lists it under workflows. The Qory harness does not list capture-demo, so Build waits and starts no run."

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

      refute has_element?(view, "select#stage-entry-0-workflow")

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

    test "a stage's description: the form, the card, a save, and an empty field removes it", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, path)
      select(view, "Shape")

      assert has_element?(view, ~s(#stage-form label[for="stage-description"]), "Description")
      assert has_element?(view, ~s(textarea#stage-description[maxlength="500"]))
      refute has_element?(view, "#stage-description-hint")

      # A browser sends a textarea's line breaks as CRLF.
      view
      |> form("#stage-form",
        stage: %{description: "Turn the ticket into a plan.\r\nKeep it short."}
      )
      |> render_change()

      text = "Turn the ticket into a plan.\nKeep it short."
      assert card(view, "Shape")["description"] == text

      assert card(view, "Shape")["label"] =~
               "Shape. Turn the ticket into a plan.\nKeep it short. "

      assert card(view, "Explore")["description"] == nil
      assert has_element?(view, "textarea#stage-description", "Keep it short.")

      # More than 500 characters keeps the first 500.
      view
      |> form("#stage-form", stage: %{description: String.duplicate("a", 501)})
      |> render_change()

      assert card(view, "Shape")["description"] == String.duplicate("a", 500)

      # The cut counts code points, as the schema's maxLength does, and keeps whole
      # graphemes: "é" written as "e" and a combining accent is one grapheme of two.
      accent = "e\u0301"

      view
      |> form("#stage-form", stage: %{description: "a" <> String.duplicate(accent, 300)})
      |> render_change()

      cut = card(view, "Shape")["description"]
      assert cut == "a" <> String.duplicate(accent, 249)
      assert length(String.codepoints(cut)) == 499

      view |> form("#stage-form", stage: %{description: text}) |> render_change()
      view |> element("#stages-save") |> render_click()
      assert has_element?(view, "#stages-notice", "Saved as version 2.")

      assert Processes.stage(Processes.current(scope.workspace), id_of("Shape"))["description"] ==
               text

      # The page opened again shows the saved description.
      {:ok, view, _html} = live(conn, path)
      select(view, "Shape")
      assert card(view, "Shape")["description"] == text
      assert has_element?(view, "textarea#stage-description", "Keep it short.")

      view |> form("#stage-form", stage: %{description: "  \r\n "}) |> render_change()
      assert card(view, "Shape")["description"] == nil
      view |> element("#stages-save") |> render_click()
      assert has_element?(view, "#stages-notice", "Saved as version 3.")

      refute Map.has_key?(
               Processes.stage(Processes.current(scope.workspace), id_of("Shape")),
               "description"
             )
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
               "Commit this file to a harness repository. Workspaces that use that harness get it at their next update."
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

  describe "a refused save's banner, for a stage's sequence and lists" do
    defp save(view) do
      view |> element("#stages-save") |> render_click()

      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-save-error]")
      |> LazyHTML.text()
    end

    setup %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      %{view: view}
    end

    # A machine type that breaks the schema's pattern, as a stored document or a recovered
    # form can have it, at `sequence` of the stage: the picker offers no such value, and a
    # save of it is refused.
    defp bad_machine(view, stage, sequence) do
      render_hook(view, "edit_stage", %{
        "stage" => %{"id" => id_of(stage), "sequence" => sequence}
      })
    end

    test "a refused machine type: the banner points at the marked field", %{view: view} do
      bad_machine(view, "Explore", %{"0" => %{"machine" => "Gone"}})

      assert save(view) =~ "Explore: fix the fields marked below."
      assert has_element?(view, "#stage-entry-0 summary [data-machine-error]")
    end

    test "a default machine type removed since the page read the list is saved and kept", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      machine_type_fixture(key: "gone")
      {:ok, view, _html} = live(conn, path)
      remove_machine_types(~w(gone))
      details(view, path)
      view |> form("#stages-process-form", process: %{machine: "gone"}) |> render_change()

      assert save(view) == ""
      assert Processes.current(scope.workspace).document["machine"] == "gone"

      assert has_element?(
               view,
               "#stages-machine option[value=gone][selected]",
               "Default (Standard)"
             )
    end

    test "a refused machine type in a loop: the same", %{view: view} do
      view |> element("#stage-add-loop") |> render_click()

      bad_machine(view, "Explore", %{
        "0" => %{},
        "1" => %{"body" => %{"0" => %{"machine" => "Gone"}}}
      })

      assert save(view) =~ "Explore: fix the fields marked below."
      assert has_element?(view, "#stage-entry-1-0 summary [data-machine-error]")
    end

    test "a corrected machine type takes its stage's line away", %{view: view} do
      bad_machine(view, "Explore", %{"0" => %{"machine" => "Gone"}})

      assert save(view) =~ "Explore: fix the fields marked below."

      view
      |> form("#stage-form", stage: %{sequence: %{"0" => %{machine: "standard"}}})
      |> render_change()

      refute has_element?(view, "[data-machine-error]")
      refute has_element?(view, "[data-save-error]")

      # By value, as the row's mark is: the same value in an `edit_stage` event, as one sent
      # before the page's patch arrives, shows both again. The picker no longer offers it.
      render_hook(view, "edit_stage", %{
        "stage" => %{"id" => id_of("Explore"), "sequence" => %{"0" => %{"machine" => "Gone"}}}
      })

      assert has_element?(view, "[data-machine-error]")
      assert has_element?(view, "[data-save-error]", "Explore: fix the fields marked below.")
    end

    test "each stage with a mark has one line, with the stage's name today", %{view: view} do
      bad_machine(view, "Explore", %{"0" => %{"machine" => "Gone"}})
      select(view, "Build")
      view |> element("#stage-add-entry") |> render_click()
      bad_machine(view, "Build", %{"0" => %{"machine" => "Gone-too"}})

      banner = save(view)
      assert banner =~ "Explore: fix the fields marked below."
      assert banner =~ "Build: fix the fields marked below."

      view |> form("#stage-form", stage: %{name: "Plan"}) |> render_change()
      assert has_element?(view, "[data-save-error]", "Plan: fix the fields marked below.")
      refute has_element?(view, "[data-save-error]", "Build:")

      view
      |> form("#stage-form", stage: %{sequence: %{"0" => %{machine: ""}}})
      |> render_change()

      refute has_element?(view, "[data-save-error]", "Plan:")
      assert has_element?(view, "[data-save-error]", "Explore: fix the fields marked below.")
    end

    test "more than 20 workflows: no field to mark", %{view: view} do
      for _i <- 1..20, do: view |> element("#stage-add-entry") |> render_click()

      assert save(view) =~ "Explore: keep at most 20 entries in each list."
    end

    test "more than 20 inputs: no field to mark", %{view: view} do
      add = ~s(button[phx-click="add_artifact"][phx-value-key="inputs"])
      for _i <- 1..21, do: view |> element(add) |> render_click()

      assert save(view) =~ "Explore: keep at most 20 entries in each list."
    end

    test "more than 10 workflows in a loop: no field to mark", %{view: view} do
      view |> element("#stage-add-loop") |> render_click()

      for _i <- 1..10 do
        view |> element(~s(#stage-loop-1 button[phx-click="add_entry"])) |> render_click()
      end

      assert save(view) == "Explore: keep at most 10 workflows in a loop."
    end

    test "a loop of 10 workflows is saved", %{view: view} do
      view |> element("#stage-add-loop") |> render_click()

      for _i <- 1..9 do
        view |> element(~s(#stage-loop-1 button[phx-click="add_entry"])) |> render_click()
      end

      assert save(view) == ""
      assert has_element?(view, "#stages-notice")
    end

    test "a loop too long with a refused machine type: both lines", %{view: view} do
      view |> element("#stage-add-loop") |> render_click()

      for _i <- 1..10 do
        view |> element(~s(#stage-loop-1 button[phx-click="add_entry"])) |> render_click()
      end

      # A stored document or a recovered form can have a value that breaks the schema's pattern.
      # Validation fails on the loop first, so the instance's list is not read.
      body = Map.new(0..10, &{"#{&1}", if(&1 == 0, do: %{"machine" => "not valid"}, else: %{})})

      render_hook(view, "edit_stage", %{
        "stage" => %{
          "id" => id_of("Explore"),
          "sequence" => %{"0" => %{}, "1" => %{"body" => body}}
        }
      })

      banner = save(view)
      assert banner =~ "Explore: keep at most 10 workflows in a loop."
      assert banner =~ "Explore: fix the fields marked below."
    end

    test "a refusal selects the stage with the refused value, with another stage selected", %{
      view: view
    } do
      inputs = ~s(button[phx-click="add_artifact"][phx-value-key="inputs"])
      for _i <- 1..21, do: view |> element(inputs) |> render_click()
      select(view, "Build")

      assert save(view) == "Explore: keep at most 20 entries in each list."
      assert canvas_view(view)["selected"] == id_of("Explore")
    end

    test "a refusal keeps the selected stage if the refused value is in it", %{view: view} do
      bad_machine(view, "Explore", %{"0" => %{"machine" => "Gone"}})
      select(view, "Build")
      view |> element("#stage-add-entry") |> render_click()
      bad_machine(view, "Build", %{"0" => %{"machine" => "Gone-too"}})

      assert save(view) =~ "Build: fix the fields marked below."
      assert canvas_view(view)["selected"] == id_of("Build")
      assert has_element?(view, ~s{#stage-entry-0 summary [data-machine-error]})
    end

    # Explore and Build saved with a row at place 0 and a loop at place 1, then a bad workflow
    # name and bad rounds typed on Build. Explore, selected after `load/2`, has valid values
    # at both places.
    defp bad_values_on_build(view) do
      view |> element("#stage-add-loop") |> render_click()
      select(view, "Build")
      view |> element("#stage-add-entry") |> render_click()
      view |> element("#stage-add-loop") |> render_click()
      save(view)
      select(view, "Build")

      view
      |> form("#stage-form",
        stage: %{
          name: "Assemble",
          sequence: %{"0" => %{workflow: "Bad_Name"}, "1" => %{rounds: "40"}}
        }
      )
      |> render_change()

      assert has_element?(view, "#stage-loop-1", "Give the loop 1 to 10 rounds.")
      assert has_element?(view, "#stage-panel", "Write a workflow name")
    end

    defp no_errors_by_place_on_explore(view) do
      assert canvas_view(view)["selected"] == id_of("Explore")
      assert has_element?(view, "#stage-loop-1")
      refute has_element?(view, "#stage-loop-1", "Give the loop 1 to 10 rounds.")
      refute has_element?(view, "#stage-panel", "Write a workflow name")
    end

    test "a successful save drops the errors by place", %{view: view} do
      bad_values_on_build(view)
      assert save(view) == ""
      assert has_element?(view, "#stages-notice")
      no_errors_by_place_on_explore(view)
    end

    test "Discard drops the errors by place", %{view: view} do
      bad_values_on_build(view)
      view |> element("#stages-discard") |> render_click()
      no_errors_by_place_on_explore(view)
    end

    test "a refusal that selects another stage drops the errors by place", %{view: view} do
      bad_machine(view, "Explore", %{"0" => %{"machine" => "Gone"}})

      view |> element("#stage-add-loop") |> render_click()

      select(view, "Build")
      view |> element("#stage-add-entry") |> render_click()
      view |> element("#stage-add-loop") |> render_click()

      view
      |> form("#stage-form", stage: %{sequence: %{"1" => %{rounds: "40"}}})
      |> render_change()

      assert has_element?(view, "#stage-loop-1", "Give the loop 1 to 10 rounds.")

      save(view)

      assert canvas_view(view)["selected"] == id_of("Explore")
      refute has_element?(view, "#stage-loop-1", "Give the loop 1 to 10 rounds.")
    end
  end

  describe "a form's values after a reconnect" do
    # A reconnect mounts the page with the first stage selected, then LiveView's form recovery
    # sends the form as it stood. These tests send that event with Explore selected.
    setup %{conn: conn, path: path} do
      machine_type_fixture(key: "gpu-large")
      {:ok, view, _html} = live(conn, path)
      %{view: view}
    end

    test "go to the stage in the form's id, which becomes the selected stage", %{view: view} do
      before = canvas_view(view)["stages"]
      assert canvas_view(view)["selected"] == id_of("Explore")

      render_hook(view, "edit_stage", %{
        "stage" => %{"id" => id_of("Release"), "name" => "Ship"}
      })

      assert names(view) ==
               Enum.map(before, &if(&1["name"] == "Release", do: "Ship", else: &1["name"]))

      assert ids(view) == Enum.map(before, & &1["id"])
      assert canvas_view(view)["selected"] == id_of("Release")
      assert has_element?(view, "#stage-panel-title", "Edit Ship")
      assert has_element?(view, ~s(#stage-form-id[value="#{id_of("Release")}"]))
      assert card(view, "Explore")["sequence"] == Enum.at(before, 0)["sequence"]
    end

    # Saves Build with `rows`, the form's values for the rows that `make` adds with the buttons,
    # and returns a new page on the saved version, as after a reconnect.
    defp saved_build(view, conn, path, make, rows) do
      select(view, "Build")
      make.(view)
      view |> form("#stage-form", stage: rows) |> render_change()
      save(view)
      {:ok, page, _html} = live(conn, path)
      page
    end

    defp add(view, selector), do: view |> element(selector) |> render_click()

    defp recover(page, form) do
      id = card(page, "Build")["id"]

      render_hook(page, "edit_stage", %{
        "stage" => Map.merge(%{"id" => id, "name" => "Build"}, form)
      })
    end

    test "after an unsaved Remove, the stage's rows stay", %{view: view, conn: conn, path: path} do
      page =
        saved_build(
          view,
          conn,
          path,
          fn view ->
            add(view, "#stage-add-entry")
            add(view, "#stage-add-entry")
          end,
          %{
            sequence: %{
              "0" => %{workflow: "review-notes"},
              "1" => %{workflow: "check-links", machine: "gpu-large"}
            }
          }
        )

      recover(page, %{
        "sequence" => %{"0" => %{"workflow" => "check-links", "machine" => "gpu-large"}}
      })

      assert card(page, "Build")["sequence"] == [
               %{"workflow" => "review-notes"},
               %{"workflow" => "check-links"}
             ]

      refute has_element?(page, ~s(#stage-entry-0-machine option[value="gpu-large"][selected]))
      assert has_element?(page, ~s(#stage-entry-1-machine option[value="gpu-large"][selected]))
    end

    test "after an unsaved Remove loop, the stage's rows stay", %{
      view: view,
      conn: conn,
      path: path
    } do
      page =
        saved_build(
          view,
          conn,
          path,
          fn view ->
            add(view, "#stage-add-entry")
            add(view, "#stage-add-loop")
            add(view, ~s(#stage-loop-1 button[phx-click="add_entry"]))
            add(view, "#stage-add-entry")
          end,
          %{
            sequence: %{
              "0" => %{workflow: "first-step"},
              "1" => %{body: %{"0" => %{workflow: "loop-a"}, "1" => %{workflow: "loop-b"}}},
              "2" => %{workflow: "last-step"}
            }
          }
        )

      saved = card(page, "Build")["sequence"]
      assert List.last(saved) == %{"workflow" => "last-step"}

      recover(page, %{
        "sequence" => %{
          "0" => %{"workflow" => "first-step"},
          "1" => %{"workflow" => "loop-a", "rounds" => "99"},
          "2" => %{"workflow" => "loop-b"},
          "3" => %{"workflow" => "last-step"}
        }
      })

      assert card(page, "Build")["sequence"] == saved
      refute has_element?(page, "#stage-loop-1", "Give the loop 1 to 10 rounds.")
    end

    test "after an unsaved Remove on inputs or outputs, those rows stay", %{
      view: view,
      conn: conn,
      path: path
    } do
      inputs = ~s(button[phx-click="add_artifact"][phx-value-key="inputs"])

      page =
        saved_build(
          view,
          conn,
          path,
          fn view ->
            add(view, inputs)
            add(view, inputs)
          end,
          %{}
        )

      select(page, "Build")
      rows = page |> element("#stage-inputs") |> render()
      assert rows =~ ~s(id="stage-inputs-1-required")

      recover(page, %{"inputs" => %{"0" => %{"required" => "false"}}})

      assert page |> element("#stage-inputs") |> render() == rows
    end

    test "on rows of the same shape, the form's values replace the stage's", %{
      view: view,
      conn: conn,
      path: path
    } do
      page =
        saved_build(view, conn, path, &add(&1, "#stage-add-entry"), %{
          sequence: %{"0" => %{workflow: "review-notes"}}
        })

      recover(page, %{
        "name" => "Ship",
        "sequence" => %{"0" => %{"workflow" => "check-links", "machine" => "gpu-large"}}
      })

      assert card(page, "Ship")["sequence"] == [%{"workflow" => "check-links"}]
      assert has_element?(page, ~s(#stage-entry-0-machine option[value="gpu-large"][selected]))
    end

    test "after an unsaved Remove, the name still goes to the stage", %{
      view: view,
      conn: conn,
      path: path
    } do
      page =
        saved_build(
          view,
          conn,
          path,
          fn view ->
            add(view, "#stage-add-entry")
            add(view, "#stage-add-entry")
          end,
          %{sequence: %{"0" => %{workflow: "review-notes"}, "1" => %{workflow: "check-links"}}}
        )

      recover(page, %{"name" => "Ship", "sequence" => %{"0" => %{"workflow" => "check-links"}}})

      assert card(page, "Ship")["sequence"] == [
               %{"workflow" => "review-notes"},
               %{"workflow" => "check-links"}
             ]
    end

    test "are ignored without a stage of that id in the draft", %{view: view} do
      before = names(view)

      for params <- [%{"id" => "st_0000000000", "name" => "Ship"}, %{"name" => "Ship"}] do
        render_hook(view, "edit_stage", %{"stage" => params})
        assert names(view) == before
        assert canvas_view(view)["selected"] == id_of("Explore")
      end
    end
  end

  describe "the stage form's boxes and folds" do
    # Build, with a workflow, then a loop of the workflows `names`.
    defp build_with_loop(view, names) do
      select(view, "Build")
      view |> element("#stage-add-entry") |> render_click()
      view |> element("#stage-add-loop") |> render_click()

      for _name <- tl(names) do
        view |> element(~s(#stage-loop-1 button[phx-click="add_entry"])) |> render_click()
      end

      body = names |> Enum.with_index() |> Map.new(fn {n, j} -> {"#{j}", %{workflow: n}} end)
      view |> form("#stage-form", stage: %{sequence: %{"1" => %{body: body}}}) |> render_change()
    end

    defp offsets(html, markers), do: Enum.map(markers, &(:binary.match(html, &1) |> elem(0)))

    defp fold(view, entry) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s{details[id^="#{entry}-settings-"]})
    end

    test "the boxes come in the order a stage works, each with a heading under the panel's", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      form_html = view |> element("#stage-form") |> render()

      inputs_sequence_outputs_gate = ~w(id="stage-inputs" id="stage-sequence"
                                        id="stage-outputs" id="stage-gate")

      assert offsets(form_html, ["id=\"stage-name\"" | inputs_sequence_outputs_gate]) ==
               Enum.sort(offsets(form_html, ["id=\"stage-name\"" | inputs_sequence_outputs_gate]))

      for {box, title} <- [
            {"inputs", "Inputs"},
            {"sequence", "Sequence"},
            {"outputs", "Outputs"},
            {"gate", "Gate"}
          ] do
        assert has_element?(view, "section#stage-#{box}.q-sect-side > header h3", title)
      end

      # Each Add sits on the heading row of its box, and the gate's choices stay a group.
      assert has_element?(view, "#stage-inputs > header #stage-add-inputs")
      assert has_element?(view, "#stage-sequence > header #stage-add-entry")
      assert has_element?(view, "#stage-sequence > header #stage-add-loop")
      assert has_element?(view, "#stage-outputs > header #stage-add-outputs")
      assert has_element?(view, "#stage-gate fieldset > legend.sr-only", "Gate")
      refute has_element?(view, "#stage-panel [role=dialog]")
      refute has_element?(view, "#stage-panel dialog")
    end

    test "a row's fold starts closed in a native summary, with Change and Close for each state",
         %{
           conn: conn,
           path: path
         } do
      {:ok, view, _html} = live(conn, path)
      explore = id_of("Explore")
      details = ~s{details#stage-entry-0-settings-#{explore}}

      # Closed, and the fold's id includes the stage's, so an open state stays with its stage.
      assert has_element?(view, details <> ".q-tool.group:not([open])")

      assert has_element?(
               view,
               details <> " > summary",
               "Machine type: Workspace default (Standard)"
             )

      # The summary is the control: native, so a key and a tap work, with no hover. Each word
      # shows in one state only.
      assert has_element?(view, details <> " > summary .group-open\\:hidden", "Change")
      assert has_element?(view, details <> " > summary .hidden.group-open\\:inline", "Close")

      # The canvas's pan key is Space. Without this class, Space did nothing in a browser.
      assert has_element?(view, details <> " > summary.nokey")

      # A patch leaves `open` as the browser has it, so a change elsewhere keeps a row open.
      assert fold(view, "stage-entry-0") |> LazyHTML.attribute("phx-mounted") |> hd() =~
               "ignore_attrs"

      # Inside the fold: the field and the words for the check.
      assert has_element?(view, details <> " #stage-entry-0-machine")
      assert has_element?(view, details <> ~s{ [data-mark="listed"]}, "A stage can run it")

      # On the row, the check alone, with its words for a screen reader and as a title. A
      # phone reaches the words by opening the row.
      assert has_element?(
               view,
               ~s{#stage-entry-0-workflow-mark[data-mark="listed"][title="A stage can run it"] .sr-only},
               "A stage can run it"
             )

      refute has_element?(view, details <> " #stage-entry-0-workflow-mark")

      # Another stage has other folds.
      select(view, "Build")
      view |> element("#stage-add-entry") |> render_click()
      refute has_element?(view, details)
      assert has_element?(view, ~s{details#stage-entry-0-settings-#{id_of("Build")}})
    end

    test "a row's fold has the picker: the default, then the instance's types", %{
      conn: conn,
      path: path
    } do
      machine_type_fixture(key: "large")
      {:ok, view, _html} = live(conn, path)
      picker = ~s{details[id^="stage-entry-0-settings-"] select#stage-entry-0-machine}

      assert has_element?(view, picker <> " option[value='']", "Workspace default (Standard)")
      assert has_element?(view, picker <> " option[value=standard]", "Standard: 2 vCPUs, 4 GiB")
      assert has_element?(view, picker <> " option[value=large]", "Large: 4 vCPUs, 16 GiB")
    end

    test "a key no machine type has: the notice beside the picker, the line when closed", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      # A new instance has the type browser; this one has none.
      remove_machine_types(["browser"])
      version = Processes.current(scope.workspace)

      document =
        put_in(
          version.document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          "browser"
        )

      version |> Ecto.Changeset.change(document: document) |> Repo.update!()
      [%{"workflow" => workflow} | _rest] = hd(document["stages"])["sequence"]
      {:ok, view, _html} = live(conn, path)
      summary = ~s{details[id^="stage-entry-0-settings-"] > summary}

      assert has_element?(view, summary, "Machine type: Workspace default (Standard)")
      assert has_element?(view, summary, "Pick a machine type: no type has the key browser.")

      assert view
             |> element("#stage-entry-0-missing")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text()
             |> String.split()
             |> Enum.join(" ") ==
               "Pick a machine type for #{workflow}. The process.yaml this workspace was made from sets machine: browser, and this Qory Apiary has no machine type with the key browser. Until you pick one, runs of #{workflow} start on the default type, Standard."

      # The picker keeps the key, with the words of the type the runs start on.
      assert has_element?(
               view,
               "#stage-entry-0-machine option[value=browser][selected]",
               "Workspace default (Standard)"
             )

      # A save keeps the key; a type with the key ends the notice.
      view |> form("#stage-form", stage: %{name: "Explore two"}) |> render_change()
      view |> element("#stages-save") |> render_click()
      assert has_element?(view, "#stages-notice")
      assert has_element?(view, "#stage-entry-0-missing")

      machine_type_fixture(key: "browser", name: "Browser tests")
      {:ok, view, _html} = live(conn, path)
      refute has_element?(view, "#stage-entry-0-missing")
      assert has_element?(view, summary, "Machine type: Browser tests")
    end

    test "the closed line shows the row's machine type, else the stage's default", %{
      conn: conn,
      path: path
    } do
      machine_type_fixture(key: "large")
      machine_type_fixture(key: "medium")
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#stage-form", stage: %{sequence: %{"0" => %{machine: "large"}}})
      |> render_change()

      assert has_element?(
               view,
               ~s{details[id^="stage-entry-0-settings-"] > summary},
               "Machine type: Large"
             )

      view
      |> form("#stage-form", stage: %{sequence: %{"0" => %{machine: ""}}})
      |> render_change()

      assert has_element?(
               view,
               ~s{details[id^="stage-entry-0-settings-"] > summary},
               "Machine type: Workspace default (Standard)"
             )

      details(view, path)
      view |> form("#stages-process-form", process: %{machine: "medium"}) |> render_change()
      stages_tab(view, path)

      assert has_element?(
               view,
               ~s{details[id^="stage-entry-0-settings-"] > summary},
               "Machine type: Workspace default (Medium)"
             )
    end

    test "a type of 64 characters beside an empty stage name has no mark", %{
      conn: conn,
      path: path
    } do
      long = String.duplicate("a", 64)
      machine_type_fixture(key: long)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#stage-form", stage: %{name: "", sequence: %{"0" => %{machine: long}}})
      |> render_change()

      view |> element("#stages-save") |> render_click()

      assert has_element?(view, "#stage-panel", "Give every stage a name")
      refute has_element?(view, "[data-machine-error]")
    end

    test "a stored type that breaks the schema's pattern is marked on its closed row", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      version = Processes.current(scope.workspace)

      document =
        put_in(
          version.document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          "gpu.large"
        )

      version |> Ecto.Changeset.change(document: document) |> Repo.update!()
      {:ok, view, _html} = live(conn, path)

      view |> form("#stage-form", stage: %{name: "Explore two"}) |> render_change()
      view |> element("#stages-save") |> render_click()

      assert has_element?(view, "[data-save-error]", "Explore two: fix the fields marked below.")
      refute has_element?(view, "[data-save-error]", "a value is not valid")

      assert has_element?(
               view,
               ~s{details[id^="stage-entry-0-settings-"]:not([open]) > summary [data-machine-error]},
               "Choose a machine type from the list."
             )
    end

    test "a default picked on a document with no machine stays in the draft", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      machine_type_fixture(key: "large")

      document =
        scope.workspace
        |> Processes.current()
        |> Map.fetch!(:document)
        |> Map.delete("machine")
        |> put_in(["stages", Access.at(0), "description"], "No default machine type.")

      {:ok, version} = Processes.save(scope, scope.workspace, document)
      refute Map.has_key?(version.document, "machine")

      {:ok, view, _html} = live(conn, path)
      details(view, path)
      view |> form("#stages-process-form", process: %{machine: "large"}) |> render_change()

      assert has_element?(view, "#stages-machine option[value=large][selected]")
    end

    test "after a save the picker keeps a removed type only on the row that has it", %{
      conn: conn,
      path: path
    } do
      machine_type_fixture(key: "gone")
      {:ok, view, _html} = live(conn, path)
      remove_machine_types(~w(gone))
      view |> element("#stage-add-entry") |> render_click()

      view
      |> form("#stage-form", stage: %{sequence: %{"0" => %{machine: "gone"}}})
      |> render_change()

      view |> element("#stages-save") |> render_click()
      assert has_element?(view, "#stages-notice")

      assert has_element?(
               view,
               "#stage-entry-0-machine option[value=gone][selected]",
               "Workspace default (Standard)"
             )

      assert has_element?(view, "#stage-entry-1-machine")
      refute has_element?(view, "#stage-entry-1-machine option[value=gone]")

      view
      |> form("#stage-form", stage: %{sequence: %{"0" => %{machine: "standard"}}})
      |> render_change()

      refute has_element?(view, "#stage-entry-0-machine option[value=gone]")
    end

    test "a refused machine type shows on a closed row and at its field, until the value changes",
         %{conn: conn, path: path} do
      machine_type_fixture(key: "large")
      {:ok, view, _html} = live(conn, path)
      build_with_loop(view, ~w(explore-a-ticket explore-a-ticket))
      error = "Choose a machine type from the list."

      # A value that breaks the schema's pattern, as a recovered form can have it.
      render_hook(view, "edit_stage", %{
        "stage" => %{
          "id" => id_of("Build"),
          "sequence" => %{
            "0" => %{},
            "1" => %{"body" => %{"0" => %{}, "1" => %{"machine" => "Gone"}}}
          }
        }
      })

      # Before a save, as before: the form takes the value.
      refute has_element?(view, "[data-machine-error]")

      view |> element("#stages-save") |> render_click()

      # Above the canvas, as before, and on the summary line, which a closed fold shows.
      assert has_element?(view, "[data-save-error]")

      assert has_element?(
               view,
               ~s{details[id^="stage-entry-1-1-settings-"]:not([open]) > summary [data-machine-error]},
               error
             )

      # At the field, for an open fold.
      assert has_element?(view, ~s(#stage-entry-1-1-machine[aria-invalid="true"]))
      assert has_element?(view, "#stage-entry-1-1-machine-error", error)

      # On no other row.
      refute has_element?(view, ~s{details[id^="stage-entry-1-0-settings-"] [data-machine-error]})
      refute has_element?(view, ~s{details[id^="stage-entry-0-settings-"] [data-machine-error]})

      # A change of the value ends the row's error.
      view
      |> form("#stage-form", stage: %{sequence: %{"1" => %{body: %{"1" => %{machine: "large"}}}}})
      |> render_change()

      refute has_element?(view, "[data-machine-error]")
      refute has_element?(view, "#stage-entry-1-1-machine-error")
    end

    test "a machine type shows as refused only after a save refused it, on any stage", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)

      render_hook(view, "edit_stage", %{
        "stage" => %{"id" => id_of("Explore"), "sequence" => %{"0" => %{"machine" => "Gone"}}}
      })

      select(view, "Build")
      view |> element("#stage-add-entry") |> render_click()
      view |> element("#stages-save") |> render_click()

      # The selected stage, Build, has no such row, so the stage that has one is selected.
      assert canvas_view(view)["selected"] == id_of("Explore")
      assert has_element?(view, ~s{#stage-entry-0 summary [data-machine-error]})

      # Discard forgets the refused value: the same value in an `edit_stage` event, as one sent
      # before the page's patch arrives, shows nothing before a save.
      view |> element("#stages-discard") |> render_click()

      render_hook(view, "edit_stage", %{
        "stage" => %{"id" => id_of("Explore"), "sequence" => %{"0" => %{"machine" => "Gone"}}}
      })

      refute has_element?(view, "[data-machine-error]")
    end

    test "errors on the fields of a row stay visible: a workflow's name and a loop's rounds", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      build_with_loop(view, ~w(explore-a-ticket explore-a-ticket))

      view
      |> form("#stage-form",
        stage: %{
          sequence: %{
            "0" => %{workflow: "Not Valid"},
            "1" => %{rounds: "40", body: %{"0" => %{workflow: "Not Valid"}}}
          }
        }
      )
      |> render_change()

      # Outside any fold.
      assert has_element?(view, "#stage-entry-0 > div:first-child", "Write a workflow name")
      assert has_element?(view, "#stage-entry-1-0 > div:first-child", "Write a workflow name")
      assert has_element?(view, "#stage-loop-1 .q-stage-rounds", "Give the loop 1 to 10 rounds.")
    end

    test "every field of the form reaches the saved document", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      for name <- ~w(small medium large), do: machine_type_fixture(key: name)
      {:ok, view, _html} = live(conn, path)
      build_with_loop(view, ~w(explore-a-ticket explore-a-ticket))
      view |> element("#stage-add-inputs") |> render_click()
      view |> element("#stage-add-outputs") |> render_click()

      [type | _rest] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#stage-outputs-0-type option")
        |> LazyHTML.attribute("value")

      view
      |> form("#stage-form",
        stage: %{
          name: "Make",
          sequence: %{
            "0" => %{workflow: "explore-a-ticket", machine: "small"},
            "1" => %{
              rounds: "5",
              body: %{
                "0" => %{machine: "medium"},
                "1" => %{workflow: "explore-a-ticket", machine: "large"}
              }
            }
          },
          inputs: %{"0" => %{type: type, required: "false"}},
          outputs: %{"0" => %{type: type, required: "true"}},
          gate: %{kind: "none"}
        }
      )
      |> render_change()

      assert has_element?(view, "#stages-dirty", "Unsaved changes")
      view |> element("#stages-save") |> render_click()
      assert has_element?(view, "#stages-notice", "Saved as version 2.")

      saved = Processes.current(scope.workspace).document
      stage = Enum.find(saved["stages"], &(&1["name"] == "Make"))

      assert stage["sequence"] == [
               %{"workflow" => "explore-a-ticket", "machine" => "small"},
               %{
                 "loop" => %{
                   "rounds" => 5,
                   "body" => [
                     %{"workflow" => "explore-a-ticket", "machine" => "medium"},
                     %{"workflow" => "explore-a-ticket", "machine" => "large"}
                   ]
                 }
               }
             ]

      assert [%{"type" => ^type, "required" => false}] = stage["inputs"]
      assert [%{"type" => ^type, "required" => true}] = stage["outputs"]
      assert stage["gate"]["kind"] == "none"

      # The form adds no image field, at any level of the document or on the page.
      refute saved |> Jason.encode!() |> String.contains?("image")
      select(view, "Make")
      html = view |> element("#stage-panel") |> render()
      refute html =~ "[image]"
      refute html =~ "Browser image"
    end

    test "one workflow has one row, with one fold and Remove", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "#stage-entry-0")
      refute has_element?(view, "#stage-entry-1")
      refute has_element?(view, "#stage-entry-0.border-t")
      assert fold(view, "stage-entry-0") |> Enum.count() == 1
      assert has_element?(view, ~s(#stage-entry-0 button[phx-click="remove_entry"]), "Remove")

      # The field keeps its name for a screen reader, with no visible label.
      assert has_element?(view, ~s(#stage-entry-0-workflow[aria-label="Workflow"]))
      refute has_element?(view, ~s(#stage-entry-0 label[for="stage-entry-0-workflow"]))
    end

    test "a loop of several: a row and a fold each, and adding and removing keep working", %{
      conn: conn,
      path: path
    } do
      machine_type_fixture(key: "large")
      {:ok, view, _html} = live(conn, path)
      build_with_loop(view, ~w(explore-a-ticket explore-a-ticket explore-a-ticket))

      for j <- 0..2 do
        assert fold(view, "stage-entry-1-#{j}") |> Enum.count() == 1

        assert has_element?(
                 view,
                 ~s(#stage-loop-1 #stage-entry-1-#{j} button[phx-click="remove_entry"])
               )
      end

      refute has_element?(view, "#stage-entry-1-0.border-t")
      assert has_element?(view, "#stage-entry-1-1.border-t")

      # A picked machine type stays through an add, and a remove moves its row up.
      view
      |> form("#stage-form", stage: %{sequence: %{"1" => %{body: %{"2" => %{machine: "large"}}}}})
      |> render_change()

      view |> element(~s(#stage-loop-1 button[phx-click="add_entry"])) |> render_click()
      assert has_element?(view, "#stage-entry-1-2-machine option[value=large][selected]")
      assert has_element?(view, "#stage-entry-1-3")

      view
      |> element(~s(#stage-entry-1-0 button[phx-click="remove_entry"]))
      |> render_click()

      assert has_element?(view, "#stage-entry-1-1-machine option[value=large][selected]")
      refute has_element?(view, "#stage-entry-1-3")

      for j <- [1, 1] do
        view
        |> element(~s(#stage-entry-1-#{j} button[phx-click="remove_entry"]))
        |> render_click()
      end

      # A loop of one shows no Remove on its row. Remove loop keeps the workflow.
      refute has_element?(view, ~s(#stage-entry-1-0 button[phx-click="remove_entry"]))
      view |> element(~s(#stage-loop-1 button[phx-click="remove_loop"])) |> render_click()
      refute has_element?(view, "#stage-loop-1")
      assert has_element?(view, "#stage-entry-1")
      assert has_element?(view, "#stage-entry-1.border-t")
    end

    test "a workflow that the harness does not list keeps its words on the row", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#stage-form", stage: %{sequence: %{"0" => %{workflow: "not-in-the-list"}}})
      |> render_change()

      assert has_element?(
               view,
               ~s{#stage-entry-0 > div:first-child [data-mark="missing"].w-full},
               "Not in the harness"
             )

      refute has_element?(view, ~s{#stage-entry-0-workflow-mark .sr-only})
      refute has_element?(view, ~s{details[id^="stage-entry-0-settings-"] [data-mark]})
    end

    test "a stage with no workflow shows No workflow, and offers the Add buttons", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      select(view, "Build")

      assert has_element?(view, "#stage-sequence", "No workflow")
      assert has_element?(view, "#stage-sequence #stage-add-entry")
      refute has_element?(view, "#stage-sequence details")
    end
  end

  describe "a member's panel" do
    setup %{scope: scope} do
      %{user: user} = member_fixture(scope)
      %{member: log_in_user(build_conn(), user)}
    end

    test "has the same four boxes in the same order, with no field", %{member: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      html = view |> element("#stage-panel") |> render()

      markers = ~w(id="stage-inputs" id="stage-sequence" id="stage-outputs" id="stage-gate")
      assert offsets(html, markers) == Enum.sort(offsets(html, markers))

      for {box, title} <- [
            {"inputs", "Inputs"},
            {"sequence", "Sequence"},
            {"outputs", "Outputs"},
            {"gate", "Gate"}
          ] do
        assert has_element?(view, "section#stage-#{box}.q-sect-side > header h3", title)
      end

      assert has_element?(
               view,
               "#stage-sequence li",
               "explore-a-ticket, machine type Workspace default (Standard)"
             )

      assert has_element?(view, "#stage-gate", "A member approves")
      refute has_element?(view, "#stage-panel input")
      refute has_element?(view, "#stage-panel select")
      refute has_element?(view, "#stage-panel details")
      refute has_element?(view, "#stage-panel button")
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

      # The sidebar's Workflows entry, for a member too, with no Harness entry.
      assert has_element?(view, ~s(#settings-tab-workflows[href="#{path}"][aria-current="page"]))
      refute has_element?(view, "#settings-tab-harness")

      details(view, path)
      assert has_element?(view, "#stages-harness", "Harness: Qory harness, stack software")
      refute has_element?(view, "#stages-harness-open")

      assert has_element?(
               view,
               "#stages-machine-read",
               "Default machine type: Default (Standard)"
             )

      for selector <- ~w(#stages-process-form #stages-trial #stages-save) do
        refute has_element?(view, selector), selector
      end

      stages_tab(view, path)

      assert names(view) == ~w(Explore Shape Build Verify Release)
      refute canvas_view(view)["editable"]
      # Focus, for a member too.
      assert canvas_data(view, "data-words")["focus"] == "Focus"
      assert has_element?(view, "#stage-panel-title", "Explore")

      assert has_element?(
               view,
               "#stage-panel",
               "explore-a-ticket, machine type Workspace default (Standard)"
             )

      assert has_element?(view, "#stages-version", "Version 1, current.")
      refute has_element?(view, "#stages-version", "Editing")
      assert has_element?(view, "#stage-gate", "A member approves")
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

    test "reads a stage's description in full, with its line breaks; a stage without one has no row",
         %{member: conn, path: path, scope: scope} do
      text = "Turn the proposal into a plan for the storefront.\nA member checks the plan."
      document = Processes.default_document("software")

      stages =
        Enum.map(document["stages"], fn
          %{"name" => "Shape"} = stage -> Map.put(stage, "description", text)
          stage -> stage
        end)

      {:ok, _version} = Processes.save(scope, scope.workspace, %{document | "stages" => stages})
      {:ok, view, _html} = live(conn, path)

      # Explore, first and selected, has none.
      assert has_element?(view, "#stage-panel-title", "Explore")
      refute has_element?(view, "#stage-panel-description")
      refute has_element?(view, "#stage-panel dt", "Description")

      select(view, "Shape")
      assert has_element?(view, "#stage-panel dt", "Description")

      [row] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#stage-panel-description.whitespace-pre-line")
        |> Enum.to_list()

      # The whole text, its line break kept, with no white space around it.
      assert LazyHTML.text(row) == text
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

  describe "Make current of a trial from the harness" do
    # A trial saved from the Qory harness at a commit whose template has the stack core.
    setup %{scope: scope} do
      files =
        Map.update!(Apiary.QoryHarnessFixture.files(), @harness_process, fn process ->
          String.replace(process, "stack: software\n", "stack: core\n", global: false)
        end)

      Apiary.QoryHarnessFixture.serve!(files)
      {:ok, _commit} = Apiary.Harnesses.Qory.read({:branch, "main"})
      {:ok, update} = Apiary.Processes.HarnessUpdate.read(scope, scope.workspace)

      {:ok, trial} =
        Apiary.Processes.HarnessUpdate.save(scope, scope.workspace, update, trial: true)

      %{trial: trial}
    end

    test "with a stack for the shared harness says to change that stack", ctx do
      Apiary.Stacks.put_stack(
        ctx.scope,
        {:organisation, ctx.scope.organisation},
        ~s(extends:\n  git: "#{Apiary.Harnesses.Qory.git()}"\n  ref: "main"\n  stack: "software"\n),
        choice: :qory,
        version: {:branch, "main"}
      )

      {:ok, view, _html} = live(ctx.conn, ctx.path)
      details(view, ctx.path)
      view |> element("#stages-make-current") |> render_click()

      assert has_element?(
               view,
               "[data-save-error]",
               "Change the stack of the harness your organisation shares, then press Make current again. Every workspace that takes that harness uses its stack."
             )

      assert %{status: :trial} = Repo.reload!(ctx.trial)
    end

    test "after the harness choice changed says to press Update from harness again", ctx do
      {:ok, view, _html} = live(ctx.conn, ctx.path)
      details(view, ctx.path)

      Repo.insert!(%Apiary.Stacks.Stack{
        organisation_id: ctx.scope.organisation.id,
        workspace_id: ctx.scope.workspace.id,
        harness: "extends:\n  git: https://code.example.com/acme/harness\n  stack: web\n",
        choice: :repository,
        version_kind: :branch,
        version_name: "main"
      })

      view |> element("#stages-make-current") |> render_click()

      assert has_element?(
               view,
               "[data-save-error]",
               "Press Update from harness again. The harness choice changed after you opened this difference."
             )

      assert %{status: :trial} = Repo.reload!(ctx.trial)
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

  describe "a workspace on a tag of the Qory harness, with no workflows of its stack" do
    test "a new entry starts with the first name of the tag, not of main", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      files =
        Map.update!(
          Apiary.QoryHarnessFixture.files(),
          "stacks/software/qory-stack.yaml",
          fn stack ->
            String.replace(
              stack,
              "  explore-a-ticket: {access: read}\n",
              "  chart-a-ticket: {access: read}\n  explore-a-ticket: {access: read}\n"
            )
          end
        )

      Apiary.QoryHarnessFixture.serve!(files, tags: ["v1.0.0"])
      {:ok, _commit} = Apiary.Harnesses.Qory.read({:tag, "v1.0.0"})

      # A choice of the tag whose document has no stack: the page lists no workflow of it.
      Repo.insert!(%Apiary.Stacks.Stack{
        organisation_id: scope.workspace.organisation_id,
        workspace_id: scope.workspace.id,
        choice: :qory,
        version_kind: :tag,
        version_name: "v1.0.0",
        harness: "extends:\n  git: #{Apiary.Harnesses.Qory.git()}\n  ref: v1.0.0\n"
      })

      :ok = Processes.record_declared(scope.workspace, [])
      assert Processes.declared_workflows(scope.workspace) == []

      {:ok, view, _html} = live(conn, path)
      render_async(view, 5_000)
      select(view, "Shape")

      view |> element("#stage-add-entry") |> render_click()

      assert card(view, "Shape")["sequence"] == [%{"workflow" => "chart-a-ticket"}]
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

      for refused <- ["Triage", "triage bugs", "-triage", "", String.duplicate("a", 56)] do
        view
        |> form("#stage-form", stage: %{sequence: %{"0" => %{workflow: refused}}})
        |> render_change()

        assert hd(card(view, "Build")["sequence"]) == %{"workflow" => "triage-bugs"}, refused

        assert has_element?(
                 view,
                 "#stage-entry-0",
                 "Write a workflow name of lower-case letters, digits and hyphens that starts with a letter, at most 55 characters."
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

      # A name of 55 characters, the most a workflow name has, is the entry's workflow.
      longest = "triage-" <> String.duplicate("a", 48)

      view
      |> form("#stage-form", stage: %{sequence: %{"0" => %{workflow: longest}}})
      |> render_change()

      assert hd(card(view, "Build")["sequence"]) == %{"workflow" => longest}

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

      assert has_element?(
               member,
               ~s{#stage-sequence li [data-mark="missing"]},
               "Not in the harness"
             )

      assert has_element?(
               member,
               ~s{#stage-sequence li [data-mark="listed"]},
               "A stage can run it"
             )
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
        |> Draft.update_stage(id_of("Verify"), &Map.put(&1, "description", "Check it."))

      lines = for change <- Processes.diff(old, new), do: Words.change(change, old, new)

      assert "Changed the description of Verify." in lines
      assert "Changed the default machine type from Default to large." in lines
      assert "Renamed the stage Shape to Plan." in lines
      assert "Changed the sequence of Build." in lines
      assert Enum.any?(lines, &(&1 =~ ~r/^Moved (Release|Verify) from place \d to place \d\.$/))
    end

    test "a change of the default machine type reads Default with no type name, also after the instance default changes" do
      large = machine_type_fixture(key: "large")
      none = Processes.default_document("software") |> Map.delete("machine")
      on_large = Map.put(none, "machine", "large")
      on_default = Map.put(none, "machine", "default")

      line = fn older, newer ->
        [line] =
          for change <- Processes.diff(older, newer), do: Words.change(change, older, newer)

        line
      end

      from_default = "Changed the default machine type from Default to large."
      to_default = "Changed the default machine type from large to Default."

      assert line.(none, on_large) == from_default
      assert line.(on_large, on_default) == to_default

      # No machine and `default` run on the same type: a change between them has no line.
      assert Processes.diff(none, on_default) == []
      assert Processes.diff(on_default, none) == []

      # A version does not record which type was the default when it was saved: a later
      # change of the instance's default changes no line.
      make_default!(large)

      assert line.(none, on_large) == from_default
      assert line.(on_large, on_default) == to_default
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
             ) == "Explore: a value is not valid. Check the stage, then save again."

      for list <- ~w(sequence inputs outputs) do
        assert Words.refusal(
                 %{path: "#/stages/0/#{list}", error: :schema, detail: :maxItems},
                 doc
               ) == "Explore: keep at most 20 entries in each list."
      end
    end
  end
end
