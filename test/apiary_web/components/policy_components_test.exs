defmodule ApiaryWeb.PolicyComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias ApiaryWeb.PolicyComponents

  @digest "sha256=c41d7e02b9a61f0d83c5a97be6240d1e5f8b3a6c9d2e7f10a4b5c6d7e8f90a1b"

  defp text(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
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
          navigate: "/hive/policy/versions/10",
          copy: true
        )

      assert html =~ ~s(href="/hive/policy/versions/10")
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
    assert render_component(&PolicyComponents.source_chip/1, source: :hive) |> text() ==
             "Workplace"

    assert render_component(&PolicyComponents.source_chip/1, source: :target) |> text() ==
             "This repository"

    locked = render_component(&PolicyComponents.source_chip/1, source: :hive_locked)
    assert text(locked) == "Workplace, locked"
    assert locked =~ "hero-lock-closed-micro"

    assert render_component(&PolicyComponents.source_chip/1,
             source: :hive,
             label: "Hive baseline"
           )
           |> text() == "Hive baseline"
  end

  test "rule_mark says its word to a screen reader, and pending is not decided" do
    assert render_component(&PolicyComponents.rule_mark/1, action: "allow") =~ "q-mark-ok"
    assert render_component(&PolicyComponents.rule_mark/1, action: "deny") |> text() == "Deny"

    pending = render_component(&PolicyComponents.rule_mark/1, action: "pending")
    assert pending =~ "q-mark-pend"
    assert text(pending) == "Not allowed"
  end

  describe "provenance in the rules table" do
    @at ~U[2026-09-09 10:00:00.000000Z]

    defp row(attrs) do
      Map.merge(
        %{
          id: "r1",
          action: "allow",
          host: "registry.example",
          paths: nil,
          locked: false,
          source: :hive,
          by: "dana",
          at: @at,
          locked_tip: nil,
          can_change: true,
          act: :disable,
          beaten: []
        },
        attrs
      )
    end

    defp table(assigns) do
      ~H"""
      <PolicyComponents.rules_table
        id="t"
        label="Effective policy"
        rows={@rows}
        scope={@scope}
        can_lock={@can_lock}
        activity={@activity}
      />
      """
    end

    defp render_table(rows, opts \\ []) do
      rendered_to_string(
        table(%{
          rows: rows,
          scope: Keyword.get(opts, :scope, :target),
          can_lock: Keyword.get(opts, :can_lock, false),
          activity: Keyword.get(opts, :activity, :unavailable)
        })
      )
    end

    test "a target row names its source and its one act" do
      html = render_table([row(%{})])

      assert text(html) =~ "Comes from"
      assert text(html) =~ "Allow registry.example every path Workplace Disable here"
      assert html =~ ~s(aria-label="Disable registry.example for this repository")
      refute text(html) =~ "Last 7 days"
    end

    test "the rule that lost hangs under the rule that beat it, struck and announced" do
      beaten = %{
        id: "h1",
        action: "allow",
        host: "gitlab.example",
        source: :hive,
        kind: :override,
        by: "beekeeper",
        at: @at,
        winner_by: "dana",
        winner_at: @at
      }

      html =
        render_table([
          row(%{
            id: "r2",
            action: "deny",
            host: "gitlab.example",
            source: :target,
            act: :restore,
            beaten: [beaten]
          })
        ])

      assert html =~ ~s(id="rule-r2-over-h1")
      assert html =~ "q-has-over"

      assert html =~
               ~r{<s>\s*<span class="sr-only">not in force: </span>allow gitlab.example\s*</s>}

      assert text(html) =~ "Overrides the workplace's rule"
      assert text(html) =~ "Disabled here by dana · 9 Sep"
      assert text(html) =~ "Restore"
    end

    test "a locked hive rule holds against the target's, which can be removed" do
      beaten = %{
        id: "p1",
        action: "allow",
        host: "bin.paste.example",
        source: :target,
        kind: :lock,
        by: "dana",
        at: @at,
        winner_by: "beekeeper",
        winner_at: @at
      }

      html =
        render_table([
          row(%{
            id: "r3",
            action: "deny",
            host: "*.paste.example",
            locked: true,
            source: :hive_locked,
            act: :open,
            beaten: [beaten]
          })
        ])

      assert text(html) =~ "Workplace, locked"
      assert text(html) =~ "Holds against this repository's rule"
      assert text(html) =~ "It is not in force."
      assert html =~ "Remove it"

      assert html =~
               ~s(aria-description="Every host below paste.example, and not paste.example itself.")

      assert html =~ ~s(href="/hive/policy?rule=%2A.paste.example")
    end

    test "last 7 days: counts, not seen, a skeleton while loading, no column when unavailable" do
      rows = [row(%{}), row(%{id: "r9", host: "quiet.example"})]

      html = render_table(rows, activity: %{"r1" => %{allowed: 1412, denied: 3}})
      assert text(html) =~ "1,412 allowed · 3 denied"
      assert text(html) =~ "not seen"

      assert render_table(rows, activity: :loading) =~ "skeleton"
      refute text(render_table(rows, activity: :unavailable)) =~ "Last 7 days"
    end

    test "on the hive's page an owner toggles a lock and a member reads it" do
      locked =
        row(%{
          locked: true,
          source: :hive_locked,
          locked_tip:
            "Locked by beekeeper@example.com on 2 Sep 2026. Only an owner can change or unlock it.",
          can_change: false
        })

      owner = render_table([%{locked | can_change: true}], scope: :hive, can_lock: true)
      assert owner =~ ~s(aria-pressed="true")
      # One carrier of the state: the name stays, aria-pressed says whether it is locked.
      assert owner =~ ~s(aria-label="Lock registry.example")
      refute owner =~ ~s(aria-label="Unlock)
      assert owner =~ ~s(aria-label="Actions for registry.example")

      member = render_table([locked], scope: :hive, can_lock: false)
      refute member =~ "aria-pressed"
      refute member =~ "Actions for"
      assert member =~ "Locked by beekeeper@example.com on 2 Sep 2026."
      assert member =~ ~s(aria-description="Locked by beekeeper@example.com on 2 Sep 2026.)
      assert text(member) =~ "dana · 9 Sep"
    end

    test "a host from anywhere is escaped" do
      html = render_table([row(%{host: "<img src=x onerror=alert>"})])
      refute html =~ "<img"
    end
  end

  test "rich text is escaped at every level" do
    assigns = %{text: ["a ", {:b, ["<b>", {:m, "<i>"}]}, {:code, "<u>"}]}
    html = rendered_to_string(~H"<PolicyComponents.rich text={@text} />")

    refute html =~ "<i>"
    refute html =~ "<u>"
    assert html =~ "&lt;u&gt;"
  end

  test "the target's mode is a radio group, its radios checked and never pressed" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <PolicyComponents.target_mode
        id="rm"
        setting="follow"
        effective="enforce"
        hive_default="enforce"
        can_edit={false}
        locked_denies={["*.paste.example"]}
      />
      """)

    assert html =~ ~s(role="radiogroup")
    assert html =~ ~s(id="rm-follow" type="button" role="radio" aria-checked="true")
    refute html =~ "aria-pressed"

    assert html =~
             ~s(id="rm-enforce" type="button" role="radio" aria-checked="false" aria-disabled="true")

    assert html =~ "Only an owner sets a mode."
    refute html =~ "rm-locked-note"
  end

  test "a mode card is described by its sentence, its fact and the owners' line" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <PolicyComponents.mode_switch mode="observe" can_edit={false} served={false} />
      """)

    assert html =~
             ~s(aria-describedby="policy-mode-observe-p policy-mode-fact policy-mode-owners")

    assert html =~ ~s(aria-describedby="policy-mode-enforce-p policy-mode-owners")
    assert html =~ "Not served yet: it applies from the first change here."
  end
end
