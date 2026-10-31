defmodule ApiaryWeb.StagesLive.Words do
  # The words of the Stages page that more than one place shows: a stage card's lines, the
  # placement check's lines, a version's changes and a refused save. The canvas gets
  # them as text, never as markup.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  alias ApiaryWeb.StagesLive.Calls

  @doc false
  def loop_line(stage) do
    case Enum.find(stage["sequence"], &Map.has_key?(&1, "loop")) do
      %{"loop" => %{"rounds" => rounds}} ->
        ngettext("Loop: at most %{number} round", "Loop: at most %{number} rounds", rounds,
          number: rounds
        )

      nil ->
        gettext("No loop")
    end
  end

  @doc false
  def gate_line(%{"gate" => %{"kind" => "none"}}), do: gettext("No gate")

  def gate_line(%{"gate" => %{"approvers" => %{"members" => named}}}),
    do:
      ngettext(
        "Gate: %{number} named member approves",
        "Gate: one of %{number} named members approves",
        length(named),
        number: length(named)
      )

  def gate_line(_stage), do: gettext("Gate: a member approves")

  @doc false
  def workflow_lines(stage) do
    case Calls.workflow_names(stage) do
      [] -> [gettext("No workflow")]
      names -> Enum.uniq(names)
    end
  end

  # A workflow the harness no longer declares (spec addition 2).
  @doc false
  def undeclared(stage_name, workflow),
    do:
      gettext(
        "%{stage} uses %{workflow}, which the harness no longer declares. Add it to the harness, or choose another workflow for %{stage}.",
        stage: stage_name,
        workflow: workflow
      )

  @doc false
  def missing_type(stage_name, type),
    do:
      gettext("%{stage} uses the type %{type}, which this workspace does not have.",
        stage: stage_name,
        type: type
      )

  @doc false
  def input_not_output(stage_name, type),
    do:
      gettext(
        "%{stage} needs %{type} as an input, and no stage before %{stage} lists it as an output.",
        stage: stage_name,
        type: type
      )

  # One change between two versions, in plain words.
  @doc false
  def change({:stage_added, _id, %{name: name}}),
    do: gettext("Added the stage %{name}.", name: name)

  def change({:stage_removed, _id, %{name: name}}),
    do: gettext("Removed the stage %{name}.", name: name)

  def change({:stage_renamed, _id, %{name: name, from: from}}),
    do: gettext("Renamed the stage %{from} to %{name}.", from: from, name: name)

  def change({:stage_moved, _id, %{name: name, from: from, to: to}}),
    do:
      gettext("Moved %{name} from place %{from} to place %{to}.", name: name, from: from, to: to)

  def change({:sequence_changed, _id, %{name: name}}),
    do: gettext("Changed the sequence of %{name}.", name: name)

  def change({:inputs_changed, _id, %{name: name}}),
    do: gettext("Changed the inputs of %{name}.", name: name)

  def change({:outputs_changed, _id, %{name: name}}),
    do: gettext("Changed the outputs of %{name}.", name: name)

  def change({:gate_changed, _id, %{name: name}}),
    do: gettext("Changed the gate of %{name}.", name: name)

  def change({:machine_changed, _id, %{from: from, to: to}}),
    do:
      gettext("Changed the default machine type from %{from} to %{to}.",
        from: from || "default",
        to: to || "default"
      )

  # Why a save was refused.
  @doc false
  def refusal(:forbidden, _doc), do: gettext("Only owners and admins can change the stages.")

  def refusal({nil, :duplicate_id}, _doc),
    do: gettext("Two stages have the same id. Reload the page, then make the change again.")

  def refusal({id, reason}, doc) do
    name = (Calls.stage(doc, id) || %{})["name"]
    name = if name in [nil, ""], do: gettext("A stage"), else: name

    case reason do
      :blank_name ->
        gettext("Give every stage a name.")

      :bad_sequence ->
        gettext(
          "%{stage}: give every loop 1 to 10 rounds and at least one workflow, and choose a workflow for every entry.",
          stage: name
        )

      :no_approvers ->
        gettext("%{stage}: choose at least one member who approves, or let any member approve.",
          stage: name
        )
    end
  end
end
