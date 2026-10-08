defmodule ApiaryWeb.PageComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]
  import ApiaryWeb.PageComponents
  import ApiaryWeb.CoreComponents, only: [button: 1]

  defp attribute(html, selector, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  defp text(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  test "a page's header: the title as the h1, its line, its actions" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.page_header title="Nodes">
        <:badge><span id="tag">3 running</span></:badge>
        <:description>The machines your runs run on.</:description>
        <:actions><.button id="new-node">New node</.button></:actions>
        <p id="narrowed">Showing the runs of acme/shop only.</p>
      </.page_header>
      """)

    assert text(html, "#page-header h1#page-header-title") =~ "Nodes"
    assert text(html, "#page-header-title + #tag") =~ "3 running"
    assert text(html, "#page-header-description") =~ "The machines your runs run on."
    assert text(html, "#page-header-description + #narrowed") =~ "acme/shop"
    assert attribute(html, "#page-header-actions #new-node", "id") == "new-node"

    html = rendered_to_string(~H|<.page_header title="Runs" />|)
    refute html =~ "page-header-description"
    refute html =~ "page-header-actions"
  end

  test "a thing's tabs: links, the current one marked, Settings last and set apart" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.page_tabs id="target-tabs" label="Target" current={:policy}>
        <:tab key={:overview} patch="/acme/shop/targets/acme/shop">Overview</:tab>
        <:tab key={:policy} patch="/acme/shop/targets/acme/shop/-/policy" count={2}>Policy</:tab>
        <:tab key={:settings} navigate="/acme/shop/targets/acme/shop/-/settings" settings>
          Settings
        </:tab>
      </.page_tabs>
      """)

    assert attribute(html, "nav#target-tabs.q-tabs", "aria-label") == "Target"
    assert attribute(html, "#target-tabs-policy", "aria-current") == "page"
    assert attribute(html, "#target-tabs-overview", "aria-current") == nil
    assert attribute(html, "#target-tabs-settings", "class") =~ "q-tabs-end"
    assert text(html, "#target-tabs-policy .q-tabs-n") =~ "2"

    # A thing's bar sticks and scrolls sideways: it carries no section class.
    assert attribute(html, "nav#target-tabs", "class") |> String.split() == ["q-tabs"]
  end

  test "a settings section's tabs: in the flow under its h1, wrapping, without bleed" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.page_tabs id="secrets-tabs" label="Secrets and variables" current={:secrets} place="section">
        <:tab key={:secrets} patch="/acme/shop/settings/secrets" count={2}>Secrets</:tab>
        <:tab key={:variables} patch="/acme/shop/settings/variables" count={3}>Variables</:tab>
      </.page_tabs>
      """)

    assert attribute(html, "nav#secrets-tabs", "class") |> String.split() ==
             ["q-tabs", "q-tabs-section"]

    assert attribute(html, "nav#secrets-tabs", "aria-label") == "Secrets and variables"
    assert attribute(html, "#secrets-tabs-secrets", "aria-current") == "page"

    # The class undoes what makes a thing's bar a bar: not sticky, no bleed to the gutter,
    # no side padding, wrapping in place of the sideways scroll; and the root keeps no room
    # for a sticky bar that a section's tabs are not.
    css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))
    [rule] = Regex.run(~r/\.q-tabs\.q-tabs-section \{([^}]*)\}/, css, capture: :all_but_first)

    for declaration <- [
          "position: static;",
          "flex-wrap: wrap;",
          "margin-inline: 0;",
          "padding-inline: 0;",
          "overflow: visible;"
        ] do
      assert rule =~ declaration
    end

    refute css =~ ":root:has(.q-tabs) {"
    assert css =~ ":root:has(.q-tabs:not(.q-tabs-section)) {"
  end

  test "a settings page: the section's title is its one h1; the frame names the level" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.settings_page section={:runs} title="Runs" measure="list">
        <:subtitle>How long this workspace keeps its runs.</:subtitle>
        <:actions><.button>Save</.button></:actions>
        <p>body</p>
      </.settings_page>
      """)

    assert text(html, "#settings-section-runs.q-settings-main-list h1#settings-section-title") =~
             "Runs"

    # The section's title takes the focus after a navigation.
    assert attribute(html, "h1#settings-section-title", "tabindex") == "-1"
    assert html |> LazyHTML.from_fragment() |> LazyHTML.query("h1") |> Enum.count() == 1
    refute html =~ "<h2"
    refute html =~ "settings-tabs"

    # A caller that still names the level compiles, and the level is not drawn.
    html =
      rendered_to_string(~H"""
      <.settings_page heading="Organisation settings" section={:people} title="People">
        <p>body</p>
      </.settings_page>
      """)

    assert text(html, "h1#settings-section-title") =~ "People"
    refute html =~ "Organisation settings"
  end

  test "a form page: its title, and Cancel at its foot to where it was opened from" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.page_form id="new-node" title="New node">
        <:description>A machine that runs runs.</:description>
        <form id="new-node-form">
          <.page_form_foot id="new-node-save" cancel="/acme/shop/nodes">
            <.button variant="primary" type="submit">Create node</.button>
          </.page_form_foot>
        </form>
      </.page_form>
      """)

    assert text(html, "#new-node h1#new-node-title") =~ "New node"
    assert attribute(html, "#new-node-form #new-node-save-cancel", "href") == "/acme/shop/nodes"
    refute html =~ "<dialog"

    # No bare Back in the header: Cancel and the breadcrumb lead back, and a caller that
    # still passes where the form came from draws none either.
    refute html =~ "new-node-back"
    refute text(html, "#new-node header") =~ "Back"

    html =
      rendered_to_string(~H"""
      <.page_form id="new-node" title="New node" cancel="/acme/shop/nodes" cancel_by="patch">
        <form id="new-node-form"></form>
      </.page_form>
      """)

    refute html =~ "new-node-back"
    refute html =~ "/acme/shop/nodes"
  end

  test "the line of what a run receives, in the page's own words" do
    assigns = %{}

    html =
      rendered_to_string(
        ~H|<.not_on_runs>A run receives only its security policy.</.not_on_runs>|
      )

    assert text(html, "p#not-on-runs.q-not-yet") =~ "A run receives only its security policy."

    html =
      rendered_to_string(~H"""
      <.not_on_runs id="policy-only">Qory Apiary sends a run only its security policy.</.not_on_runs>
      """)

    assert text(html, "#policy-only") =~ "Qory Apiary sends a run only its security policy."

    # The page's sentence is required: no vague default.
    assert %{required: true} =
             Enum.find(
               ApiaryWeb.PageComponents.__components__().not_on_runs.slots,
               &(&1.name == :inner_block)
             )
  end
end
