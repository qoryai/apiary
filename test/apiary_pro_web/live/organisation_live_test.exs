defmodule ApiaryProWeb.OrganisationLiveTest do
  @moduledoc """
  The organisation's own path under workspace access: a member reaches only the
  workspaces they were added to, and one added to none is told so on the organisation's
  page, which offers them a workspace once an owner adds them to it.
  """
  use ApiaryWeb.ConnCase, async: true

  # A workspace's set-up is finished, so a link to it leads to the Overview.
  setup do: Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias ApiaryPro.WorkspaceAccess

  describe "a member added to no workspace" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user, membership: membership} = member_fixture(owner.scope, :member)

      {:ok, _} = WorkspaceAccess.remove(owner.scope, membership.id, owner.workspace.id)

      %{conn: log_in_user(conn, user), owner: owner, membership: membership, user: user}
    end

    test "signs in to the organisation, which says they have not been added to a workspace",
         ctx do
      organisation = ctx.owner.organisation
      assert redirected_to(get(ctx.conn, ~p"/")) == ~p"/#{organisation}"

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{organisation}")

      assert has_element?(lv, "#not-added h1")
      assert has_element?(lv, "#not-added", organisation.name)

      assert has_element?(
               lv,
               "#not-added-members[href='#{~p"/#{organisation}/settings/people"}']"
             )

      # The organisation's own sidebar, and no workspace's entries.
      assert has_element?(lv, "aside#sidebar[aria-label='Organisation'] #nav-organisation")
      refute has_element?(lv, "#nav-overview")
      refute has_element?(lv, "#nav-runs")
      refute has_element?(lv, "#nav-nodes")
    end

    test "is not found in the workspace, as a workspace that does not exist", ctx do
      %{organisation: organisation, workspace: workspace} = ctx.owner

      for path <- [
            ~p"/#{organisation}/#{workspace}",
            ~p"/#{organisation}/#{workspace}/runs",
            ~p"/#{organisation}/#{workspace}/machines",
            ~p"/#{organisation}/#{workspace}/settings"
          ] do
        assert ctx.conn |> get(path) |> html_response(404)
      end

      assert ctx.conn |> get(~p"/#{organisation}/no-such-workspace") |> html_response(404)
    end

    test "is offered the workspace once an owner adds them, while the page is open", ctx do
      %{organisation: organisation, workspace: workspace, scope: owner_scope} = ctx.owner
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{organisation}")
      assert has_element?(lv, "#not-added")

      {:ok, _} = WorkspaceAccess.add(owner_scope, ctx.membership.id, workspace.id)

      assert has_element?(lv, "#added-open[href='#{~p"/#{organisation}/#{workspace}"}']")
      refute has_element?(lv, "#not-added")
    end
  end

  describe "a person who reaches a workspace" do
    test "a member is not found in a workspace they were not added to", %{conn: conn} do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      platform = workspace_fixture(organisation, "Platform")
      %{user: user} = member_fixture(owner, :member)
      conn = log_in_user(conn, user)

      assert conn |> get(~p"/#{organisation}/#{owner.workspace}") |> html_response(200)
      assert conn |> get(~p"/#{organisation}/#{platform}") |> html_response(404)
      assert conn |> get(~p"/#{organisation}/#{platform}/runs") |> html_response(404)

      # Nor does the session send them there.
      conn = conn |> put_session(:last_workspace_id, platform.id)
      assert redirected_to(get(conn, ~p"/")) == ~p"/#{organisation}/#{owner.workspace}"
    end
  end
end
