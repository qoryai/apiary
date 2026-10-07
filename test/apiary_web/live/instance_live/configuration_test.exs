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
  alias Apiary.Retention.Scheduler

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

  # Puts the application's settings for one test, and what was there back after it: the
  # page reads them when it mounts, as the server read them when it started.
  defp put_settings(settings) do
    for {key, value} <- settings do
      before = Application.fetch_env(:apiary, key)
      Application.put_env(:apiary, key, value)

      on_exit(fn ->
        case before do
          {:ok, value} -> Application.put_env(:apiary, key, value)
          :error -> Application.delete_env(:apiary, key)
        end
      end)
    end
  end

  # The values that come from a setting of the server's environment, by their ids.
  @variables [
    {"config-url-sources", "INTEGRATION_URL_SOURCES"},
    {"config-audit-retention", "AUDIT_RETENTION_DAYS"},
    {"config-audit-address-retention", "AUDIT_ADDRESS_RETENTION_DAYS"},
    {"config-grace", "DELETION_GRACE_DAYS"},
    {"config-invitations-per-day", "INVITATIONS_PER_DAY"}
  ]

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
      # The section is the page's one h1; the level is the breadcrumb's and the title's.
      assert text(view, "h1#settings-section-title") =~ "Configuration"
      refute has_element?(view, "#main h1", "Instance")

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

      # The suite does not start the nightly retention job: its configuration says so.
      assert text(view, "#config-run-pruning-value") == "Off"

      assert text(view, "#config-run-pruning-source") ==
               "Set in the application's configuration"

      # Each value says the setting of the server's environment it comes from, the features
      # once for them all.
      for {id, variable} <- @variables do
        assert text(view, "##{id}-source code") == variable
      end

      assert text(view, "#config-features-source code") == "QORY_FEATURES"

      for feature <- Features.built() do
        refute has_element?(view, "#config-feature-#{feature}-source")
      end

      # Nothing on the page changes a value.
      refute has_element?(view, "#settings-section-configuration form")
      refute has_element?(view, "#settings-section-configuration input")
    end

    test "shows each value as the server read it, and the setting that set it",
         %{conn: conn} do
      put_settings(
        features_setting: "all",
        integration_url_sources_setting: "true",
        audit_retention_days: 60,
        audit_retention_setting: "60",
        audit_address_retention_days: 14,
        audit_address_retention_setting: "14",
        deletion_grace_days: 21,
        deletion_grace_setting: "21",
        invitations_per_day: 5,
        invitations_per_day_setting: "5"
      )

      put_settings([{Scheduler, enabled: true, hour: 23}])

      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      assert text(view, "#config-audit-retention-value") == "60 days"
      assert text(view, "#config-audit-address-retention-value") == "14 days"
      assert text(view, "#config-grace-value") == "21 days"
      assert text(view, "#config-invitations-per-day-value") == "5"

      # The hour the scheduler starts at, and the hour within which it prunes.
      assert text(view, "#config-run-pruning-value") == "Every day, 23:00–00:00 UTC"
      assert text(view, "#config-run-pruning") =~ "The server prunes each workspace's runs"

      assert text(view, "#config-run-pruning-source") ==
               "Set in the application's configuration"

      for {id, variable} <- @variables do
        assert text(view, "##{id}-source") == "Set by #{variable}"
      end

      assert text(view, "#config-features-source") == "Set by QORY_FEATURES"
    end

    test "says the default where whoever runs the server set nothing, or an empty value",
         %{conn: conn} do
      put_settings(
        features_setting: nil,
        integration_url_sources_setting: nil,
        audit_retention_setting: "",
        audit_address_retention_setting: "  ",
        deletion_grace_setting: nil,
        invitations_per_day_setting: nil
      )

      put_settings([{Scheduler, []}])

      {:ok, view, html} = live(conn, ~p"/instance/configuration")

      assert html =~ "What whoever runs this server set for the whole instance, or the default"

      # Set to an empty or blank value: the default too, and said so.
      empty = ["config-audit-retention", "config-audit-address-retention"]

      for {id, variable} <- @variables do
        if id in empty,
          do: assert(text(view, "##{id}-source") == "The default: #{variable} is empty"),
          else: assert(text(view, "##{id}-source") == "The default: #{variable} is not set")
      end

      assert text(view, "#config-features-source") == "The default: QORY_FEATURES is not set"

      put_settings(features_setting: "")
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")
      assert text(view, "#config-features-source") == "The default: QORY_FEATURES is empty"

      # The scheduler's own hour, 3, and the default that starts it.
      assert text(view, "#config-run-pruning-value") == "Every day, 03:00–04:00 UTC"

      assert text(view, "#config-run-pruning-source") ==
               "The default: the application's configuration does not set it"
    end

    test "/instance sends on to the first section the person may open", %{conn: conn} do
      assert conn |> get(~p"/instance") |> redirected_to(302) == "/instance/configuration"
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

      # With no second column and so no disclosure, a phone's bar keeps both segments.
      refute has_element?(view, "#settings-disclosure")
      refute has_element?(view, "#breadcrumb li.q-trail-lead")

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
      # With no section to open, the level itself is not found either.
      assert_error_sent :not_found, fn -> get(conn, ~p"/instance") end

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
      refute has_element?(view, "#user-menu-instance")
    end
  end

  test "sends a visitor to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/instance/configuration")
    assert conn |> get(~p"/instance") |> redirected_to(302) == "/users/log-in"
  end
end
