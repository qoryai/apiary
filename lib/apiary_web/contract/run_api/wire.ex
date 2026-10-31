defmodule ApiaryWeb.Contract.RunApi.Wire do
  @moduledoc false

  # The run API's answers as JSON, each member in a fixed order (`Jason.OrderedObject`),
  # from what the workflow model's modules return (`ApiaryWeb.Contract.RunApi.Boundary`).
  # Only the members listed here are written: a field the modules add is never sent to a
  # run until it is listed here.
  #
  # - `work_item/2`: the work item as a run reads it: the ticket, the instruction, the
  #   comments and the answers as Explore's input has them
  #   (`Apiary.Dispatches.Inputs.explore/4`, within its 768 KiB with the oldest comments
  #   left out), then the stage, its inputs, its outputs with each check result, the
  #   newest verdict with its gaps, the stage's gaps and the work item's notes.
  # - `index/1`: every artifact of the work item with its versions, each version's files,
  #   writer and approvals (`Apiary.Stages.artifact_index/1`).
  # - `version/3`: a version as a push returns it.
  #
  # A person is written by name, as Explore's input writes a person
  # (`Apiary.Dispatches.Inputs.person_name/1`); a run by its run id.

  import Ecto.Query, only: [from: 2]

  alias Apiary.Repo
  alias Apiary.Dispatches.{DispatchRun, Inputs}
  alias Apiary.Lingo.Domain
  alias ApiaryWeb.Contract.RunApi.Boundary

  @wire_version 1

  # The members of Explore's input that the work item's answer takes, in this order.
  @from_explore ~w(ticket instruction comments comments_omitted answers)

  @spec work_item(map, Jason.OrderedObject.t() | nil) ::
          {:ok, Jason.OrderedObject.t()} | {:error, :ticket_gone | :inputs_invalid}
  def work_item(%{run: run, dispatch_run: dispatch_run, work_item: work_item}, verdict) do
    explore =
      Inputs.explore(
        work_item,
        dispatch_run,
        %{domain: Domain.name(work_item.workspace), target: nil},
        Inputs.max_bytes()
      )

    with {:ok, inputs} <- explore do
      status = Boundary.status(work_item)
      stage = get(status, :stage)

      {:ok,
       object(
         [
           {"version", @wire_version},
           {"work_item",
            object([
              {"id", work_item.public_id},
              {"number", work_item.number},
              {"url", Apiary.WorkItems.stable_url(work_item)}
            ])},
           {"run",
            object([
              {"id", run.node_run_id},
              {"workflow", Boundary.workflow(dispatch_run)},
              {"round", Boundary.round(dispatch_run)}
            ])},
           {"stage",
            object([
              {"id", stage_value(stage, :id) || Boundary.stage_id(dispatch_run)},
              {"name", stage_value(stage, :name)},
              {"round", get(status, :round)},
              {"rounds", get(status, :rounds)},
              {"state", text(get(status, :state))}
            ])},
           {"inputs", Enum.map(Boundary.inputs(work_item) || [], &input/1)},
           {"outputs", Enum.map(get(status, :outputs) || [], &output/1)},
           {"verdict", verdict},
           {"gaps", get(status, :gaps)}
         ] ++
           Enum.filter(inputs.values, fn {key, _value} -> key in @from_explore end) ++
           [{"notes", notes(Boundary.notes(work_item))}]
       )}
    end
  end

  # The stage as `Apiary.Stages.status/1` returns it: the stage of the process document,
  # a map with its `id` and `name`, or its name alone.
  defp stage_value(stage, key) when is_map(stage), do: get(stage, key)
  defp stage_value(stage, :name) when is_binary(stage), do: stage
  defp stage_value(_stage, _key), do: nil

  defp input(input) do
    object([
      {"type", get(input, :type)},
      {"required", get(input, :required) == true},
      {"version", ref(get(input, :version))}
    ])
  end

  defp output(output) do
    object([
      {"type", get(output, :type)},
      {"required", get(output, :required) == true},
      {"version", ref(get(output, :version))},
      {"check", text(get(output, :check))}
    ])
  end

  # verdict/2 is the newest verdict as the work item's answer has it: its value, its gaps
  # and its version, or nil for none.
  @spec verdict(map | nil, map | nil) :: Jason.OrderedObject.t() | nil
  def verdict(nil, _content), do: nil

  def verdict(version, content) do
    content = if is_map(content), do: content, else: %{}

    object([
      {"verdict", Map.get(content, "verdict")},
      {"gaps", Map.get(content, "gaps")},
      {"version", ref(version)}
    ])
  end

  @spec index([map]) :: Jason.OrderedObject.t()
  def index(entries) do
    versions = Enum.flat_map(entries, &(get(&1, :versions) || []))
    approvals = Enum.flat_map(versions, &(get(&1, :approvals) || []))

    context = %{
      names: names(Enum.map(versions ++ approvals, &get(&1, :user_id))),
      runs: run_ids(Enum.map(versions, &get(&1, :run_id)))
    }

    object([
      {"version", @wire_version},
      {"artifacts", Enum.map(entries, &artifact(&1, context))}
    ])
  end

  defp artifact(entry, context) do
    object([
      {"type", get(entry, :type)},
      {"name", get(entry, :name)},
      {"stage_id", get(entry, :stage_id)},
      {"approved_version", get(entry, :approved_version)},
      {"newest_version", newest_number(get(entry, :versions) || [])},
      {"changed_after_approval", get(entry, :changed_after_approval) == true},
      {"versions", Enum.map(get(entry, :versions) || [], &index_version(&1, context))}
    ])
  end

  defp newest_number(versions) do
    versions
    |> Enum.map(&get(&1, :number))
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  defp index_version(version, context) do
    object([
      {"id", version_id(version)},
      {"number", get(version, :number)},
      {"writer", writer(version, context)},
      {"stage_id", get(version, :stage_id)},
      {"note", get(version, :note)},
      {"at", time(get(version, :inserted_at))},
      {"files", Enum.map(get(version, :files) || [], &file/1)},
      {"approvals", Enum.map(get(version, :approvals) || [], &approval(&1, context))}
    ])
  end

  # A version written by a run has the run's id, as the run's documents contain it; one
  # written by a person has the person's name.
  defp writer(version, context) do
    case text(get(version, :writer)) do
      "run" ->
        object([{"kind", "run"}, {"run_id", Map.get(context.runs, get(version, :run_id))}])

      "person" ->
        object([{"kind", "person"}, {"name", name(context, get(version, :user_id))}])

      _other ->
        nil
    end
  end

  defp file(file) do
    object([
      {"filename", get(file, :filename)},
      {"content_type", get(file, :content_type)},
      {"size", get(file, :size)},
      {"sha256", get(file, :sha256)}
    ])
  end

  defp approval(approval, context) do
    object([
      {"by", object([{"name", name(context, get(approval, :user_id))}])},
      {"stage_id", get(approval, :stage_id)},
      {"at", time(get(approval, :inserted_at))}
    ])
  end

  # notes/1 is the notes of the work item (`Apiary.Stages.notes/1`), oldest first: a
  # request for changes, an escalation resolved with a note, a move, an answer to a run's
  # questions and the gaps of failed checks that started a round.
  @spec notes([map]) :: [Jason.OrderedObject.t()]
  def notes(notes) do
    context = %{names: names(Enum.map(notes, &get(&1, :user_id)))}

    for note <- notes do
      object([
        {"kind", text(get(note, :kind))},
        {"stage_id", get(note, :stage_id)},
        {"by", by(note, context)},
        {"note", get(note, :note)},
        {"artifact_version_id", get(note, :artifact_version_id)},
        {"at", time(get(note, :inserted_at))}
      ])
    end
  end

  # A failed check has no person.
  defp by(note, context) do
    if text(get(note, :kind)) == "check",
      do: nil,
      else: object([{"name", name(context, get(note, :user_id))}])
  end

  # The name of each person, read once per id (`Apiary.Dispatches.Inputs.person_name/1`).
  defp names(user_ids) do
    user_ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Map.new(&{&1, Inputs.person_name(&1)})
  end

  defp name(context, user_id), do: Map.get(context.names, user_id, Inputs.former_member())

  # The run id of each run of the queue, as the run's documents contain it, by the row's
  # id, which `Apiary.Artifacts` keeps on a version.
  defp run_ids(ids) do
    case ids |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        Repo.all(from d in DispatchRun, where: d.id in ^ids, select: {d.id, d.run_id})
        |> Map.new()
    end
  end

  @spec version(map, String.t(), String.t()) :: Jason.OrderedObject.t()
  def version(version, type, name) do
    object([
      {"version", @wire_version},
      {"artifact",
       object([
         {"type", type},
         {"name", name},
         {"version", ref(version)}
       ])}
    ])
  end

  defp ref(nil), do: nil

  defp ref(version) when is_map(version),
    do: object([{"id", version_id(version)}, {"number", get(version, :number)}])

  defp ref(_version), do: nil

  # A version's public id (`av_...`): `public_id` of `Apiary.Artifacts.Version`, or `id`
  # of the maps `Apiary.Stages` returns.
  defp version_id(version), do: get(version, :public_id) || get(version, :id)

  # A field of a map or a struct by its atom key, or by its name where the map is keyed
  # by strings.
  defp get(nil, _key), do: nil

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_value, _key), do: nil

  defp text(nil), do: nil
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp time(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> time()

  defp time(_value), do: nil

  defp object(pairs), do: Jason.OrderedObject.new(pairs)
end
