defmodule ApiaryWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias ApiaryWeb.CoreComponents

  describe "an input with a prefix" do
    test "shows the prefix before the value as one field, read with it" do
      form = Phoenix.Component.to_form(%{"slug" => "data"}, as: :workspace)

      html =
        render_component(&CoreComponents.input/1,
          field: form[:slug],
          type: "text",
          label: "Address",
          prefix: "qory.example/acme/",
          hint: "Made from the name."
        )

      doc = LazyHTML.from_fragment(html)

      assert [prefix] =
               LazyHTML.query(doc, ".q-input-prefix > span#workspace_slug-prefix")
               |> Enum.to_list()

      assert LazyHTML.text(prefix) == "qory.example/acme/"

      assert [input] =
               LazyHTML.query(doc, ".q-input-prefix > input#workspace_slug") |> Enum.to_list()

      assert LazyHTML.attribute(input, "value") == ["data"]

      assert LazyHTML.attribute(input, "aria-describedby") == [
               "workspace_slug-prefix workspace_slug-hint"
             ]
    end

    test "without one the input stands alone" do
      form = Phoenix.Component.to_form(%{"name" => "Data"}, as: :workspace)

      html =
        render_component(&CoreComponents.input/1, field: form[:name], type: "text", label: "Name")

      refute html =~ "q-input-prefix"
    end
  end

  describe "an input with more than one error" do
    test "shows each, with an id of its own, and is described by all of them" do
      form =
        Phoenix.Component.to_form(%{"email" => "dana"},
          as: :user,
          errors: [email: {"is too long", []}, email: {"must have the @ sign", []}],
          action: :validate
        )

      html = render_component(&CoreComponents.input/1, field: form[:email], type: "email")
      doc = LazyHTML.from_fragment(html)

      assert ["user_email-error", "user_email-error-2"] =
               doc |> LazyHTML.query("p[id^=user_email-error]") |> LazyHTML.attribute("id")

      assert LazyHTML.attribute(LazyHTML.query(doc, "input#user_email"), "aria-describedby") ==
               ["user_email-error user_email-error-2"]
    end
  end

  describe "a menu's items" do
    test "are not tab stops, as a link or as a button" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.row_menu id="row" label="Actions for build-01">
          <CoreComponents.menu_item patch="/keys/1/rotate">Rotate</CoreComponents.menu_item>
          <CoreComponents.menu_item phx-click="copy">Copy</CoreComponents.menu_item>
        </CoreComponents.row_menu>
        """)

      items = html |> LazyHTML.from_fragment() |> LazyHTML.query("[role=menuitem]")
      assert Enum.count(items) == 2
      assert LazyHTML.attribute(items, "tabindex") == ["-1", "-1"]
    end
  end

  describe "a Filter menu with sections" do
    test "opens a section by showing it, then focusing its content, not its way back" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.filter_menu id="f" count={0}>
          <:section key="host" label="Host" icon="hero-globe-alt">
            <input id="f-host-search" type="search" aria-label="Find a host" />
          </:section>
        </CoreComponents.filter_menu>
        """)

      doc = LazyHTML.from_fragment(html)

      assert [_] =
               doc |> LazyHTML.query("#f-section-host > #f-body-host > input") |> Enum.to_list()

      [click] = doc |> LazyHTML.query("#f-open-host") |> LazyHTML.attribute("phx-click")
      assert click =~ ~s("to":"#f-body-host")
      [show, hide, focus] = click |> Jason.decode!() |> Enum.map(&hd/1)
      assert {show, hide, focus} == {"show", "hide", "focus_first"}
    end
  end

  describe "a page's header" do
    test "has a title that takes focus after a navigation, without a ring" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.header>Runs</CoreComponents.header>
        """)

      h1 = html |> LazyHTML.from_fragment() |> LazyHTML.query("h1")
      assert LazyHTML.attribute(h1, "tabindex") == ["-1"]
    end
  end

  describe "a button with a path" do
    test "is a link while it may act" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button id="older" patch="/runs?page=2">Older</CoreComponents.button>
        """)

      assert [_] = html |> LazyHTML.from_fragment() |> LazyHTML.query("a#older") |> Enum.to_list()
    end

    test "is a disabled button, not a link, when it may not" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button id="newer" patch="/policy/history" disabled>Newer</CoreComponents.button>
        """)

      doc = LazyHTML.from_fragment(html)
      assert [] = doc |> LazyHTML.query("a") |> Enum.to_list()
      button = LazyHTML.query(doc, "button#newer[disabled]")
      assert [_] = Enum.to_list(button)
      assert LazyHTML.attribute(button, "data-phx-link") == []
      assert LazyHTML.attribute(button, "href") == []
    end
  end

  describe "a table" do
    test "is a region named by its label, never by its id" do
      assigns = %{rows: [%{id: 1, name: "build-01"}]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.table id="keys" label="Access keys" rows={@rows}>
          <:col :let={row} label="Name">{row.name}</:col>
          <:col sr_label="Pinned"></:col>
        </CoreComponents.table>
        """)

      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.attribute(LazyHTML.query(doc, "[role=region]"), "aria-label") == [
               "Access keys"
             ]

      assert doc |> LazyHTML.query("th .sr-only") |> LazyHTML.text() == "Pinned"
    end

    # A table wider than its box scrolls sideways: the confirmation is one cell across the
    # row, its content in the block the stylesheet keeps in the box's view (`q-confirm-view`,
    # sticky), so the question and its buttons are never off to one side.
    test "shows a row's confirmation in one cell across its columns, kept in view" do
      assigns = %{rows: [%{id: 1, name: "build-01"}, %{id: 2, name: "build-02"}]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.table
          id="keys"
          label="Access keys"
          rows={@rows}
          row_id={&"key-#{&1.id}"}
          confirming="key-2"
        >
          <:col :let={row} label="Name" kind="title">{row.name}</:col>
          <:col label="Added by" from="sm">dana</:col>
          <:action :let={row}>
            <CoreComponents.row_menu id={"key-#{row.id}-menu"} label={"Actions for #{row.name}"} />
          </:action>
          <:confirm :let={row}>
            <CoreComponents.inline_confirm
              id={"key-#{row.id}-confirm"}
              question={"Revoke #{row.name}?"}
              cancel="/acme/shop/settings/secrets"
            >
              Runs that use it are refused from their next request.
              <:action>
                <CoreComponents.button variant="danger" size="xs">Yes, revoke</CoreComponents.button>
              </:action>
            </CoreComponents.inline_confirm>
          </:confirm>
        </CoreComponents.table>
        """)

      doc = LazyHTML.from_fragment(html)

      assert [cell] = doc |> LazyHTML.query("tr#key-2.q-confirming > td") |> Enum.to_list()
      assert LazyHTML.attribute(cell, "class") == ["q-confirm-cell"]
      assert LazyHTML.attribute(cell, "colspan") == ["3"]

      view = LazyHTML.query(cell, "td > .q-confirm-view > #key-2-confirm.q-confirm")
      assert [_] = Enum.to_list(view)
      assert view |> LazyHTML.query(".q-confirm-q") |> LazyHTML.text() == "Revoke build-02?"

      assert view |> LazyHTML.query(".q-confirm-sub") |> LazyHTML.text() =~
               "refused from their next request"

      assert view
             |> LazyHTML.query(".q-confirm-act button")
             |> Enum.map(&LazyHTML.text/1)
             |> Enum.map(&String.trim/1) ==
               ["Yes, revoke", "Cancel"]

      # The other rows keep their cells.
      assert doc |> LazyHTML.query("tr#key-1 > td") |> Enum.count() == 3
      assert doc |> LazyHTML.query("tr#key-1 .q-confirm-view") |> Enum.to_list() == []
    end
  end

  describe "a menu's trigger, as the Menu hook finds it" do
    # The selector the hook (assets/js/hooks/menu.js) finds a menu's trigger by.
    defp menu_trigger do
      js = File.read!(Path.expand("../../../assets/js/hooks/menu.js", __DIR__))
      [_, selector] = Regex.run(~r/export const TRIGGER = "([^"]+)"/, js)
      selector
    end

    # Each Menu of the markup, and the id of the first element in it the hook takes for
    # its trigger.
    defp menu_triggers(html) do
      doc = LazyHTML.from_fragment(html)

      for menu <- LazyHTML.query(doc, "[phx-hook=Menu]") do
        trigger = menu |> LazyHTML.query(menu_trigger()) |> Enum.take(1)

        {menu |> LazyHTML.attribute("id") |> hd(),
         Enum.flat_map(trigger, &LazyHTML.attribute(&1, "id"))}
      end
    end

    test "is a menu button, or a disclosure's button: a filter chip, Filter, Sort, a row's ⋯" do
      assert menu_trigger() == "[aria-haspopup], [aria-controls][aria-expanded]"

      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ApiaryWeb.RunComponents.filter
          id="filter-action"
          name="action"
          label="Action"
          value="workspace.rename"
          options={[{"Workspace renamed", "workspace.rename", nil}]}
          remove="/acme/audit-log"
        />
        <CoreComponents.filter_menu id="runs-filter" count={1}>
          <:section key="state" label="State" icon="hero-check-circle" value="Failed">
            <p>options</p>
          </:section>
        </CoreComponents.filter_menu>
        <CoreComponents.filter_menu id="network-filter">
          <CoreComponents.menu_item checked={false}>Denied</CoreComponents.menu_item>
        </CoreComponents.filter_menu>
        <CoreComponents.sort_menu id="sort" current="Newest first">
          <CoreComponents.menu_item checked={true}>Newest first</CoreComponents.menu_item>
        </CoreComponents.sort_menu>
        <CoreComponents.row_menu id="row-1-menu" label="Actions for build-01">
          <CoreComponents.menu_item>Rename</CoreComponents.menu_item>
        </CoreComponents.row_menu>
        """)

      assert menu_triggers(html) == [
               {"filter-action", ["filter-action-button"]},
               {"runs-filter", ["runs-filter-button"]},
               {"network-filter", ["network-filter-button"]},
               {"sort", ["sort-button"]},
               {"row-1-menu", ["row-1-menu-button"]}
             ]

      # The chip and the sections' Filter are disclosures: no aria-haspopup, which
      # the hook found them by alone before.
      doc = LazyHTML.from_fragment(html)

      for id <- ~w(filter-action-button runs-filter-button) do
        assert [_] =
                 doc
                 |> LazyHTML.query("##{id}[aria-controls][aria-expanded=false]")
                 |> Enum.to_list()

        assert [] = doc |> LazyHTML.query("##{id}[aria-haspopup]") |> Enum.to_list()
      end
    end
  end

  describe "an inline confirmation" do
    test "is named by its question and described by what happens" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.inline_confirm
          id="secret-1-confirm"
          question="Delete FORGE_TOKEN?"
          cancel="/acme/shop/settings/secrets"
        >
          The secret and its value are deleted. This cannot be undone.
          <:action>
            <CoreComponents.button variant="danger" size="xs">Yes, delete</CoreComponents.button>
          </:action>
        </CoreComponents.inline_confirm>
        """)

      doc = LazyHTML.from_fragment(html)
      [group] = doc |> LazyHTML.query("#secret-1-confirm[role=group]") |> Enum.to_list()
      assert LazyHTML.attribute(group, "aria-labelledby") == ["secret-1-confirm-question"]
      assert LazyHTML.attribute(group, "aria-describedby") == ["secret-1-confirm-sub"]

      assert doc |> LazyHTML.query("#secret-1-confirm-sub") |> LazyHTML.text() =~
               "This cannot be undone."
    end
  end

  describe "an empty state" do
    test "as the page's h1 it takes the focus after a navigation; as an h2 it does not" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.empty_state title="No nodes yet" heading="h1">
          A node runs runs.
        </CoreComponents.empty_state>
        <CoreComponents.empty_state title="No runs match">Clear the filters.</CoreComponents.empty_state>
        """)

      doc = LazyHTML.from_fragment(html)
      assert doc |> LazyHTML.query("h1[tabindex='-1']") |> LazyHTML.text() =~ "No nodes yet"
      assert [_] = doc |> LazyHTML.query("h2:not([tabindex])") |> Enum.to_list()
    end
  end

  describe "an input described by the page too" do
    test "keeps its own description, its hint or its errors, and adds the page's" do
      form = Phoenix.Component.to_form(%{"name" => ""}, as: :variable)

      html =
        render_component(&CoreComponents.input/1,
          field: form[:name],
          label: "Name",
          hint: "Letters, digits and underscores.",
          "aria-describedby": "variable_name-rules"
        )

      doc = LazyHTML.from_fragment(html)
      [input] = doc |> LazyHTML.query("input#variable_name") |> Enum.to_list()

      assert LazyHTML.attribute(input, "aria-describedby") == [
               "variable_name-hint variable_name-rules"
             ]

      # Once, not twice: the page's is merged, not written again after the input's own.
      refute html =~ ~r/aria-describedby="[^"]*"[^>]*aria-describedby=/

      form =
        Phoenix.Component.to_form(%{"name" => ""},
          as: :variable,
          errors: [name: {"can't be blank", []}],
          action: :insert
        )

      html =
        render_component(&CoreComponents.input/1,
          field: form[:name],
          label: "Name",
          "aria-describedby": "variable_name-rules"
        )

      [input] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("input#variable_name")
        |> Enum.to_list()

      assert LazyHTML.attribute(input, "aria-describedby") == [
               "variable_name-error variable_name-rules"
             ]

      # A select, a text area and a field with a prefix merge it the same way.
      for type <- ~w(select textarea) do
        html =
          render_component(&CoreComponents.input/1,
            name: "kind",
            id: "kind",
            type: type,
            value: "a",
            options: [{"A", "a"}],
            "aria-describedby": "kind-rules"
          )

        assert html =~ ~s(aria-describedby="kind-rules"), type
      end

      html =
        render_component(&CoreComponents.input/1,
          name: "slug",
          id: "slug",
          value: "shop",
          prefix: "qory.example/acme/",
          "aria-describedby": "slug-rules"
        )

      assert html =~ ~s(aria-describedby="slug-prefix slug-rules")
    end
  end
end
