defmodule ApiaryWeb.StagesLive.Words do
  # The words of the Stages page that more than one place shows: a stage card's lines, the
  # placement check's lines, a version's changes and a refused save. The canvas gets
  # them as text, never as markup.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText, only: [rich_gettext: 2]

  alias Apiary.Processes
  alias ApiaryWeb.StagesLive.Draft

  # A stage's gate, with each named approver by name: `people` maps a person's user id,
  # as the document keeps it, to the name the page shows. The id is never shown.
  @doc false
  def gate_line(%{"gate" => %{"kind" => "none"}}, _people), do: gettext("No gate")

  def gate_line(%{"gate" => %{"approvers" => %{"members" => [id]}}}, people),
    do: gettext("Gate: %{person} approves", person: person(people, id))

  def gate_line(%{"gate" => %{"approvers" => %{"members" => ids}}}, people),
    do: gettext("Gate: one of %{people} approves", people: people(people, ids))

  def gate_line(_stage, _people), do: gettext("Gate: a member approves")

  # The gate under the heading Gate, in a member's read-only panel.
  @doc false
  def gate_value(%{"gate" => %{"kind" => "none"}}, _people), do: gettext("None")

  def gate_value(%{"gate" => %{"approvers" => %{"members" => [id]}}}, people),
    do: gettext("%{person} approves", person: person_first(people, id))

  def gate_value(%{"gate" => %{"approvers" => %{"members" => ids}}}, people),
    do: gettext("One of %{people} approves", people: people(people, ids))

  def gate_value(_stage, _people), do: gettext("A member approves")

  # The name of the person with the user id `id`, or the words for one who left.
  @doc false
  def person(people, id), do: Map.get(people, id) || gettext("a former member")

  # The same at the start of a line or a label: "Former member", as `ApiaryWeb.People`
  # writes it in the history.
  @doc false
  def person_first(people, id), do: Map.get(people, id) || ApiaryWeb.People.former_member()

  defp people(people, ids), do: Enum.map_join(ids, ", ", &person(people, &1))

  # A stage's sequence as its card draws it: each workflow, and each loop as a group with
  # its label and its workflows. Text only.
  @doc false
  def card_sequence(stage) do
    for entry <- stage["sequence"] do
      case entry do
        %{"loop" => %{"rounds" => rounds, "body" => body}} ->
          %{
            loop:
              ngettext("at most %{number} round", "at most %{number} rounds", rounds,
                number: rounds
              ),
            workflows: Enum.map(body, &to_string(&1["workflow"]))
          }

        entry ->
          %{workflow: to_string(entry["workflow"])}
      end
    end
  end

  # The words a screen reader reads for a card: its name, its description, its workflows
  # and loops, its gate, each in full.
  @doc false
  def card_label(stage, people) do
    sequence =
      case card_sequence(stage) do
        [] ->
          [gettext("No workflow")]

        items ->
          Enum.map(items, fn
            %{loop: loop, workflows: names} ->
              gettext("a loop of %{workflows}, %{rounds}",
                workflows: Enum.join(names, ", "),
                rounds: loop
              )

            %{workflow: name} ->
              name
          end)
      end

    rest = Enum.join(sequence ++ [gate_line(stage, people)], ". ")

    case label_description(stage) do
      nil -> stage["name"] <> ". " <> rest
      text -> stage["name"] <> ". " <> text <> rest
    end
  end

  # The stage's description as the document has it, plain text; nil for none or a blank one.
  @doc false
  def description(%{"description" => text}) when is_binary(text),
    do: if(String.trim(text) == "", do: nil, else: text)

  def description(_stage), do: nil

  # The description in the card's label, with the ". " that joins the label's parts: one
  # final full stop of the text ends it, and after a final "?" or "!" a space alone.
  defp label_description(stage) do
    case description(stage) do
      nil ->
        nil

      text ->
        text = String.trim(text)

        cond do
          String.ends_with?(text, ".") -> text <> " "
          String.ends_with?(text, ["?", "!"]) -> text <> " "
          true -> text <> ". "
        end
    end
  end

  # The label of the "+" after a stage on the canvas.
  @doc false
  def add_after(name), do: gettext("Add a stage after %{stage}", stage: name)

  # The workflows the harness listed at its last read (`Apiary.Processes.declared_snapshot/1`),
  # with the time of that read; before the first read, that it has not been read. The
  # Qory harness is never read: `qory`, the workflows of its stack, with no time. A stack
  # with none, `core`, reads as any harness that listed none.
  @doc false
  def workflows_line(_snapshot, [_ | _] = qory),
    do: gettext("The Qory harness's workflows: %{names}.", names: Enum.join(qory, ", "))

  def workflows_line(%{names: [], read_at: at}, _qory),
    do: gettext("The harness listed no workflows %{time}.", time: read_time(at))

  def workflows_line(%{names: names, read_at: at}, _qory),
    do:
      gettext("Workflows the harness listed %{time}: %{names}.",
        time: read_time(at),
        names: Enum.join(names, ", ")
      )

  def workflows_line(nil, _qory), do: not_read()

  # Before the first read of the harness: the canvas shows no marks, and no stage waits
  # for a workflow.
  @doc false
  def not_read, do: gettext("The harness has not been read yet.")

  # The time of a read in a sentence: "just now", "5 minutes ago", "yesterday, 17:20".
  defp read_time(at), do: ApiaryWeb.Format.time_ago(at, DateTime.utc_now(), case: :inline)

  # A read of the harness that failed, with its cause (`words`): the list stays as the
  # last read left it, with that read's time. Rich text, since the cause can link to
  # support (`ApiaryWeb.Support`); the page shows it, the canvas does not.
  @doc false
  def read_failed(words, %{read_at: at}),
    do:
      rich_gettext("Reading the harness failed, so the list is from the read %{time}. %{cause}",
        time: read_time(at),
        cause: words
      )

  def read_failed(words, nil),
    do: rich_gettext("Reading the harness failed. %{cause}", cause: words)

  # The label of the "+" before the first stage.
  @doc false
  def add_before(name), do: gettext("Add a stage before %{stage}", stage: name)

  # A workflow the harness does not list under `workflows` (spec addition 2): the red
  # cross's line. On the Stages page, `:workspace` for a harness repository and
  # `:qory_workspace` for the Qory harness; `:qory` for the Qory harness on Instance
  # settings › Workspace types.
  @doc false
  def undeclared(stage_name, workflow, harness \\ :workspace)

  def undeclared(stage_name, workflow, :workspace),
    do:
      gettext(
        "List %{workflow} under workflows in the harness's qory-stack.yaml, or choose another workflow for %{stage}. Until then, %{stage} waits and starts no run.",
        stage: stage_name,
        workflow: workflow
      )

  def undeclared(stage_name, workflow, :qory_workspace),
    do:
      gettext(
        "Choose another workflow for %{stage}. To keep %{workflow}, change the harness on the Details tab to one that lists it under workflows. The Qory harness does not list %{workflow}, so %{stage} waits and starts no run.",
        stage: stage_name,
        workflow: workflow
      )

  def undeclared(stage_name, workflow, :qory),
    do:
      gettext(
        "Choose another workflow for %{stage}, or list %{workflow} in the harness of each workspace of this type. The Qory harness does not list %{workflow}. A workspace on the Qory harness waits at %{stage} once an owner or admin opens its Stages page, or someone uses Check again on a work item.",
        stage: stage_name,
        workflow: workflow
      )

  # A workflow's mark, in words beside the check or the cross: a check for a name a stage
  # may run (`Apiary.Processes.declared_workflows/1`: the Qory harness's names, the names
  # the harness listed at its last read, and the workflows saved on the Workflow page), a
  # cross for any other.
  @doc false
  def mark_text(true), do: gettext("A stage can run it")
  def mark_text(false), do: gettext("Not in the harness")

  # The same with the workflow's name, for a mark on a card.
  @doc false
  def mark_label(workflow, true),
    do: gettext("%{workflow}: a stage can run it", workflow: workflow)

  def mark_label(workflow, false),
    do: gettext("%{workflow}: not in the harness", workflow: workflow)

  # A typed workflow name that breaks the schema's pattern, under its field.
  @doc false
  def workflow_refused,
    do:
      gettext(
        "Write a workflow name of lower-case letters, digits and hyphens that starts with a letter, at most 55 characters."
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
  def change(change, older, newer, people \\ %{})

  def change({:stage_added, _id, %{name: name}}, _older, _newer, _people),
    do: gettext("Added the stage %{name}.", name: name)

  def change({:stage_removed, _id, %{name: name}}, _older, _newer, _people),
    do: gettext("Removed the stage %{name}.", name: name)

  def change({:stage_renamed, _id, %{from: from, to: to}}, _older, _newer, _people),
    do: gettext("Renamed the stage %{from} to %{name}.", from: from, name: to)

  def change({:stage_moved, id, %{from: from, to: to}}, _older, newer, _people),
    do:
      gettext("Moved %{name} from place %{from} to place %{to}.",
        name: name(newer, id),
        from: from + 1,
        to: to + 1
      )

  def change({:description_changed, id, _detail}, _older, newer, _people),
    do: gettext("Changed the description of %{name}.", name: name(newer, id))

  def change({:sequence_changed, id, _detail}, _older, newer, _people),
    do: gettext("Changed the sequence of %{name}.", name: name(newer, id))

  def change({:inputs_changed, id, _detail}, _older, newer, _people),
    do: gettext("Changed the inputs of %{name}.", name: name(newer, id))

  def change({:outputs_changed, id, _detail}, _older, newer, _people),
    do: gettext("Changed the outputs of %{name}.", name: name(newer, id))

  def change({:gate_changed, id, _detail}, _older, newer, people) do
    name = name(newer, id)

    case (Processes.stage(newer, id) || %{})["gate"] do
      %{"kind" => "none"} ->
        gettext("Changed the gate of %{name}: no gate.", name: name)

      %{"approvers" => %{"members" => [person]}} ->
        gettext("Changed the gate of %{name}: %{person} approves.",
          name: name,
          person: person(people, person)
        )

      %{"approvers" => %{"members" => ids}} ->
        gettext("Changed the gate of %{name}: one of %{people} approves.",
          name: name,
          people: people(people, ids)
        )

      _members ->
        gettext("Changed the gate of %{name}: any member approves.", name: name)
    end
  end

  # The document's "Default machine type" before and after: "Default" for `default` or
  # none, else the type's name. The line has no type name for "Default": a version does
  # not record which type was the default when it was saved.
  def change({:machine_changed, _id, %{from: from, to: to}}, _older, _newer, _people),
    do:
      gettext("Changed the default machine type from %{from} to %{to}.",
        from: machine_words(from),
        to: machine_words(to)
      )

  defp machine_words(value) when value in [nil, "", "default"], do: gettext("Default")
  defp machine_words(value), do: value

  defp name(doc, id), do: (Processes.stage(doc, id) || %{})["name"]

  # Why a save was refused: `:forbidden`, or an error of `Apiary.Processes.validate/1`,
  # `%{path, error, detail}`, with the place in the document as JSV writes it.
  @doc false
  def refusal(:forbidden, _doc), do: gettext("Only owners and admins can change the stages.")

  def refusal(%{error: :unchanged}, _doc),
    do: gettext("Nothing to save: the stages are the same as in the version you started from.")

  def refusal(%{error: :too_large}, _doc),
    do: gettext("The process is too large to save. Remove stages or entries, then save again.")

  # A type's process lists no people (`Apiary.Processes.TypeTemplates.save/4`).
  def refusal(%{error: :named_approvers}, _doc),
    do:
      gettext(
        "A workspace type has no members to name. Choose \"A person approves before the work item moves on.\""
      )

  def refusal(%{error: :duplicate_stage_id}, _doc),
    do: gettext("Two stages have the same id. Reload the page, then make the change again.")

  def refusal(%{error: error, path: path} = refused, doc) do
    {stage, field} = place(path, doc)
    error_detail = refused[:detail]

    cond do
      error == :duplicate_stage_name ->
        gettext("Two stages have the name %{stage}. Give each stage a different name.",
          stage: stage
        )

      field == "name" ->
        gettext("Give every stage a name of 1 to 60 characters.")

      String.contains?(path, "machine") ->
        machine_refused()

      String.contains?(path, "approvers") ->
        gettext("%{stage}: choose at least one member who approves, or let any member approve.",
          stage: stage
        )

      field in ["sequence", "inputs", "outputs"] and error_detail == :maxItems ->
        gettext("%{stage}: keep at most 20 entries in each list.", stage: stage)

      field == "sequence" and Draft.loop_too_long?(Draft.entry_at(doc, path)) ->
        gettext("%{stage}: keep at most 10 workflows in a loop.", stage: stage)

      true ->
        gettext("%{stage}: a value is not valid. Check the stage, then save again.",
          stage: stage
        )
    end
  end

  # The banner's line for a stage with rows that show a refused machine type
  # (`Editor.banner/1`).
  @doc false
  def fields_marked(name) do
    name = if String.trim(name) != "", do: name, else: gettext("A stage")
    gettext("%{stage}: fix the fields marked below.", stage: name)
  end

  # A machine type that the schema's pattern or the instance's list does not take, for the
  # default's and a workflow's.
  @doc false
  def machine_refused, do: gettext("Choose a machine type from the list.")

  # A loop's rounds outside 1 to 10, under the field.
  @doc false
  def rounds_refused, do: gettext("Give the loop 1 to 10 rounds.")

  # A refusal that means the page was behind the versions: a trial dropped or made current
  # in another tab or by another person, or a version gone.
  @doc false
  def stale,
    do:
      gettext(
        "The versions changed since this page loaded, so nothing was changed. The page shows them again; check them, then try again."
      )

  @doc false
  def trial_exists(trial),
    do:
      gettext(
        "Version %{number} is already a trial. Make it current or drop it, then save another trial.",
        number: trial.number
      )

  # A work item that keeps a trial from being dropped: its stage is only in the trial.
  @doc false
  def not_dropped(%{number: nil}, stage),
    do:
      gettext(
        "The trial was not dropped: a work item of it is in the stage %{stage}, which the current version does not have. Assign that work item to another version first.",
        stage: stage
      )

  def not_dropped(item, stage),
    do:
      gettext(
        "The trial was not dropped: work item %{number}, %{title}, is in the stage %{stage}, which the current version does not have. Assign it to another version first.",
        number: item.number,
        title: item.title,
        stage: stage
      )

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
