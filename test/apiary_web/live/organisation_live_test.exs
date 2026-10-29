defmodule ApiaryWeb.OrganisationLiveTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.OrganisationsFixtures
  import Phoenix.LiveViewTest

  # A workspace's set-up is finished: a link to it leads to its first page.
  setup do
    Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)
  end

  # A member reaches each workspace as the edition marks it, as
  # `Apiary.EditionStubs.MembersReachMarked` has it, and every set-up is finished.
  defmodule MembersReachMarkedFinished do
    @moduledoc false
    alias Apiary.EditionStubs.{MembersReachMarked, SetUpFinished}
    defdelegate limits, to: MembersReachMarked
    defdelegate every_workspace_levels, to: MembersReachMarked
    defdelegate reached_workspaces(query, scope), to: MembersReachMarked
    defdelegate reaches_workspace?(scope, workspace_id, opts), to: MembersReachMarked
    defdelegate test_run_passed?(workspace), to: SetUpFinished
  end

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

      # The breadcrumb: the organisation, then Overview, the page itself.
      assert crumbs(view, :organisation) == [{"Overview", nil}]
      assert has_element?(view, "#breadcrumb [aria-current=page]", "Overview")

      # No bare "Settings" link in Details: the sidebar's foot names Organisation settings
      # on the same page.
      refute has_element?(view, "#about-settings")
      refute has_element?(view, "#about a", "Settings")

      assert has_element?(
               view,
               ~s(.q-sidebar-foot #nav-organisation[href="/#{organisation.slug}/settings"]),
               "Organisation settings"
             )

      # The workspaces' facts land off the first paint.
      assert render_async(view) =~ "none alive"
    end

    test "the root sends on to the workspace opened last while it is reached, else the first",
         %{conn: conn} do
      %{user: user, scope: scope, organisation: organisation} = sign_up_fixture()
      platform = workspace_fixture(organisation, "Platform")
      conn = log_in_user(conn, user)

      assert redirected_to(get(conn, ~p"/")) == ~p"/#{organisation}/#{scope.workspace}"

      conn = conn |> get(~p"/#{organisation}/#{platform}/settings/runs") |> recycle()
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

    test "where a workspace shows no overview, the root and its links lead to its first page",
         %{conn: conn} do
      %{user: user, scope: scope, organisation: organisation} = sign_up_fixture()
      platform = workspace_fixture(organisation, "Platform")
      # The edition leaves the record out of the organisation, the overview with it.
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.WithoutRecordOrPolicy)
      conn = log_in_user(conn, user)

      assert_error_sent 404, fn -> get(conn, ~p"/#{organisation}/#{scope.workspace}") end
      assert redirected_to(get(conn, ~p"/")) == ~p"/#{organisation}/#{scope.workspace}/nodes"

      {:ok, view, _html} = live(conn, ~p"/#{organisation}")

      for workspace <- [scope.workspace, platform] do
        assert has_element?(
                 view,
                 ~s(#workspace-#{workspace.id} a[href="/#{organisation.slug}/#{workspace.slug}/nodes"]),
                 workspace.name
               )
      end
    end

    test "each workspace's link is asked with the scope the member would have in it", %{
      conn: conn
    } do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      platform = workspace_fixture(organisation, "Platform")
      %{user: user} = member_fixture(owner, :member)
      # The edition marks each workspace a member reaches, and the scope reaches only the
      # workspace its mark names.
      :ok = Apiary.Edition.put_test_stub(MembersReachMarkedFinished)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/#{organisation}")

      for workspace <- [owner.workspace, platform] do
        assert has_element?(
                 view,
                 ~s(#workspace-#{workspace.id} a[href="/#{organisation.slug}/#{workspace.slug}"]),
                 workspace.name
               )
      end
    end

    test "a member added to a workspace while the page is open is offered its first page", %{
      conn: conn
    } do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      %{user: user} = member_fixture(owner, :member)
      # The member reaches no workspace yet, and the organisation shows no overview.
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.MembersReachNamedWithoutRecord)
      Apiary.EditionStubs.MembersReachNamed.put([])
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/#{organisation}")
      assert has_element?(view, "#not-added")

      Apiary.EditionStubs.MembersReachNamed.put([owner.workspace.id])
      send(view.pid, {:membership_changed, :added})

      assert has_element?(
               view,
               ~s(#added-open[href="/#{organisation.slug}/#{owner.workspace.slug}/nodes"]),
               owner.workspace.name
             )
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
