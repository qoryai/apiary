defmodule ApiaryWeb.IntegrationComponentsTest do
  @moduledoc """
  The collections table of an integration's page
  (`ApiaryWeb.IntegrationComponents.collections_table/1`): a collection's name is the
  title its adapter sent, shown as a page shows an external system's text.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ApiaryWeb.IntegrationComponents

  test "a collection's name: isolated in <bdi>, and cleaned in its title and its controls' names" do
    # A bidirectional override, a zero-width space and a control character, and what is
    # left of them (`Apiary.ExternalText.line/1`).
    row = %{
      id: 1,
      public_id: "co_01",
      name: "\u202Eacme/shop\u200B\a",
      workspace: nil,
      backlog: %{on: true},
      open_tickets: 0,
      added_at: DateTime.utc_now()
    }

    shown = "acme/shop\uFFFD"

    doc =
      render_component(&IntegrationComponents.collections_table/1,
        id: "collections",
        label: "Repositories",
        rows: [row],
        column: "Repository",
        open: nil,
        backlog: "tickets",
        may_set_backlog: true,
        picks: true,
        selected: %{},
        every: "Select every repository",
        none: nil
      )
      |> LazyHTML.from_fragment()

    name = LazyHTML.query(doc, "#collection-co_01 .q-td-title > span:first-child")
    assert name |> LazyHTML.query("bdi") |> LazyHTML.text() == shown
    assert LazyHTML.attribute(name, "title") == [shown]

    assert doc |> LazyHTML.query("#collection-co_01-pick") |> LazyHTML.attribute("aria-label") ==
             ["Select " <> shown]

    switch = "Take the tickets of #{shown} into the Backlog"

    for id <- ["#collection-co_01-backlog", "#collection-co_01-backlog-line"] do
      assert doc |> LazyHTML.query(id) |> LazyHTML.attribute("aria-label") == [switch]
      assert doc |> LazyHTML.query(id) |> LazyHTML.attribute("title") == [switch]
    end
  end
end
