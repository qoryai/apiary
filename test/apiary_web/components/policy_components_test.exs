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
  end

  test "the target's mode is a radio group, its radios checked and never pressed" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <PolicyComponents.target_mode
        id="rm"
        setting="follow"
        effective="enforce"
        workspace_default="enforce"
        workspace="Main"
        can_edit={false}
      />
      """)

    assert html =~ ~s(role="radiogroup")
    assert html =~ ~s(id="rm-follow" type="button" role="radio" aria-checked="true")
    refute html =~ "aria-pressed"
    assert text(html) =~ "Follow Main Observe Enforce"

    assert html =~
             ~s(id="rm-enforce" type="button" role="radio" aria-checked="false" aria-disabled="true")

    assert text(html) =~ "It follows Main, which enforces. A connection no rule allows is denied."
    assert html =~ "Only an owner or an admin sets a mode."

    own =
      rendered_to_string(~H"""
      <PolicyComponents.target_mode
        id="rm"
        setting="observe"
        effective="observe"
        workspace_default="enforce"
        workspace="Main"
        set={%{by: "sam", at: DateTime.utc_now()}}
        can_edit={true}
      />
      """)

    assert text(own) =~
             "Its own, set by sam today; Main enforces. What no rule names is let through and recorded; a deny rule holds, and so do Main's locked rules."

    refute own =~ "aria-disabled"
  end

  test "a mode card is described by its sentence, its fact and the owners' line" do
    assigns = %{scope: @scope}

    html =
      rendered_to_string(~H"""
      <PolicyComponents.mode_switch scope={@scope} mode="observe" can_edit={false} served={false} />
      """)

    assert html =~
             ~s(aria-describedby="policy-mode-observe-p policy-mode-fact policy-mode-owners")

    assert html =~ ~s(aria-describedby="policy-mode-enforce-p policy-mode-owners")
    assert html =~ "Not served yet: it applies from the first change here."
  end
end
