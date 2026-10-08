defmodule ApiaryWeb.IntegrationLive.ShowTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.ConnectionsFixtures
  import Apiary.DescriptionFixtures

  alias Apiary.Connections
  alias Apiary.Connections.Connection
  alias Apiary.Integrations.Release

  @moduletag needs: :security

  setup :register_and_log_in_user

  defp ipath(scope, connection, rest \\ ""),
    do:
      "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/integrations/#{connection.public_id}#{rest}"

  defp member_conn(scope, level) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  defp reload(scope, connection) do
    {:ok, connection} = Connections.get_connection(scope, connection.public_id)
    connection
  end

  # github_description/0 with a yes/no setting its credential role lists, described.
  defp flag_description do
    github_description()
    |> put_in(["settings", "properties", "verbose"], %{
      "title" => "Verbose",
      "type" => "boolean",
      "description" => "Logs every request it makes."
    })
    |> update_in(["roles", "credential", "settings"], &(&1 ++ ["verbose"]))
  end

  describe "Overview" do
    test "says what an agent is, its id, the runs it is for and the secrets it declares",
         %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, html} = live(conn, ipath(scope, runtime))

      assert has_element?(lv, "h1#settings-section-title", "Claude Code")
      assert has_element?(lv, "#connection-name.q-mono", "claude")
      assert has_element?(lv, "#connection-kind", "Agent")

      assert has_element?(
               lv,
               "header #connection-role",
               "Runs in the repositories it applies to start this agent."
             )

      refute has_element?(lv, "#connection-role", "never holds")
      assert has_element?(lv, "#connection-facts dt", "Agent")
      assert has_element?(lv, "#connection-facts dt", "For runs in")
      refute has_element?(lv, "#connection-facts dt", "Runtime")
      refute has_element?(lv, "#connection-facts dt", "Applies to")
      assert has_element?(lv, "#connection-tabs[aria-label=Agent]")
      assert has_element?(lv, "#breadcrumb-section", "Integrations")
      assert page_title(lv) =~ "Claude Code · Integrations · Workspace settings"
      assert has_element?(lv, "#connection-tabs-overview[aria-current=page]")
      assert has_element?(lv, "#connection-id", runtime.public_id)
      assert has_element?(lv, "#connection-facts", "Every repository")
      assert has_element?(lv, "#connection-secrets", "ANTHROPIC_API_KEY")
      assert has_element?(lv, "#connection-secrets", "It needs one of: api_key, oauth_token.")

      assert has_element?(
               lv,
               "#connection-secrets-unlinked",
               "Qory Apiary links no stored secret to it."
             )

      section = lv |> element("#settings-section-integrations") |> render()
      # Qory Apiary is named only in the line of the secrets it declares.
      refute String.replace(section, "Qory Apiary links no stored secret", "") =~ "Qory"

      assert has_element?(lv, "#not-on-runs", "A run receives only its security policy.")

      refute html =~ "runs receive"
    end

    test "says where an integration comes from, its publisher beside the source, and its way",
         %{conn: conn, scope: scope} do
      release = ready_release!(scope, tracker_description(), "github.com/acme/tracker")

      {:ok, integration} =
        Connections.create_integration(scope, release.id, %{
          settings: %{"url" => "https://tracker.example.com"}
        })

      {:ok, lv, _html} = live(conn, ipath(scope, integration))

      assert has_element?(lv, "#connection-publisher", "Acme")
      assert has_element?(lv, "#connection-publisher", "github.com/acme")
      assert has_element?(lv, "#connection-ways", "Calls its API.")
      assert has_element?(lv, "#connection-tool-way", "which no runner runs yet")
      assert has_element?(lv, "#connection-roles", "credential, tool, work_source")
      assert has_element?(lv, "#connection-plain-settings", "https://tracker.example.com")
      assert has_element?(lv, "#settings-section-title", "Acme tracker")
      assert has_element?(lv, "#connection-name", "acme-tracker")
      assert has_element?(lv, "#connection-kind", "Program")

      assert has_element?(
               lv,
               "header #connection-role",
               "The runner starts this program outside the agent, to get the run a token for its API."
             )
    end

    test "says an API's kind, and the API it is set up from", %{conn: conn, scope: scope} do
      {:ok, service} = Connections.create_service(scope, %{service: "sentry"})
      {:ok, lv, _html} = live(conn, ipath(scope, service))

      assert has_element?(lv, "h1#settings-section-title", "Sentry")
      assert has_element?(lv, "#connection-kind", "API")

      assert has_element?(
               lv,
               "header #connection-role",
               "The agent in a run may call this API. The runner adds its token to the agent's requests."
             )

      assert has_element?(lv, "#connection-facts dd", "API")
      assert has_element?(lv, "#connection-facts dt", "Set up from")
      assert has_element?(lv, "#connection-definition", "Sentry")
      refute lv |> element("#settings-section-integrations") |> render() =~ "ervice"
    end

    test "For runs in leads to Targets, its tab taking the focus", %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, _html} = live(conn, ipath(scope, runtime))

      assert lv
             |> element("#connection-applies-link[phx-click*='connection-tabs-targets']")
             |> render_click() =~ "It applies to every repository of this workspace."

      assert has_element?(lv, "#connection-tabs-targets[aria-current=page]")
    end
  end

  describe "Targets" do
    test "a chosen target is added from a page, and removed on its row, confirmed",
         %{conn: conn, scope: scope} do
      shop = target!(scope, "acme/shop")
      billing = target!(scope, "acme/billing")

      {:ok, runtime} =
        Connections.create_runtime(scope, %{runtime: "claude", applies_to: "selected"})

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/targets"))
      assert has_element?(lv, "#connection-targets-empty")

      {:ok, lv, _html} =
        lv |> element("#add-target") |> render_click() |> follow_redirect(conn)

      assert has_element?(
               lv,
               "#add-target-page-title",
               "Add a repository to Claude Code (claude)"
             )

      assert has_element?(lv, "#candidate-#{shop.id}")
      assert has_element?(lv, "#target-candidates-status[role=status]", "2 repositories found.")
      assert has_element?(lv, "#add-#{shop.id}[aria-label='Add acme/shop']", "Add")

      lv |> form("#find-target-form", find: %{text: "shop"}) |> render_change()
      assert has_element?(lv, "#target-candidates-status", "1 repository found.")
      refute has_element?(lv, "#candidate-#{billing.id}")

      lv |> element("#add-#{shop.id}") |> render_click()
      # The row leaves the list; the focus goes to the search field, nothing else being left.
      assert_push_event(lv, "run:focus", %{id: "find_text"})

      assert [%{target_id: target_id}] = reload(scope, runtime).targets
      assert target_id == shop.id
      refute has_element?(lv, "#candidate-#{shop.id}")
      assert has_element?(lv, "#target-candidates-empty")

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/targets"))
      assert has_element?(lv, "#target-#{shop.id}", "acme/shop")
      assert has_element?(lv, "#remove-target-#{shop.id}[aria-label='Remove acme/shop']")

      # Cancel gives the focus back to the row's Remove.
      lv |> element("#remove-target-#{shop.id}") |> render_click()

      assert has_element?(
               lv,
               "#target-#{shop.id}-confirm",
               "Remove acme/shop from Claude Code (claude)?"
             )

      render_patch(lv, ipath(scope, runtime, "/targets"))
      focused = "remove-target-#{shop.id}"
      assert_push_event(lv, "run:focus", %{id: ^focused})
      assert has_element?(lv, "#remove-target-#{shop.id}")

      # Yes, remove: the row is gone, and Add target takes the focus.
      lv |> element("#remove-target-#{shop.id}") |> render_click()
      lv |> element("#target-#{shop.id}-remove", "Yes, remove") |> render_click()
      assert_push_event(lv, "run:focus", %{id: "add-target"})
      assert reload(scope, runtime).targets == []
      refute has_element?(lv, "#target-#{shop.id}")
    end

    test "a chosen target links to its page at its address, its system there where its path is shared",
         %{conn: conn, scope: scope} do
      shop = target!(scope, "acme/shop")
      billing = target!(scope, "acme/billing")

      Apiary.Repo.insert!(%Apiary.Runs.Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "gitlab.example",
        path: "acme/shop",
        first_seen_at: DateTime.utc_now()
      })

      {:ok, runtime} =
        Connections.create_runtime(scope, %{runtime: "claude", applies_to: "selected"})

      {:ok, runtime} = Connections.put_target(scope, runtime, shop.id)
      {:ok, runtime} = Connections.put_target(scope, runtime, billing.id)
      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/targets"))

      assert has_element?(
               lv,
               "#target-#{shop.id} a[href='#{workspace_path(scope, "/targets/github.example/acme/shop")}']"
             )

      assert has_element?(
               lv,
               "#target-#{billing.id} a[href='#{workspace_path(scope, "/targets/acme/billing")}']"
             )
    end

    test "after an Add, the next row's Add takes the focus", %{conn: conn, scope: scope} do
      billing = target!(scope, "acme/billing")
      docs = target!(scope, "acme/docs")
      shop = target!(scope, "acme/shop")

      {:ok, runtime} =
        Connections.create_runtime(scope, %{runtime: "claude", applies_to: "selected"})

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/targets/add"))

      lv |> element("#add-#{billing.id}") |> render_click()
      focused = "add-#{docs.id}"
      assert_push_event(lv, "run:focus", %{id: ^focused})

      lv |> element("#add-#{shop.id}") |> render_click()
      focused = "add-#{docs.id}"
      assert_push_event(lv, "run:focus", %{id: ^focused})
    end

    test "Add target lists the first 20 by name, and says there are more",
         %{conn: conn, scope: scope} do
      for n <- 1..21, do: target!(scope, "acme/shop-#{String.pad_leading("#{n}", 2, "0")}")

      {:ok, runtime} =
        Connections.create_runtime(scope, %{runtime: "claude", applies_to: "selected"})

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/targets/add"))

      assert has_element?(
               lv,
               "#target-candidates-more",
               "The first 20 by name: type to find another."
             )

      assert has_element?(lv, "#target-candidates tr", "acme/shop-20")
      refute has_element?(lv, "#target-candidates tr", "acme/shop-21")

      lv |> form("#find-target-form", find: %{text: "shop-21"}) |> render_change()
      assert has_element?(lv, "#target-candidates tr", "acme/shop-21")
      refute has_element?(lv, "#target-candidates-more")
    end

    test "a connection for every target offers no target to add", %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/targets"))

      assert has_element?(lv, "#connection-applies", "every repository")
      refute has_element?(lv, "#add-target")
    end

    test "for every target, the chosen ones it keeps are not listed to remove",
         %{conn: conn, scope: scope} do
      shop = target!(scope, "acme/shop")

      {:ok, runtime} =
        Connections.create_runtime(scope, %{runtime: "claude", applies_to: "selected"})

      {:ok, runtime} = Connections.put_target(scope, runtime, shop.id)
      {:ok, _runtime} = Connections.update_connection(scope, runtime, %{"applies_to" => "all"})

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/targets"))
      refute has_element?(lv, "#connection-targets")
      refute has_element?(lv, "#remove-target-#{shop.id}")

      assert {:error, {:live_redirect, _}} =
               live(conn, ipath(scope, runtime, "/targets/#{shop.id}/remove"))
    end
  end

  describe "Settings" do
    test "where it applies and a service's name are saved", %{conn: conn, scope: scope} do
      {:ok, service} = Connections.create_service(scope, %{service: "npm"})
      {:ok, lv, _html} = live(conn, ipath(scope, service, "/settings"))
      assert has_element?(lv, "#connection-form fieldset legend", "For runs in")

      lv
      |> form("#connection-form", connection: %{applies_to: "selected", name: "Packages"})
      |> render_submit()

      assert %Connection{applies_to: "selected", name: "Packages"} = reload(scope, service)
    end

    test "an integration's plain settings are saved and checked", %{conn: conn, scope: scope} do
      release = ready_release!(scope, github_description())
      {:ok, integration} = Connections.create_integration(scope, release.id, %{})

      {:ok, lv, _html} = live(conn, ipath(scope, integration, "/settings"))
      assert has_element?(lv, "#connection-setting-app_id")
      refute has_element?(lv, "#connection-setting-private_key")

      lv
      |> form("#connection-form",
        connection: %{applies_to: "all", argument: "acme/shop", settings: %{app_id: "104231"}}
      )
      |> render_submit()

      integration = reload(scope, integration)
      assert Connection.settings_map(integration) == %{"app_id" => "104231"}
      assert integration.argument == "acme/shop"

      html =
        lv
        |> form("#connection-form", connection: %{applies_to: "all", argument: "not a path!"})
        |> render_submit()

      assert html =~ "The argument doesn&#39;t match"
    end

    test "removing asks in place, then removes it", %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/settings"))

      assert has_element?(lv, "#delete-connection-title", "Remove this runtime")

      assert has_element?(
               lv,
               "#delete-connection",
               "It is removed from this workspace. This cannot be undone."
             )

      lv |> element("#delete-connection-button", "Remove runtime…") |> render_click()
      assert has_element?(lv, "#delete-connection-button[aria-expanded=true]")
      assert has_element?(lv, "#delete-connection-confirming", "Remove Claude Code (claude)?")
      assert has_element?(lv, "#delete-connection-confirm", "Yes, remove")

      {:error, {:live_redirect, %{to: to}}} =
        result = lv |> form("#delete-connection-form") |> render_submit()

      assert to =~ "/settings/integrations"
      {:ok, _lv, html} = follow_redirect(result, conn)
      assert html =~ "Claude Code (claude) is removed."
      assert {:ok, []} = Connections.list_connections(scope)
    end

    test "an integration's and a service's removal say what they remove",
         %{conn: conn, scope: scope} do
      release = ready_release!(scope, github_description())
      {:ok, integration} = Connections.create_integration(scope, release.id, %{})
      {:ok, service} = Connections.create_service(scope, %{service: "npm"})

      {:ok, lv, _html} = live(conn, ipath(scope, integration, "/settings"))
      assert has_element?(lv, "#delete-connection-button", "Remove program…")

      {:ok, lv, _html} = live(conn, ipath(scope, service, "/settings"))
      assert has_element?(lv, "#delete-connection-button", "Remove API…")
    end

    test "a yes/no setting says what it is, and is saved as no", %{conn: conn, scope: scope} do
      release = ready_release!(scope, flag_description())

      {:ok, integration} =
        Connections.create_integration(scope, release.id, %{settings: %{"verbose" => true}})

      {:ok, lv, _html} = live(conn, ipath(scope, integration, "/settings"))

      assert has_element?(
               lv,
               "#connection-setting-verbose[aria-describedby='connection-setting-verbose-hint']"
             )

      assert has_element?(lv, "#connection-setting-verbose-hint", "Logs every request it makes.")

      lv
      |> form("#connection-form",
        connection: %{applies_to: "all", argument: "", settings: %{verbose: "false"}}
      )
      |> render_submit()

      assert Connection.settings_map(reload(scope, integration)) == %{"verbose" => false}
    end

    test "another version is asked for, and leads to the release", %{conn: conn, scope: scope} do
      release = ready_release!(scope, github_description())
      {:ok, integration} = Connections.create_integration(scope, release.id, %{})
      {:ok, lv, _html} = live(conn, ipath(scope, integration, "/version"))

      {:error, {:live_redirect, %{to: to}}} =
        lv |> form("#version-form", version: %{version: "0.2.0"}) |> render_submit()

      asked = Apiary.Repo.get_by!(Release, requested_version: "0.2.0")
      assert to =~ "/releases/#{asked.id}?for=#{integration.public_id}"
    end

    test "a version that isn't one is said under its field", %{conn: conn, scope: scope} do
      release = ready_release!(scope, github_description())
      {:ok, integration} = Connections.create_integration(scope, release.id, %{})
      {:ok, lv, _html} = live(conn, ipath(scope, integration, "/version"))

      assert has_element?(lv, "#version-page-title", "Change the version of GitHub (github)")

      lv |> form("#version-form", version: %{version: "latest"}) |> render_submit()
      assert has_element?(lv, "#version_version-error", "must be a version such as 1.4.0")
      refute has_element?(lv, "#version-problems")
    end

    test "a runtime or a service has no version to change", %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ipath(scope, runtime, "/version"))

      assert to == ipath(scope, runtime, "/settings")

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/settings"))
      refute has_element?(lv, "#change-version")
    end

    test "is read only for a member, whose acts are refused", %{scope: scope} do
      {:ok, runtime} =
        Connections.create_runtime(scope, %{runtime: "claude", applies_to: "selected"})

      conn = member_conn(scope, :member)

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/targets"))
      refute has_element?(lv, "#add-target")

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/settings"))
      assert has_element?(lv, "#connection-readonly", "Only owners and admins")
      refute has_element?(lv, "#connection-form")
      refute has_element?(lv, "#delete-connection")

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(conn, ipath(scope, runtime, "/version"))

      assert flash["error"] =~ "Only owners and admins"

      assert {:error, {:live_redirect, _}} = live(conn, ipath(scope, runtime, "/delete"))
    end

    test "a member's writes, sent as events, are refused and change nothing", %{scope: scope} do
      shop = target!(scope, "acme/shop")
      billing = target!(scope, "acme/billing")
      release = ready_release!(scope, github_description())

      {:ok, integration} =
        Connections.create_integration(scope, release.id, %{applies_to: "selected"})

      {:ok, integration} = Connections.put_target(scope, integration, shop.id)
      conn = member_conn(scope, :member)
      {:ok, lv, _html} = live(conn, ipath(scope, integration, "/targets"))

      for {event, params} <- [
            {"put_target", %{"id" => billing.id}},
            {"remove_target", %{"id" => shop.id}},
            {"save", %{"connection" => %{"applies_to" => "all", "argument" => "acme/shop"}}},
            {"request_version", %{"version" => %{"version" => "0.2.0"}}},
            {"delete", %{}}
          ] do
        assert render_hook(lv, event, params) =~ "Only owners and admins", event
      end

      after_all = reload(scope, integration)
      assert after_all.applies_to == "selected"
      assert after_all.argument == integration.argument
      assert [%{target_id: target_id}] = after_all.targets
      assert target_id == shop.id
      assert Apiary.Repo.all(Release) |> length() == 1
    end

    test "an admin changes it", %{scope: scope} do
      shop = target!(scope, "acme/shop")

      {:ok, runtime} =
        Connections.create_runtime(scope, %{runtime: "claude", applies_to: "selected"})

      conn = member_conn(scope, :admin)
      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/targets/add"))
      lv |> element("#add-#{shop.id}") |> render_click()
      assert [%{target_id: target_id}] = reload(scope, runtime).targets
      assert target_id == shop.id

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/settings"))
      lv |> form("#connection-form", connection: %{applies_to: "all"}) |> render_submit()
      assert reload(scope, runtime).applies_to == "all"
    end

    test "an event its controls don't send changes nothing", %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, _html} = live(conn, ipath(scope, runtime))

      render_hook(lv, "save", %{"not" => "a form"})
      render_hook(lv, "request_version", %{"version" => %{"version" => "0.2.0"}})
      render_hook(lv, "unknown", %{})

      assert Process.alive?(lv.pid)
      assert reload(scope, runtime).applies_to == "all"
      assert Apiary.Repo.all(Release) == []
    end

    test "a connection the workspace does not have is not found", %{conn: conn, scope: scope} do
      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, ipath(scope, %{public_id: "con_0123456789abcdef"}))
      end
    end

    test "another workspace's connection and targets are not this one's",
         %{conn: conn, scope: scope} do
      other = sign_up_fixture().scope
      {:ok, theirs} = Connections.create_runtime(other, %{runtime: "claude"})
      their_target = target!(other, "acme/shop")

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, ipath(scope, theirs)) end

      {:ok, ours} =
        Connections.create_runtime(scope, %{runtime: "claude", applies_to: "selected"})

      assert {:error, {:live_redirect, _}} =
               live(conn, ipath(scope, ours, "/targets/#{their_target.id}/remove"))

      {:ok, lv, _html} = live(conn, ipath(scope, ours, "/targets/add"))
      refute has_element?(lv, "#candidate-#{their_target.id}")

      assert render_hook(lv, "put_target", %{"id" => their_target.id}) =~
               "That repository is not one of this workspace&#39;s."

      assert reload(scope, ours).targets == []
    end
  end
end
