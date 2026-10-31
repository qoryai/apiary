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

      # Details: the organisation's address, as Organisation settings shows it.
      assert has_element?(view, "#about dt", "Address")
      assert has_element?(view, "#about dd.q-mono", "/#{organisation.slug}")
      refute has_element?(view, "#about dt", "Slug")

      assert has_element?(
               view,
               ~s(.q-sidebar-foot #nav-organisation[href="/#{organisation.slug}/settings"]),
               "Organisation settings"
             )

      # The workspaces' facts land off the first paint: no run yet, said once.
      assert render_async(view) =~ "No run yet"
      refute has_element?(view, "#workspaces .q-spark")
      refute render(view) =~ "0 runs"

      assert has_element?(
               view,
               ".q-band-hint",
               "Runs and denied network connections in the last 14 days"
             )
    end

    test "Details has no Owners row for an organisation without an owner", %{conn: conn} do
      %{organisation: organisation, user: owner, scope: scope} = sign_up_fixture()
      %{user: admin} = member_fixture(scope, :admin)
      require Ecto.Query

      {1, _rows} =
        Apiary.Repo.update_all(
          Ecto.Query.from(m in Apiary.Organisations.Membership,
            where: m.organisation_id == ^organisation.id and m.user_id == ^owner.id
          ),
          set: [level: :admin]
        )

      {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/#{organisation}")
      assert has_element?(view, "#about dt", "Address")
      refute has_element?(view, "#about dt", "Owners")
    end

    test "each workspace's line says each of its figures once", %{conn: conn} do
      %{user: user, scope: scope, organisation: organisation} = sign_up_fixture()
      recent = workspace_fixture(organisation, "Recent")
      older = workspace_fixture(organisation, "Older")
      now = DateTime.utc_now()

      for {workspace, days_ago, state} <- [
            {recent, 1, "completed"},
            {recent, 0, "running"},
            {older, 30, "completed"}
          ] do
        Apiary.RunEventsFixtures.run_fixture(%{scope | workspace: workspace}, %{
          state: state,
          started_at: DateTime.add(now, -days_ago, :day)
        })
      end

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}")
      render_async(view)

      text = fn workspace ->
        view
        |> element("#workspace-#{workspace.id}")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.split()
        |> Enum.join(" ")
      end

      # Runs in the 14 days: the days' shape, named, their count and the last run.
      assert text.(recent) =~ "1 run in progress"
      assert text.(recent) =~ "2 runs"

      assert has_element?(
               view,
               ~s(#workspace-#{recent.id} svg.q-spark[role=img][aria-label="Runs per day in the last 14 days"])
             )

      # Runs before the 14 days alone: no shape, the count of the 14 days and the last run.
      assert text.(older) =~ "No run in progress"
      assert text.(older) =~ "0 runs"
      refute has_element?(view, "#workspace-#{older.id} .q-spark")
      refute text.(older) =~ "No run yet"

      # No run ever: "No run yet" alone.
      main = text.(scope.workspace)
      assert main =~ "No run yet"
      refute main =~ "in progress"
      refute main =~ "0 runs"
      refute has_element?(view, "#workspace-#{scope.workspace.id} .q-spark")
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
