defmodule ApiaryWeb.InstanceLive.WorkspaceTypesTest do
  # Instance settings › Workspace types (`ApiaryWeb.InstanceLive.WorkspaceTypes`): the
  # section in the Instance level's menu, the list of types, a type's stages edited on
  # the canvas and saved as a new version, the types a stage offers, the Details tab with
  # the type's texts, the history, the refusals of a save, and a path
  # that does not exist for an organisation's owner or with `workflow_model` off. Not
  # async: a test of an instance admin hides the instance's organisation, a row every test
  # shares, and each test sets the instance's features.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Apiary.Harnesses.Qory
  alias Apiary.QoryHarnessFixture
  alias Apiary.Processes
  alias Apiary.Processes.TypeTemplates

  @moduletag with_features: Apiary.Features.all()

  @type_key "qory.software"
  @index "/instance/workspace-types"
  @edit "/instance/workspace-types/qory.software"
  @custom_type "web-shop-brief"

  setup do
    Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)
  end

  defp details(view), do: render_patch(view, @edit <> "?tab=details")

  defp canvas_stages(view) do
    [json] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#type-canvas")
      |> LazyHTML.attribute("data-view")

    Jason.decode!(json)["stages"]
  end

  defp form_stage_id(view) do
    [id] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#stage-form-id")
      |> LazyHTML.attribute("value")

    id
  end

  defp history(view, number),
    do: view |> element("#type-version-#{number}") |> render() |> LazyHTML.from_fragment()

  # A commit of the Qory harness whose template lists `listed` as its types, read as
  # main's.
  defp put_template_types(listed) do
    QoryHarnessFixture.files()
    |> Map.update!("modules/software-factory/process.yaml", fn process ->
      [kept, _types] = String.split(process, "\nartifact_types:\n", parts: 2)
      kept <> "\nartifact_types: " <> Jason.encode!(listed) <> "\n"
    end)
    |> QoryHarnessFixture.serve!()

    {:ok, commit} = Qory.read("main")
    assert Qory.template(commit).artifact_types == listed
  end

  # The type options of an output added to Explore, whose one output is at 0.
  defp new_output_options(view) do
    view |> element("#stage-add-outputs") |> render_click()

    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#stage-outputs-1-type option")
    |> LazyHTML.attribute("value")
  end

  defp standard_names, do: Enum.map(TypeTemplates.artifact_types(), & &1.name)

  describe "an instance admin" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "finds Workspace types in the Instance level's menu", %{scope: scope} do
      assert %{label: "Workspace types", path: @index} =
               Enum.find(
                 ApiaryWeb.Layouts.instance_sections(scope),
                 &(&1.key == :workspace_types)
               )
    end

    test "lists the types with their newest version, and opens one", %{conn: conn} do
      {:ok, view, _html} = live(conn, @index)

      assert has_element?(view, "#workspace-type-qory-software", "Software factory")
      assert has_element?(view, "#workspace-type-qory-software", "Version 1")
      assert has_element?(view, "#workspace-type-qory-software", "Qory Apiary default")

      assert has_element?(
               view,
               ~s(#workspace-type-qory-software-edit[href="#{@edit}"]),
               "Edit stages"
             )
    end

    test "edits a type's stages on the canvas and saves a new version, with its author", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, @edit)

      assert has_element?(view, ~s(#type-canvas[phx-update="ignore"]))
      assert has_element?(view, "#type-version", "Editing version 1.")
      assert has_element?(view, "#stage-panel-title", "Edit Explore")
      refute has_element?(view, "#type-save:not([disabled])")

      # No trial and no work items.
      refute has_element?(view, "#stages-save-trial")
      refute has_element?(view, "#stages-assign-form")

      # The workflow field suggests the Qory harness's workflows alone.
      options =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("datalist#stage-entry-0-workflow-names option")
        |> LazyHTML.attribute("value")

      assert options == TypeTemplates.workflows()

      assert has_element?(
               view,
               ~s{#stage-entry-0-workflow[type="text"][value="explore-a-ticket"]}
             )

      view |> form("#stage-form", stage: %{name: "Discover"}) |> render_change()
      assert has_element?(view, "#type-dirty", "Unsaved changes")
      view |> element("#type-save") |> render_click()

      assert has_element?(
               view,
               "#type-notice",
               "Saved as version 2. New workspaces of this type start with it."
             )

      assert %{number: 2, author_id: author_id, based_on: 1} = TypeTemplates.newest(@type_key)
      assert author_id == user.id
      assert has_element?(view, "#type-version", "Editing version 2.")

      details(view)
      assert LazyHTML.text(history(view, 2)) =~ "Renamed the stage Explore to Discover."
      assert LazyHTML.text(history(view, 2)) =~ "Newest"
      refute LazyHTML.text(history(view, 1)) =~ "Newest"
      assert LazyHTML.text(history(view, 1)) =~ "Qory Apiary default"
      assert LazyHTML.text(history(view, 1)) =~ "The first version."
    end

    test "a typed workflow: any name the pattern allows, marked against the Qory harness's workflows",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @edit)

      assert has_element?(
               view,
               ~s{#stage-entry-0-workflow-mark[data-mark="listed"]},
               "A stage can run it"
             )

      view
      |> form("#stage-form",
        stage: %{sequence: %{"0" => %{workflow: "triage"}}}
      )
      |> render_change()

      assert has_element?(
               view,
               ~s{#stage-entry-0-workflow-mark[data-mark="missing"]},
               "Not in the harness"
             )

      alert =
        "Choose another workflow for Explore, or list triage in the harness of each workspace of this type. The Qory harness does not list triage. A workspace on the Qory harness waits at Explore once an owner or admin opens its Workflows page, or someone uses Check again on a work item."

      assert has_element?(view, "#stage-panel [data-stage-alert]", alert)

      [json] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#type-canvas")
        |> LazyHTML.attribute("data-view")

      explore = hd(Jason.decode!(json)["stages"])

      assert explore["marks"]["triage"] == %{
               "listed" => false,
               "label" => "triage: not in the harness"
             }

      assert alert in explore["alerts"]

      # A name the pattern refuses keeps triage, with the error at the field.
      view
      |> form("#stage-form",
        stage: %{sequence: %{"0" => %{workflow: "Triage!"}}}
      )
      |> render_change()

      assert has_element?(view, "#stage-entry-0", "Write a workflow name")
      assert has_element?(view, ~s{#stage-entry-0-workflow-mark[data-mark="missing"]})

      view |> element("#type-save") |> render_click()

      assert [%{"workflow" => "triage"}] =
               hd(TypeTemplates.newest(@type_key).document["stages"])["sequence"]
    end

    test "Stages opens first; Details has the sentence, the type's texts and the history", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @edit)

      assert has_element?(view, ~s(#type-tabs-stages[href="#{@edit}"][aria-current="page"]))
      assert has_element?(view, ~s(#type-tabs-details[href="#{@edit}?tab=details"]))
      assert has_element?(view, "#type-editor #type-canvas")
      refute has_element?(view, "#type-details")

      details(view)
      assert has_element?(view, ~s(#type-tabs-details[aria-current="page"]))
      refute has_element?(view, "#type-canvas")
      assert has_element?(view, "#type-version", "Editing version 1.")
      assert has_element?(view, "#type-save[disabled]")

      assert has_element?(
               view,
               "#type-details > p:first-child",
               "New workspaces of this type start with these stages."
             )

      # A copy of the release's default shows the texts from code.
      assert has_element?(view, ~s(#type-name[value="Software factory"][maxlength="60"]))

      assert has_element?(
               view,
               ~s(#type-summary[maxlength="200"][value="Agents change code in your repositories. Each ticket needs a repository."])
             )

      assert has_element?(view, ~s(#type-description[maxlength="1200"]), "You connect:")
      # The default machine type is a picker of the instance's types, with a link to them.
      assert has_element?(
               view,
               ~s(select#type-machine option[value="default"]),
               "Default (Standard)"
             )

      assert has_element?(
               view,
               ~s(select#type-machine option[value="standard"]),
               "Standard: 2 vCPUs, 4 GiB"
             )

      assert has_element?(
               view,
               "#type-machine-hint",
               "New workspaces of this type start with this default. Add machine types in Instance settings › Machine types."
             )

      assert has_element?(view, ~s(#type-machine-hint a[href="/instance/machine-types"]))
      refute render(view) =~ "It does not choose the machine that runs it."
      assert has_element?(view, "#type-version-1", "The first version.")
    end

    test "a form's values after a reconnect go to the stage in the form's id", %{conn: conn} do
      {:ok, view, _html} = live(conn, @edit)
      first = form_stage_id(view)

      other =
        Enum.find(canvas_stages(view), &(&1["id"] != first))

      render_hook(view, "edit_stage", %{"stage" => %{"id" => other["id"], "name" => "Ship"}})

      assert form_stage_id(view) == other["id"]
      assert has_element?(view, "#stage-panel-title", "Edit Ship")

      names = Map.new(canvas_stages(view), &{&1["id"], &1["name"]})
      assert names[other["id"]] == "Ship"
      refute names[first] == "Ship"
    end

    test "Discard and a save drop the errors by place", %{conn: conn} do
      {:ok, view, _html} = live(conn, @edit)
      first = form_stage_id(view)
      other = Enum.find(canvas_stages(view), &(&1["sequence"] == []))
      add = fn selector -> view |> element(selector) |> render_click() end

      # The first stage and `other`, each with a row at place 0 and a loop at place 1, and a
      # bad workflow name and bad rounds typed on `other`.
      bad_values = fn ->
        render_hook(view, "select", %{"id" => other["id"]})

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

      valid_first_stage = fn ->
        assert form_stage_id(view) == first
        assert has_element?(view, "#stage-loop-1")
        refute has_element?(view, "#stage-loop-1", "Give the loop 1 to 10 rounds.")
        refute has_element?(view, "#stage-panel", "Write a workflow name")
      end

      add.("#stage-add-loop")
      render_hook(view, "select", %{"id" => other["id"]})
      add.("#stage-add-entry")
      add.("#stage-add-loop")
      add.("#type-save")

      bad_values.()
      add.("#type-discard")
      valid_first_stage.()

      bad_values.()
      add.("#type-save")
      assert has_element?(view, "#type-notice")
      valid_first_stage.()
    end

    test "a key no machine type has: the line of the closed row, in the fold too", %{
      conn: conn,
      scope: scope
    } do
      # A new instance has the type browser; this one has none.
      Apiary.MachineTypesFixtures.remove_machine_types(["browser"])
      newest = TypeTemplates.newest(@type_key)

      document =
        put_in(
          newest.document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          "browser"
        )

      {:ok, _version} = TypeTemplates.save(scope, @type_key, document)
      {:ok, view, _html} = live(conn, @edit)
      line = "Pick a machine type: no type has the key browser."

      assert has_element?(view, ~s{details[id^="stage-entry-0-settings-"] > summary}, line)
      assert has_element?(view, "#stage-entry-0-missing", line)

      assert has_element?(
               view,
               ~s{details[id^="stage-entry-0-settings-"] > summary},
               "Machine type: Workspace default (Standard)"
             )
    end

    test "a refused machine type shows on its closed row, until Discard", %{conn: conn} do
      {:ok, view, _html} = live(conn, @edit)

      [stage_id] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#stage-form-id")
        |> LazyHTML.attribute("value")

      # A value that breaks the schema's pattern, as a recovered form can have it.
      render_hook(view, "edit_stage", %{
        "stage" => %{"id" => stage_id, "sequence" => %{"0" => %{"machine" => "Gone"}}}
      })

      view |> element("#type-save") |> render_click()

      assert has_element?(view, "[data-save-error]", "fix the fields marked below.")

      assert has_element?(
               view,
               ~s{details[id^="stage-entry-0-settings-"]:not([open]) > summary [data-machine-error]},
               "Choose a machine type from the list."
             )

      assert has_element?(view, ~s(#stage-entry-0-machine[aria-invalid="true"]))

      # Discard forgets the refused value: the same value in an `edit_stage` event, as one sent
      # before the page's patch arrives, shows nothing before a save.
      view |> element("#type-discard") |> render_click()
      refute has_element?(view, "[data-machine-error]")
      refute has_element?(view, "[data-save-error]")

      render_hook(view, "edit_stage", %{
        "stage" => %{"id" => stage_id, "sequence" => %{"0" => %{"machine" => "Gone"}}}
      })

      refute has_element?(view, "[data-machine-error]")
    end

    test "a switch of tabs keeps the draft; a save keeps the stages and the texts", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @edit)
      view |> form("#stage-form", stage: %{name: "Discover"}) |> render_change()

      details(view)
      assert has_element?(view, "#type-dirty", "Unsaved changes")

      view
      |> form("#type-texts-form",
        texts: %{name: "Web shop factory", summary: "For the Web shop."}
      )
      |> render_change()

      render_patch(view, @edit)
      assert has_element?(view, "#stage-panel-title", "Edit Discover")
      view |> element("#type-save") |> render_click()

      assert %{
               number: 2,
               name: "Web shop factory",
               summary: "For the Web shop.",
               description: nil
             } =
               TypeTemplates.newest(@type_key)

      assert has_element?(view, "#settings-section-title", "Web shop factory")
      refute has_element?(view, "#type-dirty")

      details(view)
      assert LazyHTML.text(history(view, 2)) =~ "Renamed the stage Explore to Discover."
      assert LazyHTML.text(history(view, 2)) =~ "Changed the name."
      assert LazyHTML.text(history(view, 2)) =~ "Changed the summary."
      refute LazyHTML.text(history(view, 2)) =~ "Changed How it works."

      {:ok, list, _html} = live(conn, @index)
      assert has_element?(list, "#workspace-type-qory-software", "Web shop factory")
    end

    test "a text over its limit shows under its field on Details", %{conn: conn} do
      {:ok, view, _html} = live(conn, @edit)
      render_hook(view, "edit_texts", %{"texts" => %{"name" => String.duplicate("a", 61)}})
      view |> element("#type-save") |> render_click()

      assert_patch(view, @edit <> "?tab=details")
      assert has_element?(view, "#type-texts-form", "Write at most 60 characters.")
      assert has_element?(view, ~s(#type-name[aria-invalid="true"]))
      assert TypeTemplates.newest(@type_key).number == 1
    end

    test "How it works over 80 words shows under its field", %{conn: conn} do
      {:ok, view, _html} = live(conn, @edit <> "?tab=details")
      words = Enum.map_join(1..81, " ", fn _n -> "shop" end)

      view |> form("#type-texts-form", texts: %{description: words}) |> render_change()
      view |> element("#type-save") |> render_click()

      assert has_element?(view, "#type-texts-form", "Write at most 80 words.")
      assert has_element?(view, ~s(#type-description[aria-invalid="true"]))
      assert TypeTemplates.newest(@type_key).number == 1
    end

    test "a gate is none or any member: no named approvers", %{conn: conn} do
      {:ok, view, _html} = live(conn, @edit)

      assert has_element?(view, "#stage-gate-kind-0")
      assert has_element?(view, "#stage-gate-kind-1")
      refute has_element?(view, "#stage-gate-approvers")
      refute has_element?(view, "#stage-gate-named")
    end

    test "a gate that names people is refused with its text", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @edit)

      render_hook(view, "edit_stage", %{
        "stage" => %{
          "id" => form_stage_id(view),
          "gate" => %{"kind" => "person", "approvers" => "named", "named" => [user.id]}
        }
      })

      view |> element("#type-save") |> render_click()

      assert has_element?(
               view,
               "[data-save-error]",
               ~s(A workspace type has no members to name. Choose "A person approves before the work item moves on.")
             )

      assert TypeTemplates.newest(@type_key).number == 1
    end

    test "a version saved after the page opened refuses the save as stale", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, @edit)

      # Another tab saves version 2.
      newest = TypeTemplates.newest(@type_key)
      other = put_in(newest.document, ["machine"], "standard")
      {:ok, _version} = TypeTemplates.save(scope, @type_key, other, based_on: 1)

      view |> form("#stage-form", stage: %{name: "Discover"}) |> render_change()
      view |> element("#type-save") |> render_click()

      assert has_element?(
               view,
               "[data-save-error]",
               "Version 2 was saved after you opened this page. Copy your changes, then reload."
             )

      assert TypeTemplates.newest(@type_key).number == 2
    end

    test "offers the custom types of the copied template, and a draft may use them", %{
      conn: conn
    } do
      put_template_types([
        %{"name" => "proposal"},
        %{"name" => @custom_type, "base_view" => "document", "size_limit" => 1, "max_files" => 1}
      ])

      {:ok, view, _html} = live(conn, @edit)

      assert new_output_options(view) == standard_names() ++ [@custom_type]

      view
      |> form("#stage-form", stage: %{outputs: %{"1" => %{type: @custom_type}}})
      |> render_change()

      view |> element("#type-save") |> render_click()
      document = TypeTemplates.newest(@type_key).document

      assert Enum.any?(hd(document["stages"])["outputs"], &(&1["type"] == @custom_type))

      assert {:missing_type, hd(document["stages"])["id"], @custom_type} in Processes.placement_check(
               document,
               TypeTemplates.workflows(),
               TypeTemplates.artifact_types()
             )

      refute Enum.any?(
               Processes.placement_check(
                 document,
                 TypeTemplates.workflows(),
                 TypeTemplates.offered_types(@type_key)
               ),
               &match?({:missing_type, _id, _type}, &1)
             )
    end

    test "offers the standard types and the Qory harness's custom type", %{conn: conn} do
      {:ok, view, _html} = live(conn, @edit)

      assert new_output_options(view) == standard_names() ++ ["branch"]
    end

    test "another type's page offers the standard types, and no custom type of the template",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @index <> "/qory.example")

      assert new_output_options(view) == standard_names()
    end

    test "a key no type has is a path that does not exist", %{conn: conn} do
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, "/instance/workspace-types/acme.none") end
    end
  end

  describe "an organisation owner" do
    setup :register_and_log_in_user

    test "gets no menu entry, no list and no editor", %{conn: conn, scope: scope} do
      refute Apiary.Access.instance_admin?(scope)
      refute Enum.any?(ApiaryWeb.Layouts.instance_sections(scope), &(&1.key == :workspace_types))
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, @index) end
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, @edit) end
    end
  end

  describe "with workflow_model off" do
    @describetag with_features: Apiary.Features.all() -- [:workflow_model]

    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    # The route gate (`ApiaryWeb.Features.Routes`) answers a path that does not exist.
    test "an instance admin finds no entry and no page", %{conn: conn, scope: scope} do
      refute Enum.any?(ApiaryWeb.Layouts.instance_sections(scope), &(&1.key == :workspace_types))
      assert conn |> get(@index) |> response(404)
      assert conn |> get(@edit) |> response(404)
    end
  end
end
