defmodule ApiaryWeb.PolicyLive.ShowTest do
  use ApiaryWeb.ConnCase, async: true

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Phoenix.LiveViewTest
  import ApiaryWeb.TargetComponents, only: [target_path: 4]
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [tool_invocation_data: 1]
  import Apiary.RunListFixtures

  alias Apiary.Policy
  alias ApiaryWeb.PolicyLive.Common

  setup :register_and_log_in_user

  # The coalescing window of a reload is none here, so a broadcast is followed by its
  # reload as the next message and no test waits.
  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    :ok
  end

  defp open(conn, scope, rest \\ "/policy") do
    {:ok, view, _html} = live(conn, workspace_path(scope, rest))
    render_async(view, 5_000)
    view
  end

  # An element's text as it is read: unlike text/2, its tags add no space.
  defp name(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
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

  # The composer opens from Add rule: a test that types into it opens it first.
  defp compose(view) do
    if has_element?(view, "#policy-rules-add[aria-expanded=false]") do
      view |> element("#policy-rules-add") |> render_click()
    end

    view
  end

  defp type(view, params) do
    compose(view)
    view |> form("#policy-composer", rule: params) |> render_change()
  end

  defp hosts(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#policy-rules .q-host")
    |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))
  end

  defp rule(scope, host), do: Enum.find(Policy.list_rules(scope, nil), &(&1.host == host))

  defp as_member(%{scope: scope}) do
    %{user: member} = member_fixture(scope, :member)
    log_in_user(build_conn(), member)
  end

  test "requires sign-in", %{scope: scope} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/#{scope.organisation}/#{scope.workspace}/policy")
  end

  describe "in the frame" do
    test "the page's header and its tabs; the sidebar's lists never carry a target", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = open(conn, scope)

      assert has_element?(view, "#policy-header-title", "Policy")

      assert text(view, "#policy-header-description") ==
               "What the runs of this workspace may reach through the runner's proxy."

      assert has_element?(view, "#policy-header-actions #policy-export-button")
      assert has_element?(view, "#policy-tabs-rules[aria-current=page]", "Rules")
      # A software workspace reads Targets as Repositories.
      assert has_element?(view, "#policy-tabs-targets", "Repositories")
      assert has_element?(view, "#policy-tabs-history", "History")
      assert has_element?(view, "#policy-tabs-document", "Document")

      # The Security policy is not narrowed: its sidebar entry, and the lists', link plainly.
      for {key, path} <- [policy: "/policy", runs: "/runs", network: "/network"] do
        assert has_element?(view, "#nav-#{key}[href='#{workspace_path(scope, path)}']")
      end

      refute has_element?(view, "#nav-runs[aria-label]")

      view |> element("#policy-tabs-history") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy/history"))
      assert has_element?(view, "#policy-tabs-history[aria-current=page]")
    end
  end

  describe "a workspace nobody has changed" do
    test "says machines use their own policy, with no pill, no document and no mode word",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)

      assert has_element?(view, "#nav-policy[aria-current=page]")
      refute has_element?(view, "#nav-policy-mode")
      assert has_element?(view, "h2", "Qory serves no policy yet")

      assert text(view, "#policy-unmanaged") =~
               "Until the first change here, every machine of this workspace runs under its own policy"

      refute has_element?(view, "#policy-version-pill-copy")
      assert text(view, "#policy-version-pill") == "No version yet"
      # Export is off but focusable, described by why, and does nothing.
      assert has_element?(
               view,
               "button#policy-export-button[aria-disabled=true][aria-describedby=policy-export-why]"
             )

      refute has_element?(view, "#policy-export-button[disabled]")
      refute has_element?(view, "#policy-export-button[phx-click]")

      assert text(view, "#policy-export-why") ==
               "Nothing to export yet: the first change here renders version 1."

      assert text(view, "#policy-first-version") =~ "Version 1 is rendered by the first change"
      refute has_element?(view, "#policy-tabs a", "Document")
      assert has_element?(view, "#policy-mode-observe[aria-checked=true]")

      assert text(view, "#policy-mode-fact") ==
               "Not served yet: it applies from the first change here."

      # One line, the mode a segmented control and its sentence beside it, never inside it.
      assert has_element?(view, "#policy-mode-line.q-modeline #policy-mode[role=radiogroup]")
      refute has_element?(view, "#policy-mode a")
      assert has_element?(view, "#policy-mode-under #policy-mode-fact")
    end

    test "removing the last rule gives the focus to adding the first", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      view = open(conn, scope)

      view
      |> element("#rule-#{rule(scope, "api.example").id}-menu button", "Remove")
      |> render_click()

      assert has_element?(view, "#policy-first-rule")
      assert_push_event(view, "policy:focus", %{id: "policy-first-rule"})
    end

    test "the first rule starts the policy: a version, the pill, the mode word", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope)
      view |> element("#policy-first-rule") |> render_click()
      assert has_element?(view, "#policy-composer")

      type(view, %{host: "api.example", paths: ""})
      view |> form("#policy-composer") |> render_submit()

      assert has_element?(view, "#policy-rules tr.q-fresh", "api.example")
      assert text(view, "#policy-rules tr.q-fresh") =~ "New in v1"
      assert has_element?(view, "#policy-version-pill-copy[data-copy^='sha256=']")
      assert has_element?(view, "a#policy-export-button")
      refute has_element?(view, "#policy-export-button[aria-disabled]")
      refute has_element?(view, "#policy-export-why")
      refute has_element?(view, "#policy-first-version")
      assert has_element?(view, "#policy-tabs a", "Document")
      assert text(view, "#flash-info") =~ "api.example is allowed for the workspace. Version 1."
      assert text(view, "#policy-announce") == "Rule added. Version 1."
      assert text(view, "#nav-policy-mode") == "observe"
    end
  end

  describe "the composer" do
    test "opens from Add rule with the hint and the button off, and Cancel shuts it",
         %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = open(conn, scope)

      refute has_element?(view, "#policy-composer")
      view |> element("#policy-rules-add[aria-expanded=false]") |> render_click()
      assert has_element?(view, "#policy-rules-add[aria-expanded=true]")

      assert text(view, "#policy-composer-reads") =~ "A host name in lower case"
      assert has_element?(view, "#policy-composer-add[disabled]")

      view |> element("#policy-composer-cancel") |> render_click()
      refute has_element?(view, "#policy-composer")
    end

    test "reads a host, a suffix and paths back before saving", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = open(conn, scope)

      type(view, %{host: "api.example", paths: ""})

      assert text(view, "#policy-composer-reads") ==
               "Reads as: allow api.example , on every path."

      refute has_element?(view, "#policy-composer-add[disabled]")

      type(view, %{host: "*.internal.example", paths: ""})

      assert text(view, "#policy-composer-reads") =~
               "allow every host below internal.example , on every path. It does not allow internal.example itself."

      type(view, %{host: "api.example", paths: "/v1/* /health"})

      assert text(view, "#policy-composer-reads") =~
               "allow api.example on 2 paths : everything below /v1/ , and /health exactly."
    end

    test "a deny reads back, and takes no paths", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = open(conn, scope)

      view |> compose() |> element("#policy-composer button", "Deny") |> render_click()
      type(view, %{host: "telemetry.example"})

      assert text(view, "#policy-composer-reads") =~ "Reads as: deny telemetry.example ."
      assert has_element?(view, "#policy-composer-paths[disabled]")

      view |> form("#policy-composer") |> render_submit()
      assert has_element?(view, "#policy-rules .q-mark-no")
      assert rule(scope, "telemetry.example").action == "deny"
    end

    test "a URL is not a host, and the line offers the repair", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = open(conn, scope)

      type(view, %{host: "https://API.Example:443/v1/messages", paths: ""})

      assert text(view, "#policy-composer-reads") =~
               "A rule names a host and nothing else: lower case, no scheme, no port, no path."

      assert has_element?(view, "#policy-composer-reads[role=alert]")
      assert has_element?(view, "#policy-composer-host[aria-invalid=true]")
      assert has_element?(view, "#policy-composer-add[disabled]")

      view
      |> element("#policy-composer-reads button", "Use api.example with the path /v1/messages")
      |> render_click()

      assert text(view, "#policy-composer-reads") =~ "allow api.example on 1 path"
    end

    test "says what is wrong in the contract's grammar", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = open(conn, scope)

      type(view, %{host: "api.*.example", paths: "/v1/*/files?x=1"})
      assert text(view, "#policy-composer-reads") =~ "*. may only lead a host"
      assert text(view, "#policy-composer-reads") =~ "A path starts with /"
      assert has_element?(view, "#policy-composer-paths[aria-invalid=true]")

      type(view, %{host: "-api.example", paths: ""})
      assert text(view, "#policy-composer-reads") =~ "Each part of a host is 1 to 63 letters"

      type(view, %{host: "10.0.0.12:8080", paths: ""})
      assert text(view, "#policy-composer-reads") =~ "An address is written like a host"
    end

    test "the same rule again is an error with a link to it", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = open(conn, scope)

      type(view, %{host: "registry.example", paths: ""})

      assert text(view, "#policy-composer-reads") =~
               "registry.example is already allowed for the workspace"

      assert has_element?(view, "#policy-composer-add[disabled]")

      view |> element("#policy-composer-reads button", "Show it") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?rule=registry.example"))
      assert has_element?(view, "tr.q-ruled", "registry.example")
    end

    test "the opposite rule is replaced, and the button says so", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "gitlab.example"})
      view = open(conn, scope)

      view |> compose() |> element("#policy-composer button", "Deny") |> render_click()
      type(view, %{host: "gitlab.example"})

      assert text(view, "#policy-composer-reads") =~
               "gitlab.example is allowed for the workspace. Adding this deny replaces that rule."

      assert text(view, "#policy-composer-add") == "Replace with deny"
    end

    test "a host held to paths is not opened without saying so", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*"]})
      view = open(conn, scope)

      type(view, %{host: "api.example", paths: ""})
      assert text(view, "#policy-composer-reads") =~ "api.example is held to /v1/*"
      assert has_element?(view, "#policy-composer-add[disabled]")

      view |> element("#policy-composer-reads button", "Every path") |> render_click()
      assert text(view, "#policy-composer-reads") =~ "Saving changes its paths to every path"
      view |> form("#policy-composer") |> render_submit()

      assert rule(scope, "api.example").paths == nil
    end

    test "a host an allowed suffix covers is a note, and can be saved", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _} = Policy.allow(scope, nil, %{host: "*.internal.example"})
      view = open(conn, scope)

      type(view, %{host: "tax.internal.example", paths: ""})
      assert text(view, "#policy-composer-reads") =~ "Already allowed by *.internal.example"
      refute has_element?(view, "#policy-composer-add[disabled]")
    end

    test "accepts a deny under an allowed suffix, and says the suffix still allows the rest",
         %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "*.cdn.example"})
      view = open(conn, scope)

      view |> compose() |> element("#policy-composer button", "Deny") |> render_click()
      type(view, %{host: "files.cdn.example"})

      refute has_element?(view, "#policy-composer-reads[role=alert]")
      assert text(view, "#policy-composer-reads") =~ "It is denied in either mode, observe too."

      assert text(view, "#policy-composer-reads") =~
               "*.cdn.example still allows the other hosts below it."

      refute has_element?(view, "#policy-composer-add[disabled]")
      view |> form("#policy-composer") |> render_submit()

      assert %{allow: ["*.cdn.example"], deny: ["files.cdn.example"]} =
               Policy.effective(scope, nil)
    end

    test "a pasted list fills the composer with the first and queues the rest",
         %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = compose(open(conn, scope))

      render_hook(view, "composer_paste", %{"hosts" => ["a.example", "b.example", "c.example"]})
      assert text(view, "#policy-composer-reads-queued") == "2 more to add"

      view |> form("#policy-composer") |> render_submit()
      assert rule(scope, "a.example")
      assert text(view, "#policy-composer-reads-queued") == "1 more to add"
      assert text(view, "#policy-composer-reads") =~ "allow b.example"
    end

    test "what the domain refuses is shown as it says it", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "*.cdn.example", paths: ["/v1/*"]})
      view = open(conn, scope)

      type(view, %{host: "files.cdn.example", paths: ""})
      view |> form("#policy-composer") |> render_submit()

      assert text(view, "#policy-write-error") =~ "held to paths"
      refute rule(scope, "files.cdn.example")
    end
  end

  describe "the rules" do
    setup %{scope: scope} do
      {:ok, _} = Policy.deny(scope, nil, %{host: "*.paste.example", locked: true})
      {:ok, _} = Policy.allow(scope, nil, %{host: "github.example"})
      {:ok, _} = Policy.allow(scope, nil, %{host: "*.github.example"})
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*"]})
      :ok
    end

    test "locked first, then deny, then allow, a suffix beside the hosts below it",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)

      assert hosts(view) == [
               "*.paste.example",
               "api.example",
               "github.example",
               "*.github.example"
             ]

      # The views count every rule; All is current when no other is.
      assert text(view, "#policy-rules-view-all") == "All 4"
      assert text(view, "#policy-rules-view-allowed") == "Allowed 3"
      assert text(view, "#policy-rules-view-denied") == "Denied 1"
      assert text(view, "#policy-rules-view-locked") == "Locked 1"
      assert has_element?(view, "#policy-rules-view-all[aria-current=page]")
      assert text(view, "#policy-rules-pages-footer") == "1–4 of 4"
      refute has_element?(view, "#policy-rules-summary")

      # The Rules tab counts what its All view counts.
      assert has_element?(view, "#policy-tabs a[aria-current=page] .q-tabs-n", "4")

      # A search narrows the views' counts too, as the runs list's do.
      view |> render_hook("rules_search", %{"q" => "github"})
      assert text(view, "#policy-rules-view-all") == "All 2"
      assert text(view, "#policy-rules-view-allowed") == "Allowed 2"
      assert text(view, "#policy-rules-view-denied") == "Denied 0"
      view |> render_hook("rules_search", %{"q" => ""})

      # The section is Network access, and leads to the page of what the runs reached.
      assert has_element?(view, "#policy-hosts-h", "Network access")

      assert has_element?(
               view,
               "#policy-hosts a#policy-hosts-network[href='#{workspace_path(scope, "/network")}']"
             )

      assert has_element?(
               view,
               "[role=region][aria-label='Network access rules of the workspace']"
             )

      assert has_element?(view, "#policy-rules code.q-rule", "/v1/*")
      assert has_element?(view, "#policy-rules .q-every", "every path")
      # The policy names hosts and paths, and no credential.
      refute has_element?(view, "#policy-credentials")
      refute has_element?(view, "#policy-credential")
    end

    test "the view is in the URL, and one the list does not know is every rule", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope, "/policy?view=denied")
      assert has_element?(view, "#policy-rules-view-denied[aria-current=page]")
      assert hosts(view) == ["*.paste.example"]

      view |> element("#policy-rules-view-locked") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?view=locked"))
      assert hosts(view) == ["*.paste.example"]

      view |> element("#policy-rules-view-allowed") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?view=allowed"))
      assert hosts(view) == ["api.example", "github.example", "*.github.example"]

      view = open(conn, scope, "/policy?view=bogus&sort=nope&page=0")
      assert has_element?(view, "#policy-rules-view-all[aria-current=page]")
      assert has_element?(view, "#policy-rules-sort-button[aria-label='Sort: Locked first']")
      assert length(hosts(view)) == 4
    end

    test "the search finds a host, and a qualifier it reads becomes a token", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope)

      # As the reader types, the text narrows the list; a qualifier half typed does not.
      view
      |> form("#policy-rules-query", q: "github paths:h")
      |> render_change(%{"_target" => ["q"]})

      assert_patch(view, workspace_path(scope, "/policy?q=github"))
      assert hosts(view) == ["github.example", "*.github.example"]
      assert text(view, "#policy-rules-summary") == "2 rules match Clear"
      refute has_element?(view, "#policy-rules-tokens")

      # On Enter the qualifier is a token, and the text stays.
      view |> form("#policy-rules-query", q: "paths:every github") |> render_submit()
      assert_patch(view, workspace_path(scope, "/policy?q=paths%3Aevery+github"))
      assert has_element?(view, "#policy-rules-token-paths", "every")
      assert has_element?(view, "#policy-rules-query-input[value='github']")
      assert hosts(view) == ["github.example", "*.github.example"]

      view |> form("#policy-rules-query", q: "api") |> render_submit()
      assert_patch(view, workspace_path(scope, "/policy?q=paths%3Aevery+api"))
      assert text(view, "#policy-rules-summary") == "0 rules match"
      refute has_element?(view, "#policy-rules-clear")
      assert text(view, "#policy-rules") =~ "No rule matches."
      assert text(view, "#policy-rules-status[role=status]") =~ "No rule matches."

      # The token's cross takes it away; Clear takes everything away.
      view |> element("#policy-rules-token-paths a") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?q=api"))
      assert hosts(view) == ["api.example"]

      view |> element("#policy-rules-clear") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy"))
      assert length(hosts(view)) == 4

      # A word the list does not read as a qualifier is text.
      view |> form("#policy-rules-query", q: "seen:maybe") |> render_submit()
      assert_patch(view, workspace_path(scope, "/policy?q=seen%3Amaybe"))
      assert hosts(view) == []
    end

    test "the Filter menu writes the same tokens, each counted; Sort is in the URL too", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope)
      me = ApiaryWeb.People.short(scope.user.email)

      # Paths, Seen in 14 days and Added by; Source only where there is more than one.
      refute has_element?(view, "#policy-rules-filter-source-0")
      assert text(view, "#policy-rules-filter-paths-0") == "Held to paths 1 rule"
      assert text(view, "#policy-rules-filter-paths-1") == "Every path 3 rules"
      assert text(view, "#policy-rules-filter-seen-1") == "Not seen 4 rules"
      assert text(view, "#policy-rules-filter-by-0") == "#{me} 4 rules"

      view |> element("#policy-rules-filter-paths-0") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?q=paths%3Aheld"))
      assert has_element?(view, "#policy-rules-filter-paths-0[aria-checked=true]")
      assert text(view, "#policy-rules-filter-button") == "Filter 1"
      assert hosts(view) == ["api.example"]
      assert text(view, "#policy-rules-summary") == "1 rule matches"

      # One of a kind: the other value replaces it.
      view |> element("#policy-rules-filter-paths-1") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?q=paths%3Aevery"))
      assert length(hosts(view)) == 3

      view |> element("#policy-rules-filter-seen-0") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?q=paths%3Aevery+seen%3Ayes"))
      assert hosts(view) == []

      view |> element("#policy-rules-filter-by-0") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?q=paths%3Aevery+seen%3Ayes+by%3A#{me}"))

      view = open(conn, scope)
      assert has_element?(view, "#policy-rules-sort-button[aria-label='Sort: Locked first']")
      view |> element("#policy-rules-sort-host") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?sort=host"))

      assert hosts(view) == [
               "api.example",
               "github.example",
               "*.github.example",
               "*.paste.example"
             ]

      assert has_element?(view, "#policy-rules-sort-button[aria-label='Sort: Host']")

      view |> element("#policy-rules-sort-recent") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?sort=recent"))

      assert hosts(view) == [
               "api.example",
               "*.github.example",
               "github.example",
               "*.paste.example"
             ]
    end

    test "pages of 50, and ?rule= opens the page that holds the rule", %{
      conn: conn,
      scope: scope
    } do
      for n <- 1..60 do
        {:ok, _} =
          Policy.allow(scope, nil, %{host: "n#{String.pad_leading("#{n}", 2, "0")}.example"})
      end

      view = open(conn, scope)
      assert text(view, "#policy-rules-view-all") == "All 64"
      assert text(view, "#policy-rules-pages-footer") == "1–50 of 64"
      assert length(hosts(view)) == 50
      assert has_element?(view, "#policy-rules-pages-previous[disabled]")
      assert List.last(hosts(view)) == "n46.example"

      view |> element("#policy-rules-pages-next") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?page=2"))
      assert text(view, "#policy-rules-pages-footer") == "51–64 of 64"
      assert hosts(view) |> hd() == "n47.example"
      assert has_element?(view, "#policy-rules-pages-next[disabled]")

      # A view keeps its own pages; the page is left out of the URL when it is the first.
      view |> element("#policy-rules-view-denied") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?view=denied"))
      refute has_element?(view, "#policy-rules-pages-next")

      # The rule Network access links to is on the second page: the list opens there.
      view = open(conn, scope, "/policy?rule=n50.example")
      assert has_element?(view, "tr.q-ruled", "n50.example")
      assert text(view, "#policy-rules-pages-footer") == "51–64 of 64"

      # Under a filter that leaves the rule out, the filter gives way to it.
      view = open(conn, scope, "/policy?view=denied&rule=n50.example")
      assert has_element?(view, "tr.q-ruled", "n50.example")
      assert has_element?(view, "#policy-rules-view-all[aria-current=page]")
    end

    test "a change made elsewhere arrives into the filtered list", %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy?view=denied")
      assert hosts(view) == ["*.paste.example"]
      {:ok, _} = Policy.deny(scope, nil, %{host: "late.example"})

      _ = render(view)
      assert hosts(view) == ["*.paste.example", "late.example"]
      assert text(view, "#policy-rules-view-denied") == "Denied 2"
      assert has_element?(view, "#policy-rules-view-denied[aria-current=page]")
    end

    test "an owner locks and unlocks from the row; the toast says what it means",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)
      id = rule(scope, "github.example").id

      refute has_element?(view, "#rule-#{id}-lock")
      view |> element("#rule-#{id}-menu button", "Lock") |> render_click()

      assert text(view, "#rule-#{id}-lock") == "Locked"
      assert has_element?(view, "#rule-#{id}-menu button", "Unlock")
      lock = "rule-#{id}-lock"
      assert_push_event(view, "policy:focus", %{id: ^lock})

      assert text(view, "#flash-info") =~
               "github.example is locked. No repository can override it."

      assert rule(scope, "github.example").locked
      assert hosts(view) |> Enum.take(2) == ["github.example", "*.paste.example"]

      view |> element("#rule-#{id}-menu button", "Unlock") |> render_click()
      refute rule(scope, "github.example").locked
      refute has_element?(view, "#rule-#{id}-lock")

      # Its lock is gone: the focus goes to the row's menu.
      menu_button = "rule-#{id}-menu-button"
      assert_push_event(view, "policy:focus", %{id: ^menu_button})
    end

    test "a row that leaves the list as it is acted on gives the focus to Add rule",
         %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy?view=locked")
      id = rule(scope, "*.paste.example").id

      view |> element("#rule-#{id}-menu button", "Unlock") |> render_click()
      refute rule(scope, "*.paste.example").locked
      refute has_element?(view, "#rule-#{id}")
      assert_push_event(view, "policy:focus", %{id: "policy-rules-add"})
    end

    test "a lock that puts a target's rule out of force asks first",
         %{conn: conn, scope: scope} do
      started_run(scope, shop())
      [%{target: target}] = Policy.list_targets(scope)
      {:ok, _} = Policy.deny(scope, target, %{host: "github.example"})

      view = open(conn, scope)
      id = rule(scope, "github.example").id
      view |> element("#rule-#{id}-menu button", "Lock") |> render_click()

      assert has_element?(view, "#rule-#{id}.q-confirming #lock-confirm")
      refute has_element?(view, "dialog#lock-confirm")
      assert text(view, "#lock-confirm") =~ "1 repository rule stops being in force"
      assert text(view, "#lock-confirm") =~ "github.example/acme/shop"
      refute rule(scope, "github.example").locked

      view |> element("#lock-confirm-button") |> render_click()
      assert rule(scope, "github.example").locked
    end

    test "removing a plain rule is immediate; a locked one asks", %{conn: conn, scope: scope} do
      view = open(conn, scope)

      view
      |> element("#rule-#{rule(scope, "api.example").id}-menu button", "Remove")
      |> render_click()

      refute rule(scope, "api.example")
      assert text(view, "#flash-info") =~ "The rule api.example is removed."

      # The focus goes to the next row's menu.
      next = "rule-#{rule(scope, "github.example").id}-menu-button"
      assert_push_event(view, "policy:focus", %{id: ^next})

      locked = rule(scope, "*.paste.example")
      view |> element("#rule-#{locked.id}-menu button", "Remove") |> render_click()

      # The rule's row asks in place, not a dialog; Cancel gives the row back.
      assert has_element?(view, "#rule-#{locked.id}.q-confirming #remove-confirm")
      refute has_element?(view, "dialog#remove-confirm")
      assert text(view, "#remove-confirm") =~ "Remove the deny rule *.paste.example?"
      assert text(view, "#remove-confirm") =~ "This rule is locked"
      assert rule(scope, "*.paste.example")

      view |> element("#remove-confirm-cancel") |> render_click()
      refute has_element?(view, "#remove-confirm")
      assert has_element?(view, "#rule-#{locked.id}-menu")
      menu_button = "rule-#{locked.id}-menu-button"
      assert_push_event(view, "policy:focus", %{id: ^menu_button})

      view |> element("#rule-#{locked.id}-menu button", "Remove") |> render_click()

      view |> element("#remove-confirm-button") |> render_click()
      refute rule(scope, "*.paste.example")
    end

    test "edit paths fills the composer with the rule", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      id = rule(scope, "api.example").id

      view |> element("#rule-#{id}-menu button", "Edit paths") |> render_click()
      assert has_element?(view, "#policy-composer-host[value='api.example']")
      assert has_element?(view, "#policy-composer-paths[value='/v1/*']")
    end

    test "the menu changes a rule's action, and the toast names the version",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)
      id = rule(scope, "api.example").id

      assert has_element?(view, "#rule-#{id}-menu button", "Change to deny")
      refute has_element?(view, "#rule-#{id}-menu button", "Change to allow")

      view |> element("#rule-#{id}-menu button", "Change to deny") |> render_click()

      assert rule(scope, "api.example").action == "deny"

      # The rule is written anew: the focus goes to its row's menu, found by its host.
      menu_button = "rule-#{rule(scope, "api.example").id}-menu-button"
      assert_push_event(view, "policy:focus", %{id: ^menu_button})
      assert text(view, "#flash-info") =~ "api.example is denied for the workspace. Version"

      id = rule(scope, "api.example").id
      assert has_element?(view, "#rule-#{id}-menu button", "Change to allow")

      view |> element("#rule-#{id}-menu button", "Change to allow") |> render_click()

      assert rule(scope, "api.example").action == "allow"
      assert text(view, "#flash-info") =~ "api.example is allowed for the workspace. Version"
    end

    test "a change made elsewhere arrives without a reload", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      {:ok, _} = Policy.allow(scope, nil, %{host: "late.example"})

      # The broadcast is in the view's mailbox; once it is handled, the reload is next.
      _ = render(view)
      assert has_element?(view, "#policy-rules .q-host", "late.example")
    end
  end

  describe "a member" do
    setup %{scope: scope} do
      {:ok, _} = Policy.deny(scope, nil, %{host: "*.paste.example", locked: true})
      {:ok, _} = Policy.allow(scope, nil, %{host: "github.example"})
      :ok
    end

    test "reads locks and the mode, and changes neither", %{scope: scope} = context do
      view = open(as_member(context), scope)
      locked = rule(scope, "*.paste.example")
      plain = rule(scope, "github.example")

      assert text(view, "#rule-#{locked.id}-lock") == "Locked"
      assert has_element?(view, "span#rule-#{locked.id}-lock[tabindex='0']")
      refute has_element?(view, "#rule-#{locked.id}-menu")
      refute has_element?(view, "#rule-#{plain.id}-lock")
      assert has_element?(view, "#rule-#{plain.id}-menu")
      refute has_element?(view, "#rule-#{plain.id}-menu button", "Lock")

      assert has_element?(view, "#policy-mode[aria-disabled=true]")
      assert has_element?(view, "#policy-mode-enforce[aria-disabled=true]")
      assert text(view, "#policy-mode-owners") == "Only an owner or an admin sets a mode."
    end

    test "edits what is not locked", %{scope: scope} = context do
      view = open(as_member(context), scope)

      type(view, %{host: "api.example", paths: ""})
      view |> form("#policy-composer") |> render_submit()
      assert rule(scope, "api.example")
    end

    test "is refused in the composer on a locked rule", %{scope: scope} = context do
      view = open(as_member(context), scope)

      type(view, %{host: "*.paste.example", paths: ""})

      assert text(view, "#policy-composer-reads") =~
               "Only an owner can lock, unlock or change a locked rule."

      assert has_element?(view, "#policy-composer-add[disabled]")
    end

    test "a crafted event gets the refusal, and nothing changes", %{scope: scope} = context do
      view = open(as_member(context), scope)

      render_hook(view, "mode_ask", %{"mode" => "enforce"})
      refute has_element?(view, "#mode-enforce")
      assert Policy.get_mode(scope) == "observe"

      render_hook(view, "lock_toggle", %{"id" => rule(scope, "github.example").id})
      refute rule(scope, "github.example").locked
      assert text(view, "#policy-write-error") =~ "Only an owner"

      render_hook(view, "remove", %{"id" => rule(scope, "*.paste.example").id})
      assert rule(scope, "*.paste.example")
    end
  end

  describe "the mode" do
    setup %{scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      :ok
    end

    test "what enforce would deny names a tool invocation by its tool", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop(), egress: [tool_invocation_data(%{"rule" => ""})])

      view = open(conn, scope)
      view |> element("#policy-mode-enforce") |> render_click()

      assert has_element?(view, "#mode-would .q-dest-tool .q-tool-name", "files")
      assert text(view, "#mode-would .q-dest-tool") =~ "files.tools.internal"
    end

    test "going to enforce asks, lists what would be denied, and allows from the list",
         %{conn: conn, scope: scope} do
      started_run(scope, shop(),
        egress: [%{"host" => "files.cdn.example", "decision" => "allowed", "rule" => ""}]
      )

      view = open(conn, scope)
      assert text(view, "#policy-mode-fact") =~ "1 attempt to 1 destination had no rule"

      view |> element("#policy-mode-enforce") |> render_click()
      assert Policy.get_mode(scope) == "observe"
      assert text(view, "#mode-enforce") =~ "Set the workspace's default to enforce"
      assert text(view, "#mode-enforce") =~ "a connection no rule allows is denied"

      assert text(view, "#mode-enforce") =~
               "in the 1 repository that follows the workspace's default"

      assert text(view, "#mode-would") =~ "files.cdn.example"
      assert text(view, "#mode-would-n") == "1 destination"

      view
      |> element("#mode-would button", "Allow for the workspace: files.cdn.example")
      |> render_click()

      assert rule(scope, "files.cdn.example")
      assert text(view, "#mode-would-n") == "none left"
      assert_push_event(view, "policy:focus", %{id: "mode-confirm"})

      view |> element("#mode-confirm") |> render_click()
      assert Policy.get_mode(scope) == "enforce"
      assert has_element?(view, "#policy-mode-enforce[aria-checked=true]")

      assert text(view, "#flash-info") =~
               "The workspace's default is enforce. 1 repository follows it. Version"

      assert text(view, "#nav-policy-mode") == "enforce"
    end

    test "each Allow names its destination, and the focus goes on to the next one open",
         %{conn: conn, scope: scope} do
      started_run(scope, shop(),
        egress: [
          %{"host" => "files.cdn.example", "decision" => "allowed", "rule" => ""},
          %{"host" => "mirror.example", "decision" => "allowed", "rule" => ""},
          %{"host" => "mirror.example", "decision" => "allowed", "rule" => ""},
          %{"host" => "assets.example", "decision" => "allowed", "rule" => ""},
          %{"host" => "assets.example", "decision" => "allowed", "rule" => ""},
          %{"host" => "assets.example", "decision" => "allowed", "rule" => ""}
        ]
      )

      view = open(conn, scope)
      view |> element("#policy-mode-enforce") |> render_click()

      # Most attempts first: assets.example, mirror.example, files.cdn.example.
      allow = fn host ->
        "would-#{Common.would_key(%{host: host, path: nil})}-allow"
      end

      # Each reads "Allow for the workspace"; its name goes on with the destination.
      for host <- ~w(assets.example mirror.example files.cdn.example) do
        assert name(view, "button##{allow.(host)}") == "Allow for the workspace: #{host}"
        assert text(view, "button##{allow.(host)} .sr-only") == ": #{host}"
      end

      # The one acted on goes; the focus goes to the next Allow still open, then from the
      # top, and with none left to the act.
      view |> element("##{allow.("mirror.example")}") |> render_click()
      next = allow.("files.cdn.example")
      assert_push_event(view, "policy:focus", %{id: ^next})
      refute has_element?(view, "##{allow.("mirror.example")}")

      view |> element("##{next}") |> render_click()
      first = allow.("assets.example")
      assert_push_event(view, "policy:focus", %{id: ^first})

      view |> element("##{first}") |> render_click()
      assert_push_event(view, "policy:focus", %{id: "mode-confirm"})
      assert text(view, "#mode-would-n") == "none left"
    end

    test "with nothing to deny the list gives way to a sentence; cancel changes nothing",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)
      view |> element("#policy-mode-enforce") |> render_click()
      assert text(view, "#mode-would-none") =~ "Every destination your runs reached"

      # The confirm is in place under the switch, not a dialog; Cancel takes the focus.
      assert has_element?(view, "#policy-mode-line + section#mode-enforce")
      refute has_element?(view, "dialog#mode-enforce")
      assert has_element?(view, "#mode-enforce-cancel[phx-mounted]")

      # What it does is read with the confirm and with Cancel, which has the focus.
      assert has_element?(view, "section#mode-enforce[aria-describedby=mode-enforce-effect]")
      assert has_element?(view, "#mode-enforce-cancel[aria-describedby=mode-enforce-effect]")
      assert text(view, "#mode-enforce-effect") =~ "a connection no rule allows is denied"

      view |> element("#mode-enforce button", "Cancel") |> render_click()
      refute has_element?(view, "#mode-enforce")
      assert_push_event(view, "policy:focus", %{id: "policy-mode-observe"})
      assert Policy.get_mode(scope) == "observe"

      # The list of keys `?` shows is a panel in the page, hidden until asked, not a dialog.
      assert has_element?(
               view,
               "#policy-page section#policy-keys[hidden]",
               "Space asks to switch"
             )

      refute has_element?(view, "dialog#policy-keys")

      # Another tab leaves the confirm behind.
      view |> element("#policy-mode-enforce") |> render_click()
      view |> element("#policy-tabs a", "History") |> render_click()
      view |> element("#policy-tabs a", "Rules") |> render_click()
      refute has_element?(view, "#mode-enforce")
    end

    test "going back to observe asks too, and says a deny still holds", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _} = Policy.set_mode(scope, "enforce")
      view = open(conn, scope)

      view |> element("#policy-mode-observe") |> render_click()

      assert text(view, "#mode-observe") =~
               "only what a deny rule names is denied in the runs that name no repository"

      assert text(view, "#mode-observe") =~
               "The rules stay as they are, locked ones too: a deny holds in either mode."

      assert has_element?(view, "section#mode-observe[aria-describedby=mode-observe-effect]")
      assert has_element?(view, "#mode-observe-cancel[aria-describedby=mode-observe-effect]")

      assert text(view, "#mode-observe-effect") =~
               "only what a deny rule names is denied in the runs that name no repository"

      view |> element("#mode-confirm") |> render_click()
      assert Policy.get_mode(scope) == "observe"
    end
  end

  describe "targets that set their own mode" do
    setup %{scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      started_run(scope, shop())
      started_run(scope, %{"forge" => "github.example", "repository" => "acme/docs"})

      docs =
        Enum.find(Policy.list_targets(scope), &(&1.target.path == "acme/docs")).target

      {:ok, _} = Policy.set_mode(scope, docs, "enforce")
      %{docs: docs}
    end

    test "the workspace's page says how many, and the sidebar tag counts them", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope)

      assert text(view, "#policy-mode-under") =~
               "Followed by 1 of 2 repositories; 1 sets its own and enforces"

      assert has_element?(
               view,
               "#policy-mode-under a[href='#{workspace_path(scope, "/policy/targets?mode=own")}']"
             )

      assert text(view, "#nav-policy-mode") == "observe"

      assert has_element?(
               view,
               "#nav-policy-mode[title=\"The workspace's default mode is observe. 1 repository sets its own and enforces.\"]"
             )
    end

    test "a managed workspace with a mode set and no rule says what version is served",
         %{scope: scope} do
      other = scope_fixture()
      {:ok, _} = Policy.set_mode(other, "enforce")
      %{user: owner} = %{user: other.user}
      view = open(log_in_user(build_conn(), owner), other)
      assert text(view, "#policy-first-version") =~ "Version 1 is what machines are served now"
      _ = scope
    end

    test "the confirm names those that do not change", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      view |> element("#policy-mode-enforce") |> render_click()
      assert text(view, "#mode-enforce") =~ "1 repository sets its own mode and does not change."
    end

    test "the targets list has a Mode column, and ?mode=own keeps those with their own",
         %{conn: conn, docs: docs, scope: scope} do
      view = open(conn, scope, "/policy/targets")
      assert text(view, "#targets-summary") =~ "1 sets its own mode"
      assert text(view, "#target-#{docs.id} .q-c-mode") == "enforce its own"
      assert text(view, "#policy-targets") =~ "observe Follows the workspace"

      view = open(conn, scope, "/policy/targets?mode=own")
      assert has_element?(view, "#target-#{docs.id}")

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".q-target-row")
             |> Enum.count() == 1

      assert text(view, "#targets-own-only") =~ "Showing those that set their own mode."
    end
  end

  describe "targets" do
    test "none has posted", %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/targets")
      assert has_element?(view, "h2", "No repositories yet")
    end

    test "one row per target, with what it has of its own", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      started_run(scope, %{"forge" => "github.example", "repository" => "acme/docs"})

      target =
        Enum.find(Policy.list_targets(scope), &(&1.target.path == "acme/shop")).target

      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      {:ok, _} = Policy.deny(scope, target, %{host: "registry.example"})

      view = open(conn, scope, "/policy/targets")

      assert text(view, "#targets-summary") =~ "2 repositories have posted runs"
      assert text(view, "#targets-summary") =~ "1 with rules of their own"
      assert text(view, "#target-#{target.id}") =~ "Own rules"
      assert text(view, "#target-#{target.id}") =~ "v1"
      # Whose version each row shows, and no bare 0 where nothing is to review.
      refute text(view, "#target-#{target.id} .q-c-version") =~ "baseline"
      assert text(view, "#policy-targets") =~ "v1 of the workspace's policy"

      refute view |> element("#target-#{target.id} td.q-num:nth-of-type(6)") |> render() =~
               ">0<"

      assert text(view, "#policy-targets") =~ "Follows the workspace"

      assert has_element?(
               view,
               "#target-#{target.id} a[href='#{target_path(scope, target.system, target.path, ["policy"])}']"
             )
    end
  end

  describe "a person whose account is deleted" do
    test "is a former member beside their rule and in the history",
         %{conn: conn, scope: scope} do
      %{scope: member, user: user} = member_fixture(scope, :member)
      {:ok, rule} = Policy.allow(member, nil, %{host: "registry.example"})
      {:ok, _} = Apiary.Accounts.delete_user(member)

      view = open(conn, scope)
      assert text(view, "#rule-#{rule.id} .q-pr-by") =~ "Former member"
      refute has_element?(view, "#policy-rules-filter-by-0")

      view = open(conn, scope, "/policy/history")
      assert text(view, "#history-list") =~ "Former member allowed registry.example"
      refute render(view) =~ user.email
    end
  end

  describe "history" do
    setup %{scope: scope} do
      {:ok, rule} = Policy.allow(scope, nil, %{host: "registry.example"})
      # A deny is in the document, so it renders a version; a lock renders the same bytes.
      {:ok, _} = Policy.deny(scope, nil, %{host: "telemetry.example"})
      {:ok, _} = Policy.lock(scope, rule)
      {:ok, _} = Policy.set_mode(scope, "enforce")
      :ok
    end

    test "every change with who, the version it made or that it made none",
         %{conn: conn, user: user, scope: scope} do
      view = open(conn, scope, "/policy/history")

      assert text(view, "#history-summary") =~ "4 changes"
      assert text(view, "#history-summary") =~ "3 versions"

      assert text(view, "#history-list") =~
               "#{user.email} switched the workspace's default mode from observe to enforce"

      assert text(view, "#history-list") =~ "allowed registry.example"
      assert text(view, "#history-list") =~ "denied telemetry.example"
      assert text(view, "#history-list") =~ "locked registry.example"
      assert text(view, "#history-list") =~ "no new version"
      assert text(view, "#history-list") =~ "Today"
      assert text(view, "#history-foot") =~ "Showing 4 of 4."
    end

    test "opening a change is in the URL and shows its diff in rules and in lines",
         %{conn: conn, scope: scope} do
      change = Enum.find(Policy.list_changes(scope, nil, 1).items, &(&1.action == "mode_changed"))
      view = open(conn, scope, "/policy/history")

      view |> element("#chg-#{change.id}-summary") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy/history?change=#{change.id}"))

      assert has_element?(view, "#chg-#{change.id}[open]")
      assert text(view, "#chg-#{change.id}-diff") =~ "Removed: Mode observe"
      assert text(view, "#chg-#{change.id}-diff") =~ "Added: Mode enforce"

      assert text(view, "#chg-#{change.id}-diff .q-dlines:not(.q-dlines-sem) .q-del") =~
               ~s("mode" : "observe")

      assert text(view, "#chg-#{change.id}-diff .q-dlines:not(.q-dlines-sem) .q-add") =~
               ~s("mode" : "enforce")

      assert text(view, "#chg-#{change.id}-diff") =~ ~s("deny")
      assert text(view, "#chg-#{change.id}-diff") =~ "telemetry.example"
      assert text(view, "#chg-#{change.id}-diff") =~ "Open v3"

      view |> element("#chg-#{change.id}-summary") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy/history"))
    end

    test "another workspace's change opens nothing", %{conn: conn, scope: scope} do
      other = scope_fixture()
      {:ok, _} = Policy.allow(other, nil, %{host: "secret.example"})
      [change] = Policy.list_changes(other, nil, 1).items

      view = open(conn, scope, "/policy/history?change=#{change.id}")
      refute has_element?(view, ".q-chg[open]")
      refute render(view) =~ "secret.example"

      view = open(conn, scope, "/policy/history?change=not-an-id&page=zzz")
      refute has_element?(view, ".q-chg[open]")
    end
  end

  describe "a version" do
    setup %{scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      {:ok, _} = Policy.allow(scope, nil, %{host: "files.cdn.example"})
      :ok
    end

    test "the document tab opens the current one", %{conn: conn, scope: scope} do
      to = workspace_path(scope, "/policy/versions/2")

      assert {:error, {:live_redirect, %{to: ^to}}} =
               live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/policy/document")
    end

    test "changes from the one before, the document, and the bytes as served",
         %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/versions/2")
      {:ok, configuration} = Policy.get_configuration(scope, nil, 2)

      assert has_element?(view, "h1", "Version 2")

      # The frame's breadcrumb names the version after Policy; the Document tab is current.
      assert has_element?(
               view,
               "#breadcrumb a[href='#{workspace_path(scope, "/policy")}']",
               "Policy"
             )

      assert has_element?(view, "#breadcrumb [aria-current=page]", "Version 2")
      assert has_element?(view, "#policy-tabs-document[aria-current=page]")
      refute has_element?(view, "#policy-page nav.q-crumbs")
      assert text(view, "#policy-page") =~ "In force"
      assert text(view, "#version-strip") =~ "Allowed files.cdn.example"
      assert text(view, "#version-doc") =~ "v1 → v2 · 1 line added"
      assert text(view, "#version-lines .q-add") =~ ~s(Added: "files.cdn.example")
      assert has_element?(view, "#version-copy[data-copy='#{configuration.document}']")
      assert has_element?(view, "#ver-2[aria-current=page]")

      view |> element("#version-view button", "As served") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy/versions/2?view=served"))

      assert text(view, "#version-doc") =~
               "#{byte_size(configuration.document)} bytes · sha256 over exactly these"

      html = view |> element("#version-served") |> render()
      assert html =~ Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(configuration.document))

      view |> element("#version-view button", "Document") |> render_click()
      assert text(view, "#version-pretty") =~ ~s("mode" : "observe")
    end

    test "an older version is superseded, and says by which", %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/versions/1")
      assert text(view, "#policy-page") =~ "Superseded"
      assert text(view, "#version-superseded") =~ "by v2 after"
      assert text(view, "#version-export") == "Export the version in force"
    end

    test "a version that is superseded while it is open stops saying it is in force",
         %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/versions/2")
      assert text(view, "#policy-page") =~ "In force"

      {:ok, _} = Policy.allow(scope, nil, %{host: "later.example"})
      _ = render(view)

      assert text(view, "#policy-page") =~ "Superseded"
      assert text(view, "#version-superseded") =~ "by v3"
      assert has_element?(view, "#ver-3")
    end

    test "a version that does not exist, and one that is no number", %{conn: conn, scope: scope} do
      view = open(conn, scope, "/policy/versions/31")
      assert has_element?(view, "h2", "There is no version 31")

      assert has_element?(
               view,
               "a[href='#{workspace_path(scope, "/policy/versions/2")}']",
               "Open version 2"
             )

      view = open(conn, scope, "/policy/versions/abc?compare=x&view=y")
      assert has_element?(view, "h2", "There is no version abc")
    end

    test "export is a page at its own URL, with both texts and the caveats",
         %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "git.example", paths: ["/acme/shop.git/*"]})
      view = open(conn, scope, "/policy/versions/3/export")
      {:ok, configuration} = Policy.get_configuration(scope, nil, 3)

      # A page of its own: the frame's breadcrumb back to the policy and the version, its
      # title, and no dialog, no tabs, no version view under it.
      assert has_element?(view, "section#policy-export")
      refute has_element?(view, "dialog#policy-export")
      assert has_element?(view, "h1#policy-export-h", "Export for a node without a server")
      refute has_element?(view, "#export-crumbs")

      assert has_element?(
               view,
               "#breadcrumb a[href='#{workspace_path(scope, "/policy")}']",
               "Policy"
             )

      assert has_element?(
               view,
               "#breadcrumb a[href='#{workspace_path(scope, "/policy/versions/3")}']",
               "Version 3"
             )

      assert has_element?(view, "#breadcrumb [aria-current=page]", "Export")
      refute has_element?(view, "#policy-tabs")
      refute has_element?(view, "#version-export")
      assert text(view, "#export-lead") =~ "as of version 3"
      assert text(view, "#export-policy-text") =~ "# #{configuration.digest}"
      assert text(view, "#export-policy-text") =~ "/acme/shop.git/*"
      assert text(view, "#export-runner-text") =~ "~/.config/qory/runner.yaml egress"

      assert has_element?(
               view,
               "#export-download[download$='-policy.yaml'][href^='data:text/yaml']"
             )

      assert text(view, "#policy-export") =~ "Deny rules and locks are already applied"

      # The page's h1 takes the focus it is sent, as the page header's does.
      assert has_element?(view, "h1#policy-export-h.outline-none[tabindex='-1']")
      refute_push_event(view, "policy:focus", %{id: "policy-export-h"})

      view |> element("#policy-export a", "Done") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy/versions/3"))
      assert has_element?(view, "h1#policy-version-h.outline-none[tabindex='-1']", "Version 3")
      assert_push_event(view, "policy:focus", %{id: "policy-version-h"})

      # From the version, its Export opens the page again, named in the browser's title.
      view |> element("#version-export") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy/versions/3/export"))
      assert page_title(view) =~ "Export · Version 3 · Policy"
      assert_push_event(view, "policy:focus", %{id: "policy-export-h"})
    end

    test "only the version in force is exported", %{conn: conn, scope: scope} do
      {:ok, view, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/policy/versions/1/export")

      assert text(view, "#export-lead") =~ "as of version 2"
      assert has_element?(view, "#breadcrumb a", "Version 2")
    end
  end

  describe "the sidebar" do
    test "a page that subscribes itself gets each change, whoever subscribed first",
         %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = open(conn, scope)

      # The hook subscribed before the page did: two subscriptions, one process.
      topic = Policy.topic(scope.workspace.id)
      assert Enum.count(Registry.keys(Apiary.PubSub, view.pid), &(&1 == topic)) == 2

      {:ok, _} = Policy.allow(scope, nil, %{host: "first.example"})
      _ = render(view)
      assert has_element?(view, "#policy-rules .q-host", "first.example")
      assert Enum.count(Registry.keys(Apiary.PubSub, view.pid), &(&1 == topic)) == 1

      {:ok, _} = Policy.allow(scope, nil, %{host: "second.example"})
      _ = render(view)
      assert has_element?(view, "#policy-rules .q-host", "second.example")
    end

    test "a page that never asked for the policy never gets its messages", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")

      {:ok, _} = Policy.set_mode(scope, "enforce")
      assert text(view, "#nav-policy-mode") == "enforce"
      assert Process.alive?(view.pid)
    end

    test "the mode word follows the policy on a page that does not", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")
      assert text(view, "#nav-policy-mode") == "observe"

      {:ok, _} = Policy.set_mode(scope, "enforce")

      assert render(view) =~
               "The workspace&#39;s default mode is enforce. Every repository follows it."

      assert text(view, "#nav-policy-mode") == "enforce"
    end
  end
end
