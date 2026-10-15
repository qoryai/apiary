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
end
