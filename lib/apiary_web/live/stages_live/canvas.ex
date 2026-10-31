defmodule ApiaryWeb.StagesLive.Canvas do
  # The Stages canvas as one component: a process document (`Apiary.Processes`) drawn as
  # its stages in a line, in one of two modes.
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
  # selected stage's id, the names of named approvers and each stage's alert lines.
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
            selectable: @selectable
          )
        )
      }
      data-words={Jason.encode!(words())}
      class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-200"
    >
      <%!-- The canvas sets its height to the tallest card's, with margins. --%>
      <div data-canvas class="h-44 w-full"></div>
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
  # view/3 is what the canvas draws for `document` in `mode`: each stage's name and lines,
  # as text. `opts`: `selected`, `people`, `alerts` and `selectable`, as the component's
  # attributes.
  def view(document, mode, opts \\ []) when mode in [:edit, :view] do
    people = Keyword.get(opts, :people, %{})
    alerts = Keyword.get(opts, :alerts, %{})
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
            label: Words.card_label(stage, people),
            sequence: Words.card_sequence(stage),
            gate: Words.gate_line(stage, people),
            add: Words.add_after(stage["name"]),
            alerts: Map.get(alerts, stage["id"], [])
          }
        end
    }
  end

  # The canvas's words, as text.
  defp words do
    %{
      label: gettext("Stages, in order"),
      node:
        gettext(
          "Press Enter to open the stage under the canvas. Move it with the left and right arrow keys."
        ),
      node_read: gettext("Press Enter to open the stage under the canvas."),
      node_view: gettext("View only: the stage's workflows and gate."),
      moved: gettext("Moved the selected stage."),
      no_workflow: gettext("No workflow"),
      zoom_in: gettext("Zoom in"),
      zoom_out: gettext("Zoom out"),
      controls: gettext("Canvas controls"),
      # The canvas fills in each number of cards: the binding keeps "%{count}" in the text.
      left: gettext("← %{count} more", count: "%{count}"),
      right: gettext("→ %{count} more", count: "%{count}"),
      left_label_one: gettext("Show 1 more stage on the left"),
      left_label: gettext("Show %{count} more stages on the left", count: "%{count}"),
      right_label_one: gettext("Show 1 more stage on the right"),
      right_label: gettext("Show %{count} more stages on the right", count: "%{count}")
    }
  end
end
