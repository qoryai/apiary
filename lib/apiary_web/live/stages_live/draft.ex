defmodule ApiaryWeb.StagesLive.Draft do
  # The process document as the Workflows page edits it before a save: pure functions over
  # the document's map, with string keys as the schema has them. Every change keeps the
  # fields it does not touch, unknown fields included (the spec's § The process
  # document). A stage's id is made once, when the stage is added, and never changes.
  @moduledoc false

  @rounds 3

  @doc false
  def stages(doc), do: doc["stages"]

  # A new stage named `name` at place `at` (0 is first), the end for nil or a place past it.
  @doc false
  def add_stage(doc, name, at \\ nil) do
    stage = %{
      "id" => Apiary.Processes.new_stage_id(),
      "name" => name,
      "inputs" => [],
      "sequence" => [],
      "outputs" => [],
      "gate" => %{"kind" => "person", "approvers" => "members"}
    }

    stages = doc["stages"]
    at = if is_integer(at) and at >= 0, do: min(at, length(stages)), else: length(stages)
    {%{doc | "stages" => List.insert_at(stages, at, stage)}, stage["id"]}
  end

  @doc false
  def remove_stage(doc, id),
    do: %{doc | "stages" => Enum.reject(doc["stages"], &(&1["id"] == id))}

  # Moves the stage `by` places, within the line.
  @doc false
  def move(doc, id, by) do
    stages = doc["stages"]

    case Enum.find_index(stages, &(&1["id"] == id)) do
      nil ->
        doc

      from ->
        to = min(max(from + by, 0), length(stages) - 1)
        {stage, rest} = List.pop_at(stages, from)
        %{doc | "stages" => List.insert_at(rest, to, stage)}
    end
  end

  # The stages in the order of `ids`, when `ids` is the same set of stages; else unchanged.
  @doc false
  def reorder(doc, ids) when is_list(ids) do
    by_id = Map.new(doc["stages"], &{&1["id"], &1})

    if Enum.sort(ids) == Enum.sort(Map.keys(by_id)) and length(ids) == map_size(by_id),
      do: %{doc | "stages" => Enum.map(ids, &Map.fetch!(by_id, &1))},
      else: doc
  end

  def reorder(doc, _ids), do: doc

  @doc false
  def update_stage(doc, id, fun) do
    %{doc | "stages" => Enum.map(doc["stages"], &if(&1["id"] == id, do: fun.(&1), else: &1))}
  end

  @doc false
  def put_machine(doc, machine) do
    case String.trim(machine || "") do
      "" -> doc
      value -> Map.put(doc, "machine", value)
    end
  end

  ## The sequence

  # A workflow entry at the end of the sequence, or of the loop at `loop`.
  @doc false
  def add_entry(stage, workflow, nil),
    do: %{stage | "sequence" => stage["sequence"] ++ [%{"workflow" => workflow}]}

  def add_entry(stage, workflow, loop) do
    update_loop(stage, loop, fn l -> %{l | "body" => l["body"] ++ [%{"workflow" => workflow}]} end)
  end

  # Removes the entry at `at`, or at `at` in the loop at `loop`. A loop keeps at least one
  # workflow: the last one is not removed.
  @doc false
  def remove_entry(stage, at, nil),
    do: %{stage | "sequence" => List.delete_at(stage["sequence"], at)}

  def remove_entry(stage, at, loop) do
    update_loop(stage, loop, fn l ->
      if length(l["body"]) > 1, do: %{l | "body" => List.delete_at(l["body"], at)}, else: l
    end)
  end

  # A loop of 3 rounds with `workflow` in it, at the end of the sequence.
  @doc false
  def add_loop(stage, workflow) do
    loop = %{"loop" => %{"rounds" => @rounds, "body" => [%{"workflow" => workflow}]}}
    %{stage | "sequence" => stage["sequence"] ++ [loop]}
  end

  # Removes the loop at `at` and keeps its workflows in its place, in order.
  @doc false
  def remove_loop(stage, at) do
    case Enum.at(stage["sequence"], at) do
      %{"loop" => %{"body" => body}} ->
        {before, [_loop | rest]} = Enum.split(stage["sequence"], at)
        %{stage | "sequence" => before ++ body ++ rest}

      _other ->
        stage
    end
  end

  @doc false
  def has_loop?(stage), do: Enum.any?(stage["sequence"], &Map.has_key?(&1, "loop"))

  defp update_loop(stage, at, fun) do
    sequence =
      List.update_at(stage["sequence"], at, fn
        %{"loop" => loop} = entry -> %{entry | "loop" => fun.(loop)}
        entry -> entry
      end)

    %{stage | "sequence" => sequence}
  end

  ## Inputs and outputs

  @doc false
  def add_artifact(stage, key, type) when key in ["inputs", "outputs"],
    do: Map.update!(stage, key, &(&1 ++ [%{"type" => type, "required" => true}]))

  @doc false
  def remove_artifact(stage, key, at) when key in ["inputs", "outputs"],
    do: Map.update!(stage, key, &List.delete_at(&1, at))

  ## The panel's form

  # The stage with the values of the panel's form, `params`, merged in place: the form
  # changes values, never the shape, which the buttons change.
  @doc false
  def apply_form(stage, params) when is_map(params) do
    stage
    |> put_name(params["name"])
    |> put_description(params["description"])
    |> Map.update!("sequence", &merge_sequence(&1, params["sequence"]))
    |> Map.update!("inputs", &merge_artifacts(&1, params["inputs"]))
    |> Map.update!("outputs", &merge_artifacts(&1, params["outputs"]))
    |> Map.update!("gate", &merge_gate(&1, params["gate"]))
  end

  defp put_name(stage, name) when is_binary(name),
    do: %{stage | "name" => String.slice(name, 0, 60)}

  defp put_name(stage, _name), do: stage

  # A blank description removes the key, so a stage without one is as before. A browser
  # sends a textarea's line breaks as CRLF; the document keeps LF, no white space at the
  # start or the end, and at most 500 code points of whole graphemes
  # (`Apiary.Processes.description/1`).
  defp put_description(stage, text) when is_binary(text) do
    text = Apiary.Processes.description(text)

    if text == "",
      do: Map.delete(stage, "description"),
      else: Map.put(stage, "description", text)
  end

  defp put_description(stage, _text), do: stage

  defp merge_sequence(sequence, %{} = params) do
    if sequence_fits?(sequence, params) do
      for {entry, i} <- Enum.with_index(sequence) do
        case {entry, params[to_string(i)]} do
          {%{"loop" => loop}, %{} = p} ->
            body =
              for {e, j} <- Enum.with_index(loop["body"]),
                  do: merge_entry(e, p["body"][to_string(j)])

            %{
              entry
              | "loop" => %{
                  loop
                  | "rounds" => rounds(p["rounds"], loop["rounds"]),
                    "body" => body
                }
            }

          {entry, p} ->
            merge_entry(entry, p)
        end
      end
    else
      sequence
    end
  end

  defp merge_sequence(sequence, _params), do: sequence

  # Whether the form's rows have the sequence's shape: the same number of rows, with a loop
  # of the same number of workflows at the same places. Only the buttons change the shape.
  # A form that a reconnect recovers does not fit after an unsaved Remove or Remove loop,
  # because mount loads the saved rows; merged by place, its values would go to the wrong
  # rows. A keystroke sent after a button click and before its patch arrives has the old
  # shape too, so that event writes no rows, and the next change event sends the whole form.
  @doc false
  def sequence_fits?(sequence, %{} = params) do
    rows?(sequence, params) and
      sequence
      |> Enum.with_index()
      |> Enum.all?(fn {entry, i} -> entry_fits?(entry, params["#{i}"]) end)
  end

  defp entry_fits?(%{"loop" => %{"body" => body}}, %{"body" => %{} = form}), do: rows?(body, form)
  defp entry_fits?(%{"loop" => _loop}, _form), do: false
  defp entry_fits?(_entry, %{"body" => _form}), do: false
  defp entry_fits?(_entry, form), do: is_map(form)

  # Whether `form`'s keys are the places of `list`: "0", "1", and so on.
  defp rows?(list, form),
    do: MapSet.new(Map.keys(form)) == MapSet.new(0..(length(list) - 1)//1, &to_string/1)

  # A workflow name that breaks the schema's pattern keeps the entry's workflow, and the
  # page shows an error under the field (`workflow_name?/1`).
  defp merge_entry(entry, %{} = p) do
    entry =
      if workflow_name?(p["workflow"]),
        do: %{entry | "workflow" => p["workflow"]},
        else: entry

    case p["machine"] do
      nil ->
        entry

      text ->
        if String.trim(text) == "",
          do: Map.delete(entry, "machine"),
          else: Map.put(entry, "machine", String.trim(text))
    end
  end

  defp merge_entry(entry, _p), do: entry

  # Whether `text` is a workflow name the process schema takes
  # (`priv/schemas/process/v1.schema.json`, `workflow_name`): a lower-case letter, then up
  # to 54 lower-case letters, digits and hyphens.
  @doc false
  def workflow_name?(text) when is_binary(text), do: text =~ ~r/\A[a-z][a-z0-9-]{0,54}\z/
  def workflow_name?(_text), do: false

  # The machine types of the document's workflows that break the process schema's pattern
  # (`priv/schemas/process/v1.schema.json`, `machine`), each once: a lower-case letter, then
  # up to 63 lower-case letters, digits and hyphens.
  @doc false
  def invalid_machines(doc) do
    for stage <- doc["stages"],
        entry <- stage["sequence"],
        %{"machine" => machine} <- entry_workflows(entry),
        not machine?(machine),
        uniq: true,
        do: machine
  end

  # The sequence entry at a place such as `#/stages/1/sequence/0`, nil for another place.
  @doc false
  def entry_at(doc, path) do
    with [_all, stage, entry] <- Regex.run(~r{^#/stages/(\d+)/sequence/(\d+)}, path),
         %{"sequence" => sequence} <- Enum.at(doc["stages"] || [], String.to_integer(stage)) do
      Enum.at(sequence, String.to_integer(entry))
    else
      _other -> nil
    end
  end

  # The machine type at a place such as `#/stages/1/sequence/0/machine` or
  # `#/stages/1/sequence/2/loop/body/0/machine`, nil for another place.
  @doc false
  def machine_at(doc, path) do
    case {entry_at(doc, path), Regex.run(~r{/loop/body/(\d+)/machine$}, path)} do
      {%{"loop" => %{"body" => body}}, [_all, place]} ->
        (Enum.at(body, String.to_integer(place)) || %{})["machine"]

      {%{"machine" => machine}, nil} ->
        machine

      _other ->
        nil
    end
  end

  # Whether the entry is a loop with more workflows than the process schema takes
  # (`priv/schemas/process/v1.schema.json`, `loop_entry`).
  @doc false
  def loop_too_long?(%{"loop" => %{"body" => body}}), do: length(body) > 10
  def loop_too_long?(_entry), do: false

  # Whether a workflow of the sequence entry, or of any entry in the stage, has one of
  # the machine types in `machines`.
  @doc false
  def machine_in?(%{"sequence" => sequence}, machines),
    do: Enum.any?(sequence, &machine_in?(&1, machines))

  def machine_in?(entry, machines),
    do: Enum.any?(entry_workflows(entry), &(&1["machine"] in machines))

  defp entry_workflows(%{"loop" => %{"body" => body}}), do: body
  defp entry_workflows(entry), do: [entry]

  defp machine?(text), do: text =~ ~r/\A[a-z][a-z0-9-]{0,63}\z/

  defp rounds(text, previous), do: if(rounds?(text), do: String.to_integer(text), else: previous)

  # Whether a loop's rounds, as the form sends them, are a whole number from 1 to 10.
  @doc false
  def rounds?(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} -> n in 1..10
      _other -> false
    end
  end

  def rounds?(_text), do: false

  defp merge_artifacts(list, %{} = params) do
    if rows?(list, params) do
      for {item, i} <- Enum.with_index(list) do
        case params[to_string(i)] do
          %{} = p ->
            item =
              if is_binary(p["type"]) and p["type"] != "",
                do: %{item | "type" => p["type"]},
                else: item

            if is_binary(p["required"]),
              do: %{item | "required" => p["required"] == "true"},
              else: item

          _other ->
            item
        end
      end
    else
      list
    end
  end

  defp merge_artifacts(list, _params), do: list

  defp merge_gate(gate, %{"kind" => "none"}),
    do: gate |> Map.put("kind", "none") |> Map.delete("approvers")

  defp merge_gate(gate, %{"kind" => "person"} = p) do
    approvers =
      case p["approvers"] do
        "named" ->
          %{"members" => Enum.filter(List.wrap(p["named"]), &(is_binary(&1) and &1 != ""))}

        "members" ->
          "members"

        _other ->
          gate["approvers"] || "members"
      end

    gate |> Map.put("kind", "person") |> Map.put("approvers", approvers)
  end

  defp merge_gate(gate, _p), do: gate
end
