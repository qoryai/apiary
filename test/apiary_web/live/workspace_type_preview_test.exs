defmodule ApiaryWeb.WorkspaceTypePreviewTest do
  # The preview of the stages a new workspace starts with
  # (`ApiaryWeb.WorkspaceComponents.process_preview/1`): on New workspace and on the
  # first-workspace cards of an empty organisation's overview, the newest version of the
  # type's default process on the view-only canvas, whose cards open nothing; its line
  # with and without the workspace's name; and nothing of it with `workflow_model` off.
  # Not async: each test sets the instance's features, and one saves a version of a type,
  # which every test reads.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations
  alias Apiary.Processes.TypeTemplates
  alias ApiaryWeb.WorkspaceComponents

  @moduletag with_features: Apiary.Features.all()

  @line "The workspace starts with these stages. After you create it, owners and admins can change them in Workspace settings › Stages."

  setup do
    {:ok, %{user: user, organisation: organisation}} =
      Organisations.sign_up_user(
        %{email: unique_user_email(), organisation_name: "Acme"},
        nil,
        open: true,
        workspace: false
      )

    %{user: user, organisation: organisation}
  end

  # A version 2 of the software type, saved by the instance's admin: Explore renamed.
  defp save_version_2! do
    newest = TypeTemplates.newest("qory.software")

    document =
      Map.update!(newest.document, "stages", fn [first | rest] ->
        [Map.put(first, "name", "Discover") | rest]
      end)

    {:ok, version} =
      TypeTemplates.save(instance_admin_scope(), "qory.software", document, based_on: 1)

    version
  end

  defp canvas_view(view, id) do
    [json] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("##{id}")
      |> LazyHTML.attribute("data-view")

    Jason.decode!(json)
  end

  test "New workspace shows the newest version on the view-only canvas, with no events",
       %{conn: conn, user: user, organisation: organisation} do
    save_version_2!()
    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/#{organisation}/workspaces/new")

    assert has_element?(view, "#set-up-cards-preview-software-line", @line)

    canvas = canvas_view(view, "set-up-cards-preview-software-canvas")
    refute canvas["editable"]
    refute canvas["selectable"]
    assert hd(canvas["stages"])["name"] == "Discover"

    # The page takes no "select": the canvas sends none.
    assert has_element?(view, ~s(#set-up-cards-preview-software-canvas[phx-update="ignore"]))
  end

  test "the first-workspace cards show the same preview", %{
    conn: conn,
    user: user,
    organisation: organisation
  } do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}")

    assert has_element?(view, "#first-workspace #set-up-cards-preview-software-line", @line)

    canvas = canvas_view(view, "set-up-cards-preview-software-canvas")
    refute canvas["selectable"]

    assert Enum.map(canvas["stages"], & &1["name"]) ==
             Enum.map(TypeTemplates.newest("qory.software").document["stages"], & &1["name"])
  end

  test "with the workspace's name, the line starts with it" do
    html =
      render_component(&WorkspaceComponents.process_preview/1, %{
        id: "preview",
        document: TypeTemplates.newest("qory.software").document,
        workspace: "Web shop"
      })

    assert html =~
             "Web shop starts with these stages. After you create it, owners and admins can change them in Workspace settings › Stages."

    html =
      render_component(&WorkspaceComponents.process_preview/1, %{
        id: "preview",
        document: TypeTemplates.newest("qory.software").document
      })

    assert html =~ @line
  end

  @tag with_features: Apiary.Features.all() -- [:workflow_model]
  test "with workflow_model off, neither page shows a preview", %{
    conn: conn,
    user: user,
    organisation: organisation
  } do
    conn = log_in_user(conn, user)

    for path <- [~p"/#{organisation}/workspaces/new", ~p"/#{organisation}"] do
      {:ok, view, html} = live(conn, path)
      assert has_element?(view, "#set-up-cards")
      refute has_element?(view, "#set-up-cards-preview-software")
      refute html =~ "starts with these stages"
    end
  end
end
