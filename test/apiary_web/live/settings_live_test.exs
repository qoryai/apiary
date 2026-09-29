defmodule ApiaryWeb.SettingsLiveTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations

  describe "as an owner" do
    setup :register_and_log_in_user

    test "renames the organisation on its page and the workspace on its own; the slugs stay",
         %{conn: conn, user: user, scope: scope} do
      {:ok, lv, html} = live(conn, ~p"/#{scope.organisation}/settings")

      # The software domain's words, and no skin word: no apiary, no hive.
      assert has_element?(lv, "h2", "Organisation name")
      refute has_element?(lv, "#workspace-form")
      refute has_element?(lv, "#retention-form")
      assert html =~ "The name of this organisation, where its pages are, and who owns it."
      assert has_element?(lv, "#settings-tab-organisation[aria-current='page']")
      assert has_element?(lv, "#organisation-slug span", "/#{scope.organisation.slug}")

      page = lv |> element("#main") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
      refute page =~ ~r/\b(apiary|apiaries|hive|hives)\b/i
      assert html =~ scope.organisation.name

      html = lv |> form("#organisation-form", organisation: %{name: "Acme"}) |> render_submit()
      assert html =~ "Organisation renamed to Acme"
      assert has_element?(lv, "#organisation-slug span", "/#{scope.organisation.slug}")

      {:ok, lv, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")

      assert has_element?(lv, "h2", "Workspace name")
      refute has_element?(lv, "#organisation-form")
      refute has_element?(lv, "#owners")

      assert html =~ "The name of this workspace, and where its pages are."

      assert has_element?(lv, "aside#sidebar[aria-label='Settings']")
      assert has_element?(lv, "#settings-tab-general[aria-current='page']")
      assert has_element?(lv, "#workspace-slug span", workspace_path(scope))
      assert html =~ scope.workspace.name

      html = lv |> form("#workspace-form", workspace: %{name: "Platform"}) |> render_submit()
      assert html =~ "Workspace renamed to Platform"

      reloaded = Organisations.load_scope(Scope.for_user(user))
      assert reloaded.organisation.name == "Acme"
      assert reloaded.workspace.name == "Platform"
      assert reloaded.organisation.slug == scope.organisation.slug
      assert reloaded.workspace.slug == scope.workspace.slug
    end

    test "refuses an empty name", %{conn: conn, user: user, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      html = lv |> form("#organisation-form", organisation: %{name: ""}) |> render_submit()
      assert html =~ "can&#39;t be blank"

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")
      html = lv |> form("#workspace-form", workspace: %{name: ""}) |> render_submit()
      assert html =~ "can&#39;t be blank"

      reloaded = Organisations.load_scope(Scope.for_user(user))
      assert reloaded.organisation.name == scope.organisation.name
      assert reloaded.workspace.name == scope.workspace.name
    end

    test "lists the owners", %{conn: conn, user: user, scope: scope} do
      %{user: member} = member_fixture(scope, :member)
      %{user: other_owner} = member_fixture(scope, :owner)

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings")

      assert has_element?(lv, "#owners", user.email)
      assert has_element?(lv, "#owners", other_owner.email)
      refute has_element?(lv, "#owners", member.email)
    end

    test "sets the retention, within the bounds, and clears it", %{conn: conn, scope: scope} do
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/retention")

      assert html =~ "This workspace keeps everything."
      assert html =~ "Nothing is pruned: this workspace keeps everything."

      html =
        lv
        |> form("#retention-form", retention: %{events_retention_days: "0"})
        |> render_change()

      assert html =~ "must be between 1 and 3650 days, or empty to keep everything"

      html =
        lv
        |> form("#retention-form",
          retention: %{events_retention_days: "30", log_retention_days: "31"}
        )
        |> render_submit()

      assert html =~ "cannot be longer than the events are kept"

      html =
        lv
        |> form("#retention-form",
          retention: %{events_retention_days: "90", log_retention_days: "14"}
        )
        |> render_submit()

      assert html =~ "Retention saved."

      assert has_element?(
               lv,
               "#retention-summary",
               "Log output is pruned after 14 days, events after 90 days."
             )

      assert has_element?(lv, "#retention-runs-empty", "Nothing has been pruned yet.")

      workspace = Apiary.Repo.get!(Apiary.Organisations.Workspace, scope.workspace.id)
      assert {workspace.events_retention_days, workspace.log_retention_days} == {90, 14}

      lv
      |> form("#retention-form", retention: %{events_retention_days: "", log_retention_days: ""})
      |> render_submit()

      workspace = Apiary.Repo.get!(Apiary.Organisations.Workspace, scope.workspace.id)
      assert {workspace.events_retention_days, workspace.log_retention_days} == {nil, nil}
    end

    test "says what the job pruned, for this workspace only", %{conn: conn, scope: scope} do
      import Apiary.RunEventsFixtures

      {:ok, workspace} = Apiary.Retention.update_retention(scope, %{events_retention_days: 10})
      run = run_fixture(scope)
      events_fixture(run, record())
      {:ok, _run} = Apiary.Runs.Projector.project(run)

      other = sign_up_fixture().scope

      {:ok, other_workspace} =
        Apiary.Retention.update_retention(other, %{events_retention_days: 3})

      now = DateTime.add(DateTime.utc_now(), 40 * 86_400, :second)
      assert %{runs_pruned: 1} = Apiary.Retention.prune_workspace(workspace, now: now)
      assert %{runs_pruned: 0} = Apiary.Retention.prune_workspace(other_workspace, now: now)

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/retention")

      assert [mine] = Apiary.Retention.list_retention_runs(%{scope | workspace: workspace})

      assert has_element?(
               lv,
               "#retention-runs li",
               "1 run: 14 events and 12 B of log output in 2 chunks."
             )

      assert has_element?(lv, "#retention-run-#{mine.id}", "By hand")
      assert lv |> element("#retention-runs") |> render() =~ "events from before"
      assert lv |> render() |> String.split("retention-run-") |> length() == 2
    end
  end

  describe "as a member" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user} = member_fixture(owner.scope, :member)
      %{conn: log_in_user(conn, user), owner: owner}
    end

    test "sees the names read-only", %{conn: conn, owner: owner} do
      scope = owner.scope
      {:ok, lv, html} = live(conn, ~p"/#{scope.organisation}/settings")
      assert html =~ "Only owners and admins can change these settings"
      assert has_element?(lv, "input#organisation_name[disabled]")
      assert has_element?(lv, "#owners", owner.user.email)

      {:ok, lv, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")

      assert html =~ "Only owners and admins can change these settings"
      assert has_element?(lv, "input#workspace_name[disabled]")
      refute has_element?(lv, "button", "Save")

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/retention")

      assert has_element?(lv, "input#retention_events_retention_days[disabled]")
      assert has_element?(lv, "input#retention_log_retention_days[disabled]")
      refute has_element?(lv, "button", "Save")

      # A crafted event changes nothing.
      html = render_submit(lv, "save_retention", %{"retention" => %{"log_retention_days" => "1"}})
      assert html =~ "Only owners and admins can change these settings."

      assert Apiary.Repo.get!(Apiary.Organisations.Workspace, owner.scope.workspace.id).log_retention_days ==
               nil
    end
  end

  describe "a person removed from the organisation while the page is open" do
    test "a change it asks for is refused and the page sent to /", %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user, scope: scope, membership: membership} = member_fixture(owner.scope, :member)

      {:ok, lv, _html} =
        live(log_in_user(conn, user), ~p"/#{scope.organisation}/#{scope.workspace}/settings")

      # Removed behind the page's back: no announcement reaches it.
      Apiary.Repo.delete!(membership)

      render_hook(lv, "save_retention", %{"retention" => %{"events_retention_days" => "30"}})
      {path, flash} = assert_redirect(lv)
      assert path == ~p"/"
      assert flash["error"] =~ "no longer have access"
    end
  end

  describe "the sections" do
    setup :register_and_log_in_user

    test "the organisation's list the owner may open, the current one marked, and a page each",
         %{conn: conn, scope: scope} do
      org = scope.organisation
      {:ok, lv, _html} = live(conn, ~p"/#{org}/settings")

      for {key, path} <- [
            organisation: ~p"/#{org}/settings",
            people: ~p"/#{org}/settings/people",
            workspaces: ~p"/#{org}/settings/workspaces",
            audit_log: ~p"/#{org}/activity",
            danger: ~p"/#{org}/settings/danger"
          ] do
        assert has_element?(
                 lv,
                 ~s(#settings-group-organisation #settings-tab-#{key}[href="#{path}"])
               )
      end

      # The other kinds are beside it, each under its own name; no cross-link, no Elsewhere.
      assert has_element?(
               lv,
               ~s(#settings-group-workspace #settings-tab-general[href="#{~p"/#{org}/#{scope.workspace}/settings"}"])
             )

      assert has_element?(
               lv,
               ~s(#settings-group-person #settings-tab-user_settings[href="/users/settings"])
             )

      refute has_element?(lv, "#settings-tab-workspace_settings, #settings-tab-your_settings")
      refute render(lv) =~ "Elsewhere"

      assert has_element?(lv, "#settings-tab-organisation[aria-current=page]")
      assert has_element?(lv, "#settings-kind", "Organisation settings · #{org.name}")
      assert has_element?(lv, "h1#settings-section-title", "General")

      {:ok, lv, _html} = live(conn, ~p"/#{org}/settings/workspaces")
      assert has_element?(lv, "#settings-tab-workspaces[aria-current=page]")
      assert has_element?(lv, "#workspace-#{scope.workspace.id}", scope.workspace.name)

      {:ok, lv, _html} = live(conn, ~p"/#{org}/settings/danger")
      assert has_element?(lv, "#settings-tab-danger[aria-current=page]")
      assert has_element?(lv, "#delete-organisation-button")
    end

    test "the workspace's list, and a section a page", %{conn: conn, scope: scope} do
      base = ~p"/#{scope.organisation}/#{scope.workspace}/settings"
      {:ok, lv, _html} = live(conn, base <> "/retention")

      for {key, path} <- [
            general: base,
            keys: base <> "/keys",
            retention: base <> "/retention",
            workspace_danger: base <> "/danger"
          ] do
        assert has_element?(
                 lv,
                 ~s(#settings-group-workspace #settings-tab-#{key}[href="#{path}"])
               )
      end

      assert has_element?(
               lv,
               ~s(#settings-group-organisation #settings-tab-organisation[href="#{~p"/#{scope.organisation}/settings"}"])
             )

      refute has_element?(lv, "#settings-tab-organisation_settings")

      assert has_element?(lv, "#settings-tab-retention[aria-current=page]")
      assert has_element?(lv, "#settings-kind", "Workspace settings · #{scope.workspace.name}")
      assert has_element?(lv, "h1#settings-section-title", "Retention")
      assert has_element?(lv, "#retention-form")
      refute has_element?(lv, "#workspace-form")

      {:ok, lv, _html} = live(conn, base <> "/danger")
      assert has_element?(lv, "#settings-tab-workspace_danger[aria-current=page]")
      refute has_element?(lv, "#settings-tab-danger[aria-current=page]")
    end

    test "a workspace's danger zone deletes it when it is one of several, after its slug",
         %{conn: conn, scope: scope} do
      org = scope.organisation
      platform = workspace_fixture(org, "Platform")

      {:ok, lv, _html} = live(conn, ~p"/#{org}/#{platform}/settings/danger")
      lv |> element("#delete-workspace-button") |> render_click()
      assert_patch(lv, ~p"/#{org}/#{platform}/settings/delete")
      assert has_element?(lv, "#delete-workspace-modal")

      lv |> form("#delete-workspace-form", confirm: %{slug: platform.slug}) |> render_submit()
      {path, flash} = assert_redirect(lv)
      assert path == ~p"/#{org}/settings/workspaces"
      assert flash["info"] =~ "Platform is deleted"
    end

    test "the only workspace's danger zone says why it is not deleted on its own",
         %{conn: conn, scope: scope} do
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/danger")

      assert html =~ "The organisation&#39;s only workspace is not deleted on its own"
      refute has_element?(lv, "#delete-workspace-button")
    end

    test "a member sees no Workspaces and no Danger zone", %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user} = member_fixture(owner.scope, :member)
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/#{owner.organisation}/settings")
      assert has_element?(lv, "#settings-tab-people")
      refute has_element?(lv, "#settings-tab-workspaces")
      refute has_element?(lv, "#settings-tab-danger")
      refute has_element?(lv, "#settings-tab-audit_log")
      # nor the workspace's
      assert has_element?(lv, "#settings-tab-retention")
      refute has_element?(lv, "#settings-tab-workspace_danger")
    end
  end

  describe "the paths that moved under the settings" do
    setup :register_and_log_in_user

    test "send on to where the page is now, with what followed and the query",
         %{conn: conn, scope: scope} do
      org = scope.organisation
      ws = scope.workspace

      for {old, new} <- [
            {~p"/#{org}/members", ~p"/#{org}/settings/people"},
            {~p"/#{org}/members/invite", ~p"/#{org}/settings/people/invite"},
            {~p"/#{org}/#{ws}/keys", ~p"/#{org}/#{ws}/settings/keys"},
            {~p"/#{org}/#{ws}/keys/new", ~p"/#{org}/#{ws}/settings/keys/new"},
            {~p"/#{org}/#{ws}/keys?open=1", ~p"/#{org}/#{ws}/settings/keys?open=1"}
          ] do
        assert redirected_to(get(conn, old)) == new
      end
    end
  end
end
