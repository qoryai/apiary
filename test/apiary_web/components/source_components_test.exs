defmodule ApiaryWeb.SourceComponentsTest do
  @moduledoc """
  A ticket's text (`ApiaryWeb.SourceComponents.body/1`): Markdown formatted, with both
  views in the page and the switch between them; any other format as written alone.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ApiaryWeb.SourceComponents

  defp html(body, format) do
    assigns = [id: "ticket", body: body, format: format]
    render_component(&SourceComponents.body/1, assigns)
  end

  defp render(body, format), do: body |> html(format) |> LazyHTML.from_fragment()

  test "markdown: the formatted view, the text as written hidden, and the switch" do
    body = "## Steps\n\n- [x] one\n- two <script>alert(1)</script>\n"
    doc = render(body, "markdown")

    formatted = LazyHTML.query(doc, "#ticket-formatted")
    assert formatted |> LazyHTML.query("h4") |> LazyHTML.text() == "Steps"
    assert formatted |> LazyHTML.query("li") |> Enum.count() == 2
    assert formatted |> LazyHTML.query("script") |> Enum.empty?()

    written = LazyHTML.query(doc, "#ticket-written")
    classes = "q-ticket-written q-ticket-source hidden"
    assert LazyHTML.attribute(written, "class") == [classes]
    assert LazyHTML.text(written) == body

    [to_written] = doc |> LazyHTML.query("button#ticket-show-written") |> Enum.to_list()
    assert LazyHTML.text(to_written) =~ "Show as written"
    assert LazyHTML.attribute(to_written, "type") == ["button"]
    assert LazyHTML.attribute(to_written, "aria-controls") == ["ticket-written"]
    [click] = LazyHTML.attribute(to_written, "phx-click")
    assert click =~ "toggle_class"
    assert click =~ "#ticket-formatted"
    assert click =~ "#ticket-written"
    assert click =~ "focus"
    refute click =~ "push"

    to_formatted = LazyHTML.query(doc, "button#ticket-show-formatted")
    assert Enum.count(to_formatted) == 1
    assert LazyHTML.text(to_formatted) =~ "Show formatted"
    assert LazyHTML.attribute(to_formatted, "aria-controls") == ["ticket-formatted"]
    assert [class] = LazyHTML.attribute(to_formatted, "class")
    assert "hidden" in String.split(class)
  end

  test "markdown: the as-written view escapes markup, keeps every space and line break" do
    body = "  <script>alert(1)</script>\n\n\tline two  \n"
    html = html(body, "markdown")

    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script"

    written = html |> LazyHTML.from_fragment() |> LazyHTML.query("#ticket-written")
    assert LazyHTML.text(written) == body
  end

  test "markdown: Show as written drops invisible characters, shows controls as U+FFFD" do
    # A bidirectional override, a zero-width space and a control character, with the
    # tab and the line breaks a text of several lines keeps
    # (`Apiary.ExternalText.lines/1`).
    body = "## Fix\u202E the\u200B login\a\n\n\tline two\n"
    written = body |> render("markdown") |> LazyHTML.query("#ticket-written")

    assert LazyHTML.text(written) == "## Fix the login\uFFFD\n\n\tline two\n"
  end

  test "text: the text as written alone, escaped, and no switch" do
    body = "# not a heading\n<script>alert(1)</script>\n  **kept**\n"
    html = html(body, "text")
    doc = LazyHTML.from_fragment(html)

    assert doc |> LazyHTML.query("#ticket-written") |> LazyHTML.text() == body
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script"
    assert doc |> LazyHTML.query("button, #ticket-formatted, h3") |> Enum.empty?()
  end

  test "a link in the formatted view always has an https href" do
    doc =
      render(
        "[a](https://example.com/a) [b](https://example.com:99999/) <https://1.2.3.4.5/>",
        "markdown"
      )

    links = LazyHTML.query(doc, "#ticket-formatted a")
    assert Enum.count(links) == 1
    assert LazyHTML.attribute(links, "href") == ["https://example.com/a"]
    assert doc |> LazyHTML.query("#ticket-formatted a:not([href])") |> Enum.empty?()
  end

  test "text that is not valid UTF-8 is shown with U+FFFD, so the page can send it" do
    for format <- ["markdown", "text"] do
      html = html(<<"a ", 0xFF, " b">>, format)

      assert String.valid?(html)

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#ticket-written")
             |> LazyHTML.text() ==
               "a \uFFFD b"
    end
  end

  test "an unknown format, none, and markdown too long to format are as written alone" do
    long = String.duplicate("a", Apiary.Sources.Body.max_length() + 1)

    for {body, format} <- [{"*x*", "html"}, {"*x*", nil}, {long, "markdown"}] do
      doc = render(body, format)

      assert doc |> LazyHTML.query("#ticket-written") |> LazyHTML.text() == body
      assert doc |> LazyHTML.query("button, #ticket-formatted") |> Enum.empty?()
    end
  end

  test "a format neither markdown nor text, none included, says it is shown as written" do
    for format <- ["html", "Markdown", nil] do
      doc = render("*x*", format)

      note = LazyHTML.query(doc, "#ticket-unformatted")
      assert note |> LazyHTML.text() |> String.trim() == "Shown as written."
      assert LazyHTML.attribute(note, "class") == ["q-ticket-note text-muted"]
    end

    long = String.duplicate("a", Apiary.Sources.Body.max_length() + 1)

    for {body, format} <- [{"*x*", "text"}, {"*x*", "markdown"}, {long, "markdown"}] do
      note = body |> render(format) |> LazyHTML.query("#ticket-unformatted")
      assert Enum.empty?(note)
    end
  end

  test "an empty or nil text says the ticket has no description, with no switch" do
    for body <- [nil, ""], format <- ["markdown", "text", nil] do
      doc = render(body, format)

      empty = LazyHTML.query(doc, "#ticket-empty")
      assert empty |> LazyHTML.text() |> String.trim() == "The ticket has no description."

      others = "button, #ticket-formatted, #ticket-written, #ticket-unformatted"
      assert doc |> LazyHTML.query(others) |> Enum.empty?()
    end
  end

  describe "the words for a source's items" do
    @bug %{one: "bug", other: "bugs"}

    test "its adapter's, or ticket and tickets where it names none" do
      assert SourceComponents.item(@bug) == "bug"
      assert SourceComponents.items(@bug) == "bugs"
      assert SourceComponents.item_label(@bug) == "Bug"

      assert SourceComponents.item(nil) == "ticket"
      assert SourceComponents.items(nil) == "tickets"
      assert SourceComponents.item_label(nil) == "Ticket"

      assert SourceComponents.item_label(%{one: "user story", other: "user stories"}) ==
               "User story"
    end

    test "many of them as a label: the adapter's, or Tickets where it names none" do
      assert SourceComponents.items_label(@bug) == "Bugs"
      assert SourceComponents.items_label(nil) == "Tickets"

      assert SourceComponents.items_label(%{one: "user story", other: "user stories"}) ==
               "User stories"

      # The first letter alone, whatever it is; the rest as the adapter wrote it.
      assert SourceComponents.items_label(%{one: "élément", other: "éléments ToDo"}) ==
               "Éléments ToDo"
    end

    test "a text says them: the empty one, and a table's name" do
      empty =
        render_component(&SourceComponents.body/1, id: "ticket", body: "", item_noun: @bug)

      assert empty =~ "The bug has no description."

      table =
        render_component(&SourceComponents.body/1,
          id: "ticket",
          body: "| a |\n|---|\n| 1 |",
          format: "markdown",
          item_noun: @bug
        )

      assert table =~ ~s(aria-label="Table in the bug")
      assert html("| a |\n|---|\n| 1 |", "markdown") =~ ~s(aria-label="Table in the ticket")
    end
  end

  describe "the words for a source's collections" do
    test "its adapter's, or collection where it names none, in every kind of workspace" do
      project = %{one: "project", other: "projects"}
      assert SourceComponents.collection(project) == "project"
      assert SourceComponents.collections(project) == "projects"
      assert SourceComponents.collection_label(project) == "Project"

      assert SourceComponents.collection(nil) == "collection"
      assert SourceComponents.collections(nil) == "collections"
      assert SourceComponents.collection_label(nil) == "Collection"

      assert SourceComponents.collection_label(%{one: "work board", other: "work boards"}) ==
               "Work board"
    end

    test "of several sources: each source's words once, joined with and or with or" do
      repository = %{one: "repository", other: "repositories"}
      queue = %{one: "queue", other: "queues"}
      project = %{one: "project", other: "projects"}

      assert SourceComponents.collection([repository, queue], :or) == "repository or queue"
      assert SourceComponents.collections([repository, queue], :and) == "repositories and queues"
      assert SourceComponents.collections([repository, queue], :or) == "repositories or queues"
      assert SourceComponents.collection_label([repository, queue]) == "Repository or queue"
      assert SourceComponents.collections_label([repository, queue]) == "Repositories and queues"

      assert SourceComponents.collections([repository, project, queue], :and) ==
               "repositories, projects and queues"

      # One that names none joins as collections; the same words once; none at all.
      assert SourceComponents.collections([repository, nil], :and) ==
               "repositories and collections"

      assert SourceComponents.collection([queue, queue], :or) == "queue"
      assert SourceComponents.collection([], :or) == "collection"
      assert SourceComponents.collection_label([]) == "Collection"
    end

    test "joined/2 lists one word as it is, and more with commas and the last word" do
      assert SourceComponents.joined(["dana"], :or) == "dana"
      assert SourceComponents.joined(["dana", "priya"], :or) == "dana or priya"
      assert SourceComponents.joined(["a", "b", "c"], :and) == "a, b and c"
    end
  end

  describe "the line after a collection's Backlog switch is pressed" do
    @project %{one: "project", other: "projects"}
    @story %{one: "story", other: "stories"}

    test "on or off, in the source's words, else collection and tickets" do
      assert SourceComponents.backlog_turned(1, true, "Shop board", @project, @story) ==
               "Now taking stories into the Backlog from project Shop board."

      assert SourceComponents.backlog_turned(1, false, "Shop board", @project, @story) ==
               "No longer taking stories into the Backlog from project Shop board."

      assert SourceComponents.backlog_turned(1, true, "acme/shop", nil, nil) ==
               "Now taking tickets into the Backlog from collection acme/shop."

      assert SourceComponents.backlog_turned(1, false, "acme/shop", nil, nil) ==
               "No longer taking tickets into the Backlog from collection acme/shop."
    end

    test "nil for a press that changed nothing, so the page claims no change" do
      assert SourceComponents.backlog_turned(0, true, "Shop board", @project, @story) == nil
      assert SourceComponents.backlog_turned(0, false, "acme/shop", nil, nil) == nil
    end
  end

  describe "the generated documentation" do
    # Every instance serves the module reference at /docs, which leaves this module out.
    test "leaves ApiaryWeb.SourceComponents out" do
      assert {:docs_v1, _anno, :elixir, _format, :hidden, _meta, docs} =
               Code.fetch_docs(SourceComponents)

      assert docs != []

      for {{kind, _name, _arity}, _anno, _signature, doc, _meta} <- docs,
          kind != :type,
          do: assert(doc == :hidden)
    end
  end
end
