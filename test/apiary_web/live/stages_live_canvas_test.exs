defmodule ApiaryWeb.StagesLive.CanvasTest do
  @moduledoc """
  The Stages canvas component (`ApiaryWeb.StagesLive.Canvas`) on its own: a process
  document in the editable mode and in the view-only mode, from plain data alone.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Apiary.Processes
  alias ApiaryWeb.StagesLive.Canvas

  defp document, do: Processes.default_document("software")

  defp canvas(attrs) do
    html = render_component(&Canvas.canvas/1, Map.merge(%{id: "type-canvas"}, attrs))

    [element] =
      html |> LazyHTML.from_fragment() |> LazyHTML.query("#type-canvas") |> Enum.to_list()

    element
  end

  defp data(element, name),
    do: element |> LazyHTML.attribute(name) |> List.first() |> Jason.decode!()

  test "view only: the stages and their lines, with nothing to edit" do
    element = canvas(%{document: document(), mode: :view})
    view = data(element, "data-view")

    refute view["editable"]
    assert view["selected"] == nil
    assert Enum.map(view["stages"], & &1["name"]) == ~w(Explore Shape Build Verify Release)

    assert %{
             "sequence" => [%{"workflow" => "explore-a-ticket"}],
             "gate" => "Gate: a member approves",
             "alerts" => []
           } = hd(view["stages"])

    assert LazyHTML.attribute(element, "phx-update") == ["ignore"]
    # app.css sizes the box: as tall as its column, or the rest of the window in a
    # `.q-canvas-fill` box.
    assert LazyHTML.attribute(element, "class") == ["q-canvas"]

    assert LazyHTML.text(element) =~
             "The canvas did not load. Reload the page to see the stages."

    assert data(element, "data-words")["label"] == "Stages, in order"
  end

  test "editable: the same stages, with the selected stage and each card's alerts" do
    [first | _] = document()["stages"]

    element =
      canvas(%{
        document: document(),
        mode: :edit,
        selected: first["id"],
        alerts: %{first["id"] => ["A line on Explore."]}
      })

    view = data(element, "data-view")

    assert view["editable"]
    assert view["selected"] == first["id"]
    assert view["first"] == "Add a stage before Explore"
    assert hd(view["stages"])["alerts"] == ["A line on Explore."]
    assert hd(view["stages"])["add"] == "Add a stage after Explore"

    assert LazyHTML.text(element) =~
             "The canvas did not load. Reload the page to edit the stages."
  end

  test "marks: each workflow listed has a check, any other a cross, each with its words; none without the list" do
    [explore | _] = document()["stages"]

    doc =
      ApiaryWeb.StagesLive.Draft.update_stage(
        document(),
        explore["id"],
        &ApiaryWeb.StagesLive.Draft.add_entry(&1, "constructor", nil)
      )

    view = data(canvas(%{document: doc, mode: :view, marks: ["explore-a-ticket"]}), "data-view")

    assert hd(view["stages"])["marks"] == %{
             "explore-a-ticket" => %{
               "listed" => true,
               "label" => "explore-a-ticket: a stage can run it"
             },
             "constructor" => %{"listed" => false, "label" => "constructor: not in the harness"}
           }

    # A stage with no workflow has no marks; nor has any stage without the list.
    assert Enum.at(view["stages"], 1)["marks"] == %{}

    assert Enum.all?(
             data(canvas(%{document: doc, mode: :view}), "data-view")["stages"],
             &(&1["marks"] == %{})
           )
  end

  test "a stage's description reaches its card as plain text; a stage without one has none" do
    text = "Plan the <b>Checkout</b> change.\n**Not Markdown.**"

    doc =
      Map.update!(document(), "stages", fn [explore, shape | rest] ->
        [
          explore,
          Map.put(shape, "description", text),
          Map.put(hd(rest), "description", " ") | tl(rest)
        ]
      end)

    element = canvas(%{document: doc, mode: :view})
    [explore, shape, build | _] = data(element, "data-view")["stages"]

    assert shape["description"] == text
    assert shape["label"] == "Shape. #{text}. No workflow. Gate: a member approves"
    # A blank description is none.
    assert explore["description"] == nil
    assert build["description"] == nil
    assert build["label"] == "Build. No workflow. Gate: a member approves"
    # The text is in the JSON of an attribute, never markup on the page.
    assert LazyHTML.query(element, "b") |> Enum.to_list() == []
  end

  test "a card's label ends a description with one full stop, and adds none after ? or !" do
    label = fn text ->
      doc =
        Map.update!(document(), "stages", fn [explore, shape | rest] ->
          [explore, Map.put(shape, "description", text) | rest]
        end)

      Enum.at(Canvas.view(doc, :view).stages, 1).label
    end

    assert label.("Plan the change.") ==
             "Shape. Plan the change. No workflow. Gate: a member approves"

    assert label.("Plan the change") ==
             "Shape. Plan the change. No workflow. Gate: a member approves"

    assert label.("Wait for the vendor...") ==
             "Shape. Wait for the vendor... No workflow. Gate: a member approves"

    assert label.("Ready?") == "Shape. Ready? No workflow. Gate: a member approves"
    assert label.("Ship it!") == "Shape. Ship it! No workflow. Gate: a member approves"
  end

  test "a document with no stages draws an empty line" do
    assert %{editable: false, first: nil, stages: []} =
             Canvas.view(%{"stages" => []}, :view)
  end

  test "the filling box puts the side beside the canvas from 1328 px on Stages and Workspace types, from 1024 px elsewhere and in Focus and Full screen" do
    css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))

    # The rules of the media block that starts with the filling box's page, as
    # {selector, declarations}, with comments and line breaks removed.
    rules = fn width ->
      [_, rest] =
        Regex.split(
          ~r/@media \(min-width: #{width}px\) \{(?=\s*\.q-page:has\(\.q-canvas-fill)/,
          css,
          parts: 2
        )

      [block, _] = String.split(rest, "\n  }\n", parts: 2)

      ~r/([^{}]+)\{([^{}]*)\}/
      |> Regex.scan(String.replace(block, ~r{/\*.*?\*/}s, ""))
      |> Enum.map(fn [_, selector, body] ->
        {selector |> String.replace(~r/\s+/, " ") |> String.trim(),
         body |> String.split(";") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}
      end)
    end

    # A selector of every box but `#stages-editor` and `#type-editor`.
    others = ~r/:not\((:where\()?#stages-editor, #type-editor\)/
    wide = rules.(1328)

    {focus, rest} =
      Enum.split_with(rules.(1024), fn {selector, _} ->
        selector =~ ~r/q-canvas-focus|:fullscreen/
      end)

    # Workspace settings › Stages (`#stages-editor`) and Instance settings › Workspace types
    # (`#type-editor`): from 1328 px, the sidebar (240), the settings menu (216), a 360 px
    # card with 16 px at each side (392) and the side (480).
    assert Enum.all?(wide, fn {selector, _} ->
             selector =~ ":where(#stages-editor, #type-editor)" and not (selector =~ others)
           end)

    assert "grid-template-columns: minmax(0, 1fr) auto" in Map.fetch!(
             Map.new(wide),
             ".q-canvas-fill:where(#stages-editor, #type-editor)"
           )

    # Every other box, a workspace type's page (`#workspace-type`): from 1024 px, with the
    # same declarations, rule by rule.
    assert Enum.all?(rest, fn {selector, _} -> selector =~ others end)

    assert Enum.map(rest, &elem(&1, 1)) == Enum.map(wide, &elem(&1, 1))

    # In Focus and Full screen the sidebar and the settings menu are hidden: from 1024 px
    # on Stages and Workspace types too, with no `min-height`.
    side = Map.fetch!(Map.new(wide), ":where(#stages-editor, #type-editor) > .q-canvas-side")

    assert focus == [
             {"html.q-canvas-focus .q-canvas-fill:where(#stages-editor, #type-editor), " <>
                ".q-canvas-fill:where(#stages-editor, #type-editor):fullscreen",
              ["grid-template-columns: minmax(0, 1fr) auto"]},
             {"html.q-canvas-focus .q-canvas-fill:where(#stages-editor, #type-editor) > .q-canvas, " <>
                ".q-canvas-fill:where(#stages-editor, #type-editor):fullscreen > .q-canvas",
              ["height: auto"]},
             {"html.q-canvas-focus :where(#stages-editor, #type-editor) > .q-canvas-side, " <>
                ":where(#stages-editor, #type-editor):fullscreen > .q-canvas-side", side}
           ]
  end
end
