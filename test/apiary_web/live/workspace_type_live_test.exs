defmodule ApiaryWeb.WorkspaceTypeLiveTest do
  # A workspace type's page (`ApiaryWeb.WorkspaceTypeLive`), where a kind card leads: the
  # newest version of the type's default process on the view-only canvas, with the side
  # panel's name, summary, How it works and Stages, and Create workspace; How it works in
  # the main area with `workflow_model` off; the texts from code and the texts an instance
  # admin saved; Create workspace and its Name step; a key of no type with a card; and the
  # people New workspace is not for. Not async: each test sets the instance's features,
  # and some save a version of a type, which every test reads.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Workspace}
  alias Apiary.Processes.TypeTemplates

  @moduletag with_features: Apiary.Features.all()

  @summary "Agents change code in your repositories. Each ticket needs a repository."
  @stages "The workspace starts with the stages shown. After you create it, owners and admins can change them in Workspace settings › Stages."

  setup do
    {:ok, %{user: user, organisation: organisation}} =
      Organisations.sign_up_user(
        %{email: unique_user_email(), organisation_name: "Acme"},
        nil,
        open: true,
        workspace: false
      )

    %{
      user: user,
      organisation: organisation,
      path: ~p"/#{organisation}/workspaces/new/qory.software"
    }
  end

  # A version 2 of the software type, saved by the instance's admin: Explore renamed, and
  # with `texts`.
  defp save_version_2!(texts) do
    newest = TypeTemplates.newest("qory.software")

    document =
      Map.update!(newest.document, "stages", fn [first | rest] ->
        [Map.put(first, "name", "Discover") | rest]
      end)

    {:ok, version} =
      TypeTemplates.save(instance_admin_scope(), "qory.software", document,
        based_on: newest.number,
        texts: texts
      )

    version
  end

  defp canvas_view(view) do
    [json] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#workspace-type-canvas")
      |> LazyHTML.attribute("data-view")

    Jason.decode!(json)
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  test "shows the newest stages on the view-only canvas, beside the type's texts", %{
    conn: conn,
    user: user,
    organisation: organisation,
    path: path
  } do
    save_version_2!(nil)
    {:ok, view, html} = conn |> log_in_user(user) |> live(path)

    assert html =~ ~r{<title[^>]*>\s*Software factory}

    # The canvas fills the window left of the side panel; its cards open nothing.
    assert has_element?(view, "#workspace-type.q-canvas-fill > #workspace-type-canvas")

    assert has_element?(
             view,
             ~s(#workspace-type-side.q-canvas-side[style="--q-canvas-side: 24rem"])
           )

    canvas = canvas_view(view)
    refute canvas["editable"]
    refute canvas["selectable"]
    assert hd(canvas["stages"])["name"] == "Discover"

    assert has_element?(view, "#workspace-type-side h1", "Software factory")
    assert has_element?(view, "#workspace-type-summary", @summary)

    assert texts(view, "#workspace-type-description p") == [
             "Each ticket comes from a work source, such as an issue tracker. Agents take the ticket through the stages, and at the end of each stage a member approves the result before the next stage starts. Changes go to your repositories through the destination you connect.",
             "You connect: where work comes from, where changes go, and a model."
           ]

    assert has_element?(view, "#workspace-type-stages h2", "Stages")
    assert has_element?(view, "#workspace-type-stages p", @stages)

    assert has_element?(
             view,
             "#workspace-type-side button#workspace-type-create",
             "Create workspace"
           )

    # The breadcrumb: the organisation, New workspace, then the type's name.
    assert has_element?(view, ~s(#breadcrumb a[href="/#{organisation.slug}"]))

    assert has_element?(
             view,
             ~s(#breadcrumb a[href="/#{organisation.slug}/workspaces/new"]),
             "New workspace"
           )

    assert has_element?(view, "#breadcrumb [aria-current=page]", "Software factory")
  end

  test "shows the name, summary and description an instance admin saved", %{
    conn: conn,
    user: user,
    path: path
  } do
    save_version_2!(%{
      name: "Web shop factory",
      summary: "For the Web shop.",
      description: "Dana approves each stage.\n\nThe Web shop's tickets come from its tracker."
    })

    {:ok, view, _html} = conn |> log_in_user(user) |> live(path)

    assert has_element?(view, "#workspace-type-side h1", "Web shop factory")
    assert has_element?(view, "#breadcrumb [aria-current=page]", "Web shop factory")
    assert has_element?(view, "#workspace-type-summary", "For the Web shop.")

    assert texts(view, "#workspace-type-description p") == [
             "Dana approves each stage.",
             "The Web shop's tickets come from its tracker."
           ]
  end

  test "Create workspace creates Software factory and opens its Name step", %{
    conn: conn,
    user: user,
    organisation: organisation,
    path: path
  } do
    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, path)

    {:ok, name, _html} =
      view |> element("#workspace-type-create") |> render_click() |> follow_redirect(conn)

    assert has_element?(name, "h1", "Name this workspace")

    assert [%Workspace{name: "Software factory", domain: "software"}] =
             Organisations.list_workspaces(
               Organisations.load_scope(Scope.for_user(user), organisation.id)
             )
  end

  test "a key of no type with a card is a path that does not exist", %{
    conn: conn,
    user: user,
    organisation: organisation
  } do
    conn = log_in_user(conn, user)

    # The tests' example domain is a type with no card.
    for key <- ["acme.none", "qory.example"] do
      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, ~p"/#{organisation}/workspaces/new/#{key}")
      end
    end
  end

  test "is New workspace's not-found page for a person workspace.create does not allow", %{
    conn: conn,
    organisation: organisation,
    path: path
  } do
    admin = user_fixture()

    %Membership{organisation_id: organisation.id, user_id: admin.id}
    |> Membership.changeset(%{level: :admin})
    |> Repo.insert!()

    assert_raise ApiaryWeb.NotFound, fn -> conn |> log_in_user(admin) |> live(path) end
  end

  @tag with_features: Apiary.Features.all() -- [:workflow_model]
  test "with workflow_model off, How it works takes the main area and there is no canvas", %{
    conn: conn,
    user: user,
    path: path
  } do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(path)

    refute has_element?(view, "#workspace-type-canvas")
    refute has_element?(view, "#workspace-type-stages")
    refute has_element?(view, "#workspace-type-description")
    assert has_element?(view, "#workspace-type > #workspace-type-how h2", "How it works")
    assert has_element?(view, "#workspace-type-how p", "You connect: where work comes from")
    assert has_element?(view, "#workspace-type-side h1", "Software factory")
    assert has_element?(view, "#workspace-type-summary", @summary)
    assert has_element?(view, "#workspace-type-create", "Create workspace")
  end
end
