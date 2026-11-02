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
             "sequence" => [%{"loop" => "at most 3 rounds", "workflows" => ["explore-a-ticket"]}],
             "gate" => "Gate: a member approves",
             "alerts" => []
           } = hd(view["stages"])

    assert LazyHTML.attribute(element, "phx-update") == ["ignore"]

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
               "label" => "explore-a-ticket: in the harness"
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

  test "a document with no stages draws an empty line" do
    assert %{editable: false, first: nil, stages: []} =
             Canvas.view(%{"stages" => []}, :view)
  end
end
