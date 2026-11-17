defmodule ApiaryWeb.StagesLive.Words do
  # The words of the Workflows page that more than one place shows: a stage card's lines, the
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
  # its label and its workflows. Text only. With the process document `doc`, an entry or a
  # loop that has a condition on a track also has `condition`, its words (`condition/4`),
  # and a loop has `conditions`, the words of each workflow's condition, nil for none.
  @doc false
  def card_sequence(stage, doc \\ nil) do
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
          |> put_conditions(Enum.map(body, &condition(&1, doc, stage["id"])))
          |> put_condition(condition(entry, doc, stage["id"]))

        entry ->
          %{workflow: to_string(entry["workflow"])}
          |> put_condition(condition(entry, doc, stage["id"]))
      end
    end
  end

  # `conditions`, one place for each workflow of a loop, nil for a workflow with none; no key
  # where none of them has one.
  defp put_conditions(map, conditions) do
    if Enum.all?(conditions, &is_nil/1), do: map, else: Map.put(map, :conditions, conditions)
  end

  defp put_condition(map, nil), do: map
  defp put_condition(map, text), do: Map.put(map, :condition, text)

  # The name the process document `doc` gives the track `id`, else the id.
  @doc false
  def track_name(doc, id) do
    case Enum.find(doc["tracks"] || [], &(&1["id"] == id)) do
      %{"name" => name} -> name
      _none -> id
    end
  end

  # "Offers: Standard, Fast track" for a stage whose gate offers tracks, in the gate's
  # order; nil for a stage that offers none, or with no document.
  @doc false
  def offers(%{"gate" => %{"tracks" => [_ | _] = ids}}, %{} = doc),
    do: gettext("Offers: %{tracks}", tracks: Enum.map_join(ids, ", ", &track_name(doc, &1)))

  def offers(_stage, _doc), do: nil

  # The words of a condition on a track in `when` or `unless` of `item`, a stage, a loop or a
  # workflow entry of the stage `stage_id` in `doc`; nil for an item with none, for a
  # condition on an input (no words here), and with no document.
  #
  #   * a stage: "Skipped on Fast track" for `unless`, "Runs on Fast track." for `when`;
  #   * a loop or entry: "Runs on Fast track." for `when`; for `unless`, "Runs on Standard
  #     only.", with the other tracks that the gates before the stage offer, in the
  #     document's order, and "Skipped on Fast track" when there is none.
  @doc false
  def condition(item, doc, stage_id, kind \\ :part)

  def condition(%{"when" => %{"track" => id}}, %{} = doc, _stage_id, _kind),
    do: gettext("Runs on %{track}.", track: track_name(doc, id))

  def condition(%{"unless" => %{"track" => id}}, %{} = doc, stage_id, kind) do
    others =
      if kind == :part, do: Enum.reject(offered_before(doc, stage_id), &(&1 == id)), else: []

    case others do
      [] ->
        gettext("Skipped on %{track}", track: track_name(doc, id))

      _others ->
        gettext("Runs on %{tracks} only.",
          tracks: ApiaryWeb.SourceComponents.joined(Enum.map(others, &track_name(doc, &1)), :or)
        )
    end
  end

  def condition(_item, _doc, _stage_id, _kind), do: nil

  # The ids of the tracks that the gates before the stage `stage_id` offer, in the order of
  # the document's `tracks`.
  defp offered_before(doc, stage_id) do
    offered =
      (doc["stages"] || [])
      |> Enum.take_while(&(&1["id"] != stage_id))
      |> Enum.flat_map(&((&1["gate"] || %{})["tracks"] || []))

    for %{"id" => id} <- doc["tracks"] || [], id in offered, do: id
  end

  # The lines under a workflow entry's row in the editor and the member's panel: "Name: ..."
  # for an entry with a name, then its condition.
  @doc false
  def entry_notes(entry, doc, stage_id) do
    name =
      case entry["name"] do
        name when is_binary(name) and name != "" -> gettext("Name: %{name}", name: name)
        _none -> nil
      end

    Enum.reject([name, condition(entry, doc, stage_id)], &is_nil/1)
  end

  # The words a screen reader reads for a card, in the card's order: its name, its condition,
  # its description, its workflows and loops, its gate and the tracks it offers, each in full.
  @doc false
  def card_label(stage, people, doc \\ nil) do
    sequence =
      case card_sequence(stage, doc) do
        [] ->
          [gettext("No workflow")]

        items ->
          Enum.map(items, fn
            %{loop: loop, workflows: names} = item ->
              gettext("a loop of %{workflows}, %{rounds}",
                workflows: Enum.join(loop_names(names, item), ", "),
                rounds: loop
              )
              |> with_condition(item)

            %{workflow: name} = item ->
              with_condition(name, item)
          end)
      end

    rest =
      Enum.join(
        Enum.reject(
          sequence ++ [gate_line(stage, people), doc && offers(stage, doc)],
          &(&1 in [nil, false])
        ),
        ". "
      )

    condition =
      case condition(stage, doc, stage["id"], :stage) do
        nil -> ""
        text -> String.trim_trailing(text, ".") <> ". "
      end

    stage["name"] <> ". " <> condition <> (label_description(stage) || "") <> rest
  end

  # The workflows of a loop, each followed by its condition in brackets where it has one.
  defp loop_names(names, %{conditions: conditions}) do
    for {name, condition} <- Enum.zip(names, conditions) do
      if condition, do: name <> " (" <> String.trim_trailing(condition, ".") <> ")", else: name
    end
  end

  defp loop_names(names, _item), do: names

  defp with_condition(text, %{condition: condition}),
    do: text <> ", " <> String.trim_trailing(condition, ".")

  defp with_condition(text, _item), do: text

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
  # cross's line. On the Workflows page, `:workspace` for a harness repository and
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
        "Choose another workflow for %{stage}. To keep %{workflow}, change the harness in Workspace settings › Harness to one that lists it under workflows. The Qory harness does not list %{workflow}, so %{stage} waits and starts no run.",
        stage: stage_name,
        workflow: workflow
      )

  def undeclared(stage_name, workflow, :qory),
    do:
      gettext(
        "Choose another workflow for %{stage}, or list %{workflow} in the harness of each workspace of this type. The Qory harness does not list %{workflow}. A workspace on the Qory harness waits at %{stage} once an owner or admin opens its Workflows page, or someone uses Check again on a work item.",
        stage: stage_name,
        workflow: workflow
      )

  # A workflow's mark, in words beside the check or the cross: a check for a name a stage
  # may run (`Apiary.Processes.declared_workflows/1`: the Qory harness's names, the names
  # the harness listed at its last read, and the workflows saved on the Harness page), a
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

  # A sent workflow name that breaks the schema's pattern, under its field.
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

  def change({:tracks_changed, _id, _detail}, _older, _newer, _people),
    do: gettext("Tracks changed.")

  def change({:condition_changed, id, _detail}, _older, newer, _people),
    do: gettext("%{stage}: condition changed.", stage: name(newer, id))

  def change({:gate_changed, id, _detail}, older, newer, people) do
    stage = Processes.stage(newer, id) || %{}
    name = stage["name"]

    line =
      case stage["gate"] do
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

    # A gate that offers tracks adds them: "... any member approves. Offers: A, B."; a gate
    # that stops offering them says so.
    case {offers(stage, newer), offers(Processes.stage(older, id) || %{}, older)} do
      {nil, nil} -> line
      {nil, _before} -> line <> " " <> gettext("Offers no track.")
      {offers, _before} -> line <> " " <> offers <> "."
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

  # A condition that no earlier stage can meet, in `when` or `unless` on a stage, an input,
  # a loop or a workflow entry, or in `when` on an output, at a place such as
  # `#/stages/1/sequence/0/loop/body/1/when/input` or `#/stages/2/unless/track`.
  def refusal(%{error: :condition_input, path: path, detail: type}, doc) when is_binary(path) do
    {stage, _field} = place(path, doc)

    case condition_subject(doc, path) do
      {:workflow, workflow} ->
        gettext(
          "Remove the condition on %{workflow} in %{stage}, or add an earlier stage that makes %{type}.",
          workflow: workflow,
          stage: stage,
          type: type
        )

      {:output, output} ->
        gettext(
          "Remove the condition on the output %{output} in %{stage}, or add an earlier stage that makes %{type}.",
          output: output,
          stage: stage,
          type: type
        )

      {:input, input} ->
        gettext(
          "Remove the condition on the input %{input} in %{stage}, or add an earlier stage that makes %{type}.",
          input: input,
          stage: stage,
          type: type
        )

      :loop ->
        gettext(
          "Remove the condition on a loop in %{stage}, or add an earlier stage that makes %{type}.",
          stage: stage,
          type: type
        )

      :stage ->
        gettext(
          "Remove the condition on %{stage}, or add an earlier stage that makes %{type}.",
          stage: stage,
          type: type
        )

      nil ->
        gettext("%{stage}: a value is not valid. Check the stage, then save again.",
          stage: stage
        )
    end
  end

  def refusal(%{error: :condition_track, path: path, detail: track}, doc) when is_binary(path) do
    {stage, _field} = place(path, doc)

    case condition_subject(doc, path) do
      {:workflow, workflow} ->
        gettext(
          "Remove the condition on %{workflow} in %{stage}, or let an earlier stage offer the track %{track} at its gate.",
          workflow: workflow,
          stage: stage,
          track: track
        )

      {:input, input} ->
        gettext(
          "Remove the condition on the input %{input} in %{stage}, or let an earlier stage offer the track %{track} at its gate.",
          input: input,
          stage: stage,
          track: track
        )

      :loop ->
        gettext(
          "Remove the condition on a loop in %{stage}, or let an earlier stage offer the track %{track} at its gate.",
          stage: stage,
          track: track
        )

      :stage ->
        gettext(
          "Remove the condition on %{stage}, or let an earlier stage offer the track %{track} at its gate.",
          stage: stage,
          track: track
        )

      _other ->
        gettext("%{stage}: a value is not valid. Check the stage, then save again.",
          stage: stage
        )
    end
  end

  # A stage, an input, a loop or a workflow entry with both `when` and `unless`, at its place.
  def refusal(%{error: :condition_both, path: path}, doc) when is_binary(path) do
    {stage, _field} = place(path, doc)

    case condition_subject(doc, path) do
      {:workflow, workflow} ->
        gettext(
          "Keep one condition on %{workflow} in %{stage}: remove its when or its unless.",
          workflow: workflow,
          stage: stage
        )

      {:input, input} ->
        gettext(
          "Keep one condition on the input %{input} in %{stage}: remove its when or its unless.",
          input: input,
          stage: stage
        )

      :loop ->
        gettext("Keep one condition on a loop in %{stage}: remove its when or its unless.",
          stage: stage
        )

      :stage ->
        gettext("Keep one condition on %{stage}: remove its when or its unless.", stage: stage)

      _other ->
        gettext("%{stage}: a value is not valid. Check the stage, then save again.",
          stage: stage
        )
    end
  end

  def refusal(%{error: :duplicate_track_id, detail: track}, _doc),
    do: gettext("Give each track a different id. Two tracks have the id %{track}.", track: track)

  # A gate that offers a track id the process does not declare in its `tracks`.
  def refusal(%{error: :gate_track, path: path, detail: track}, doc) do
    {stage, _field} = place(path, doc)

    gettext(
      "Remove the track %{track} from the gate of %{stage}, or add it to the tracks of the process.",
      track: track,
      stage: stage
    )
  end

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

      field == "sequence" and bad_entry_name?(doc, path) ->
        gettext(
          "Give a workflow in %{stage} a name of 1 to 60 characters, or remove its name.",
          stage: stage
        )

      String.contains?(path, "machine") ->
        machine_refused()

      path == "#/tracks" and error_detail == :maxItems ->
        gettext("Keep at most 10 tracks in the process.")

      String.starts_with?(path, "#/tracks") and String.ends_with?(path, "/description") ->
        gettext("Shorten the description of %{track} to at most 500 characters.",
          track: track_at(doc, path)
        )

      String.starts_with?(path, "#/tracks") ->
        gettext(
          "Give every track an id of at most 40 lower-case letters, digits and hyphens, such as small-change, and a name of 1 to 60 characters."
        )

      error == :gate_none_tracks ->
        gettext(
          "Remove the tracks from the gate of %{stage}, or let a person approve at it. A gate with no approval offers no track.",
          stage: stage
        )

      String.ends_with?(path, "/gate/tracks") and error_detail == :uniqueItems ->
        gettext("List each track once in the gate of %{stage}.", stage: stage)

      String.ends_with?(path, "/gate/tracks") and error_detail == :maxItems ->
        gettext("Offer at most 10 tracks at the gate of %{stage}.", stage: stage)

      String.contains?(path, "/gate/tracks") ->
        gettext(
          "Write each track of the gate of %{stage} as an id of lower-case words joined by hyphens, such as small-change.",
          stage: stage
        )

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

  # Whether the entry at `path`, or a workflow in the loop there, has a `name` that is not a
  # text of 1 to 60 characters.
  defp bad_entry_name?(doc, path) do
    case Draft.entry_at(doc, path) do
      %{"loop" => %{"body" => body}} -> Enum.any?(body, &bad_name?/1)
      %{} = entry -> bad_name?(entry)
      _other -> false
    end
  end

  defp bad_name?(%{"name" => name}),
    do: not (is_binary(name) and length(String.codepoints(name)) in 1..60 and name =~ ~r/\S/)

  defp bad_name?(_entry), do: false

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

  # A workflow entry whose key no machine type has: the line of its closed row.
  @doc false
  def machine_missing_line(key),
    do: gettext("Pick a machine type: no type has the key %{key}.", key: key)

  # The same, in the notice beside its picker, after the bold "Pick a machine type for
  # make-mockups.": where the key came from, and the type the runs start on, `fallback`,
  # by name. `from_update` where the process came from an update from the harness.
  @doc false
  def machine_missing(key, workflow, fallback, false),
    do:
      rich_gettext(
        "The %{file} this workspace was made from sets %{setting}, and this Qory Apiary has no machine type with the key %{key}. Until you pick one, runs of %{workflow} start on the default type, %{fallback}.",
        file: {:m, "process.yaml"},
        setting: {:m, "machine: " <> key},
        key: {:m, key},
        workflow: workflow,
        fallback: fallback
      )

  def machine_missing(key, workflow, fallback, true),
    do:
      rich_gettext(
        "The %{file} of the last update from the harness sets %{setting}, and this Qory Apiary has no machine type with the key %{key}. Until you pick one, runs of %{workflow} start on the default type, %{fallback}.",
        file: {:m, "process.yaml"},
        setting: {:m, "machine: " <> key},
        key: {:m, key},
        workflow: workflow,
        fallback: fallback
      )

  # Remove loop refused: the loop's condition cannot move onto `workflow`, which has one.
  @doc false
  def loop_kept(workflow),
    do:
      gettext(
        "Keep this loop. Its condition cannot move to %{workflow}, which has a condition already.",
        workflow: workflow
      )

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

  # A save from the harness, or a trial of it made current, where the workspace's harness
  # choice changed after the person read the difference (`Apiary.Processes.HarnessUpdate`).
  @doc false
  def choice_changed,
    do:
      gettext(
        "Press Update from harness again. The harness choice changed after you opened this difference."
      )

  # A trial from the harness made current, with a stack to copy into the harness the
  # organisation shares.
  @doc false
  def shared_stack_make_current,
    do:
      gettext(
        "Change the stack of the harness your organisation shares, then press Make current again. Every workspace that takes that harness uses its stack."
      )

  # A save from the harness, or a trial of it made current, with a stack to copy into the
  # harness the organisation shares (`Apiary.Processes.HarnessUpdate`).
  @doc false
  def shared_stack,
    do:
      gettext(
        "Change the stack of the harness your organisation shares, then save again. Every workspace that takes that harness uses its stack."
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

  # The name of the track at a place such as `#/tracks/1/description`, else its id, else
  # "a track".
  defp track_at(doc, path) do
    with [_all, index] <- Regex.run(~r{^#/tracks/(\d+)}, path),
         %{} = track <- Enum.at(doc["tracks"] || [], String.to_integer(index)) do
      [track["name"], track["id"]]
      |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
      |> Kernel.||(gettext("a track"))
    else
      _none -> gettext("a track")
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

  # What has the condition at `path`, a place such as `#/stages/1/outputs/0/when/input`:
  # `{:workflow, name}`, `{:output, type}`, `{:input, type}`, `:loop` or `:stage`; nil where the
  # document has nothing there.
  defp condition_subject(doc, path) do
    holder = String.replace(path, ~r{/(when|unless)/(input|track)$}, "")

    case {document_at(doc, holder), String.contains?(holder, "/outputs/"),
          String.contains?(holder, "/inputs/")} do
      {%{"workflow" => workflow}, _output, _input} when is_binary(workflow) ->
        {:workflow, workflow}

      {%{"type" => type}, true, _input} when is_binary(type) ->
        {:output, type}

      {%{"type" => type}, _output, true} when is_binary(type) ->
        {:input, type}

      {%{"loop" => _loop}, _output, _input} ->
        :loop

      {%{"sequence" => _sequence}, _output, _input} ->
        :stage

      _other ->
        nil
    end
  end

  defp document_at(doc, place) do
    place
    |> String.replace_prefix("#/", "")
    |> String.split("/")
    |> Enum.reduce_while(doc, fn key, at ->
      case {at, Integer.parse(key)} do
        {list, {index, ""}} when is_list(list) -> {:cont, Enum.at(list, index)}
        {map, _not_index} when is_map(map) -> {:cont, Map.get(map, key)}
        _other -> {:halt, nil}
      end
    end)
  end
end
