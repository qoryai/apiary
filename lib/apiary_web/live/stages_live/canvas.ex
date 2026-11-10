defmodule ApiaryWeb.StagesLive.Canvas do
  # The Stages canvas as one component: a process document (`Apiary.Processes`) drawn as
  # its stages in a column, top to bottom, on dots, in one of two modes.
  #
  #   * `:edit`: the person drags a card, moves it with the arrow keys and adds a stage at
  #     a "+"; the canvas sends "reorder", "move" and "add_stage" to the page, which
  #     changes the document.
  #   * `:view`: the cards show their stages, workflows, loops and gates, with no "+", no
  #     drag and no move; the canvas sends no event that changes the document.
  #
  # In both modes a click or Enter on a card sends "select" with the stage's id, unless
  # `selectable` is false: then a card opens nothing and the canvas sends no event, for a
  # page with no "select" to take, such as New workspace's preview. The
  # canvas is drawn by `assets/js/canvas.js` (React Flow) through the colocated hook
  # below; it reads `data-view` once, then each "stages:view" event the page pushes with
  # `view/3`. Its inputs are plain data: the document, the mode, and optionally the
  # selected stage's id, the names of named approvers, each stage's alert lines and the
  # workflows a stage may run, which mark each workflow on a card with a check or a cross.
  #
  # In both modes the canvas has, at its top right, Zoom out, Zoom in, Focus (`f`: the box
  # takes the window until Escape) and Full screen. Put it first in a `.q-canvas-fill` box, with
  # the inspector or a side panel in a `.q-canvas-side` after it, and the box takes the
  # rest of the window with the side beside the canvas (app.css); Focus and Full screen
  # then show the canvas and the side. Elsewhere the canvas is as tall as its column.
  @moduledoc false

  use ApiaryWeb, :html

  alias ApiaryWeb.StagesLive.Words

  attr :id, :string, required: true
  attr :document, :map, required: true, doc: "the process document, with its stages"
  attr :mode, :atom, required: true, values: [:edit, :view]
  attr :selected, :string, default: nil, doc: "the id of the selected stage, nil for none"

  attr :people, :map,
    default: %{},
    doc: "a named approver's user id to the name a gate line shows"

  attr :alerts, :map, default: %{}, doc: "a stage's id to the alert lines its card shows"

  attr :marks, :list,
    default: nil,
    doc:
      "the workflows the harness lists, each marked with a check, any other with a cross; nil for no marks"

  attr :selectable, :boolean,
    default: true,
    doc: "whether a click or Enter on a card sends \"select\"; false sends no event"

  def canvas(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".StagesCanvas"
      phx-update="ignore"
      data-script={~p"/assets/js/canvas.js"}
      data-stylesheet={~p"/assets/js/canvas.css"}
      data-view={
        Jason.encode!(
          view(@document, @mode,
            selected: @selected,
            people: @people,
            alerts: @alerts,
            marks: @marks,
            selectable: @selectable
          )
        )
      }
      data-words={Jason.encode!(words())}
      class="q-canvas"
    >
      <%!-- Outside a `.q-canvas-fill` box the canvas sets its height to its column's. --%>
      <div data-canvas></div>
      <p data-canvas-failed hidden class="p-4 text-[13px]/5 text-muted">
        {failed_line(@mode)}
      </p>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".StagesCanvas">
      import {StagesCanvas} from "@/js/hooks/stages_canvas"
      export default StagesCanvas
    </script>
    """
  end

  defp failed_line(:edit),
    do: gettext("The canvas did not load. Reload the page to edit the stages.")

  defp failed_line(:view),
    do: gettext("The canvas did not load. Reload the page to see the stages.")

  @doc false
  # view/3 is what the canvas draws for `document` in `mode`: each stage's name, its
  # description (nil for none) and lines, as text. `opts`: `selected`, `people`, `alerts`,
  # `marks` and `selectable`, as the component's attributes.
  def view(document, mode, opts \\ []) when mode in [:edit, :view] do
    people = Keyword.get(opts, :people, %{})
    alerts = Keyword.get(opts, :alerts, %{})
    listed = Keyword.get(opts, :marks)
    stages = document["stages"] || []

    %{
      editable: mode == :edit,
      selectable: Keyword.get(opts, :selectable, true),
      selected: Keyword.get(opts, :selected),
      first:
        case stages do
          [first | _] -> Words.add_before(first["name"])
          [] -> nil
        end,
      stages:
        for stage <- stages do
          %{
            id: stage["id"],
            name: stage["name"],
            description: Words.description(stage),
            label: Words.card_label(stage, people),
            sequence: Words.card_sequence(stage),
            gate: Words.gate_line(stage, people),
            add: Words.add_after(stage["name"]),
            alerts: Map.get(alerts, stage["id"], []),
            marks: marks(stage, listed)
          }
        end
    }
  end

  # Each workflow of the stage by name, with whether the harness lists it and its label;
  # none with no list.
  defp marks(_stage, nil), do: %{}

  defp marks(stage, listed) do
    for name <- workflow_names(stage), into: %{} do
      listed? = name in listed
      {name, %{listed: listed?, label: Words.mark_label(name, listed?)}}
    end
  end

  defp workflow_names(stage) do
    Enum.flat_map(stage["sequence"] || [], fn
      %{"loop" => %{"body" => body}} -> Enum.map(body, &to_string(&1["workflow"]))
      entry -> [to_string(entry["workflow"])]
    end)
  end

  # The canvas's words, as text.
  defp words do
    %{
      label: gettext("Stages, in order"),
      node:
        gettext(
          "Press Enter to open the stage beside the canvas. Move it with the up and down arrow keys."
        ),
      node_read: gettext("Press Enter to open the stage beside the canvas."),
      node_view: gettext("View only: the stage's workflows and gate."),
      moved: gettext("Moved the selected stage."),
      no_workflow: gettext("No workflow"),
      zoom_in: gettext("Zoom in"),
      zoom_out: gettext("Zoom out"),
      controls: gettext("Canvas controls"),
      focus: gettext("Focus"),
      focus_title: gettext("Focus: the canvas takes the window (f)"),
      full_screen: gettext("Full screen"),
      leave_full_screen: gettext("Leave full screen")
    }
  end
end
