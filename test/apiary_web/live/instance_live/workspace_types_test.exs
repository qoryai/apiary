defmodule ApiaryWeb.InstanceLive.WorkspaceTypesTest do
  # Instance settings › Workspace types (`ApiaryWeb.InstanceLive.WorkspaceTypes`): the
  # section in the Instance level's menu, the list of types, a type's stages edited on
  # the canvas and saved as a new version, the history, the refusals of a save, and a path
  # that does not exist for an organisation's owner or with `workflow_model` off. Not
  # async: a test of an instance admin hides the instance's organisation, a row every test
  # shares, and each test sets the instance's features.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Apiary.Processes.TypeTemplates

  @moduletag with_features: Apiary.Features.all()

  @type_key "qory.software"
  @index "/instance/workspace-types"
  @edit "/instance/workspace-types/qory.software"

  setup do
    Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)
  end

  defp history(view, number),
    do: view |> element("#type-version-#{number}") |> render() |> LazyHTML.from_fragment()

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
        |> LazyHTML.query("datalist#stage-entry-0-0-workflow-names option")
        |> LazyHTML.attribute("value")

      assert options == TypeTemplates.workflows()

      assert has_element?(
               view,
               ~s{#stage-entry-0-0-workflow[type="text"][value="explore-a-ticket"]}
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
               ~s{#stage-entry-0-0-workflow-mark[data-mark="listed"]},
               "A stage can run it"
             )

      view
      |> form("#stage-form",
        stage: %{sequence: %{"0" => %{body: %{"0" => %{workflow: "triage"}}}}}
      )
      |> render_change()

      assert has_element?(
               view,
               ~s{#stage-entry-0-0-workflow-mark[data-mark="missing"]},
               "Not in the harness"
             )

      alert =
        "Choose another workflow for Explore, or list triage in the harness of each workspace of this type. The Qory harness does not list triage. A workspace on the Qory harness waits at Explore once its harness has been read, on its Stages or Workflow page or by Check again."

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
        stage: %{sequence: %{"0" => %{body: %{"0" => %{workflow: "Triage!"}}}}}
      )
      |> render_change()

      assert has_element?(view, "#stage-entry-0-0", "Write a workflow name")
      assert has_element?(view, ~s{#stage-entry-0-0-workflow-mark[data-mark="missing"]})

      view |> element("#type-save") |> render_click()

      assert [%{"loop" => %{"body" => [%{"workflow" => "triage"}]}}] =
               hd(TypeTemplates.newest(@type_key).document["stages"])["sequence"]
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
      other = put_in(newest.document, ["machine"], "large")
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
