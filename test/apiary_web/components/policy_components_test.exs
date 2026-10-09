defmodule ApiaryWeb.PolicyComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}
  alias ApiaryWeb.PolicyComponents
  alias ApiaryWeb.PolicyLive.RuleList

  # The caller's scope: its organisation and workspace name the links.
  @scope %Scope{
    organisation: %Organisation{slug: "acme"},
    workspace: %Workspace{slug: "main"}
  }

  @digest "sha256=c41d7e02b9a61f0d83c5a97be6240d1e5f8b3a6c9d2e7f10a4b5c6d7e8f90a1b"

  defp text(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  describe "change_list" do
    defp change(id, at) do
      %{
        id: id,
        sentence: "Changed",
        origin: nil,
        who: "dana",
        at: at,
        version: nil,
        digest: nil,
        navigate: nil,
        workspace: false,
        patch: "/p",
        close: "/c"
      }
    end

    test "groups the changes by the reader's day, not by UTC's" do
      ApiaryWeb.Format.put_time_zone("Europe/Berlin")

      html =
        render_component(&PolicyComponents.change_list/1,
          id: "history",
          label: "History",
          # 23:30 UTC on the 19th is 01:30 on the 20th in Berlin: the day of 10:00 UTC.
          changes: [change(1, ~U[2026-09-20 10:00:00Z]), change(2, ~U[2026-09-19 23:30:00Z])],
          now: ~U[2026-09-20 12:00:00Z]
        )

      assert length(Regex.scan(~r/class="q-day"/, html)) == 1
      assert text(html) =~ "Today"
      refute text(html) =~ "Yesterday"
    end
  end

  describe "version_pill" do
    test "the version, the first twelve characters of the digest, the whole digest as the title" do
      html = render_component(&PolicyComponents.version_pill/1, version: 14, digest: @digest)

      assert text(html) == "Version v14 sha256 c41d7e02b9a6"
      assert html =~ ~s(title="#{@digest}")
      refute html =~ "<a "
      refute html =~ "CopyToClipboard"
    end

    test "links the version, and copies the full digest" do
      html =
        render_component(&PolicyComponents.version_pill/1,
          id: "pill",
          version: 10,
          digest: @digest,
          navigate: "/acme/main/policy/versions/10",
          copy: true
        )

      assert html =~ ~s(href="/acme/main/policy/versions/10")
      assert html =~ ~s(id="pill-copy")
      assert html =~ ~s(data-copy="#{@digest}")
      assert html =~ ~s(aria-label="Copy the digest")
    end

    test "sm has no sha256 word and never a copy button" do
      html =
        render_component(&PolicyComponents.version_pill/1,
          id: "pill",
          version: 3,
          digest: @digest,
          size: "sm",
          copy: true
        )

      assert text(html) == "Version v3 c41d7e02b9a6"
      assert html =~ "q-vpill-sm"
      refute html =~ "CopyToClipboard"
    end

    test "a scope names whose version it is, away from its own page" do
      html =
        render_component(&PolicyComponents.version_pill/1,
          version: 3,
          digest: @digest,
          size: "sm",
          scope: "github.example/acme/shop"
        )

      assert text(html) == "Version v3 c41d7e02b9a6 of github.example/acme/shop"
      assert html =~ "q-vpill-scope"
    end

    test "no version yet" do
      assert render_component(&PolicyComponents.version_pill/1, []) |> text() == "No version yet"
    end

    test "a digest from a runner is escaped and cut, whatever it holds" do
      html =
        render_component(&PolicyComponents.version_pill/1, version: 1, digest: ~s(<script>"x"))

      refute html =~ "<script>"
      assert PolicyComponents.short_digest(nil) == nil
    end
  end

  test "version_link is a link only when it has somewhere to go" do
    assert render_component(&PolicyComponents.version_link/1, version: 9, navigate: "/v/9") =~
             ~s(href="/v/9")

    html = render_component(&PolicyComponents.version_link/1, version: 9)
    refute html =~ "<a "
    assert text(html) == "v9"
  end

  test "source_chip: three wordings, a label in their place" do
    assert render_component(&PolicyComponents.source_chip/1, source: :workspace) |> text() ==
             "Workspace"

    assert render_component(&PolicyComponents.source_chip/1, source: :target) |> text() ==
             "This repository"

    locked = render_component(&PolicyComponents.source_chip/1, source: :workspace_locked)
    assert text(locked) == "Workspace, locked"
    assert locked =~ "hero-lock-closed-micro"

    assert render_component(&PolicyComponents.source_chip/1,
             source: :workspace,
             label: "Workspace baseline"
           )
           |> text() == "Workspace baseline"
  end

  test "rule_mark says its word to a screen reader, and pending is not decided" do
    assert render_component(&PolicyComponents.rule_mark/1, action: "allow") =~ "q-mark-ok"
    assert render_component(&PolicyComponents.rule_mark/1, action: "deny") |> text() == "Deny"

    pending = render_component(&PolicyComponents.rule_mark/1, action: "pending")
    assert pending =~ "q-mark-pend"
    assert text(pending) == "Not allowed"
  end

  describe "the list of rules" do
    @at ~U[2026-09-09 10:00:00.000000Z]
    @own %{key: "repo", label: "This repository", rank: 0}
    @main %{key: "main", label: "Main", rank: 2}

    defp row(attrs) do
      Map.merge(
        %{
          id: "r1",
          action: "allow",
          host: "registry.example",
          paths: nil,
          locked: false,
          source: @main,
          own: false,
          in_force: true,
          off: nil,
          by: "dana",
          at: @at,
          locked_tip: nil,
          can_change: false,
          act: nil,
          view: {"View in Main's policy", "/acme/main/policy?rule=registry.example"}
        },
        attrs
      )
    end

    defp own(attrs) do
      row(Map.merge(%{source: @own, own: true, can_change: true, act: :remove, view: nil}, attrs))
    end

    defp list(assigns) do
      ~H"""
      <PolicyComponents.rule_list
        id="policy-rules"
        label="Rules"
        listing={@listing}
        query={@query}
        path={fn query -> "/acme/main/policy?" <> URI.encode_query(RuleList.to_params(query)) end}
        sections={RuleList.sections(@rows, @activity)}
        default_sort="Its own first"
        activity={@activity}
        source={@source}
        can_add={@can_add}
        can_lock={@can_lock}
      />
      """
    end

    defp render_list(rows, opts \\ []) do
      activity = Keyword.get(opts, :activity, :unavailable)
      query = Keyword.get(opts, :query, %RuleList{})

      rendered_to_string(
        list(%{
          rows: rows,
          listing: RuleList.list(rows, query, activity),
          query: query,
          activity: activity,
          source: Keyword.get(opts, :source, true),
          can_add: Keyword.get(opts, :can_add, true),
          can_lock: Keyword.get(opts, :can_lock, false)
        })
      )
    end

    test "the views count every row, the bar holds the search, Filter, Sort and Add rule" do
      html = render_list([row(%{}), own(%{id: "r2", host: "mcp.example", action: "deny"})])

      assert text(html) =~ "All 2 Allowed 1 Denied 1 Locked 0"

      assert html =~ ~s(id="policy-rules-view-all") and
               html =~ ~s(href="/acme/main/policy?view=denied")

      assert html =~ ~s(id="policy-rules-query-input")

      assert html =~ ~s(id="policy-rules-filter-source-0") and
               html =~ ~s(href="/acme/main/policy?q=source%3Arepo")

      assert html =~ ~s(aria-label="Sort: Its own first")
      assert html =~ ~s(id="policy-rules-add" phx-click="composer_open" aria-expanded="false")
      assert text(html) =~ "1–2 of 2"
      # Its own first.
      assert text(html) =~ ~r/mcp\.example.*registry\.example/

      refute render_list([row(%{})], can_add: false) =~ "policy-rules-add"
      refute render_list([row(%{})], source: false) =~ "Source"
    end

    defp narrowed_list(assigns) do
      ~H"""
      <PolicyComponents.rule_list
        id="policy-rules"
        label="Rules"
        listing={@listing}
        query={%RuleList{}}
        path={fn _query -> "/x" end}
        sections={[]}
        default_sort="Denies first"
        activity={%{}}
        views={[:all, :allow, :deny]}
        use_label="Last 14 days, every workspace"
      />
      """
    end

    test "the views and the use column's heading are the caller's" do
      html =
        rendered_to_string(narrowed_list(%{listing: RuleList.list([row(%{})], %RuleList{}, %{})}))

      assert text(html) =~ "All 1 Allowed 1 Denied 0"
      refute html =~ "policy-rules-view-locked"
      assert html =~ "Last 14 days, every workspace"
    end

    test "a rule of the level above the workspace has its tile with its words, no lock, and the way to it" do
      above = %{key: "8wonders", label: "Eight Wonders", rank: 1, tile: "E"}

      html =
        render_list([
          row(%{
            source: above,
            above: true,
            locked_tip: "Eight Wonders's rule: it holds in every workspace.",
            view: {"View in Eight Wonders's policy", "/8wonders/policy?rule=registry.example"}
          })
        ])

      # The tile says whose rule it is; the lock is the workspace's locked rules' alone.
      doc = LazyHTML.from_fragment(html)
      [tile] = doc |> LazyHTML.query(".q-pr-src .q-tile") |> Enum.to_list()
      assert LazyHTML.attribute(tile, "id") == ["rule-r1-lock"]
      assert LazyHTML.text(tile) == "E"

      assert LazyHTML.attribute(tile, "data-tip") == [
               "Eight Wonders's rule: it holds in every workspace."
             ]

      assert LazyHTML.attribute(tile, "aria-label") == LazyHTML.attribute(tile, "data-tip")
      refute html =~ "hero-lock-closed-micro"
      assert html =~ ~s(href="/8wonders/policy?rule=registry.example")
      assert text(html) =~ "View in Eight Wonders's policy"
      refute html =~ "rule-r1-remove"
    end

    test "a rule written elsewhere names its source and leads to it; the page's own has its acts" do
      html = render_list([row(%{})])
      assert text(html) =~ "Allow registry.example every path Main dana · 9 Sept"
      assert html =~ ~s(aria-label="Actions for registry.example")
      assert html =~ ~s(href="/acme/main/policy?rule=registry.example")
      assert text(html) =~ "View in Main's policy"
      refute text(html) =~ "Remove"

      html = render_list([own(%{paths: ["/v1/*"]})])
      assert text(html) =~ "This repository"
      assert text(html) =~ "Edit paths Change to deny Remove"
      refute text(html) =~ "Lock Remove"

      assert html =~
               ~r/&quot;value&quot;:\{&quot;id&quot;:&quot;r1&quot;\},&quot;event&quot;:&quot;remove&quot;/

      # Nothing changes a rule the reader may not change: no menu at all.
      refute render_list([own(%{can_change: false})]) =~ "Actions for"
    end

    test "a rule not in force is struck, and says why where its use would be" do
      off =
        own(%{
          id: "p1",
          host: "bin.paste.example",
          in_force: false,
          off: "Not in force: Main's locked *.paste.example holds"
        })

      html =
        render_list([
          off,
          row(%{id: "r3", host: "*.paste.example", action: "deny", locked: true})
        ])

      assert html =~ ~s(id="rule-p1" class="q-pr-row q-pr-off")

      assert html =~
               ~r{<td class="q-pr-host" title="Not in force: Main&#39;s locked \*\.paste\.example holds">}

      assert text(html) =~ "Not in force: Main's locked *.paste.example holds"
      # Its menu holds Remove alone: nothing is edited while the lock holds.
      assert text(html) =~ ~r/bin\.paste\.example.*Remove.*Deny \*\. paste\.example/
      refute text(html) =~ "Edit paths"

      assert html =~
               ~s(aria-description="Every host below paste.example, and not paste.example itself.")
    end

    test "the use in 14 days: counts, not seen, a skeleton while loading, no column when unavailable" do
      rows = [row(%{}), row(%{id: "r9", host: "quiet.example"})]

      html = render_list(rows, activity: %{"r1" => %{allowed: 1412, denied: 3}})
      assert text(html) =~ "Last 14 days"
      assert text(html) =~ "1,412 allowed · 3 denied"
      assert text(html) =~ "not seen"
      assert html =~ ~s(id="policy-rules-filter-seen-0")

      loading = render_list(rows, activity: :loading, query: %RuleList{sort: :used})
      assert loading =~ "skeleton" and loading =~ ~s(aria-busy="true")
      refute loading =~ "policy-rules-pages"

      unavailable = render_list(rows, activity: :unavailable)
      refute text(unavailable) =~ "Last 14 days"
      refute unavailable =~ "policy-rules-sort-used"
      refute unavailable =~ "policy-rules-filter-seen"

      unseen = render_list(rows, activity: :unavailable, query: %RuleList{tokens: [seen: :no]})
      assert text(unseen) =~ "2 rules match"
      assert text(unseen) =~ "could not be counted, so seen: narrows nothing"
    end

    test "on the workspace's page an owner locks from the menu and a member reads the lock" do
      locked =
        own(%{
          locked: true,
          locked_tip:
            "Locked by beekeeper@example.com on 2 Sept 2026. Only an owner can change or unlock it.",
          can_change: false
        })

      owner = render_list([%{locked | can_change: true}], source: false, can_lock: true)
      assert text(owner) =~ "Edit paths Change to deny Unlock Remove"
      assert owner =~ ~s(id="rule-r1-lock")
      assert owner =~ ~s(aria-label="Actions for registry.example")

      assert text(render_list([own(%{})], source: false, can_lock: true)) =~
               "Change to deny Lock Remove"

      member = render_list([locked], source: false, can_lock: false)
      refute member =~ "Actions for"
      assert member =~ ~s(aria-description="Locked by beekeeper@example.com on 2 Sept 2026.)
      assert text(member) =~ "dana · 9 Sept Locked"
    end

    test "a host from anywhere is escaped" do
      html = render_list([row(%{host: "<img src=x onerror=alert>"})])
      refute html =~ "<img"
    end

    test "no rule, and no rule matching, each say so" do
      assert text(render_list([], query: %RuleList{text: "x"})) =~ "No rule matches."
      assert text(render_list([])) =~ "No rule matches."
    end

    defp confirming_list(assigns) do
      ~H"""
      <PolicyComponents.rule_list
        id="policy-rules"
        label="Rules"
        listing={@listing}
        query={@query}
        path={fn _query -> "/acme/main/policy" end}
        sections={RuleList.sections(@rows, :unavailable)}
        default_sort="Its own first"
        confirming="r2"
      >
        <:confirm :let={rule}>
          <ApiaryWeb.CoreComponents.inline_confirm
            id="remove-confirm"
            question={"Remove the deny rule #{rule.host}?"}
            cancel="/acme/main/policy"
          >
            This takes effect within a heartbeat.
            <:action>
              <ApiaryWeb.CoreComponents.button variant="danger" size="xs">
                Yes, remove
              </ApiaryWeb.CoreComponents.button>
            </:action>
          </ApiaryWeb.CoreComponents.inline_confirm>
        </:confirm>
      </PolicyComponents.rule_list>
      """
    end

    # As `table/1`'s: in a table wider than its box, the question and its buttons stay in
    # the box's view (`q-confirm-view`, sticky), wherever the table is scrolled.
    test "a row asking to confirm is one cell across the row, kept in view" do
      rows = [row(%{}), own(%{id: "r2", host: "mcp.example", action: "deny"})]
      query = %RuleList{}

      html =
        rendered_to_string(
          confirming_list(%{
            rows: rows,
            listing: RuleList.list(rows, query, :unavailable),
            query: query
          })
        )

      doc = LazyHTML.from_fragment(html)

      assert [cell] = doc |> LazyHTML.query("tr#rule-r2.q-confirming > td") |> Enum.to_list()
      assert LazyHTML.attribute(cell, "class") == ["q-confirm-cell"]
      assert LazyHTML.attribute(cell, "colspan") == ["7"]

      view = LazyHTML.query(cell, "td > .q-confirm-view > #remove-confirm.q-confirm")
      assert [_] = Enum.to_list(view)

      assert text(LazyHTML.to_html(view)) ==
               "Remove the deny rule mcp.example? This takes effect within a heartbeat. " <>
                 "Yes, remove Cancel"

      assert doc |> LazyHTML.query("tr#rule-r1 .q-confirm-view") |> Enum.to_list() == []
    end
  end

  describe "mode_card" do
    defp card(html), do: LazyHTML.from_fragment(html)
    defp all(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.to_list()

    defp text_of(doc, selector),
      do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> squeeze()

    defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

    test "the workspace's mode as it is: the mode, the default's badge, what it does, Change mode" do
      assigns = %{scope: @scope}

      doc =
        card(
          rendered_to_string(~H"""
          <PolicyComponents.mode_card
            level={:workspace}
            scope={@scope}
            mode="enforce"
            can_edit={true}
            following={3}
            fact={%{denied: 9, destinations: 3}}
          />
          """)
        )

      assert [_] = all(doc, "section#policy-mode.q-modecard[aria-labelledby=policy-mode-h]")
      assert text_of(doc, "#policy-mode-h") == "Mode: Enforce"
      assert text_of(doc, "#policy-mode-value") == "Enforce"
      assert text_of(doc, "#policy-mode-source") == "Workspace default"
      assert [_] = all(doc, ".q-modecard-tile .hero-shield-exclamation")

      assert text_of(doc, "#policy-mode-effect") ==
               "A connection no rule allows is denied. All 3 repositories follow it."

      assert text_of(doc, "#policy-mode-fact") ==
               "In the last 14 days it denied 9 attempts to 3 destinations. See them"

      assert [button] = all(doc, "button#policy-mode-change")
      assert LazyHTML.attribute(button, "aria-expanded") == ["false"]
      assert LazyHTML.attribute(button, "aria-controls") == ["policy-mode-form"]
      assert LazyHTML.attribute(button, "phx-click") == ["mode_open"]
      refute LazyHTML.attribute(button, "class") |> hd() =~ "btn-primary"

      # A status, not a control: no radio and no form until Change mode.
      assert all(doc, "[role=radio], [role=radiogroup], input, form") == []
      assert all(doc, "#policy-mode-owners") == []
    end

    test "choosing: native radios in a fieldset, the pick checked, the current one marked" do
      assigns = %{scope: @scope}

      doc =
        card(
          rendered_to_string(~H"""
          <PolicyComponents.mode_card
            level={:workspace}
            scope={@scope}
            mode="observe"
            can_edit={true}
            pick="observe"
          />
          """)
        )

      assert all(doc, "#policy-mode-change") == []
      assert [form] = all(doc, "form#policy-mode-form")
      assert LazyHTML.attribute(form, "phx-change") == ["mode_pick"]
      assert LazyHTML.attribute(form, "phx-submit") == ["mode_set"]
      # Escape is the PolicyPage hook's, with the focus in the form: never the window's.
      assert LazyHTML.attribute(form, "phx-window-keydown") == []

      assert text_of(doc, "fieldset legend#policy-mode-legend") ==
               "Choose the workspace's default mode"

      assert length(all(doc, "fieldset input[type=radio][name=mode]")) == 2
      assert [_] = all(doc, "input#policy-mode-opt-observe[checked]")
      assert all(doc, "input#policy-mode-opt-enforce[checked]") == []
      assert all(doc, "[role=radio]") == []
      assert text_of(doc, "#policy-mode-opt-observe-h") == "Observe Current"
      assert [_] = all(doc, "#policy-mode-opt-observe-h #policy-mode-current")

      assert text_of(doc, "#policy-mode-opt-observe-p") ==
               "What no rule names is let through and recorded; a deny rule holds."

      # The pick is the mode now: no question, and Cancel alone.
      assert text_of(doc, "#policy-mode-now") == "Observe is the mode now."
      assert all(doc, "#policy-mode-q, #policy-mode-set") == []
      assert [_] = all(doc, "button#policy-mode-cancel[type=button][phx-click=mode_cancel]")
    end

    test "confirming: the question under the options, its sentence, one button naming the pick" do
      assigns = %{scope: @scope}

      doc =
        card(
          rendered_to_string(~H"""
          <PolicyComponents.mode_card
            level={:target}
            scope={@scope}
            mode="enforce"
            setting="follow"
            workspace_default="enforce"
            workspace="Main"
            target="incident-bot"
            can_edit={true}
            pick="observe"
          >
            <:effect>Only what a deny rule names is denied.</:effect>
            <p id="more">The rules stay as they are.</p>
          </PolicyComponents.mode_card>
          """)
        )

      assert text_of(doc, "#policy-mode-legend") == "Choose the mode for incident-bot"
      assert text_of(doc, "#policy-mode-opt-follow-h") == "Follow Main Current"
      assert [_] = all(doc, "#policy-mode-opt-follow-h .hero-link")
      assert all(doc, ".hero-arrow-uturn-left") == []

      assert text_of(doc, "#policy-mode-opt-follow-p") ==
               "Main's mode, now enforce. It changes when Main's does."

      assert [_] = all(doc, "input#policy-mode-opt-observe[checked]")

      assert [_] =
               all(
                 doc,
                 "[role=group][aria-labelledby=policy-mode-q][aria-describedby=policy-mode-q-effect]"
               )

      assert text_of(doc, "h3#policy-mode-q") == "Observe incident-bot?"
      assert text_of(doc, "#policy-mode-q-effect") == "Only what a deny rule names is denied."
      assert [_] = all(doc, "#policy-mode-form #more")

      assert [set] = all(doc, "button#policy-mode-set[type=submit]")
      assert LazyHTML.attribute(set, "class") |> hd() =~ "btn-primary"
      assert text_of(doc, "#policy-mode-set .btn-label") == "Observe this repository"
      assert all(doc, ".btn-error") == []
      assert all(doc, "#policy-mode-now") == []

      # The source of the mode in force: following the workspace, or its own.
      assert text_of(doc, "#policy-mode-source") == "Follows Main"
      assert [_] = all(doc, "#policy-mode-source .hero-link-micro")
    end

    test "a member sees the card with no Change mode, and the line that says who may" do
      assigns = %{scope: @scope}

      html =
        rendered_to_string(~H"""
        <PolicyComponents.mode_card
          level={:target}
          scope={@scope}
          mode="observe"
          setting="observe"
          workspace_default="enforce"
          workspace="Main"
          target="incident-bot"
          set={%{by: "sam", at: DateTime.utc_now()}}
          pick="enforce"
        />
        """)

      doc = card(html)
      assert all(doc, "#policy-mode-change, form, input, button") == []
      refute html =~ "aria-disabled"
      assert text_of(doc, "#policy-mode-source") == "Its own"
      assert [_] = all(doc, ".q-modecard-tile .hero-eye")

      assert text_of(doc, "#policy-mode-effect") ==
               "Its own, set by sam today; Main enforces. What no rule names is let through and recorded; a deny rule holds, and so do Main's locked rules. Only an owner or an admin sets a mode."

      assert text_of(doc, "#policy-mode-owners") == "Only an owner or an admin sets a mode."
    end

    test "under a level that requires enforce: the lock, who requires it, nothing to change" do
      assigns = %{scope: @scope}

      doc =
        card(
          rendered_to_string(~H"""
          <PolicyComponents.mode_card
            level={:workspace}
            scope={@scope}
            mode="observe"
            can_edit={true}
            following={2}
            floor={%{name: "Eight Wonders"}}
            pick="observe"
          />
          """)
        )

      assert [_] = all(doc, "#policy-mode[data-floor=true]")
      assert text_of(doc, "#policy-mode-value") == "Enforce"
      assert [_] = all(doc, ".q-modecard-tile .hero-lock-closed")
      assert text_of(doc, "#policy-mode-required") == "Required by Eight Wonders"
      assert [_] = all(doc, "#policy-mode-required .hero-lock-closed-micro")
      assert all(doc, "#policy-mode-source, #policy-mode-change, form, #policy-mode-fact") == []

      assert text_of(doc, "#policy-mode-effect") =~
               "No workspace or repository may observe: Eight Wonders requires enforce."
    end

    test "a workspace not served yet says so in its fact line" do
      assigns = %{scope: @scope}

      doc =
        card(
          rendered_to_string(~H"""
          <PolicyComponents.mode_card
            level={:workspace}
            scope={@scope}
            mode="observe"
            can_edit={true}
            served={false}
          />
          """)
        )

      assert text_of(doc, "#policy-mode-value") == "Observe"
      assert [_] = all(doc, ".q-modecard-tile .hero-eye")

      assert text_of(doc, "#policy-mode-fact") ==
               "Not served yet: it applies from the first change here."

      assert [_] = all(doc, "#policy-mode-change")
    end
  end
end
