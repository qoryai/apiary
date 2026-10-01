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
          <:section key="host" label="Host" icon="hero-globe-alt-micro">
            <input id="f-host-search" type="search" aria-label="Find a host" />
          </:section>
        </CoreComponents.filter_menu>
        """)

      doc = LazyHTML.from_fragment(html)
      assert [_] = doc |> LazyHTML.query("#f-section-host > #f-body-host > input") |> Enum.to_list()
      [click] = doc |> LazyHTML.query("#f-open-host") |> LazyHTML.attribute("phx-click")
      assert click =~ ~s("to":"#f-body-host")
      [show, hide, focus] = click |> Jason.decode!() |> Enum.map(&hd/1)
      assert {show, hide, focus} == {"show", "hide", "focus_first"}
    end
  end
end
