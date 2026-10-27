defmodule ApiaryWeb.InstanceLive.ConfigurationTest do
  @moduledoc """
  Instance settings › Configuration (`ApiaryWeb.InstanceLive.Configuration`): the
  instance's settings, for the instance's admins after a recent sign-in, behind the Qory
  Apiary menu's Instance settings; anyone else is answered as a path that does not exist.
  Retention, Deletion and Invitations each have a form with its Save, a field for each
  setting the server's environment does not set; the rest is read only. The suite's
  instance has had its first sign-up; a test that needs an instance admin hides its
  organisation inside its sandbox (`Apiary.EditionKit`), so the organisation it signs up
  is the instance's.
  """
  # Not async: hiding the instance's organisation acts on the row every test shares, and
  # the environment's values are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures, only: [member_fixture: 1]

  alias Apiary.{Features, InstanceConfig}
  alias Apiary.Retention.Scheduler

  @subtitle "The settings of the whole instance. A setting with a field is changed here; a value set in the server's environment wins, and shows here read only. The others are read when Qory Apiary starts, from the server's environment or the application's configuration, as each says."

  @footnote "To change a value without a field, whoever runs Qory Apiary changes the setting named beside it and starts it again."

  @notes %{
    retention:
      "A change applies at the next daily job, at 02:40 UTC. A shorter period deletes or clears what it no longer keeps then; setting it longer again does not bring it back.",
    deletion:
      "A change applies to what is deleted after it; what is already deleted keeps its purge date.",
    invitations: "A change applies at once."
  }

  @sudo "You must re-authenticate to access this page."

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

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

  # The variables of the instance's settings, none set: the environment's value of each
  # is nil.
  defp unset_variables, do: put_settings(Enum.map(InstanceConfig.keys(), &{&1, nil}))

  # Submits a part's form with `attrs`, by the fields' names.
  defp save(view, part, attrs),
    do: view |> form("#config-#{part}-form", config: attrs) |> render_submit()

  # The rows of the instance's settings, by their ids, with the variable that sets each.
  @rows [
    {"config-audit-retention", "AUDIT_RETENTION_DAYS"},
    {"config-audit-address-retention", "AUDIT_ADDRESS_RETENTION_DAYS"},
    {"config-grace", "DELETION_GRACE_DAYS"},
    {"config-invitations-per-day", "INVITATIONS_PER_DAY"}
  ]

  describe "for an instance admin" do
    setup do
      unset_variables()
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    @tag :feature_sets
    test "shows the instance's settings, with a field for each the environment does not set",
         %{conn: conn, scope: scope} do
      assert Apiary.Access.instance_admin?(scope)

      {:ok, view, html} = live(conn, ~p"/instance/configuration")

      assert html =~ ~r{<title[^>]*>\s*Configuration · Instance settings · Qory Apiary\s*</title>}
      # The section is the page's one h1; the level is the breadcrumb's and the title's.
      assert text(view, "h1#settings-section-title") =~ "Configuration"
      refute has_element?(view, "#main h1", "Instance")

      assert text(view, "#settings-section-configuration .q-settings-head-sub") == @subtitle
      assert text(view, "#config-note") == @footnote

      for feature <- Features.built() do
        value = if Features.on?(feature), do: "On", else: "Off"
        assert text(view, "#config-feature-#{feature}-value") == value
      end

      if Features.on?(:secrets) do
        assert text(view, "#config-url-sources-value") ==
                 if(Apiary.Integrations.Source.url_sources?(), do: "Allowed", else: "Not allowed")
      else
        refute has_element?(view, "#config-integrations")
      end

      # The suite does not start the nightly retention job: its configuration says so, read
      # only, in the Retention part.
      assert text(view, "#config-run-pruning-value") == "Off"

      assert text(view, "#config-run-pruning-source") ==
               "Set in the application's configuration"

      refute has_element?(view, "#config-run-pruning input")

      # A field for each, empty while none is saved, with the default as its placeholder,
      # its unit and what empty gives; no value and no source line.
      for {id, default, hint} <- [
            {"config-audit-retention", "90", "Empty: 90 days."},
            {"config-audit-address-retention", "90", "Empty: 90 days."},
            {"config-grace", "30", "Empty: 30 days."},
            {"config-invitations-per-day", "20", "Empty: 20."}
          ] do
        assert has_element?(
                 view,
                 "##{id} input##{id}-input[type='text'][inputmode='numeric'][placeholder='#{default}']"
               )

        refute has_element?(view, "##{id}-input[value]:not([value=''])")
        # The row's label names the field.
        assert has_element?(view, "##{id} dt label[for='#{id}-input']")
        assert text(view, "##{id}-hint") == hint
        refute has_element?(view, "##{id}-value")
        refute has_element?(view, "##{id}-source")
      end

      for id <- ["config-audit-retention", "config-audit-address-retention", "config-grace"],
          do: assert(text(view, "##{id}-unit") == "days")

      refute has_element?(view, "#config-invitations-per-day-unit")

      # Each part its Save, with when a change takes effect.
      for {part, note} <- @notes do
        assert has_element?(view, "#config-#{part}-form #config-#{part}-save button", "Save")
        assert has_element?(view, "#config-#{part}-save button .btn-busy", "Saving")
        assert text(view, "#config-#{part}-save > span") == note
      end
    end

    @tag :feature_sets
    test "shows a value the environment sets read only, with the variable that sets it",
         %{conn: conn} do
      put_settings(
        features_setting: "all",
        integration_url_sources_setting: "true",
        audit_retention_days: 60,
        audit_address_retention_days: 14,
        deletion_grace_days: 21,
        invitations_per_day: 5
      )

      put_settings([{Scheduler, enabled: true, hour: 23}])

      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      assert text(view, "#config-audit-retention-value") == "60 days"
      assert text(view, "#config-audit-address-retention-value") == "14 days"
      assert text(view, "#config-grace-value") == "21 days"
      assert text(view, "#config-invitations-per-day-value") == "5"

      for {id, variable} <- @rows do
        assert text(view, "##{id}-source") == "Set by #{variable}"
        assert text(view, "##{id}-source code") == variable
        refute has_element?(view, "##{id}-input")
        refute has_element?(view, "##{id}-hint")
      end

      # A part whose every setting the environment sets has no form and no Save.
      for part <- [:retention, :deletion, :invitations] do
        refute has_element?(view, "#config-#{part}-form")
        refute has_element?(view, "#config-#{part}-save")
      end

      # The hour the scheduler starts at, and the hour within which it prunes.
      assert text(view, "#config-run-pruning-value") == "Every day, 23:00–00:00 UTC"
      assert text(view, "#config-run-pruning") =~ "Qory Apiary prunes each workspace's runs"

      if Features.on?(:secrets),
        do: assert(text(view, "#config-url-sources-source") == "Set by INTEGRATION_URL_SOURCES")

      assert text(view, "#config-features-source") == "Set by QORY_FEATURES"
    end

    test "the daily jobs' times are in the reader's time zone, with its mark",
         %{conn: conn, user: user} do
      {:ok, _} = Apiary.Accounts.update_user_preferences(user, %{time_zone: "Asia/Kolkata"})
      put_settings([{Scheduler, enabled: true, hour: 23}])

      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      # 23:00 UTC is 04:30 in Kolkata (IST, UTC+5:30); the audit trail's job at 02:40 UTC is
      # at 08:10 there.
      assert text(view, "#config-run-pruning-value") == "Every day, 04:30–05:30 IST"

      assert text(view, "#config-retention-save > span") ==
               "A change applies at the next daily job, at 08:10 IST. A shorter period deletes or clears what it no longer keeps then; setting it longer again does not bring it back."
    end

    test "a part whose environment sets one setting keeps a field for the other",
         %{conn: conn} do
      put_settings(audit_address_retention_days: 14)

      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      assert has_element?(view, "#config-retention-form #config-audit-retention-input")
      assert text(view, "#config-audit-address-retention-value") == "14 days"

      assert text(view, "#config-audit-address-retention-source") ==
               "Set by AUDIT_ADDRESS_RETENTION_DAYS"

      refute has_element?(view, "#config-audit-address-retention-input")
    end

    test "a variable set empty or blank is not set: the row has its field",
         %{conn: conn} do
      put_settings(
        audit_retention_setting: "",
        audit_address_retention_setting: "  ",
        deletion_grace_setting: " ",
        invitations_per_day_setting: ""
      )

      # As the boot reads them.
      Apiary.Audit.boot!()
      Apiary.Deletion.boot!()
      Apiary.Instance.boot!()

      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      for {id, _variable} <- @rows do
        assert has_element?(view, "##{id}-input")
        refute has_element?(view, "##{id}-source")
      end
    end

    @tag :feature_sets
    test "says the default where whoever runs the server set nothing, or an empty value, for the values read at start",
         %{conn: conn} do
      put_settings(features_setting: nil, integration_url_sources_setting: nil)
      put_settings([{Scheduler, []}])

      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      assert text(view, "#config-features-source") == "The default: QORY_FEATURES is not set"

      if Features.on?(:secrets),
        do:
          assert(
            text(view, "#config-url-sources-source") ==
              "The default: INTEGRATION_URL_SOURCES is not set"
          )

      put_settings(features_setting: "")
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")
      assert text(view, "#config-features-source") == "The default: QORY_FEATURES is empty"

      # The scheduler's own hour, 3, and the default that starts it.
      assert text(view, "#config-run-pruning-value") == "Every day, 03:00–04:00 UTC"

      assert text(view, "#config-run-pruning-source") ==
               "The default: the application's configuration does not set it"
    end

    test "saves each part, with its toast, and leaves the other parts as they were",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      save(view, :retention, %{
        audit_retention_days: " 60 ",
        audit_address_retention_days: "30"
      })

      assert text(view, "#flash-info") =~ "Retention saved."

      assert %{
               audit_retention_days: 60,
               audit_address_retention_days: 30,
               deletion_grace_days: nil,
               invitations_per_day: nil
             } = InstanceConfig.load()

      # The field holds what is saved, and what empty gives follows the trail's period.
      assert has_element?(view, "#config-audit-retention-input[value='60']")
      assert has_element?(view, "#config-audit-address-retention-input[value='30']")
      assert text(view, "#config-audit-address-retention-hint") == "Empty: 60 days."

      save(view, :deletion, %{deletion_grace_days: "1"})
      assert text(view, "#flash-info") =~ "Grace period saved."
      assert has_element?(view, "#config-grace-input[value='1']")

      save(view, :invitations, %{invitations_per_day: "50"})
      assert text(view, "#flash-info") =~ "Invitations a day saved."
      assert has_element?(view, "#config-invitations-per-day-input[value='50']")

      assert %{
               audit_retention_days: 60,
               audit_address_retention_days: 30,
               deletion_grace_days: 1,
               invitations_per_day: 50
             } = InstanceConfig.load()

      # Emptied: none saved, the default again.
      save(view, :deletion, %{deletion_grace_days: ""})
      assert %{deletion_grace_days: nil, invitations_per_day: 50} = InstanceConfig.load()
      refute has_element?(view, "#config-grace-input[value]:not([value=''])")

      # As the page reads it when it opens again.
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")
      assert has_element?(view, "#config-invitations-per-day-input[value='50']")
    end

    test "says what is wrong under the field, and saves nothing", %{conn: conn} do
      ceiling = Apiary.Edition.audit_retention_max_days()
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      for {part, id, attrs, message} <- [
            {:retention, "config-audit-retention", %{audit_retention_days: "29"},
             "must be between 30 and #{ceiling} days, or empty for the default"},
            {:retention, "config-audit-retention", %{audit_retention_days: "abc"},
             "must be between 30 and #{ceiling} days, or empty for the default"},
            {:retention, "config-audit-address-retention",
             %{audit_retention_days: "", audit_address_retention_days: "0"},
             "must be between 1 and 90 days, or empty for the default"},
            {:retention, "config-audit-address-retention",
             %{audit_retention_days: "60", audit_address_retention_days: "61"},
             "cannot be longer than the audit log entries are kept: 60 days"},
            {:deletion, "config-grace", %{deletion_grace_days: "91"},
             "must be between 1 and 90 days, or empty for the default"},
            {:deletion, "config-grace", %{deletion_grace_days: "0"},
             "must be between 1 and 90 days, or empty for the default"},
            {:invitations, "config-invitations-per-day", %{invitations_per_day: "0"},
             "must be a whole number from 1 to 1,000,000, or empty for the default"},
            {:invitations, "config-invitations-per-day", %{invitations_per_day: "1000001"},
             "must be a whole number from 1 to 1,000,000, or empty for the default"}
          ] do
        save(view, part, attrs)

        assert text(view, "##{id}-error") == message
        assert has_element?(view, "##{id}-input[aria-invalid='true']")
        refute has_element?(view, "#flash-info")
      end

      # What was typed stays in the field.
      assert has_element?(view, "#config-invitations-per-day-input[value='1000001']")
      assert InstanceConfig.load() == Map.new(InstanceConfig.keys(), &{&1, nil})

      # A save of another part leaves the errors of this one.
      save(view, :deletion, %{deletion_grace_days: "10"})
      assert text(view, "#flash-info") =~ "Grace period saved."
      refute has_element?(view, "#config-grace-error")
      assert has_element?(view, "#config-invitations-per-day-error")
    end

    test "refuses a trail's period shorter than the IP addresses the environment keeps",
         %{conn: conn} do
      put_settings(audit_address_retention_days: 80)
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      save(view, :retention, %{audit_retention_days: "60"})

      assert text(view, "#config-audit-retention-error") ==
               "cannot be shorter than the IP addresses are kept: 80 days"

      assert InstanceConfig.load().audit_retention_days == nil
    end

    test "asks for a recent sign-in, as Mail does", %{conn: conn, user: user} do
      stale = DateTime.add(DateTime.utc_now(:second), -11, :minute)
      stale_conn = log_in_user(build_conn(), user, token_authenticated_at: stale)

      assert {:error, {:redirect, %{to: "/users/log-in", flash: flash}}} =
               live(stale_conn, ~p"/instance/configuration")

      assert flash == %{"error" => @sudo}

      # Opened in time, and saved once the sign-in has grown old: nothing is saved, and the
      # page leads to the log-in page the same way.
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")
      old = DateTime.add(DateTime.utc_now(:second), -21, :minute)

      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns.current_scope.user.authenticated_at, old)
      end)

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               save(view, :invitations, %{invitations_per_day: "50"})

      assert assert_redirect(view, ~p"/users/log-in") == %{"error" => @sudo}
      assert InstanceConfig.load().invitations_per_day == nil
    end

    test "a part the page does not have saves nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      render_hook(view, "save", %{"part" => "other", "config" => %{"invitations_per_day" => "5"}})

      assert InstanceConfig.load().invitations_per_day == nil
      refute has_element?(view, "#flash-info")
    end

    test "renders the edition's parts after Invitations, which save as the core's do",
         %{conn: conn} do
      Apiary.Edition.put_test_stub(Apiary.EditionStubs.ConfigurationPart)

      {:ok, view, html} = live(conn, ~p"/instance/configuration")

      order =
        for id <- ["config-invitations", "config-example", "config-note"] do
          {at, _length} = :binary.match(html, ~s(id="#{id}"))
          at
        end

      assert order == Enum.sort(order)

      # Built from the core's row and source line.
      assert text(view, "#config-example-row-value") == "On"
      assert text(view, "#config-example-row-source") == "Set by EXAMPLE_SETTING"

      view |> form("#config-example-form") |> render_submit()
      assert text(view, "#flash-info") =~ "Example saved."

      # Its save after the sign-in has grown old: the page leads to the log-in page. The
      # part is given the page's scope when the page renders again.
      old = DateTime.add(DateTime.utc_now(:second), -21, :minute)

      :sys.replace_state(view.pid, fn state ->
        scope = state.socket.assigns.current_scope
        scope = put_in(scope.user.authenticated_at, old)
        %{state | socket: Phoenix.Component.assign(state.socket, :current_scope, scope)}
      end)

      render_hook(view, "save", %{})
      view |> form("#config-example-form") |> render_submit()
      assert assert_redirect(view, ~p"/users/log-in") == %{"error" => @sudo}
    end

    test "/instance sends on to the first section the person may open",
         %{conn: conn, scope: scope} do
      # Configuration in the core, the last section, after whatever the edition puts
      # before it.
      [first | _] = sections = ApiaryWeb.Layouts.instance_sections(scope)
      assert %{key: :configuration, path: "/instance/configuration"} = List.last(sections)
      path = ApiaryWeb.Nav.Entry.path(first, scope.organisation, scope.workspace)

      assert conn |> get(~p"/instance") |> redirected_to(302) == path
    end

    test "is the Qory Apiary menu's Instance settings, a page of its own beside the sidebar the person came from",
         %{conn: conn, scope: scope} do
      # Instance settings leads to the first section the person may open: Configuration
      # in the core, whatever the edition puts before it.
      [first | _] = ApiaryWeb.Layouts.instance_sections(scope)
      path = ApiaryWeb.Nav.Entry.path(first, scope.organisation, scope.workspace)
      instance = "#sidebar #brand-menu a#brand-menu-instance[href='#{path}']"

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
      assert has_element?(view, instance, "Instance settings")
      # The account menu has no Instance: the level is not the person's.
      refute has_element?(view, "#user-menu-instance")

      {:ok, view, _html} = live(conn, ~p"/instance/configuration")
      assert has_element?(view, instance, "Instance settings")
      refute has_element?(view, "#user-menu-instance")

      assert has_element?(view, "aside#sidebar[aria-label='Workspace']")

      # The breadcrumb's Instance settings leads to the first section, as the menu does.
      assert has_element?(view, "#breadcrumb a[href='#{path}']", "Instance settings")
      assert has_element?(view, "#breadcrumb [aria-current='page']", "Configuration")

      # The core's General and Mail, and an edition's sections, before it: the second
      # column lists Configuration too, the current page.
      assert [_, _ | _] = ApiaryWeb.Layouts.instance_sections(scope)

      assert has_element?(
               view,
               "#instance-tabs a#instance-tab-configuration[href='/instance/configuration'][aria-current='page']"
             )

      # The sidebar's lists open whole: nothing carries a target here.
      assert has_element?(view, "#nav-runs[href='#{workspace_path(scope, "/runs")}']")
      assert has_element?(view, "#nav-network[href='#{workspace_path(scope, "/network")}']")
    end

    # An opt-in feature is listed only where the instance has it.
    @tag with_features: Apiary.Features.all()
    test "lists path_rules, on, with what it covers, where the instance has it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      assert text(view, "#config-feature-path_rules") =~ "path_rules"
      assert text(view, "#config-feature-path_rules-value") == "On"
      assert text(view, "#config-feature-path_rules") =~ "Paths on a policy rule's form."
    end

    @tag with_features: Apiary.Features.all() -- [:path_rules]
    test "does not list path_rules where the instance does not have it", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/instance/configuration")

      assert has_element?(view, "#config-feature-security")
      refute has_element?(view, "#config-feature-path_rules")
      refute html =~ "path_rules"
      refute html =~ "Paths on a policy rule's form."
    end
  end

  describe "for a plain member of the instance's organisation" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "the Qory Apiary menu has no Instance settings, and the page is not found",
         %{conn: conn, scope: scope} do
      assert Apiary.Access.instance_admin?(scope)
      member = member_fixture(scope)
      refute Apiary.Access.instance_admin?(member.scope)

      conn = log_in_user(conn, member.user)
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
      assert has_element?(view, "#brand-menu a#brand-menu-docs")
      refute has_element?(view, "#brand-menu-instance")
      refute has_element?(view, "#user-menu-instance")

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, ~p"/instance/configuration") end
    end
  end

  describe "for anyone else" do
    setup :register_and_log_in_user

    test "is not found, and the Qory Apiary menu has no Instance settings for the owner of another organisation",
         %{conn: conn, scope: scope} do
      refute Apiary.Access.instance_admin?(scope)
      assert Apiary.Access.level(scope) == :owner

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, ~p"/instance/configuration") end
      # With no section to open, the level itself is not found either.
      assert_error_sent :not_found, fn -> get(conn, ~p"/instance") end

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
      assert has_element?(view, "#brand-menu a#brand-menu-docs")
      refute has_element?(view, "#brand-menu-instance")
      refute has_element?(view, "#user-menu-instance")
    end
  end

  test "sends a visitor to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/instance/configuration")
    assert conn |> get(~p"/instance") |> redirected_to(302) == "/users/log-in"
  end
end
