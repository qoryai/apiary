defmodule ApiaryWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias ApiaryWeb.CoreComponents

  @endpoint ApiaryWeb.Endpoint

  defmodule RowMenuLive do
    use Phoenix.LiveView

    alias ApiaryWeb.CoreComponents

    def mount(_params, _session, socket), do: {:ok, assign(socket, show: false, name: "Rename")}

    def handle_event("set", params, socket) do
      {:noreply,
       assign(
         socket,
         Enum.map(params, fn {key, value} -> {String.to_existing_atom(key), value} end)
       )}
    end

    def render(assigns) do
      ~H"""
      <CoreComponents.row_menu id="row" label="Actions for build-01">
        <CoreComponents.menu_item :if={@show} phx-click="noop">{@name}</CoreComponents.menu_item>
      </CoreComponents.row_menu>
      """
    end
  end

  describe "an avatar without an address" do
    test "is decorative, its markup as before the avatar could stand for a person" do
      assigns = %{}

      assert rendered_to_string(~H|<CoreComponents.avatar name="dana@example.com" />|) ==
               "<span phx-r class=\"avatar avatar-placeholder flex-none \" aria-hidden=\"true\">\n  <div class=\"size-6 text-[11px] rounded-full bg-base-300 text-muted ring-1 ring-inset ring-line\">\n    \n      d\n    \n  </div>\n</span>"

      assert rendered_to_string(
               ~H|<CoreComponents.avatar name="dana@example.com" kind="self" size="md" />|
             ) ==
               "<span phx-r class=\"avatar avatar-placeholder flex-none \" aria-hidden=\"true\">\n  <div class=\"size-7 text-xs rounded-full bg-primary-soft text-primary-soft-content\">\n    \n      d\n    \n  </div>\n</span>"

      assert rendered_to_string(
               ~H|<CoreComponents.avatar name="Acme" kind="organisation" size="xs" />|
             ) ==
               "<span phx-r class=\"avatar avatar-placeholder flex-none \" aria-hidden=\"true\">\n  <div class=\"size-[18px] text-[10.5px] rounded-selector bg-neutral text-neutral-content\">\n    \n      A\n    \n  </div>\n</span>"

      assert rendered_to_string(~H|<CoreComponents.avatar kind="pending" />|) ==
               "<span phx-r class=\"avatar avatar-placeholder flex-none \" aria-hidden=\"true\">\n  <div class=\"size-6 text-[11px] rounded-full border border-dashed border-line-field bg-transparent text-faint\">\n    \n      <span phx-r class=\"hero-envelope size-3.5\"></span>\n    \n  </div>\n</span>"

      assert rendered_to_string(~H|<CoreComponents.avatar />|) ==
               "<span phx-r class=\"avatar avatar-placeholder flex-none \" aria-hidden=\"true\">\n  <div class=\"size-6 text-[11px] rounded-full bg-base-300 text-muted ring-1 ring-inset ring-line\">\n    \n      ?\n    \n  </div>\n</span>"
    end
  end

  describe "an avatar for a person's address" do
    defp avatar(attrs) do
      LazyHTML.from_fragment(render_component(&CoreComponents.avatar/1, attrs))
    end

    test "is the first letter in an abbr of the address, a tab stop, read as the address" do
      doc = avatar(email: "priya@example.com", size: "xs")
      abbr = LazyHTML.query(doc, "abbr.term.tooltip")

      assert LazyHTML.attribute(abbr, "tabindex") == ["0"]
      assert LazyHTML.attribute(abbr, "data-tip") == ["priya@example.com"]
      assert LazyHTML.attribute(abbr, "aria-label") == ["priya@example.com"]
      assert LazyHTML.text(LazyHTML.query(abbr, "span[aria-hidden=true]")) == "P"
      assert LazyHTML.text(LazyHTML.query(abbr, "span.sr-only")) == "priya@example.com"

      assert LazyHTML.query(abbr, "span[aria-hidden=true].size-\\[18px\\].bg-base-300")
             |> Enum.count() == 1
    end

    test "inside a link or a row that opens, is no tab stop" do
      abbr = LazyHTML.query(avatar(email: "priya@example.com", in_link: true), "abbr")

      assert LazyHTML.attribute(abbr, "tabindex") == []
      assert LazyHTML.attribute(abbr, "data-tip") == ["priya@example.com"]
    end

    test "shows a digit or a symbol as it is, and upper-cases a letter by Unicode rules" do
      letter = &(&1 |> avatar() |> LazyHTML.query("span[aria-hidden=true]") |> LazyHTML.text())

      assert letter.(email: "7days@example.com") == "7"
      assert letter.(email: "_ops@example.com") == "_"
      assert letter.(email: "élodie@example.com") == "É"
      assert letter.(email: "ørjan@example.com") == "Ø"
    end

    test "for the reader, has the account menu's colour and says you" do
      for attrs <- [
            [email: "dana@example.com", reader: "dana@example.com"],
            [email: "dana@example.com", kind: "self"]
          ] do
        abbr = LazyHTML.query(avatar(attrs), "abbr")

        assert LazyHTML.attribute(abbr, "data-tip") == ["dana@example.com (you)"]
        assert LazyHTML.attribute(abbr, "aria-label") == ["dana@example.com (you)"]
        assert LazyHTML.text(LazyHTML.query(abbr, "span.sr-only")) == "dana@example.com (you)"
        assert Enum.count(LazyHTML.query(abbr, "span.bg-primary-soft")) == 1
      end

      other = avatar(email: "priya@example.com", reader: "dana@example.com")

      assert LazyHTML.attribute(LazyHTML.query(other, "abbr"), "data-tip") == [
               "priya@example.com"
             ]

      assert Enum.count(LazyHTML.query(other, "span.bg-base-300")) == 1
    end

    test "for two people of one letter, draws the same neutral circle; the hint differs" do
      [sam, sofia] = Enum.map(["sam@example.com", "sofia@example.com"], &avatar(email: &1))
      circle = &(&1 |> LazyHTML.query("span[aria-hidden=true]") |> LazyHTML.attribute("class"))

      assert circle.(sam) == circle.(sofia)
      assert hd(circle.(sam)) =~ "bg-base-300"
      refute hd(circle.(sam)) =~ "primary"

      assert LazyHTML.attribute(LazyHTML.query(sam, "abbr"), "data-tip") !=
               LazyHTML.attribute(LazyHTML.query(sofia, "abbr"), "data-tip")
    end

    test "for a deleted account is the words Former member, with no letter and no hint" do
      html = render_component(&CoreComponents.avatar/1, email: ApiaryWeb.People.former_member())

      assert String.trim(html) == "Former member"
    end

    test "for no person is nothing" do
      assert String.trim(render_component(&CoreComponents.avatar/1, email: nil)) == ""
    end
  end

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

  describe "a radio group" do
    test "a choice with a line is a card, its radio described by the line" do
      form = Phoenix.Component.to_form(%{"domain" => "b"}, as: :workspace)

      html =
        render_component(&CoreComponents.input/1,
          field: form[:domain],
          type: "radio",
          label: "Type",
          options: [{"A", "a", "For a."}, {"B", "b", "For b."}]
        )

      doc = LazyHTML.from_fragment(html)

      assert ["workspace_domain-0", "workspace_domain-1"] =
               doc
               |> LazyHTML.query("label.q-choice > input[type=radio]")
               |> LazyHTML.attribute("id")

      assert doc |> LazyHTML.query("#workspace_domain-1") |> LazyHTML.attribute("checked") != []

      assert doc
             |> LazyHTML.query("#workspace_domain-0")
             |> LazyHTML.attribute("aria-describedby") ==
               ["workspace_domain-0-line"]

      assert doc |> LazyHTML.query("#workspace_domain-1-line") |> LazyHTML.text() |> String.trim() ==
               "For b."

      assert doc |> LazyHTML.query("label.q-choice .q-choice-h") |> Enum.map(&LazyHTML.text/1) ==
               ["A", "B"]
    end

    test "a choice without a line stays a plain label" do
      form = Phoenix.Component.to_form(%{}, as: :workspace)

      html =
        render_component(&CoreComponents.input/1,
          field: form[:kind],
          type: "radio",
          label: "Create",
          options: [{"An organisation", "organisation"}]
        )

      refute html =~ "q-choice"
      refute html =~ "aria-describedby"
      assert html =~ "An organisation"
    end
  end

  describe "an input with more than one error" do
    test "shows each, with a separate id, and is described by all of them" do
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

  describe "a row's menu" do
    test "with no slot shows no trigger and no list" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.row_menu id="row" label="Actions for build-01" />
        """)

      assert String.trim(html) == ""
    end

    test "whose items are each left out shows no trigger and no list" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.row_menu id="row" label="Actions for build-01">
          <CoreComponents.menu_item :if={false} patch="/keys/1/rotate">Rotate</CoreComponents.menu_item>
          <CoreComponents.menu_divider :if={false} />
          <CoreComponents.menu_item :if={false} phx-click="copy">Copy</CoreComponents.menu_item>
        </CoreComponents.row_menu>
        """)

      assert String.trim(html) == ""
    end

    test "with an item shows its trigger and the item" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.row_menu id="row" label="Actions for build-01">
          <CoreComponents.menu_item :if={false} phx-click="copy">Copy</CoreComponents.menu_item>
          <CoreComponents.menu_item patch="/keys/1/rotate">Rotate</CoreComponents.menu_item>
        </CoreComponents.row_menu>
        """)

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#row > button#row-button") |> LazyHTML.attribute("aria-label") ==
               ["Actions for build-01"]

      items = LazyHTML.query(doc, "#row > ul[role=menu] [role=menuitem]")
      assert items |> Enum.map(&LazyHTML.text/1) |> Enum.map(&String.trim/1) == ["Rotate"]
    end

    test "gains and loses its trigger as its items come and go in a live view" do
      {:ok, view, html} =
        live_isolated(Phoenix.ConnTest.build_conn(), __MODULE__.RowMenuLive)

      refute html =~ "row-button"
      refute has_element?(view, "#row")

      render_click(view, "set", %{"show" => true})
      assert has_element?(view, "#row > button#row-button")
      assert has_element?(view, "#row [role=menuitem]", "Rename")

      render_click(view, "set", %{"name" => "Rotate"})
      assert has_element?(view, "#row [role=menuitem]", "Rotate")
      refute has_element?(view, "#row [role=menuitem]", "Rename")

      render_click(view, "set", %{"show" => false})
      refute has_element?(view, "#row")
      refute has_element?(view, "#row-button")
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

  describe "a Filter menu's label" do
    test "is Filter unless given, on the button and as the menu's name, in both kinds" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.filter_menu id="runs-filter">
          <:section key="state" label="State" icon="hero-check-circle">
            <p>options</p>
          </:section>
        </CoreComponents.filter_menu>
        <CoreComponents.filter_menu id="network-filter">
          <CoreComponents.menu_item checked={false}>Denied</CoreComponents.menu_item>
        </CoreComponents.filter_menu>
        """)

      doc = LazyHTML.from_fragment(html)

      for id <- ~w(runs-filter network-filter) do
        assert doc |> LazyHTML.query("##{id}-button") |> LazyHTML.text() |> String.trim() ==
                 "Filter"
      end

      assert LazyHTML.attribute(LazyHTML.query(doc, "#runs-filter-panel"), "aria-label") ==
               ["Filter"]

      assert LazyHTML.attribute(LazyHTML.query(doc, "#network-filter [role=menu]"), "aria-label") ==
               ["Filter"]
    end

    test "is what the caller gives, on the button and as the menu's name, in both kinds" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.filter_menu id="runs-filter" label="Workspace" count={1}>
          <:section key="state" label="State" icon="hero-check-circle">
            <p>options</p>
          </:section>
        </CoreComponents.filter_menu>
        <CoreComponents.filter_menu id="network-filter" label="Workspace">
          <CoreComponents.menu_item checked={false}>Denied</CoreComponents.menu_item>
        </CoreComponents.filter_menu>
        """)

      doc = LazyHTML.from_fragment(html)

      for id <- ~w(runs-filter network-filter) do
        text = doc |> LazyHTML.query("##{id}-button") |> LazyHTML.text()
        assert text =~ "Workspace"
        refute text =~ "Filter"
      end

      assert doc |> LazyHTML.query("#runs-filter-button .q-listmenu-n") |> LazyHTML.text() == "1"

      assert LazyHTML.attribute(LazyHTML.query(doc, "#runs-filter-panel"), "aria-label") ==
               ["Workspace"]

      assert LazyHTML.attribute(LazyHTML.query(doc, "#network-filter [role=menu]"), "aria-label") ==
               ["Workspace"]
    end
  end

  describe "a list's bar with the Assign to workspace button" do
    # Opt-in by a class on the bar: no other bar's search changes, and a phone keeps the
    # search on a separate line.
    test "narrows its search to 260px from 768px; the assign menu's search fills its item, up to 260px" do
      css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))

      assert css =~
               ~r/@media \(min-width: 768px\) \{\s*\.q-bar\.q-int-assignbar > \.q-find \{\s*width: min\(260px, 100%\);\s*\}\s*\}/

      assert css =~
               ~r/\n  \.q-int-assign li > form \{\s*grid-template-columns: minmax\(0, 1fr\);\s*\}/

      assert css =~
               ~r/\n  \.q-int-assign \.q-filter-search \{\s*width: 100%;\s*max-width: 260px;\s*\}/
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

    # A column's header cell is its label as text, beside a screen reader's header; a
    # header slot changes nothing for a table that gives none.
    test "heads its columns with their labels when no header slot is given" do
      assigns = %{rows: [%{id: 1, name: "build-01"}]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.table id="keys" label="Access keys" rows={@rows}>
          <:col :let={row} label="Name" kind="title">{row.name}</:col>
          <:col label="Runs" kind="num" from="sm" class="w-24">3</:col>
          <:col sr_label="Pinned"></:col>
          <:action>x</:action>
        </CoreComponents.table>
        """)

      [thead] = Regex.run(~r/<thead>.*<\/thead>/s, html)

      assert thead <> "\n" == ~S"""
             <thead>
                   <tr>
                     <th scope="col" class="">
                       Name
                     </th><th scope="col" class="q-num q-from-sm w-24">
                       Runs
                     </th><th scope="col" class="">
                       <span class="sr-only">Pinned</span>
                     </th>
                     <th scope="col" class="w-px">
                       <span class="sr-only">Actions</span>
                     </th>
                   </tr>
                 </thead>
             """
    end

    test "gives a column's header cell the header slot that names its key, in place of its label" do
      assigns = %{rows: [%{id: 1, name: "build-01"}, %{id: 2, name: "build-02"}]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.table id="keys" label="Access keys" rows={@rows}>
          <:header col="pick">
            <input id="keys-all" type="checkbox" aria-label="Select every key" />
          </:header>
          <:col :let={row} key="pick" label="Unused" class="q-int-cb">
            <input type="checkbox" aria-label={row.name} />
          </:col>
          <:col :let={row} key="name" label="Name" kind="title">{row.name}</:col>
        </CoreComponents.table>
        """)

      doc = LazyHTML.from_fragment(html)
      [pick, name] = doc |> LazyHTML.query("thead th") |> Enum.to_list()

      assert pick |> LazyHTML.query("input#keys-all[type=checkbox]") |> Enum.count() == 1
      assert LazyHTML.attribute(pick, "class") == ["q-int-cb"]
      refute LazyHTML.text(pick) =~ "Unused"

      # A column whose key no header slot names keeps its label.
      assert name |> LazyHTML.text() |> String.trim() == "Name"

      # The rows keep their cells: a checkbox each, then the name.
      assert doc |> LazyHTML.query("tbody input[type=checkbox]") |> Enum.count() == 2

      assert doc
             |> LazyHTML.query("tbody td.q-td-title")
             |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) == ["build-01", "build-02"]
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

    # The classes a cell's words take to fit the table's box: each scoped to a list table,
    # so it outranks a nowrap a word's class sets and reaches no other part of a page.
    test "a cell's words fit the box: q-cut, q-parts, q-stw-wrap and a titled q-side" do
      css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))

      rule = fn selector ->
        [body] =
          Regex.run(~r/\n  #{Regex.escape(selector)} \{([^}]*)\}/, css, capture: :all_but_first)

        body
      end

      # One line, cut with an ellipsis down to a floor.
      cut = rule.(".q-tbl .q-cut")

      for declaration <- [
            "display: -webkit-box;",
            "-webkit-line-clamp: 1;",
            "overflow: hidden;",
            "white-space: normal;",
            "word-break: break-all;",
            "min-width: 5ch;"
          ] do
        assert cut =~ declaration
      end

      # A line that breaks between its parts, never inside one.
      assert rule.(".q-tbl .q-parts") =~ "white-space: normal;"
      assert rule.(".q-tbl .q-parts > *") =~ "white-space: nowrap;"

      # The one state word that breaks onto further lines.
      assert rule.(".q-stw.q-stw-wrap") =~ "white-space: normal;"

      # A word beside a title that carries a title gives way, down to its floor; a cut
      # title gives way last.
      side = rule.(".q-tbl .q-nm > .q-side[title]")
      assert side =~ "flex: 0 1 auto;"
      assert side =~ "min-width: min(10ch, 14cqi);"
      assert rule.(".q-tbl .q-nm > .q-cut") =~ "flex: 0 1 auto;"
      assert rule.(".q-tbl .q-nm > .q-title.q-cut") =~ "min-width: min(24ch, 32cqi);"

      # An id beside a title hides below 600 px of table, a titled one too.
      assert css =~
               ~r/@container \(max-width: 599px\) \{\s*\.q-tbl \.q-side\.q-mono,\s*\.q-tbl \.q-nm > \.q-side\.q-mono\[title\] \{\s*display: none;/

      # None of them reaches outside a list table.
      for unscoped <- [".q-cut", ".q-parts", ".q-stw-wrap", ".q-nm > .q-side[title]"] do
        refute css =~ "\n  #{unscoped} {"
      end
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

  describe "a link out" do
    defp link_out(href, text \\ "pull request #412", title \\ nil) do
      assigns = %{href: href, text: text, title: title}

      rendered_to_string(~H"""
      <CoreComponents.external_link href={@href} title={@title}>{@text}</CoreComponents.external_link>
      """)
    end

    test "opens in a new tab, keeps the console from the page, and says so" do
      doc = LazyHTML.from_fragment(link_out("https://git.example.com/acme/shop/pull/412"))

      [a] = doc |> LazyHTML.query("a") |> Enum.to_list()
      assert LazyHTML.attribute(a, "href") == ["https://git.example.com/acme/shop/pull/412"]
      assert LazyHTML.attribute(a, "target") == ["_blank"]
      assert LazyHTML.attribute(a, "rel") == ["noopener noreferrer nofollow"]
      assert a |> LazyHTML.query(".hero-arrow-top-right-on-square-micro") |> Enum.count() == 1
      assert a |> LazyHTML.query(".sr-only") |> LazyHTML.text() == "(opens in a new tab)"
      assert LazyHTML.text(a) =~ "pull request #412"
    end

    test "is plain text for a url that may not be a link, or none" do
      for href <- [
            "javascript:alert(1)",
            "JAVASCRIPT:alert(1)",
            "data:text/html,<b>hi</b>",
            "ftp://files.example.com/a",
            "/acme/shop/pull/412",
            "//git.example.com/acme/shop",
            "https://",
            "https:git.example.com",
            "https://exa mple.com/",
            "https://user@git.example.com/acme/shop/pull/412",
            "https://user:secret@git.example.com/acme/shop/pull/412",
            "",
            nil
          ] do
        html = link_out(href)
        doc = LazyHTML.from_fragment(html)
        assert doc |> LazyHTML.query("a, [href], [target]") |> Enum.to_list() == [], inspect(href)
        assert doc |> LazyHTML.text() |> String.trim() == "pull request #412", inspect(href)
        refute html =~ "opens in a new tab"
        refute html =~ "hero-arrow-top-right-on-square-micro"
      end
    end

    test "escapes its words and its title, as a link and as text" do
      for href <- ["https://git.example.com/acme/shop/pull/412", nil] do
        html = link_out(href, "<b>#412</b>", ~s[Fix "it" <script>alert(1)</script>])

        refute html =~ "<b>"
        refute html =~ "<script>"
        assert html =~ "&lt;b&gt;#412&lt;/b&gt;"
        assert html =~ ~s[title="Fix &quot;it&quot; &lt;script&gt;alert(1)&lt;/script&gt;"]
      end
    end

    test "may be a link only when absolute http or https with a host" do
      assert CoreComponents.external_url?("https://tracker.example.com/browse/ENG-17")
      assert CoreComponents.external_url?("http://git.example.com")
      refute CoreComponents.external_url?("javascript:alert(1)")
      refute CoreComponents.external_url?("mailto:someone@example.com")
      refute CoreComponents.external_url?("https://user@git.example.com/x")
      refute CoreComponents.external_url?("https://user:pass@git.example.com/x")
      refute CoreComponents.external_url?("tracker.example.com/browse/ENG-17")
      refute CoreComponents.external_url?(nil)
      refute CoreComponents.external_url?(412)
    end
  end
end
