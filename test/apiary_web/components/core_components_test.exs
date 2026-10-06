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
              cancel="/acme/shop/settings/keys"
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
end
