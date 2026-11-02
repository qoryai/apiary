defmodule ApiaryWeb.WorkspaceTypePreviewTest do
  # The preview of the stages a new workspace starts with
  # (`ApiaryWeb.WorkspaceComponents.process_preview/1`), for an edition's form: its line
  # with and without the workspace's name. The kind cards show no preview: each leads to
  # its type's page (`ApiaryWeb.WorkspaceTypeLiveTest`).
  # Not async: each test sets the instance's features.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures

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

  test "the kind cards show no preview: the type's page shows the stages", %{
    conn: conn,
    user: user,
    organisation: organisation
  } do
    conn = log_in_user(conn, user)

    for path <- [~p"/#{organisation}/workspaces/new", ~p"/#{organisation}"] do
      {:ok, view, html} = live(conn, path)
      assert has_element?(view, "#set-up-cards")
      refute has_element?(view, "[data-canvas]")
      refute html =~ "starts with these stages"
    end
  end
end
