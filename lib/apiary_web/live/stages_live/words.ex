defmodule ApiaryWeb.StagesLive.Words do
  # The words of the Stages page that more than one place shows: a stage card's lines, the
  # placement check's lines, a version's changes and a refused save. The canvas gets
  # them as text, never as markup.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Processes

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
    case Processes.workflows(stage) do
      [] -> [gettext("No workflow")]
      names -> names
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

  # One change between two versions (`Apiary.Processes.diff/2`), in plain words. A stage's
  # name is the newer document's, else the older one's for a removed stage.
  @doc false
  def change({:stage_added, _id, %{name: name}}, _older, _newer),
    do: gettext("Added the stage %{name}.", name: name)

  def change({:stage_removed, _id, %{name: name}}, _older, _newer),
    do: gettext("Removed the stage %{name}.", name: name)

  def change({:stage_renamed, _id, %{from: from, to: to}}, _older, _newer),
    do: gettext("Renamed the stage %{from} to %{name}.", from: from, name: to)

  def change({:stage_moved, id, %{from: from, to: to}}, _older, newer),
    do:
      gettext("Moved %{name} from place %{from} to place %{to}.",
        name: name(newer, id),
        from: from + 1,
        to: to + 1
      )

  def change({:sequence_changed, id, _detail}, _older, newer),
    do: gettext("Changed the sequence of %{name}.", name: name(newer, id))

  def change({:inputs_changed, id, _detail}, _older, newer),
    do: gettext("Changed the inputs of %{name}.", name: name(newer, id))

  def change({:outputs_changed, id, _detail}, _older, newer),
    do: gettext("Changed the outputs of %{name}.", name: name(newer, id))

  def change({:gate_changed, id, _detail}, _older, newer),
    do: gettext("Changed the gate of %{name}.", name: name(newer, id))

  def change({:machine_changed, _id, %{from: from, to: to}}, _older, _newer),
    do:
      gettext("Changed the default machine type from %{from} to %{to}.",
        from: from || "default",
        to: to || "default"
      )

  defp name(doc, id), do: (Processes.stage(doc, id) || %{})["name"]

  # Why a save was refused: `:forbidden`, or an error of `Apiary.Processes.validate/1`,
  # `%{path, error, detail}`, with the place in the document as JSV writes it.
  @doc false
  def refusal(:forbidden, _doc), do: gettext("Only owners and admins can change the stages.")

  def refusal(%{error: :unchanged}, _doc),
    do: gettext("Nothing to save: the stages are the same as in the version you started from.")

  def refusal(%{error: :too_large}, _doc),
    do: gettext("The process is too large to save. Remove stages or entries, then save again.")

  def refusal(%{error: :duplicate_stage_id}, _doc),
    do: gettext("Two stages have the same id. Reload the page, then make the change again.")

  def refusal(%{error: error, path: path}, doc) do
    {stage, field} = place(path, doc)

    cond do
      error == :duplicate_stage_name ->
        gettext("Two stages have the name %{stage}. Give each stage a different name.",
          stage: stage
        )

      field == "name" ->
        gettext("Give every stage a name of 1 to 60 characters.")

      String.contains?(path, "machine") ->
        gettext(
          "Write a machine type with letters, digits, dots, hyphens and underscores, starting with a letter or a digit."
        )

      String.contains?(path, "approvers") ->
        gettext("%{stage}: choose at least one member who approves, or let any member approve.",
          stage: stage
        )

      field in ["sequence", "inputs", "outputs"] ->
        gettext(
          "%{stage}: give every loop 1 to 10 rounds and at least one workflow, and keep at most 20 entries in each list.",
          stage: stage
        )

      true ->
        gettext("%{stage}: a value is not valid. Check the stage, then save again.",
          stage: stage
        )
    end
  end

  # The stage's name and the field under it, of a place such as `#/stages/1/name`.
  defp place(path, doc) when is_binary(path) do
    case Regex.run(~r{^#/stages/(\d+)(?:/([a-z_]+))?}, path) do
      [_all, index | field] ->
        stage = Enum.at(doc["stages"] || [], String.to_integer(index)) || %{}
        name = stage["name"]
        name = if is_binary(name) and String.trim(name) != "", do: name, else: gettext("A stage")
        {name, List.first(field)}

      nil ->
        {gettext("The process"), nil}
    end
  end

  defp place(_path, _doc), do: {gettext("The process"), nil}
end
