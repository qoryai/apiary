defmodule ApiaryWeb.PolicyLive.ShowTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Policy

  setup :register_and_log_in_user

  # The coalescing window of a reload is none here, so a broadcast is followed by its
  # reload as the next message and no test waits.
  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    :ok
  end

  defp open(conn, path \\ "/hive/policy") do
    {:ok, view, _html} = live(conn, path)
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

  defp type(view, params) do
    view |> form("#policy-composer", rule: params) |> render_change()
  end

  defp rule(scope, host), do: Enum.find(Policy.list_rules(scope, nil), &(&1.host == host))

  defp as_member(%{scope: scope}) do
    %{user: member} = member_fixture(scope, :member)
    log_in_user(build_conn(), member)
  end

  test "requires sign-in" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/hive/policy")
  end

  describe "a hive nobody has changed" do
    test "says machines use their own policy, with no pill, no document and no mode word",
         %{conn: conn} do
      view = open(conn)

      assert has_element?(view, "#nav-policy[aria-current=page]")
      refute has_element?(view, "#nav-policy-mode")
      assert has_element?(view, "h2", "Qory serves no policy yet")

      assert text(view, "#policy-unmanaged") =~
               "Until the first change here, every machine of this hive runs under its own policy"

      refute has_element?(view, "#policy-version-pill-copy")
      assert text(view, "#policy-version-pill") == "No version yet"
      assert has_element?(view, "#policy-export-button[disabled]")
      assert text(view, "#policy-first-version") =~ "Version 1 is rendered by the first change"
      refute has_element?(view, "#policy-tabs a", "Document")
      assert has_element?(view, "#policy-mode-observe[aria-checked=true]")

      assert text(view, "#policy-mode-fact") ==
               "Not served yet: it applies from the first change here."

      assert text(view, "#policy-mode-observe") =~ "Hive default"
    end

    test "the first rule starts the policy: a version, the pill, the mode word", %{conn: conn} do
      view = open(conn)
      view |> element("#policy-first-rule") |> render_click()
      assert has_element?(view, "#policy-composer")

      type(view, %{host: "api.example", paths: ""})
      view |> form("#policy-composer") |> render_submit()

      assert has_element?(view, "#policy-rules tr.q-fresh", "api.example")
      assert text(view, "#policy-rules tr.q-fresh") =~ "New in v1"
      assert has_element?(view, "#policy-version-pill-copy[data-copy^='sha256=']")
      refute has_element?(view, "#policy-export-button[disabled]")
      refute has_element?(view, "#policy-first-version")
      assert has_element?(view, "#policy-tabs a", "Document")
      assert text(view, "#flash-info") =~ "api.example is allowed for the hive. Version 1."
      assert text(view, "#policy-announce") == "Rule added. Version 1."
      assert text(view, "#nav-policy-mode") == "observe"
    end
  end

  describe "the composer" do
    test "starts with the hint and the button off", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = open(conn)

      assert text(view, "#policy-composer-reads") =~ "A host name in lower case"
      assert has_element?(view, "#policy-composer-add[disabled]")
    end

    test "reads a host, a suffix and paths back before saving", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = open(conn)

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
      view = open(conn)

      view |> element("#policy-composer button", "Deny") |> render_click()
      type(view, %{host: "telemetry.example"})

      assert text(view, "#policy-composer-reads") =~ "Reads as: deny telemetry.example ."
      assert has_element?(view, "#policy-composer-paths[disabled]")

      view |> form("#policy-composer") |> render_submit()
      assert has_element?(view, "#policy-rules .q-mark-no")
      assert rule(scope, "telemetry.example").action == "deny"
    end

    test "a URL is not a host, and the line offers the repair", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = open(conn)

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
      view = open(conn)

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
      view = open(conn)

      type(view, %{host: "registry.example", paths: ""})

      assert text(view, "#policy-composer-reads") =~
               "registry.example is already allowed for the hive"

      assert has_element?(view, "#policy-composer-add[disabled]")

      view |> element("#policy-composer-reads button", "Show it") |> render_click()
      assert_patch(view, "/hive/policy?rule=registry.example")
      assert has_element?(view, "tr.q-ruled", "registry.example")
    end

    test "the opposite rule is replaced, and the button says so", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "gitlab.example"})
      view = open(conn)

      view |> element("#policy-composer button", "Deny") |> render_click()
      type(view, %{host: "gitlab.example"})

      assert text(view, "#policy-composer-reads") =~
               "gitlab.example is allowed for the hive. Adding this deny replaces that rule."

      assert text(view, "#policy-composer-add") == "Replace with deny"
    end

    test "a host held to paths is not opened without saying so", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*"]})
      view = open(conn)

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
      view = open(conn)

      type(view, %{host: "tax.internal.example", paths: ""})
      assert text(view, "#policy-composer-reads") =~ "Already allowed by *.internal.example"
      refute has_element?(view, "#policy-composer-add[disabled]")
    end

    test "accepts a deny under an allowed suffix, and says the suffix still allows the rest",
         %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "*.cdn.example"})
      view = open(conn)

      view |> element("#policy-composer button", "Deny") |> render_click()
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
      view = open(conn)

      render_hook(view, "composer_paste", %{"hosts" => ["a.example", "b.example", "c.example"]})
      assert text(view, "#policy-composer-reads-queued") == "2 more to add"

      view |> form("#policy-composer") |> render_submit()
      assert rule(scope, "a.example")
      assert text(view, "#policy-composer-reads-queued") == "1 more to add"
      assert text(view, "#policy-composer-reads") =~ "allow b.example"
    end

    test "what the domain refuses is shown as it says it", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "*.cdn.example", paths: ["/v1/*"]})
      view = open(conn)

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
      {:ok, _} = Policy.allow(scope, nil, %{kind: "credential", name: "model-key"})
      :ok
    end

    test "locked first, then deny, then allow, a suffix beside the hosts below it",
         %{conn: conn} do
      view = open(conn)

      hosts =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#policy-rules .q-host")
        |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))

      assert hosts == ["*.paste.example", "api.example", "github.example", "*.github.example"]
      assert text(view, "#policy-hosts-n") == "4"
      assert has_element?(view, "#policy-rules code.q-rule", "/v1/*")
      assert has_element?(view, "#policy-rules .q-every", "every path")
      assert text(view, "#policy-credential-rows") =~ "model-key"
      assert text(view, "#policy-credential-rows") =~ "no argument"
    end

    test "the filter is in the URL, and one that matches nothing says so", %{conn: conn} do
      view = open(conn, "/hive/policy?show=deny")
      assert has_element?(view, "#policy-rules .q-host", "paste.example")
      refute has_element?(view, "#policy-rules .q-host", "api.example")

      view |> element("#policy-show button", "Locked") |> render_click()
      assert_patch(view, "/hive/policy?show=locked")

      view = open(conn, "/hive/policy?show=bogus")
      assert has_element?(view, "#policy-rules .q-host", "api.example")
    end

    test "an owner locks and unlocks from the row; the toast says what it means",
         %{conn: conn, scope: scope} do
      view = open(conn)
      id = rule(scope, "github.example").id

      assert has_element?(
               view,
               "#rule-#{id}-lock[aria-pressed=false][aria-label='Lock github.example']"
             )

      view |> element("#rule-#{id}-lock") |> render_click()

      assert has_element?(view, "#rule-#{id}-lock[aria-pressed=true]", "Locked")

      assert text(view, "#flash-info") =~
               "github.example is locked. No repository can override it."

      assert rule(scope, "github.example").locked

      view |> element("#rule-#{id}-lock") |> render_click()
      refute rule(scope, "github.example").locked
    end

    test "a lock that puts a target's rule out of force asks first",
         %{conn: conn, scope: scope} do
      started_run(scope, shop())
      [%{target: target}] = Policy.list_targets(scope)
      {:ok, _} = Policy.deny(scope, target, %{host: "github.example"})

      view = open(conn)
      id = rule(scope, "github.example").id
      view |> element("#rule-#{id}-lock") |> render_click()

      assert text(view, "#lock-confirm") =~ "1 repository rule stops being in force"
      assert text(view, "#lock-confirm") =~ "github.example/acme/shop"
      refute rule(scope, "github.example").locked

      view |> element("#lock-confirm-button") |> render_click()
      assert rule(scope, "github.example").locked
    end

    test "removing a plain rule is immediate; a locked one asks", %{conn: conn, scope: scope} do
      view = open(conn)

      view
      |> element("#rule-#{rule(scope, "api.example").id}-menu button", "Remove")
      |> render_click()

      refute rule(scope, "api.example")
      assert text(view, "#flash-info") =~ "The rule api.example is removed."

      locked = rule(scope, "*.paste.example")
      view |> element("#rule-#{locked.id}-menu button", "Remove") |> render_click()
      assert text(view, "#remove-confirm") =~ "This rule is locked"
      assert rule(scope, "*.paste.example")

      view |> element("#remove-confirm-button") |> render_click()
      refute rule(scope, "*.paste.example")
    end

    test "edit paths fills the composer with the rule", %{conn: conn, scope: scope} do
      view = open(conn)
      id = rule(scope, "api.example").id

      view |> element("#rule-#{id}-menu button", "Edit paths") |> render_click()
      assert has_element?(view, "#policy-composer-host[value='api.example']")
      assert has_element?(view, "#policy-composer-paths[value='/v1/*']")
    end

    test "the menu changes a rule's action, and the toast names the version",
         %{conn: conn, scope: scope} do
      view = open(conn)
      id = rule(scope, "api.example").id

      assert has_element?(view, "#rule-#{id}-menu button", "Change to deny")
      refute has_element?(view, "#rule-#{id}-menu button", "Change to allow")

      view |> element("#rule-#{id}-menu button", "Change to deny") |> render_click()

      assert rule(scope, "api.example").action == "deny"
      assert text(view, "#flash-info") =~ "api.example is denied for the hive. Version"

      id = rule(scope, "api.example").id
      assert has_element?(view, "#rule-#{id}-menu button", "Change to allow")

      view |> element("#rule-#{id}-menu button", "Change to allow") |> render_click()

      assert rule(scope, "api.example").action == "allow"
      assert text(view, "#flash-info") =~ "api.example is allowed for the hive. Version"
    end

    test "a credential is added by name and removed", %{conn: conn, scope: scope} do
      view = open(conn)

      view |> form("#policy-credential", credential: %{name: "Forge Token"}) |> render_change()
      assert text(view, "#policy-credential-reads") =~ "A name is 1 to 64 lower-case letters"

      view
      |> form("#policy-credential", credential: %{name: "forge-token", argument: "acme/shop"})
      |> render_change()

      view |> form("#policy-credential") |> render_submit()

      credential = Enum.find(Policy.list_rules(scope, nil), &(&1.name == "forge-token"))
      assert credential.argument == "acme/shop"
      assert text(view, "#policy-credential-rows") =~ "acme/shop"

      view |> element("#rule-#{credential.id}-remove") |> render_click()
      refute Enum.find(Policy.list_rules(scope, nil), &(&1.name == "forge-token"))
    end

    test "a change made elsewhere arrives without a reload", %{conn: conn, scope: scope} do
      view = open(conn)
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
      view = open(as_member(context))
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
      assert text(view, "#policy-mode-owners") == "Only an owner sets a mode."
    end

    test "edits what is not locked", %{scope: scope} = context do
      view = open(as_member(context))

      type(view, %{host: "api.example", paths: ""})
      view |> form("#policy-composer") |> render_submit()
      assert rule(scope, "api.example")
    end

    test "is refused in the composer on a locked rule", context do
      view = open(as_member(context))

      type(view, %{host: "*.paste.example", paths: ""})

      assert text(view, "#policy-composer-reads") =~
               "Only an owner can lock, unlock or change a locked rule."

      assert has_element?(view, "#policy-composer-add[disabled]")
    end

    test "a crafted event gets the refusal, and nothing changes", %{scope: scope} = context do
      view = open(as_member(context))

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

    test "going to enforce asks, lists what would be denied, and allows from the list",
         %{conn: conn, scope: scope} do
      started_run(scope, shop(),
        egress: [%{"host" => "files.cdn.example", "decision" => "allowed", "rule" => ""}]
      )

      view = open(conn)
      assert text(view, "#policy-mode-fact") =~ "1 attempt to 1 destination had no rule"

      view |> element("#policy-mode-enforce") |> render_click()
      assert Policy.get_mode(scope) == "observe"
      assert text(view, "#mode-enforce") =~ "Set the hive's default to enforce"
      assert text(view, "#mode-enforce") =~ "a connection no rule allows is denied"
      assert text(view, "#mode-enforce") =~ "in the 1 repository that follows the hive's default"
      assert text(view, "#mode-would") =~ "files.cdn.example"
      assert text(view, "#mode-would-n") == "1 destination"

      view |> element("#mode-would button", "Allow for the hive") |> render_click()
      assert rule(scope, "files.cdn.example")
      assert text(view, "#mode-would-n") == "none left"

      view |> element("#mode-confirm") |> render_click()
      assert Policy.get_mode(scope) == "enforce"
      assert has_element?(view, "#policy-mode-enforce[aria-checked=true]")

      assert text(view, "#flash-info") =~
               "The hive's default is enforce. 1 repository follows it. Version"

      assert text(view, "#nav-policy-mode") == "enforce"
    end

    test "with nothing to deny the list gives way to a sentence; cancel changes nothing",
         %{conn: conn, scope: scope} do
      view = open(conn)
      view |> element("#policy-mode-enforce") |> render_click()
      assert text(view, "#mode-would-none") =~ "Every destination your runs reached"

      view |> element("#mode-enforce button", "Cancel") |> render_click()
      refute has_element?(view, "#mode-enforce")
      assert Policy.get_mode(scope) == "observe"
    end

    test "going back to observe asks too, and says a deny still holds", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _} = Policy.set_mode(scope, "enforce")
      view = open(conn)

      view |> element("#policy-mode-observe") |> render_click()

      assert text(view, "#mode-observe") =~
               "only what a deny rule names is denied in the runs that name no repository"

      assert text(view, "#mode-observe") =~
               "The rules stay as they are, locked ones too: a deny holds in either mode."

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

    test "the hive's page says how many, and the sidebar tag counts them", %{conn: conn} do
      view = open(conn)

      assert text(view, "#policy-mode-under") =~
               "A repository follows it unless an owner sets a mode of its own: 1 of 2 repositories does , and enforces."

      assert has_element?(view, "#policy-mode-under a[href='/hive/policy/targets?mode=own']")
      assert text(view, "#nav-policy-mode") == "observe · 1 own"

      assert has_element?(
               view,
               "#nav-policy-mode[title=\"The hive's default mode is observe. 1 repository sets its own and enforces.\"]"
             )
    end

    test "a managed hive with a mode set and no rule says what version is served",
         %{scope: scope} do
      other = scope_fixture()
      {:ok, _} = Policy.set_mode(other, "enforce")
      %{user: owner} = %{user: other.user}
      view = open(log_in_user(build_conn(), owner))
      assert text(view, "#policy-first-version") =~ "Version 1 is what machines are served now"
      _ = scope
    end

    test "the confirm names those that do not change", %{conn: conn} do
      view = open(conn)
      view |> element("#policy-mode-enforce") |> render_click()
      assert text(view, "#mode-enforce") =~ "1 repository sets its own mode and does not change."
    end

    test "the targets list has a Mode column, and ?mode=own keeps those with their own",
         %{conn: conn, docs: docs} do
      view = open(conn, "/hive/policy/targets")
      assert text(view, "#targets-summary") =~ "1 sets its own mode"
      assert text(view, "#target-#{docs.id} .q-c-mode") == "enforce Its own"
      assert text(view, "#policy-targets") =~ "observe Hive default"

      view = open(conn, "/hive/policy/targets?mode=own")
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
    test "none has posted", %{conn: conn} do
      view = open(conn, "/hive/policy/targets")
      assert has_element?(view, "h2", "No repositories yet")
    end

    test "one row per target, with what it has of its own", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      started_run(scope, %{"forge" => "github.example", "repository" => "acme/docs"})

      target =
        Enum.find(Policy.list_targets(scope), &(&1.target.path == "acme/shop")).target

      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      {:ok, _} = Policy.deny(scope, target, %{host: "registry.example"})

      view = open(conn, "/hive/policy/targets")

      assert text(view, "#targets-summary") =~ "2 repositories have posted runs"
      assert text(view, "#targets-summary") =~ "1 with rules of their own"
      assert text(view, "#target-#{target.id}") =~ "Own rules"
      assert text(view, "#target-#{target.id}") =~ "v1"
      # Whose version each row shows, and no bare 0 where nothing is to review.
      assert text(view, "#target-#{target.id} .q-vpill") =~ "of github.example/acme/shop"
      assert text(view, "#policy-targets") =~ "of hive baseline"

      refute view |> element("#target-#{target.id} td.q-num:nth-of-type(6)") |> render() =~
               ">0<"

      assert text(view, "#policy-targets") =~ "Hive baseline"

      assert has_element?(
               view,
               "#target-#{target.id} a[href='/hive/policy/targets/#{target.id}']"
             )
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
         %{conn: conn, user: user} do
      view = open(conn, "/hive/policy/history")

      assert text(view, "#history-summary") =~ "4 changes"
      assert text(view, "#history-summary") =~ "3 versions"

      assert text(view, "#history-list") =~
               "#{user.email} switched the hive's default mode from observe to enforce"

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
      view = open(conn, "/hive/policy/history")

      view |> element("#chg-#{change.id}-summary") |> render_click()
      assert_patch(view, "/hive/policy/history?change=#{change.id}")

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
      assert_patch(view, "/hive/policy/history")
    end

    test "another hive's change opens nothing", %{conn: conn} do
      other = scope_fixture()
      {:ok, _} = Policy.allow(other, nil, %{host: "secret.example"})
      [change] = Policy.list_changes(other, nil, 1).items

      view = open(conn, "/hive/policy/history?change=#{change.id}")
      refute has_element?(view, ".q-chg[open]")
      refute render(view) =~ "secret.example"

      view = open(conn, "/hive/policy/history?change=not-an-id&page=zzz")
      refute has_element?(view, ".q-chg[open]")
    end
  end

  describe "a version" do
    setup %{scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      {:ok, _} = Policy.allow(scope, nil, %{host: "files.cdn.example"})
      :ok
    end

    test "the document tab opens the current one", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/hive/policy/versions/2"}}} =
               live(conn, "/hive/policy/document")
    end

    test "changes from the one before, the document, and the bytes as served",
         %{conn: conn, scope: scope} do
      view = open(conn, "/hive/policy/versions/2")
      {:ok, configuration} = Policy.get_configuration(scope, nil, 2)

      assert has_element?(view, "h1", "Version 2")
      assert text(view, "#policy-page") =~ "In force"
      assert text(view, "#version-strip") =~ "Allowed files.cdn.example"
      assert text(view, "#version-doc") =~ "v1 → v2 · 1 line added"
      assert text(view, "#version-lines .q-add") =~ ~s(Added: "files.cdn.example")
      assert has_element?(view, "#version-copy[data-copy='#{configuration.document}']")
      assert has_element?(view, "#ver-2[aria-current=page]")

      view |> element("#version-view button", "As served") |> render_click()
      assert_patch(view, "/hive/policy/versions/2?view=served")

      assert text(view, "#version-doc") =~
               "#{byte_size(configuration.document)} bytes · sha256 over exactly these"

      html = view |> element("#version-served") |> render()
      assert html =~ Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(configuration.document))

      view |> element("#version-view button", "Document") |> render_click()
      assert text(view, "#version-pretty") =~ ~s("mode" : "observe")
    end

    test "an older version is superseded, and says by which", %{conn: conn} do
      view = open(conn, "/hive/policy/versions/1")
      assert text(view, "#policy-page") =~ "Superseded"
      assert text(view, "#version-superseded") =~ "by v2 after"
      assert text(view, "#version-export") == "Export the version in force"
    end

    test "a version that is superseded while it is open stops saying it is in force",
         %{conn: conn, scope: scope} do
      view = open(conn, "/hive/policy/versions/2")
      assert text(view, "#policy-page") =~ "In force"

      {:ok, _} = Policy.allow(scope, nil, %{host: "later.example"})
      _ = render(view)

      assert text(view, "#policy-page") =~ "Superseded"
      assert text(view, "#version-superseded") =~ "by v3"
      assert has_element?(view, "#ver-3")
    end

    test "a version that does not exist, and one that is no number", %{conn: conn} do
      view = open(conn, "/hive/policy/versions/31")
      assert has_element?(view, "h2", "There is no version 31")
      assert has_element?(view, "a[href='/hive/policy/versions/2']", "Open version 2")

      view = open(conn, "/hive/policy/versions/abc?compare=x&view=y")
      assert has_element?(view, "h2", "There is no version abc")
    end

    test "export is a modal at its own URL, with both texts and the caveats",
         %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{kind: "credential", name: "model-key"})
      view = open(conn, "/hive/policy/versions/3/export")
      {:ok, configuration} = Policy.get_configuration(scope, nil, 3)

      assert has_element?(view, "#policy-export")
      assert text(view, "#export-lead") =~ "as of version 3"
      assert text(view, "#export-policy-text") =~ "# #{configuration.digest}"
      assert text(view, "#export-policy-text") =~ "model-key"
      assert text(view, "#export-runner-text") =~ "~/.config/qory/runner.yaml egress"

      assert has_element?(
               view,
               "#export-download[download$='-policy.yaml'][href^='data:text/yaml']"
             )

      assert text(view, "#policy-export") =~ "Deny rules and locks are already applied"

      view |> element("#policy-export a", "Done") |> render_click()
      assert_patch(view, "/hive/policy/versions/3")
    end

    test "only the version in force is exported", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/hive/policy/versions/1/export")
      assert text(view, "#export-lead") =~ "as of version 2"
      assert has_element?(view, "h1", "Version 2")
    end
  end

  describe "the sidebar" do
    test "a page that subscribes itself gets each change, whoever subscribed first",
         %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      view = open(conn)

      # The hook subscribed before the page did: two subscriptions, one process.
      topic = Policy.topic(scope.hive.id)
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
      {:ok, view, _html} = live(conn, ~p"/hive/settings")

      {:ok, _} = Policy.set_mode(scope, "enforce")
      assert text(view, "#nav-policy-mode") == "enforce"
      assert Process.alive?(view.pid)
    end

    test "the mode word follows the policy on a page that does not", %{conn: conn, scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
      {:ok, view, _html} = live(conn, ~p"/hive/members")
      assert text(view, "#nav-policy-mode") == "observe"

      {:ok, _} = Policy.set_mode(scope, "enforce")

      assert render(view) =~
               "The hive&#39;s default mode is enforce. Every repository follows it."

      assert text(view, "#nav-policy-mode") == "enforce"
    end
  end
end
