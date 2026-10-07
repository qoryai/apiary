defmodule ApiaryWeb.InstanceLive.ConfigurationTest do
  @moduledoc """
  Instance › Configuration (`ApiaryWeb.InstanceLive.Configuration`): what whoever runs the
  server set, read only, for the instance's admins, behind the account menu's Instance;
  anyone else is answered as a path that does not exist. The suite's instance has had its
  first sign-up; a test that needs an instance admin hides its organisation inside its
  sandbox (`Apiary.EditionKit`), so the organisation it signs up is the instance's.
  """
  # Not async: hiding the instance's organisation acts on the row every test shares.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Apiary.{Audit, Deletion, Features, Instance}

  defp text(view, selector),
    do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  describe "for an instance admin" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "shows what the server set, read only, with where each value comes from",
         %{conn: conn, scope: scope} do
      assert Apiary.Access.instance_admin?(scope)

      {:ok, view, html} = live(conn, ~p"/instance/configuration")

      assert html =~ ~r{<title[^>]*>\s*Configuration · Instance · Qory Apiary\s*</title>}
      assert text(view, "h1.q-settings-title") =~ "Instance"
      assert text(view, "#settings-section-title") =~ "Configuration"

      for feature <- Features.built() do
        value = if Features.on?(feature), do: "On", else: "Off"
        assert text(view, "#config-feature-#{feature}-value") == value
      end

      assert text(view, "#config-url-sources-value") ==
               if(Apiary.Integrations.Source.url_sources?(), do: "Allowed", else: "Not allowed")

      assert text(view, "#config-audit-retention-value") == "#{Audit.retention_days()} days"

      assert text(view, "#config-audit-address-retention-value") ==
               "#{Audit.address_retention_days()} days"

      assert text(view, "#config-grace-value") == "#{Deletion.grace_days()} days"

      assert text(view, "#config-invitations-per-day-value") ==
               "#{Instance.invitations_per_day()}"

      # The suite does not start the nightly retention job.
      assert text(view, "#config-run-pruning-value") == "Off"

      # Each value says the setting of the server's environment it comes from.
      for {id, variable} <- [
            {"config-url-sources", "INTEGRATION_URL_SOURCES"},
            {"config-audit-retention", "AUDIT_RETENTION_DAYS"},
            {"config-audit-address-retention", "AUDIT_ADDRESS_RETENTION_DAYS"},
            {"config-grace", "DELETION_GRACE_DAYS"},
            {"config-invitations-per-day", "INVITATIONS_PER_DAY"}
          ] do
        assert text(view, "##{id} code") == variable
      end

      # Nothing on the page changes a value.
      refute has_element?(view, "#settings-section-configuration form")
      refute has_element?(view, "#settings-section-configuration input")
    end

    test "is the account menu's Instance, a page of its own beside the sidebar the person came from",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
      assert has_element?(view, "#user-menu-instance[href='/instance/configuration']")

      {:ok, view, _html} = live(conn, ~p"/instance/configuration")
      assert has_element?(view, "#user-menu-instance[href='/instance/configuration']")

      # The core's Instance has the one section: no second column.
      refute has_element?(view, "#instance-tabs")
      assert has_element?(view, "aside#sidebar[aria-label='Workspace']")
      assert has_element?(view, "#breadcrumb a[href='/instance/configuration']", "Instance")
      assert has_element?(view, "#breadcrumb [aria-current='page']", "Configuration")

      # The sidebar's lists open whole: nothing carries a target here.
      assert has_element?(view, "#nav-runs[href='#{workspace_path(scope, "/runs")}']")
      assert has_element?(view, "#nav-network[href='#{workspace_path(scope, "/network")}']")
    end
  end

  describe "for anyone else" do
    setup :register_and_log_in_user

    test "is not found, and the account menu has no Instance", %{conn: conn, scope: scope} do
      refute Apiary.Access.instance_admin?(scope)

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, ~p"/instance/configuration") end

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
      refute has_element?(view, "#user-menu-instance")
    end
  end

  test "sends a visitor to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/instance/configuration")
  end
end
