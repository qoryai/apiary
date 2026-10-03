defmodule ApiaryWeb.OrganisationLiveTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.OrganisationsFixtures
  import Phoenix.LiveViewTest

  describe "a person who reaches a workspace" do
    test "sees the organisation's overview: its workspaces, each leading to its own", %{
      conn: conn
    } do
      %{user: user, scope: scope, organisation: organisation} = sign_up_fixture()
      platform = workspace_fixture(organisation, "Platform")
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/#{organisation}")
      assert html =~ organisation.name

      for workspace <- [scope.workspace, platform] do
        assert has_element?(
                 view,
                 ~s(#workspace-#{workspace.id} a[href="/#{organisation.slug}/#{workspace.slug}"]),
                 workspace.name
               )
      end

      assert has_element?(view, ~s(#people-open[href="/#{organisation.slug}/settings/people"]))
      assert has_element?(view, "#nav-organisation_overview[aria-current=page]")

      # The workspaces' facts land off the first paint.
      assert render_async(view) =~ "none alive"
    end

    test "the root sends on to the workspace opened last while it is reached, else the first",
         %{conn: conn} do
      %{user: user, scope: scope, organisation: organisation} = sign_up_fixture()
      platform = workspace_fixture(organisation, "Platform")
      conn = log_in_user(conn, user)

      assert redirected_to(get(conn, ~p"/")) == ~p"/#{organisation}/#{scope.workspace}"

      conn = conn |> get(~p"/#{organisation}/#{platform}/settings/keys") |> recycle()
      assert redirected_to(get(conn, ~p"/")) == ~p"/#{organisation}/#{platform}"
    end

    test "a member opens the workspace they were invited to, and is sent on to it", %{
      conn: conn
    } do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      %{user: user} = member_fixture(owner, :member)
      conn = log_in_user(conn, user)

      assert conn |> get(~p"/#{organisation}/#{owner.workspace}") |> html_response(200)
      assert conn |> get(~p"/#{organisation}/#{owner.workspace}/runs") |> html_response(200)
      assert redirected_to(get(conn, ~p"/")) == ~p"/#{organisation}/#{owner.workspace}"
    end

    test "an admin opens every workspace", %{conn: conn} do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      platform = workspace_fixture(organisation, "Platform")
      %{user: user} = member_fixture(owner, :admin)
      conn = log_in_user(conn, user)

      for workspace <- [owner.workspace, platform] do
        assert conn |> get(~p"/#{organisation}/#{workspace}") |> html_response(200)
      end
    end
  end
end
