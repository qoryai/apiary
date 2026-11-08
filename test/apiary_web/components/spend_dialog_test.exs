defmodule ApiaryWeb.SpendDialogTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias ApiaryWeb.SpendDialog

  # The `aria-describedby` of the `<dialog>` in `html`, or nil where it has none.
  defp described_by(html) do
    case html
         |> LazyHTML.from_fragment()
         |> LazyHTML.query("dialog")
         |> LazyHTML.attribute("aria-describedby") do
      [id] -> id
      [] -> nil
    end
  end

  test "the dialog's aria-describedby points at its line on what starts" do
    spend =
      SpendDialog.ask("explore_again", %{},
        title: "Run Explore again?",
        action: "Run Explore again",
        line: "Starts the next run of Explore on a machine. The run uses model tokens."
      )

    assigns = %{spend: spend}
    html = rendered_to_string(~H"<SpendDialog.dialog spend={@spend} />")

    assert described_by(html) == "spend-dialog-line"
    assert html =~ ~r/<p[^>]* id="spend-dialog-line"/
  end

  test "a frame with no line has no aria-describedby" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <SpendDialog.frame id="take-in" title="Take in?" action="Take in">
        <p>Any body.</p>
      </SpendDialog.frame>
      """)

    assert described_by(html) == nil
  end

  # The first column of the wide dialog in `html`: its `role` and its `aria-label`.
  defp body_column(html) do
    column = html |> LazyHTML.from_fragment() |> LazyHTML.query(".q-spend-col:not(.q-spend-side)")
    {LazyHTML.attribute(column, "role"), LazyHTML.attribute(column, "aria-label")}
  end

  test "the wide dialog's first column is a region named by body_label" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <SpendDialog.frame id="take-in" title="Take in?" action="Take in" body_label="ticket">
        <p>The ticket.</p>
        <:side>
          <p>The comment.</p>
        </:side>
      </SpendDialog.frame>
      """)

    assert body_column(html) == {["region"], ["ticket"]}
  end

  test "without body_label, the wide dialog's first column is no region" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <SpendDialog.frame id="take-in" title="Take in?" action="Take in">
        <p>The ticket.</p>
        <:side>
          <p>The comment.</p>
        </:side>
      </SpendDialog.frame>
      """)

    assert body_column(html) == {[], []}
  end

  test "the first focus is on Cancel, or on the element given as focus" do
    assigns = %{}

    first = fn html ->
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("dialog")
      |> LazyHTML.attribute("data-focus")
    end

    html =
      rendered_to_string(~H"""
      <SpendDialog.frame id="take-in" title="Take in?" action="Take in">
        <p>Any body.</p>
      </SpendDialog.frame>
      """)

    assert first.(html) == ["take-in-cancel"]
    assert html =~ ~r/<button[^>]* id="take-in-cancel"/

    html =
      rendered_to_string(~H"""
      <SpendDialog.frame id="take-in" title="Take in?" action="Take in" focus="take-in-comment">
        <textarea id="take-in-comment" name="comment"></textarea>
      </SpendDialog.frame>
      """)

    assert first.(html) == ["take-in-comment"]
  end

  # The `style` of the `<dialog>` in `html`.
  defp style(html) do
    [style] =
      html |> LazyHTML.from_fragment() |> LazyHTML.query("dialog") |> LazyHTML.attribute("style")

    style
  end

  test "the box is 170 px from the top, or at the distance given" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <SpendDialog.frame id="spend-dialog" title="Rebuild?" action="Rebuild">
        <p>Any body.</p>
      </SpendDialog.frame>
      """)

    assert style(html) == "padding-top: 170px"

    html =
      rendered_to_string(~H"""
      <SpendDialog.frame id="spend-dialog" title="Run the test?" action="Run the test" top={290}>
        <p>Any body.</p>
      </SpendDialog.frame>
      """)

    assert style(html) == "padding-top: 290px"
  end

  test "a top that is not an integer raises, in ask/3 and in frame/1" do
    assert_raise ArgumentError, ~r/Pass :top to ask\/3 as an integer of px/, fn ->
      SpendDialog.ask("run_test", %{},
        title: "Run the test?",
        action: "Run the test",
        line: "Starts a run.",
        top: "290"
      )
    end

    assigns = %{top: "290px; color: red"}

    assert_raise ArgumentError, fn ->
      rendered_to_string(~H"""
      <SpendDialog.frame id="spend-dialog" title="Run the test?" action="Run the test" top={@top}>
        <p>Any body.</p>
      </SpendDialog.frame>
      """)
    end
  end
end
