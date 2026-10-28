defmodule ApiaryWeb.IntegrationLive.ShowTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.ConnectionsFixtures
  import Apiary.DescriptionFixtures

  alias Apiary.{Connections, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.Integrations.Release

  @moduletag needs: :secrets

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
  defp flag_description(hint \\ "Logs every request it makes.") do
    github_description()
    |> put_in(["settings", "properties", "verbose"], %{
      "title" => "Verbose",
      "type" => "boolean",
      "description" => hint
    })
  end

  test "the breadcrumb names the integration, the page on Overview and a link to it on its other tabs",
       %{conn: conn, scope: scope} do
    {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
    integrations = workspace_path(scope, "/settings/integrations")
    {:ok, lv, _html} = live(conn, ipath(scope, runtime))

    assert crumbs(lv) == [
             {"Workspace settings", workspace_path(scope, "/settings")},
             {"Integrations", integrations},
             {"Claude Code", nil}
           ]

    # The name, as the page, is whole in its title; fixed words carry none.
    assert has_element?(lv, "#breadcrumb [aria-current=page] .truncate[title='Claude Code']")
    refute has_element?(lv, "#breadcrumb .truncate[title='Integrations']")

    for rest <- ["/targets", "/settings", "/delete"] do
      {:ok, lv, _html} = live(conn, ipath(scope, runtime, rest))

      assert crumbs(lv) == [
               {"Workspace settings", workspace_path(scope, "/settings")},
               {"Integrations", integrations},
               {"Claude Code", ipath(scope, runtime)}
             ]

      # As a link back, the name is whole in its title too.
      assert has_element?(lv, "#breadcrumb a .truncate[title='Claude Code']", "Claude Code")

      # A tab of the same page: the way back is a patch, as the tabs are.
      assert has_element?(
               lv,
               "#breadcrumb a[href='#{ipath(scope, runtime)}'][data-phx-link=patch]"
             )
    end
  end

  test "a name an external system gave, or one saved before the rules, is shown isolated and without its invisible characters" do
    connection = %Connection{kind: "service", name: "Sentry#{<<0x202E::utf8>>} EU\e"}
    names = ApiaryWeb.IntegrationLive.Common.names(connection)
    assert names == {"Sentry EU\u{FFFD}", nil}
    assert ApiaryWeb.IntegrationLive.Common.label(connection) == "Sentry EU\u{FFFD}"

    assigns = %{names: names}

    html =
      ~H"<ApiaryWeb.IntegrationLive.Common.name names={@names} />"
      |> rendered_to_string()

    assert html =~ ~r|<bdi[^>]*>Sentry EU\x{FFFD}</bdi>|u
  end

  describe "Overview" do
    test "says what an agent is, its id and where it applies, and offers no model key",
         %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, html} = live(conn, ipath(scope, runtime))

      assert has_element?(lv, "h1#settings-section-title", "Claude Code")
      assert has_element?(lv, "#connection-name.q-mono", "claude")
      assert has_element?(lv, "#connection-kind", "Agent")

      # No kind has a line under its title: nothing it would say is Qory Apiary's.
      refute has_element?(lv, "#connection-role")
      assert has_element?(lv, "#connection-facts dt", "Agent")
      assert has_element?(lv, "#connection-facts dt", "Applies to")
      assert has_element?(lv, "#connection-facts dt", "Secret files")
      assert has_element?(lv, "#connection-facts dd", "~/.claude/.credentials.json")
      refute has_element?(lv, "#connection-facts dt", "Credential files")
      refute has_element?(lv, "#connection-facts dt", "Runtime")
      refute has_element?(lv, "#connection-facts dt", "For runs in")
      assert has_element?(lv, "#connection-tabs[aria-label=Agent]")
      assert has_element?(lv, "#breadcrumb-section", "Integrations")
      assert page_title(lv) =~ "Claude Code · Integrations · Workspace settings"
      assert has_element?(lv, "#connection-tabs-overview[aria-current=page]")
      assert has_element?(lv, "#connection-id", runtime.public_id)
      assert has_element?(lv, "#connection-facts", "Every workspace")
      # A long value, such as the list of denied variables, wraps rather than widen the page.
      assert has_element?(lv, "#connection-facts dl.break-words")
      # A runtime connection offers none of the runtime's declarations, the model keys: the
      # page has no part for them and no group of them.
      refute has_element?(lv, "#connection-secrets")
      refute has_element?(lv, "#connection-secrets-unlinked")
      refute html =~ "ANTHROPIC_API_KEY"
      refute html =~ "CLAUDE_CODE_OAUTH_TOKEN"
      refute html =~ "It needs one of"

      section = lv |> element("#settings-section-integrations") |> render()
      refute section =~ "Qory"

      assert has_element?(lv, "#not-on-runs", "A run receives only its security policy.")

      refute html =~ "runs receive"
    end

    test "says where an integration comes from and its roles, every one as given",
         %{conn: conn, scope: scope} do
      release = ready_release!(scope, tracker_description(), "github.com/acme/tracker")

      {:ok, integration} =
        Connections.create_integration(scope, release.id, %{
          settings: %{"url" => "https://tracker.example.com"}
        })

      {:ok, lv, _html} = live(conn, ipath(scope, integration))

      refute has_element?(lv, "#connection-publisher")
      refute has_element?(lv, "#connection-ways")
      assert has_element?(lv, "#connection-roles", "acme_role, credential")
      assert has_element?(lv, "#connection-plain-settings", "https://tracker.example.com")
      assert has_element?(lv, "#settings-section-title", "Acme tracker")
      assert has_element?(lv, "#connection-name", "acme-tracker")
      assert has_element?(lv, "#connection-kind", "Program")

      # A program has no line under its title: nothing it would say is Qory Apiary's.
      refute has_element?(lv, "#connection-role")
    end

    test "says an API's kind, and the API it is set up from", %{conn: conn, scope: scope} do
      {:ok, service} = Connections.create_service(scope, %{service: "sentry"})
      {:ok, lv, _html} = live(conn, ipath(scope, service))

      assert has_element?(lv, "h1#settings-section-title", "Sentry")
      assert has_element?(lv, "#connection-kind", "API")

      refute has_element?(lv, "#connection-role")

      assert has_element?(lv, "#connection-facts dd", "API")
      assert has_element?(lv, "#connection-facts dt", "Set up from")
      assert has_element?(lv, "#connection-definition", "Sentry")
      refute lv |> element("#settings-section-integrations") |> render() =~ "ervice"
    end

    test "Applies to leads to Workspaces, its tab taking the focus", %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, _html} = live(conn, ipath(scope, runtime))

      assert lv
             |> element("#connection-applies-link[phx-click*='connection-tabs-targets']")
             |> render_click() =~ "It applies to every workspace of this organisation."

      assert has_element?(lv, "#connection-tabs-targets[aria-current=page]")
    end
  end

  # The tab Workspaces lists the workspaces of the organisation a connection applies to,
  # as its add set them: none is added or removed after.
  describe "Workspaces" do
    test "lists the chosen workspaces, with none to add or remove", %{conn: conn, scope: scope} do
      shop = workspace!(scope, "Shop")

      {:ok, runtime} =
        Connections.create_runtime(scope, %{
          runtime: "claude",
          applies_to: "selected",
          workspace_ids: [shop.id]
        })

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/targets"))
      assert has_element?(lv, "#target-#{shop.id}", "Shop")

      assert has_element?(
               lv,
               "#target-#{shop.id} a[href='/#{scope.organisation.slug}/#{shop.slug}']"
             )

      # The workspace's name is cut to its column, the whole of it in its title.
      assert has_element?(lv, "#target-#{shop.id} a.q-cut[title='Shop']", "Shop")
      refute has_element?(lv, "#target-#{scope.workspace.id}")
      refute has_element?(lv, "#add-target")
      refute has_element?(lv, "#remove-target-#{shop.id}")
    end

    test "a connection whose chosen workspaces are all gone applies to none",
         %{conn: conn, scope: scope} do
      {:ok, runtime} =
        Connections.create_runtime(scope, %{
          runtime: "claude",
          applies_to: "selected",
          workspace_ids: []
        })

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/targets"))
      assert has_element?(lv, "#connection-targets-empty", "It applies to no workspace.")

      {:ok, lv, _html} = live(conn, ipath(scope, runtime))
      assert has_element?(lv, "#connection-facts", "No workspace")
    end

    test "a refusal of a change of where it applies says how to share it", %{scope: scope} do
      assert ApiaryWeb.IntegrationLive.Common.refusal(scope, :reach_fixed) ==
               "To share it, add it again with “Available to every workspace in " <>
                 "#{scope.organisation.name}” on. Where it applies is set only when it is added."
    end

    test "a connection for every workspace offers none to add", %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/targets"))

      assert has_element?(lv, "#connection-applies", "every workspace")
      refute has_element?(lv, "#connection-targets")
      refute has_element?(lv, "#add-target")
    end
  end

  describe "Settings" do
    test "a service's name is saved, and where it applies is not offered",
         %{conn: conn, scope: scope} do
      {:ok, service} = Connections.create_service(scope, %{service: "npm"})
      {:ok, lv, _html} = live(conn, ipath(scope, service, "/settings"))
      refute has_element?(lv, "#connection-form fieldset legend", "Applies to")
      refute has_element?(lv, "#connection-form input[name='connection[applies_to]']")

      lv |> form("#connection-form", connection: %{name: "Packages"}) |> render_submit()

      assert %Connection{applies_to: "all", name: "Packages"} = reload(scope, service)
    end

    test "a runtime has no settings form, only its removal", %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/settings"))
      refute has_element?(lv, "#connection-form")
      assert has_element?(lv, "#delete-connection")
    end

    test "an integration's plain settings are saved and checked", %{conn: conn, scope: scope} do
      release = ready_release!(scope, github_description())
      {:ok, integration} = Connections.create_integration(scope, release.id, %{})

      {:ok, lv, _html} = live(conn, ipath(scope, integration, "/settings"))
      assert has_element?(lv, "#connection-setting-app_id")
      refute has_element?(lv, "#connection-setting-private_key")

      lv
      |> form("#connection-form",
        connection: %{argument: "acme/shop", settings: %{app_id: "104231"}}
      )
      |> render_submit()

      integration = reload(scope, integration)
      assert Connection.settings_map(integration) == %{"app_id" => "104231"}
      assert integration.argument == "acme/shop"

      html =
        lv
        |> form("#connection-form", connection: %{argument: "not a path!"})
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
               "It is removed from this organisation. This cannot be undone."
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

    test "a setting's hint is shown as an integration's text is", %{conn: conn, scope: scope} do
      release = ready_release!(scope, flag_description("Logs every\u202E request\u0085"))
      {:ok, integration} = Connections.create_integration(scope, release.id, %{})
      {:ok, lv, _html} = live(conn, ipath(scope, integration, "/settings"))

      assert has_element?(lv, "#connection-setting-verbose-hint", "Logs every request\u{FFFD}")
    end

    test "a setting whose description has nothing left to show has no hint",
         %{conn: conn, scope: scope} do
      release = ready_release!(scope, flag_description("\u202E\u200B"))
      {:ok, integration} = Connections.create_integration(scope, release.id, %{})
      {:ok, lv, _html} = live(conn, ipath(scope, integration, "/settings"))

      assert has_element?(lv, "#connection-setting-verbose")
      refute has_element?(lv, "#connection-setting-verbose-hint")
      refute has_element?(lv, "#connection-setting-verbose[aria-describedby]")
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
        connection: %{argument: "", settings: %{verbose: "false"}}
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

    test "is written by who may write its kind: a runtime under runtime.write",
         %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, service} = Connections.create_service(scope, %{service: "sentry"})

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.NoRuntimeWrite)

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/settings"))
      assert has_element?(lv, "#connection-readonly", "Only owners and admins")
      refute has_element?(lv, "#delete-connection")

      {:ok, lv, _html} = live(conn, ipath(scope, service, "/settings"))
      refute has_element?(lv, "#connection-readonly")
      assert has_element?(lv, "#delete-connection")
    end

    test "is written by who may write its kind: a service under connection.write",
         %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, service} = Connections.create_service(scope, %{service: "sentry"})

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.NoConnectionWrite)

      {:ok, lv, _html} = live(conn, ipath(scope, service, "/settings"))
      assert has_element?(lv, "#connection-readonly", "Only owners and admins")
      refute has_element?(lv, "#delete-connection")

      {:ok, lv, _html} = live(conn, ipath(scope, runtime, "/settings"))
      refute has_element?(lv, "#connection-readonly")
      assert has_element?(lv, "#delete-connection")
    end

    test "a member's writes, sent as events, are refused and change nothing", %{scope: scope} do
      shop = workspace!(scope, "Shop")
      release = ready_release!(scope, github_description())

      {:ok, integration} =
        Connections.create_integration(scope, release.id, %{
          applies_to: "selected",
          workspace_ids: [shop.id]
        })

      conn = member_conn(scope, :member)
      {:ok, lv, _html} = live(conn, ipath(scope, integration, "/targets"))

      for {event, params} <- [
            {"save", %{"connection" => %{"applies_to" => "all", "argument" => "acme/shop"}}},
            {"request_version", %{"version" => %{"version" => "0.2.0"}}},
            {"delete", %{}}
          ] do
        assert render_hook(lv, event, params) =~ "Only owners and admins", event
      end

      after_all = reload(scope, integration)
      assert after_all.applies_to == "selected"
      assert after_all.argument == integration.argument
      assert [%{workspace_id: workspace_id}] = after_all.workspaces
      assert workspace_id == shop.id
      assert Apiary.Repo.all(Release) |> length() == 1
    end

    test "an admin changes it", %{scope: scope} do
      {:ok, service} = Connections.create_service(scope, %{service: "npm"})

      conn = member_conn(scope, :admin)
      {:ok, lv, _html} = live(conn, ipath(scope, service, "/settings"))
      lv |> form("#connection-form", connection: %{name: "Packages"}) |> render_submit()
      assert reload(scope, service).name == "Packages"
    end

    test "a change of where it applies, sent as an event, changes nothing",
         %{conn: conn, scope: scope} do
      {:ok, service} = Connections.create_service(scope, %{service: "npm"})
      {:ok, lv, _html} = live(conn, ipath(scope, service, "/settings"))

      render_hook(lv, "save", %{"connection" => %{"applies_to" => "selected", "name" => "X"}})

      assert %Connection{applies_to: "all", workspaces: []} = reload(scope, service)
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

    test "a connection the organisation does not have is not found", %{
      conn: conn,
      scope: scope
    } do
      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, ipath(scope, %{public_id: "con_0123456789abcdef"}))
      end
    end

    test "another organisation's connection and workspaces are not this one's",
         %{conn: conn, scope: scope} do
      other = sign_up_fixture().scope
      {:ok, theirs} = Connections.create_runtime(other, %{runtime: "claude"})
      their_target = other.workspace

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, ipath(scope, theirs)) end

      assert Connections.create_runtime(scope, %{
               runtime: "claude",
               applies_to: "selected",
               workspace_ids: [their_target.id]
             }) == {:error, :workspace_not_found}
    end

    test "is the organisation's: another workspace of it shows the same connection",
         %{conn: conn, scope: scope, user: user} do
      site = workspace!(scope, "Site")

      {:ok, runtime} =
        Connections.create_runtime(scope, %{
          runtime: "claude",
          applies_to: "selected",
          workspace_ids: [scope.workspace.id]
        })

      at_site = workspace_scope(user, site)
      {:ok, lv, _html} = live(conn, ipath(at_site, runtime, "/targets"))
      assert has_element?(lv, "#target-#{scope.workspace.id}", "Main")
    end
  end

  describe "who added it and who changed it last" do
    # What Overview says of who added the connection `admin` added and who changed it
    # last, once `change` ran on it, and the page's text, its tags left out.
    defp said_of(conn, scope, admin, change) do
      {:ok, runtime} = Connections.create_runtime(admin.scope, %{runtime: "claude"})
      change.(runtime)
      {:ok, lv, _html} = live(conn, ipath(scope, runtime))
      text = lv |> render() |> plain()
      [_, added] = Regex.run(~r/Added (.*?) ·/, text)
      [_, changed] = Regex.run(~r/Last changed (.*?) ·/, text)
      assert added == changed
      {added, text}
    end

    defp plain(html),
      do: html |> String.replace(~r/<[^>]+>/, " ") |> String.split() |> Enum.join(" ")

    defp by_user(runtime, user) do
      runtime
      |> Ecto.Changeset.change(created_by_id: user.id, updated_by_id: user.id)
      |> Repo.update!()
    end

    # The words of a person's letter in the page's text: the letter, then the address of its
    # hidden text.
    defp letter(user), do: "#{String.upcase(String.first(user.email))} #{user.email}"

    test "a person removed from the organisation is named by the first letter of their account's address",
         %{conn: conn, scope: scope} do
      admin = member_fixture(scope, :admin)

      {said, text} =
        said_of(conn, scope, admin, fn _record -> Repo.delete!(admin.membership) end)

      assert said == letter(admin.user)
      assert text =~ admin.user.email
    end

    test "a deleted account is a former member", %{conn: conn, scope: scope} do
      admin = member_fixture(scope, :admin)

      {said, _text} =
        said_of(conn, scope, admin, fn _record ->
          {:ok, _deleted} = Apiary.Accounts.delete_user(admin.user)
        end)

      assert said == "Former member"
    end

    test "a person who is not a member of the organisation is named by the first letter of their account's address",
         %{conn: conn, scope: scope} do
      admin = member_fixture(scope, :admin)
      user = Apiary.AccountsFixtures.user_fixture()
      {said, text} = said_of(conn, scope, admin, &by_user(&1, user))
      assert said == letter(user)
      assert text =~ user.email
    end
  end
end
