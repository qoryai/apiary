defmodule ApiaryWeb.PolicyLive.RuleFormTest do
  use ApiaryWeb.ConnCase, async: true

  # The New rule and Edit rule pages of the workspace's policy and of a target's Policy
  # tab: a form that is a page of its own, never a line over the list.
  @moduletag needs: :security

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures
  import ApiaryWeb.TargetComponents, only: [target_path: 4]

  alias Apiary.Policy

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    :ok
  end

  defp open(conn, scope, rest \\ "/policy") do
    {:ok, view, _html} = live(conn, workspace_path(scope, rest))
    render_async(view, 5_000)
    view
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&#39;", "'")
    |> String.replace("&quot;", "\"")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # An element's text as it is read: unlike text/2, its tags add no space.
  defp read(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp type(view, params), do: view |> form("#policy-rule-form", rule: params) |> render_change()
  defp add(view), do: view |> form("#policy-rule-form") |> render_submit()

  # Add rule, in the section's header: a patch to the New rule page.
  defp new_rule(view) do
    view |> element("#policy-rules-head #policy-rules-add") |> render_click()
    view
  end

  defp rule(scope, host, holder \\ nil),
    do: Enum.find(Policy.list_rules(scope, holder), &(&1.host == host))

  defp as_reader(_context) do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ReadsThePolicy)
    :ok
  end

  describe "the list" do
    test "Add rule is the section's one primary button, apart from Find, Filter and Sort",
         %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      {:ok, _} = Policy.deny(scope, nil, %{host: "telemetry.example"})
      view = open(conn, scope)

      assert has_element?(view, "#policy-hosts[aria-labelledby=policy-hosts-h]")
      assert has_element?(view, "#policy-rules-head h2#policy-hosts-h", "Network access")
      assert text(view, "#policy-rules-count") == "2 rules"

      assert has_element?(
               view,
               "#policy-rules-head a#policy-rules-add.btn-primary[href='#{workspace_path(scope, "/policy/rules/new")}']",
               "Add rule"
             )

      refute has_element?(view, "#policy-rules-bar #policy-rules-add")
      assert has_element?(view, "#policy-rules-bar #policy-rules-query")
      assert has_element?(view, "#policy-rules-bar #policy-rules-filter")
      assert has_element?(view, "#policy-rules-bar #policy-rules-sort")

      assert text(view, "#policy-rules-line") ==
               "The hosts this workspace's runs may reach, and those they may not."

      # In the tab order, Add rule comes before the search.
      html = render(view)

      assert :binary.match(html, ~s(id="policy-hosts-network")) <
               :binary.match(html, ~s(id="policy-rules-add"))

      assert :binary.match(html, ~s(id="policy-rules-add")) <
               :binary.match(html, ~s(id="policy-rules-query"))
    end

    test "a row's menu offers Edit for an allow and for a deny, leading to its page",
         %{conn: conn, scope: scope} do
      {:ok, allow} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*"]})
      {:ok, deny} = Policy.deny(scope, nil, %{host: "telemetry.example"})
      view = open(conn, scope)

      for rule <- [allow, deny] do
        assert has_element?(
                 view,
                 "#rule-#{rule.id}-edit[href='#{workspace_path(scope, "/policy/rules/#{rule.id}/edit")}']",
                 "Edit"
               )
      end

      refute has_element?(view, "#rule-#{allow.id}-paths")
      refute render(view) =~ "Edit paths"
    end

    test "the top bar's New offers a network access rule", %{conn: conn, scope: scope} do
      view = open(conn, scope)

      assert has_element?(
               view,
               "#new-menu a#new-menu-rule[href='#{workspace_path(scope, "/policy/rules/new")}']",
               "Network access rule"
             )
    end

    test "the empty policy's Add a host rule leads to the page", %{conn: conn, scope: scope} do
      view = open(conn, scope)

      assert has_element?(
               view,
               "a#policy-first-rule[href='#{workspace_path(scope, "/policy/rules/new")}']",
               "Add a host rule"
             )

      view |> element("#policy-first-rule") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy/rules/new"))
      assert has_element?(view, "#policy-rule-title", "New rule")
    end
  end

  describe "the New rule page" do
    setup %{scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      :ok
    end

    test "opens from Add rule: a page of its own, empty, Allow picked, the button on",
         %{conn: conn, scope: scope} do
      view = new_rule(open(conn, scope))
      assert_patch(view, workspace_path(scope, "/policy/rules/new"))

      assert crumbs(view) == [{"Policy", workspace_path(scope, "/policy")}, {"New rule", nil}]

      assert page_title(view) =~
               "New rule · Policy · #{scope.workspace.name} · #{scope.organisation.name}"

      assert has_element?(view, "h1#policy-rule-title", "New rule")

      assert text(view, ".q-page-desc") ==
               "Let this workspace's runs reach a host, or stop them reaching it. A workspace rule applies to every repository of #{scope.workspace.name}; a repository rule may override it unless it is locked."

      # The list, its tabs and the mode card are not on the page.
      refute has_element?(view, "#policy-rules")
      refute has_element?(view, "#policy-tabs")
      refute has_element?(view, "#policy-mode")
      refute has_element?(view, "dialog#policy-rule-form")

      assert text(view, "#policy-rule-action-legend") == "What should runs do?"
      assert has_element?(view, "#policy-rule-allow[type=radio][checked]")
      refute has_element?(view, "#policy-rule-deny[checked]")

      assert text(view, "#policy-rule-allow-p") ==
               "Runs may connect to the host. Needed under enforce, where a host no rule allows is denied."

      assert text(view, "#policy-rule-deny-p") ==
               "Runs may not connect to the host, in observe and in enforce."

      assert has_element?(view, "label[for=policy-rule-host]", "Host")
      assert has_element?(view, "#policy-rule-host[placeholder='api.example.com']")
      assert has_element?(view, "#policy-rule-host[aria-describedby=policy-rule-host-hint]")

      assert read(view, "#policy-rule-host-hint") ==
               "The name runs connect to, in lower case, without https:// or a port. Start it with *. to cover every host below a domain, such as *.example.com."

      assert read(view, "label[for=policy-rule-paths]") == "PathsOptional"
      assert has_element?(view, "#policy-rule-paths[placeholder='Every path']")

      assert read(view, "#policy-rule-paths-hint") ==
               "Leave it empty to allow every path. Separate paths with spaces; end one with * for everything below it, such as /v1/*."

      assert has_element?(
               view,
               "#policy-rule-preview[aria-live=polite] h2",
               "What this rule does"
             )

      assert text(view, "#policy-rule-reads") ==
               "Type a host to see the rule in plain words before you add it."

      assert has_element?(view, "#policy-rule-add[type=submit]", "Add rule")
      refute has_element?(view, "#policy-rule-add[disabled]")

      assert has_element?(
               view,
               "a#policy-rule-save-cancel[href='#{workspace_path(scope, "/policy")}']",
               "Cancel"
             )

      assert text(view, "#policy-rule-save") =~ "It takes effect within a heartbeat, about 30 s."
      assert_push_event(view, "policy:focus", %{id: "policy-rule-allow"})
    end

    test "reads the rule back in plain words as it is typed", %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/rules/new")

      type(view, %{host: "api.partner.example.com", paths: "/v1/*  /health"})
      assert has_element?(view, "#policy-rule-preview.q-rule-preview-ok")

      assert read(view, "#policy-rule-reads") ==
               "Allow api.partner.example.com on 2 paths: everything below /v1/, and /health exactly. Behind a wall the proxy reads requests to this host to check the path."

      type(view, %{host: "*.internal.example", paths: ""})

      assert read(view, "#policy-rule-reads") ==
               "Allow every host below internal.example, on every path. It does not allow internal.example itself."
    end

    test "a deny takes no paths, and reads back what it takes out", %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/rules/new")

      type(view, %{action: "deny", host: "telemetry.example", paths: "/v1/*"})
      assert has_element?(view, "#policy-rule-deny[checked]")
      refute has_element?(view, "#policy-rule-paths")
      assert text(view, "#policy-rule-paths-deny") == "A deny covers every path of the host."

      assert read(view, "#policy-rule-reads") ==
               "Deny telemetry.example. It takes the host out of what the workspace allows; a repository can still allow it unless you lock this rule. It is denied in either mode, observe too."

      add(view)
      assert %{action: "deny", paths: nil} = rule(scope, "telemetry.example")
    end

    test "an empty host is said under Host when Add rule is pressed, and Host is focused",
         %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/rules/new")
      add(view)

      assert read(view, "#policy-rule-host-error") == "Enter a host, such as api.example.com."
      assert has_element?(view, "#policy-rule-host[aria-invalid=true].input-error")
      assert has_element?(view, "#policy-rule-host[aria-describedby=policy-rule-host-error]")
      refute has_element?(view, "#policy-rule-host-hint")
      assert_push_event(view, "policy:focus", %{id: "policy-rule-host"})
      assert has_element?(view, "#policy-rule-title", "New rule")
      assert length(Policy.list_rules(scope, nil)) == 1

      # Typing a host takes the error back.
      type(view, %{host: "api.example"})
      refute has_element?(view, "#policy-rule-host-error")
      assert has_element?(view, "#policy-rule-host-hint")
    end

    test "a URL is said under Host, with the repair as a link that fills the fields",
         %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/rules/new")

      type(view, %{host: "https://API.example:443/v1/messages?x=1", paths: ""})

      assert text(view, "#policy-rule-host-error") =~
               "A rule names a host and nothing else: lower case, no scheme, no port, no path."

      assert has_element?(view, "#policy-rule-host[aria-invalid=true]")
      refute has_element?(view, "#policy-rule-paths[aria-invalid]")
      assert text(view, "#policy-rule-reads") == "Fix the host to see the rule in plain words."

      # Add rule is never off: pressed, it says nothing new and focuses the field.
      refute has_element?(view, "#policy-rule-add[disabled]")
      add(view)
      assert_push_event(view, "policy:focus", %{id: "policy-rule-host"})
      assert length(Policy.list_rules(scope, nil)) == 1

      view
      |> element("#policy-rule-host-error button", "Use api.example with the path /v1/messages")
      |> render_click()

      assert_push_event(view, "policy:fields", %{
        fields: %{"policy-rule-host" => "api.example", "policy-rule-paths" => "/v1/messages"}
      })

      assert_push_event(view, "policy:focus", %{id: "policy-rule-host"})
      refute has_element?(view, "#policy-rule-host-error")

      assert read(view, "#policy-rule-reads") =~
               "Allow api.example on 1 path: /v1/messages exactly."
    end

    test "each error of the grammar is said under its own field", %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/rules/new")

      type(view, %{host: "api.*.example", paths: "v1"})
      assert text(view, "#policy-rule-host-error") =~ "*. may only lead a host"
      assert text(view, "#policy-rule-paths-error") =~ "A path starts with / and may end in one *"
      assert has_element?(view, "#policy-rule-host[aria-invalid=true]")
      assert has_element?(view, "#policy-rule-paths[aria-invalid=true]")
      assert has_element?(view, "#policy-rule-paths[aria-describedby=policy-rule-paths-error]")

      type(view, %{host: "-bad-.example", paths: ""})

      assert text(view, "#policy-rule-host-error") ==
               "Each part of a host is 1 to 63 letters, digits or dashes, and does not start or end with a dash."

      refute has_element?(view, "#policy-rule-paths-error")

      type(view, %{host: "10.0.0.12:443", paths: ""})

      assert read(view, "#policy-rule-host-error") ==
               "An address is written like a host, digits and dots only: 10.0.0.12. The wall refuses link-local addresses and the machine's addresses whatever the policy says."

      # The host is right and a path is not: the error under Paths, Paths focused on Add.
      type(view, %{host: "api.example", paths: "/v1?x=1"})
      refute has_element?(view, "#policy-rule-host-error")
      assert text(view, "#policy-rule-paths-error") =~ "A path starts with /"
      assert text(view, "#policy-rule-reads") == "Fix the paths to see the rule in plain words."
      add(view)
      assert_push_event(view, "policy:focus", %{id: "policy-rule-paths"})
      refute rule(scope, "api.example")
    end

    test "the same rule again is said under Host, and Show it leads to it in the list",
         %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/rules/new")

      type(view, %{host: "registry.example", paths: ""})

      assert text(view, "#policy-rule-host-error") =~
               "registry.example is already allowed for the workspace"

      assert text(view, "#policy-rule-reads") ==
               "Nothing new: this rule is already in the list. To change its paths, edit it from its row."

      view |> element("#policy-rule-host-error button", "Show it") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?rule=registry.example"))
      assert has_element?(view, "#policy-rules tr.q-ruled", "registry.example")
    end

    test "the opposite rule is a note in the preview, and the button says it replaces it",
         %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/rules/new")

      type(view, %{action: "deny", host: "registry.example"})
      assert has_element?(view, "#policy-rule-preview.q-rule-preview-note")

      assert read(view, "#policy-rule-reads") ==
               "registry.example is allowed for the workspace. Adding this deny replaces that rule."

      assert text(view, "#policy-rule-add") == "Replace with deny"
      add(view)

      assert_patch(view, workspace_path(scope, "/policy?rule=registry.example"))
      assert %{action: "deny"} = rule(scope, "registry.example")
      assert text(view, "#flash-info") =~ "registry.example is denied for the workspace. Version"
    end

    test "an allow held to paths is not opened without saying so; Every path does it",
         %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*"]})
      view = open(conn, scope, "/policy/rules/new")

      type(view, %{host: "api.example", paths: ""})
      assert read(view, "#policy-rule-paths-error") =~ "api.example is held to /v1/*"
      assert has_element?(view, "#policy-rule-paths[aria-invalid=true]")
      refute has_element?(view, "#policy-rule-host-error")
      add(view)
      assert_push_event(view, "policy:focus", %{id: "policy-rule-paths"})

      view |> element("#policy-rule-paths-error button", "Every path") |> render_click()
      assert_push_event(view, "policy:focus", %{id: "policy-rule-paths"})
      assert read(view, "#policy-rule-reads") =~ "Saving changes its paths to every path"
      assert text(view, "#policy-rule-add") == "Change paths"

      add(view)
      assert %{paths: nil} = rule(scope, "api.example")
    end

    test "Add rule writes the rule, and goes back to the list as it was left, the row marked",
         %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "zzz.example"})
      view = open(conn, scope, "/policy?sort=host&view=allowed")

      view |> element("#policy-rules-add") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy/rules/new"))

      assert has_element?(
               view,
               "#policy-rule-save-cancel[href='#{workspace_path(scope, "/policy?sort=host&view=allowed")}']"
             )

      type(view, %{host: "api.partner.example.com", paths: "/v1/*"})
      add(view)

      %{id: id} = rule(scope, "api.partner.example.com")
      [_, version] = Regex.run(~r/Version (\d+)\./, text(view, "#flash-info"))

      assert_patch(
        view,
        workspace_path(scope, "/policy?rule=api.partner.example.com&sort=host&view=allowed")
      )

      assert has_element?(view, "#rule-#{id}.q-ruled.q-fresh", "api.partner.example.com")
      assert text(view, "#rule-#{id}") =~ "New in v#{version}"
      assert has_element?(view, "#policy-rules-view-allowed[aria-current=page]")

      assert text(view, "#flash-info") ==
               "api.partner.example.com is allowed for the workspace. Version #{version}."

      assert text(view, "#policy-announce") == "Rule added. Version #{version}."
      assert_push_event(view, "policy:focus", %{id: "rule-" <> ^id <> "-menu-button"})
      assert_push_event(view, "policy:rule", %{host: "api.partner.example.com"})
    end

    test "a filter that would hide the new rule is dropped, so the rule shows",
         %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy?view=denied")
      new_rule(view)
      type(view, %{host: "api.partner.example.com", paths: ""})
      add(view)

      assert_patch(
        view,
        workspace_path(scope, "/policy?rule=api.partner.example.com&view=denied")
      )

      assert has_element?(view, "#policy-rules tr.q-ruled", "api.partner.example.com")
    end

    test "Cancel goes back to the list as it was left, and saves nothing",
         %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy?sort=host")
      new_rule(view)
      type(view, %{host: "api.partner.example.com", paths: ""})

      view |> element("#policy-rule-save-cancel") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?sort=host"))
      assert has_element?(view, "#policy-rules")
      refute rule(scope, "api.partner.example.com")

      # Opened again, the form is empty: the pasted queue and the host are dropped.
      new_rule(view)
      assert has_element?(view, "#policy-rule-host[value='']")
    end

    test "a pasted list fills Host with the first and counts the rest; the page stays until the last",
         %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/rules/new")
      assert has_element?(view, "#policy-rule-form[phx-hook=RuleComposer][data-paste=rule_paste]")

      render_hook(view, "rule_paste", %{"hosts" => ["a.example", "b.example", "c.example"]})

      assert has_element?(
               view,
               "label[for=policy-rule-host] #policy-rule-queued",
               "2 more to add"
             )

      assert has_element?(view, "#policy-rule-host[value='a.example']")

      add(view)
      assert rule(scope, "a.example")
      assert has_element?(view, "#policy-rule-title", "New rule")
      assert text(view, "#policy-rule-queued") == "1 more to add"
      assert has_element?(view, "#policy-rule-host[value='b.example']")
      assert read(view, "#policy-rule-reads") =~ "Allow b.example"
      assert text(view, "#flash-info") =~ "a.example is allowed for the workspace."
      assert_push_event(view, "policy:focus", %{id: "policy-rule-host"})

      add(view)
      refute has_element?(view, "#policy-rule-queued")
      assert has_element?(view, "#policy-rule-host[value='c.example']")

      add(view)
      assert_patch(view, workspace_path(scope, "/policy?rule=c.example"))
      assert rule(scope, "c.example")
    end

    test "the address fills the form: an action, a host, paths, and the field to focus",
         %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/rules/new?action=deny&host=telemetry.example")
      assert has_element?(view, "#policy-rule-deny[checked]")
      assert has_element?(view, "#policy-rule-host[value='telemetry.example']")
      assert read(view, "#policy-rule-reads") =~ "Deny telemetry.example."
      assert_push_event(view, "policy:focus", %{id: "policy-rule-deny"})

      view = open(conn, scope, "/policy/rules/new?host=api.example&paths=/v1/*&focus=paths")
      assert has_element?(view, "#policy-rule-allow[checked]")
      assert has_element?(view, "#policy-rule-paths[value='/v1/*']")
      assert read(view, "#policy-rule-reads") =~ "Allow api.example on 1 path"
      assert_push_event(view, "policy:focus", %{id: "policy-rule-paths"})
    end

    test "what the domain refuses stays on the page, above the foot", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "*.cdn.example", paths: ["/v1/*"]})
      view = open(conn, scope, "/policy/rules/new")

      type(view, %{host: "files.cdn.example", paths: ""})
      add(view)

      assert text(view, "#policy-rule-write-error") =~ "held to paths"
      assert has_element?(view, "#policy-rule-title", "New rule")
      refute rule(scope, "files.cdn.example")

      # The refusal stands in the read-back's place, above the foot.
      refute has_element?(view, "#policy-rule-preview")
      html = render(view)

      assert :binary.match(html, ~s(id="policy-rule-write-error")) <
               :binary.match(html, ~s(id="policy-rule-save"))

      # Edited again, the read-back is back and the refusal gone.
      type(view, %{host: "files.cdn.example", paths: "/v1/files/*"})
      refute has_element?(view, "#policy-rule-write-error")
      assert has_element?(view, "#policy-rule-preview")
      assert read(view, "#policy-rule-reads") =~ "Allow files.cdn.example on 1 path"

      # A repair link is an edit too.
      type(view, %{host: "files.cdn.example", paths: ""})
      add(view)
      refute has_element?(view, "#policy-rule-preview")
      render_click(view, "rule_use", %{"host" => "files.cdn.example", "paths" => "/v1/a"})
      refute has_element?(view, "#policy-rule-write-error")
      assert has_element?(view, "#policy-rule-preview")

      # And so is a pasted list, which the hook sends with no change after it.
      type(view, %{host: "files.cdn.example", paths: ""})
      add(view)
      assert has_element?(view, "#policy-rule-write-error")
      render_hook(view, "rule_paste", %{"hosts" => ["a.example", "b.example"]})
      refute has_element?(view, "#policy-rule-write-error")
      assert has_element?(view, "#policy-rule-preview")
      assert has_element?(view, "#policy-rule-host[value='a.example']")
      assert read(view, "#policy-rule-reads") =~ "Allow a.example"

      # Cancel leaves the refusal on the form.
      view |> element("#policy-rule-save-cancel") |> render_click()
      refute has_element?(view, "#policy-write-error")
    end

    test "under a locked rule an owner may change, a member is refused above the foot",
         %{scope: scope} = context do
      {:ok, _} = Policy.allow(scope, nil, %{host: "locked.example", locked: true})
      %{user: member} = member_fixture(scope, :member)
      view = open(log_in_user(build_conn(), member), scope, "/policy/rules/new")

      type(view, %{action: "deny", host: "locked.example"})

      assert text(view, "#policy-rule-refusal") =~
               "Only an owner can lock, unlock or change a locked rule."

      refute has_element?(view, "#policy-rule-preview")
      add(view)
      assert_push_event(view, "policy:focus", %{id: "policy-rule-host"})
      assert %{action: "allow"} = rule(scope, "locked.example")

      # The owner reads the rule back, and may replace it.
      view = open(context.conn, scope, "/policy/rules/new")
      type(view, %{action: "deny", host: "locked.example"})
      refute has_element?(view, "#policy-rule-refusal")
      assert text(view, "#policy-rule-add") == "Replace with deny"
    end
  end

  describe "the Edit rule page" do
    test "Edit opens the rule: its host kept, its paths in the field; Change paths saves",
         %{conn: conn, scope: scope} do
      {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*", "/health"]})
      view = open(conn, scope, "/policy?sort=host")

      view |> element("#rule-#{rule.id}-edit") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy/rules/#{rule.id}/edit"))

      assert crumbs(view) == [
               {"Policy", workspace_path(scope, "/policy?sort=host")},
               {"Edit rule", nil}
             ]

      assert page_title(view) =~ "Edit rule · Policy"
      assert has_element?(view, "h1#policy-rule-title", "Edit the rule for api.example")

      assert text(view, ".q-page-desc") ==
               "Change what this workspace's runs may do with api.example. The host stays; to rule on another host, add a new rule."

      refute has_element?(view, "#policy-rule-host")
      assert text(view, "#policy-rule-host-shown") == "api.example"
      assert has_element?(view, "#policy-rule-allow[checked]")
      assert has_element?(view, "#policy-rule-paths[value='/v1/* /health']")
      assert text(view, "#policy-rule-reads") == "Nothing to save: the rule is as it was."
      assert_push_event(view, "policy:focus", %{id: "policy-rule-allow"})

      # Nothing changed: nothing is written, the focus stays on the form.
      add(view)
      assert_push_event(view, "policy:focus", %{id: "policy-rule-allow"})
      assert has_element?(view, "#policy-rule-title", "Edit the rule for api.example")

      type(view, %{paths: "/v1/* /health /v2/*"})

      assert text(view, "#policy-rule-reads") ==
               "api.example is allowed for the workspace on /v1/* /health . Saving changes its paths to /v1/* /health /v2/* ."

      assert text(view, "#policy-rule-add") == "Change paths"
      add(view)

      assert_patch(view, workspace_path(scope, "/policy?rule=api.example&sort=host"))
      assert %{paths: ["/v1/*", "/health", "/v2/*"]} = rule(scope, "api.example")
      assert text(view, "#flash-info") =~ "api.example is allowed for the workspace. Version"
    end

    test "a deny's Edit offers Allow, and the button says it replaces it",
         %{conn: conn, scope: scope} do
      {:ok, rule} = Policy.deny(scope, nil, %{host: "telemetry.example"})
      view = open(conn, scope, "/policy/rules/#{rule.id}/edit")

      assert has_element?(view, "#policy-rule-deny[checked]")
      assert text(view, "#policy-rule-paths-deny") == "A deny covers every path of the host."

      type(view, %{action: "allow"})
      assert text(view, "#policy-rule-add") == "Replace with allow"
      add(view)

      assert_patch(view, workspace_path(scope, "/policy?rule=telemetry.example"))
      assert %{action: "allow"} = rule(scope, "telemetry.example")
    end

    test "a rule that is not there leads back to the list, saying so", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      gone = Ecto.UUID.generate()

      # Sent back as the page opens: the list, and the domain's sentence.
      view = open(conn, scope, "/policy/rules/#{gone}/edit")
      refute has_element?(view, "#policy-rule-form")
      assert has_element?(view, "#policy-rules")
      assert text(view, "#flash-error") =~ "This workspace has no such rule."
    end
  end

  describe "a reader who may not change the policy" do
    test "sees no Add rule and no row menus", %{conn: conn, scope: scope} = context do
      {:ok, rule} = Policy.allow(scope, nil, %{host: "registry.example"})
      as_reader(context)
      view = open(conn, scope)

      assert has_element?(view, "#policy-rules-head h2", "Network access")
      refute has_element?(view, "#policy-rules-add")
      refute has_element?(view, "#rule-#{rule.id}-menu")
      refute has_element?(view, "#new-menu-rule")
    end

    test "is sent back from the form's address to the list, told why",
         %{conn: conn, scope: scope} = context do
      {:ok, rule} = Policy.allow(scope, nil, %{host: "registry.example"})
      as_reader(context)

      for rest <- ["/policy/rules/new", "/policy/rules/#{rule.id}/edit"] do
        view = open(conn, scope, rest)
        assert text(view, "#flash-error") == "You can read this policy but not change it."
        refute has_element?(view, "#policy-rule-form")
        assert has_element?(view, "#policy-rules")
      end

      # Reached by a patch from the list, the same.
      view = open(conn, scope)
      render_patch(view, workspace_path(scope, "/policy/rules/new"))
      assert_patch(view, workspace_path(scope, "/policy"))
      refute has_element?(view, "#policy-rule-form")
    end

    test "a hand-made save is refused, and nothing is written",
         %{conn: conn, scope: scope} = context do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      as_reader(context)
      view = open(conn, scope)

      for {change, save} <- [{"rule_validate", "rule_save"}, {"composer_change", "composer_save"}] do
        render_hook(view, change, %{"rule" => %{"host" => "crafted.example", "paths" => ""}})
        render_hook(view, save, %{})
      end

      assert Process.alive?(view.pid)
      refute rule(scope, "crafted.example")
      assert length(Policy.list_rules(scope, nil)) == 1
    end

    test "is sent back from a target's form addresses to its Policy tab",
         %{conn: conn, scope: scope} = context do
      started_run(scope, shop())
      [%{target: target}] = Policy.list_targets(scope)
      {:ok, own} = Policy.allow(scope, target, %{host: "mcp.acme.example"})
      path = target_path(scope, target.system, target.path, ["policy"])
      as_reader(context)

      for rest <- ["/rules/new", "/rules/#{own.id}/edit"] do
        {:ok, view, _html} = live(conn, path <> rest)
        render_async(view, 5_000)
        assert text(view, "#flash-error") == "You can read this policy but not change it."
        refute has_element?(view, "#policy-rule-form")
        assert has_element?(view, "#policy-rules")
        refute has_element?(view, "#policy-rules-add")
      end
    end
  end

  describe "a target's New rule page" do
    setup %{scope: scope} do
      started_run(scope, shop())
      [%{target: target}] = Policy.list_targets(scope)
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _} = Policy.deny(scope, nil, %{host: "*.paste.example", locked: true})

      %{target: target, path: target_path(scope, target.system, target.path, ["policy"])}
    end

    test "opens from Add rule, the form alone under the target's breadcrumb",
         %{conn: conn, scope: scope, target: target, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, 5_000)

      assert has_element?(view, "#policy-rules-head #policy-rules-add[href='#{path}/rules/new']")

      assert text(view, "#policy-rules-line") ==
               "The hosts the runs of #{target.path} may reach, and those they may not."

      view |> element("#policy-rules-add") |> render_click()
      assert_patch(view, path <> "/rules/new")

      assert crumbs(view) == [
               {"Repositories", workspace_path(scope, "/targets")},
               {target.path, String.replace_suffix(path, "/-/policy", "")},
               {"Policy", path},
               {"New rule", nil}
             ]

      refute has_element?(view, "#target-tabs")
      refute has_element?(view, "#policy-mode")
      assert has_element?(view, "h1#policy-rule-title", "New rule")

      assert read(view, ".q-page-desc") ==
               "Let the runs of #{target.path} reach a host, or stop them reaching it. A repository rule applies to this repository only and overrides #{scope.workspace.name}'s rule for the same host, unless that rule is locked."

      assert has_element?(view, "#policy-rule-host[placeholder='mcp.acme.example']")
      assert text(view, "#policy-rule-add") == "Add repository rule"
      assert has_element?(view, "#policy-rule-save-cancel[href='#{path}']")
    end

    test "a deny overrides the workspace's allow for this target, said before it is added",
         %{conn: conn, scope: scope, target: target, path: path} do
      {:ok, view, _html} = live(conn, path <> "/rules/new")
      render_async(view, 5_000)

      type(view, %{action: "deny", host: "api.example"})
      assert has_element?(view, "#policy-rule-preview.q-rule-preview-note")

      assert read(view, "#policy-rule-reads") ==
               "api.example is allowed for the workspace. This rule denies it for this repository; other repositories keep it."

      add(view)
      assert_patch(view, path <> "?rule=api.example")
      assert %{action: "deny"} = rule(scope, "api.example", target)
      assert %{action: "allow"} = rule(scope, "api.example")
      assert text(view, "#flash-info") =~ "api.example is denied for #{target.path}."
    end

    test "a locked workspace rule refuses it, with the way to that rule",
         %{conn: conn, target: target, scope: scope, path: path} do
      {:ok, view, _html} = live(conn, path <> "/rules/new")
      render_async(view, 5_000)

      type(view, %{host: "files.paste.example"})

      assert read(view, "#policy-rule-refusal") =~
               "A locked workspace rule denies *.paste.example."

      assert has_element?(view, "#policy-rule-refusal button", "Show the locked rule")
      add(view)
      refute rule(scope, "files.paste.example", target)
    end

    test "a target rule's Edit opens its page", %{
      conn: conn,
      scope: scope,
      target: target,
      path: path
    } do
      {:ok, own} = Policy.allow(scope, target, %{host: "mcp.acme.example", paths: ["/mcp"]})
      {:ok, view, _html} = live(conn, path)
      render_async(view, 5_000)

      view |> element("#rule-#{own.id}-edit") |> render_click()
      assert_patch(view, "#{path}/rules/#{own.id}/edit")

      assert read(view, ".q-page-desc") ==
               "Change what the runs of #{target.path} may do with mcp.acme.example. The host stays; to rule on another host, add a new rule."

      type(view, %{paths: ""})
      assert read(view, "#policy-rule-paths-error") =~ "mcp.acme.example is held to /mcp"

      view |> element("#policy-rule-paths-error button", "Every path") |> render_click()
      add(view)
      assert_patch(view, path <> "?rule=mcp.acme.example")
      assert %{paths: nil} = rule(scope, "mcp.acme.example", target)

      # The workspace's rule is not this target's to edit here.
      %{id: workspace_id} = rule(scope, "api.example")
      {:ok, view, _html} = live(conn, "#{path}/rules/#{workspace_id}/edit")
      render_async(view, 5_000)
      refute has_element?(view, "#policy-rule-form")
      assert has_element?(view, "#policy-rules")
    end

    test "a suggestion's Allow with paths… opens the page with the host, Paths focused",
         %{conn: conn, scope: scope, target: target, path: path} do
      run = run_fixture(scope)
      event_fixture(run, 2, "run.started", started_data(%{"labels" => shop()}))

      event_fixture(run, 3, "run.policy_applied", %{
        "mode" => "observe",
        "allow" => [],
        "harness_hosts" => ["mcp.acme.example"]
      })

      {:ok, _run} = Apiary.Runs.Projector.project(run)

      {:ok, view, _html} = live(conn, path)
      render_async(view, 5_000)

      suggestion = ApiaryWeb.PolicyComponents.suggestion_id("mcp.acme.example")
      query = URI.encode_query(%{"focus" => "paths", "host" => "mcp.acme.example"})

      assert has_element?(
               view,
               "a##{suggestion}-paths[href='#{path}/rules/new?#{query}']",
               "Allow with paths…"
             )

      view |> element("##{suggestion}-paths") |> render_click()
      assert_patch(view, "#{path}/rules/new?#{query}")
      assert has_element?(view, "#policy-rule-host[value='mcp.acme.example']")
      assert_push_event(view, "policy:focus", %{id: "policy-rule-paths"})

      type(view, %{paths: "/mcp"})
      add(view)
      assert %{paths: ["/mcp"]} = rule(scope, "mcp.acme.example", target)
    end
  end
end
