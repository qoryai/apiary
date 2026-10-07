defmodule ApiaryWeb.WorkspaceSettingsTest do
  # The workspace's settings in the frame: its sections are the frame's second column,
  # beside the workspace's sidebar, and each section is a page of its own.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  defp settings_path(scope, rest \\ ""),
    do: "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings#{rest}"

  defp member_conn(scope, level) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  describe "General" do
    setup :register_and_log_in_user

    test "says the workspace's type, read only, beside its name and its address",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, settings_path(scope))

      assert has_element?(lv, "#settings-tabs #settings-tab-general[aria-current=page]")
      refute has_element?(lv, "#main #settings-tabs")
      assert has_element?(lv, "#workspace-name #workspace-type dt", "Type")
      assert has_element?(lv, "#workspace-type-value", "A software workspace")

      assert has_element?(
               lv,
               "#workspace-type",
               "Chosen when the workspace was created. It decides the words its pages use."
             )

      # Read only: no field for it, and the form sends none.
      refute has_element?(lv, "#workspace-type input, #workspace-type select")
      refute has_element?(lv, "#workspace-form #workspace-type")
    end

    test "says it to a member too, who changes nothing", %{scope: scope} do
      {:ok, lv, _html} = live(member_conn(scope, :member), settings_path(scope))

      assert has_element?(lv, "#workspace-type-value", "A software workspace")
      assert has_element?(lv, "input#workspace_name[disabled]")
    end

    test "holds the danger zone, whose paths open it in place on General",
         %{conn: conn, scope: scope} do
      workspace = workspace_fixture(scope.organisation, "Platform")
      general = "/#{scope.organisation.slug}/#{workspace.slug}/settings"

      {:ok, lv, _html} = live(conn, general)
      assert has_element?(lv, "#settings-section-general #danger-zone #delete-workspace")
      refute has_element?(lv, "#settings-tab-danger")

      for path <- [general <> "/danger", general <> "/delete"] do
        {:ok, lv, _html} = live(conn, path)
        assert has_element?(lv, "#settings-tab-general[aria-current=page]")
        assert has_element?(lv, "#settings-section-general #delete-workspace-form")
        assert has_element?(lv, "#workspace-type-value", "A software workspace")
      end
    end
  end

  describe "the other sections" do
    setup :register_and_log_in_user

    test "People, Runs and Access keys are each the current entry of the second column",
         %{conn: conn, scope: scope} do
      for {key, rest, title} <- [
            {:people, "/people", "People"},
            {:runs, "/runs", "Runs"},
            {:keys, "/keys", "Access keys"}
          ] do
        {:ok, lv, _html} = live(conn, settings_path(scope, rest))

        assert has_element?(lv, "#settings-tabs #settings-tab-#{key}[aria-current=page]")
        refute has_element?(lv, "#main #settings-tabs")
        assert has_element?(lv, "#main h1", "Workspace settings")
        assert has_element?(lv, "h2#settings-section-title", title)
        assert has_element?(lv, "aside#sidebar #nav-settings[aria-current=page]")
      end
    end

    test "Runs keeps what the job pruned beside the retention, read only",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, settings_path(scope, "/runs"))

      assert has_element?(lv, "#settings-section-runs #retention-form")
      assert has_element?(lv, "#settings-section-runs #retention-pruned h3", "Pruned")
      refute has_element?(lv, "#retention-pruned form, #retention-pruned button")
    end

    @tag needs: :security
    test "Secrets and variables, and each of its pages, are the section's",
         %{conn: conn, scope: scope} do
      for rest <- ["/secrets", "/variables", "/secrets/new", "/variables/new"] do
        {:ok, lv, _html} = live(conn, settings_path(scope, rest))
        assert has_element?(lv, "#settings-tabs #settings-tab-secrets[aria-current=page]")
        assert has_element?(lv, "#not-on-runs", "Today a run receives only its security policy.")
      end
    end
  end
end
