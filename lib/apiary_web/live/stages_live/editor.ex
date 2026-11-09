defmodule ApiaryWeb.StagesLive.Editor do
  # The edits of a process document on the Stages canvas and its inspector, for every
  # page that edits one: the Workflows page and Instance settings › Workspace types. The
  # page's socket has `draft` (the document), `selected` (a stage's id), `declared` (the
  # workflows offered), `types` (the artifact types offered, each with a `name`),
  # `notice`, `save_note`, `save_errors`, `stage_errors`, `rounds_errors`,
  # `workflow_errors`, `refused_machines` and `machine_types`. Each
  # function takes the page's `refresh`, which checks the draft and pushes the canvas's
  # view ("stages:view").
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  import Phoenix.Component, only: [assign: 2]

  alias Apiary.Processes
  alias ApiaryWeb.StagesLive.{Draft, Words}

  @events ~w(reorder move add_stage remove_stage edit_stage edit_process add_entry
             remove_entry add_loop remove_loop add_artifact remove_artifact)

  @doc false
  # The events `edit_event/4` takes.
  def events, do: @events

  @doc false
  # edit_event/4 is the socket after the edit `event`, with `params`, of the canvas or the
  # inspector.
  def edit_event("reorder", %{"ids" => ids}, socket, refresh),
    do: edit(socket, &Draft.reorder(&1, ids), refresh)

  def edit_event("move", %{"id" => id, "by" => by}, socket, refresh) when by in ["-1", "1"],
    do: edit(socket, &Draft.move(&1, id, String.to_integer(by)), refresh)

  # A "+" on the canvas: a new stage at place `at`, after the stage before it.
  def edit_event("add_stage", params, socket, refresh) do
    draft = socket.assigns.draft
    {draft, id} = Draft.add_stage(draft, new_name(draft), at(params["at"]))

    socket |> assign(draft: draft, selected: id, save_errors: [], notice: nil) |> refresh.()
  end

  def edit_event("remove_stage", %{"id" => id}, socket, refresh) do
    socket = edit(socket, &Draft.remove_stage(&1, id), refresh)

    selected =
      if Processes.stage(socket.assigns.draft, socket.assigns.selected),
        do: socket.assigns.selected,
        else: first_id(socket.assigns.draft)

    socket |> assign(selected: selected) |> refresh.()
  end

  # A loop's rounds outside 1 to 10 keep the rounds the loop had, and show an error under
  # the field: the form is novalidate, so the browser does not check them. A workflow name
  # that breaks the schema's pattern keeps the entry's workflow the same way.
  #
  # The form's values go to the stage in its `id`, which becomes the selected stage. After a
  # reconnect, mount selects the first stage and LiveView's form recovery then sends the
  # form as it stood, for the stage it showed. With no such stage in the draft, such as an
  # unsaved stage that the reconnect lost, the values are ignored. So are a recovered form's
  # rows that do not fit the stage's (`Draft.sequence_fits?/2`), with their errors.
  def edit_event("edit_stage", %{"stage" => params}, socket, refresh) when is_map(params) do
    case Processes.stage(socket.assigns.draft, params["id"]) do
      nil ->
        socket

      stage ->
        form = if fits?(stage, params), do: params, else: %{}

        socket
        |> assign(selected: params["id"])
        |> edit_selected(&Draft.apply_form(&1, params), refresh)
        |> assign(rounds_errors: rounds_errors(form), workflow_errors: workflow_errors(form))
    end
  end

  def edit_event("edit_process", %{"process" => %{"machine" => machine}}, socket, refresh),
    do: edit(socket, &Draft.put_machine(&1, machine), refresh)

  def edit_event("add_entry", params, socket, refresh),
    do:
      edit_selected(
        socket,
        &Draft.add_entry(&1, first_workflow(socket), at(params["loop"])),
        refresh
      )

  def edit_event("remove_entry", params, socket, refresh),
    do:
      edit_selected(
        socket,
        &Draft.remove_entry(&1, at(params["at"]), at(params["loop"])),
        refresh
      )

  def edit_event("add_loop", _params, socket, refresh),
    do: edit_selected(socket, &Draft.add_loop(&1, first_workflow(socket)), refresh)

  def edit_event("remove_loop", %{"at" => at}, socket, refresh),
    do: edit_selected(socket, &Draft.remove_loop(&1, at(at)), refresh)

  def edit_event("add_artifact", %{"key" => key}, socket, refresh)
      when key in ["inputs", "outputs"],
      do: edit_selected(socket, &Draft.add_artifact(&1, key, first_type(socket)), refresh)

  def edit_event("remove_artifact", %{"key" => key, "at" => at}, socket, refresh)
      when key in ["inputs", "outputs"],
      do: edit_selected(socket, &Draft.remove_artifact(&1, key, at(at)), refresh)

  @doc false
  # The id of the document's first stage, nil for none.
  def first_id(%{"stages" => [%{"id" => id} | _]}), do: id
  def first_id(_doc), do: nil

  @doc false
  # refused_document/3 shows the errors of a refused save of the draft. A duplicate id or
  # name shows next to the name of the stage it is in (the first such stage is selected),
  # an unchanged document next to Save, and every other error above the canvas. The schema
  # reports a workflow's machine type at its entry (`oneOf`), so `refused_machines` comes
  # from the values, plus the type at each `:unknown_machine_type` error: each shows on the
  # rows with that value, where a fold may be closed.
  # With no such duplicate, the selected stage stays if a refused value is in it, and
  # otherwise the first stage with a refused value is selected, so its marks show. The
  # instance's machine types are read again, so the pickers drop a type removed since mount.
  def refused_document(socket, errors, refresh) do
    draft = socket.assigns.draft
    errors = most_specific(errors)

    # A duplicate, and any error in a stage's name, show next to that name.
    {at_stage, rest} =
      Enum.split_with(
        errors,
        &(&1.error in [:duplicate_stage_id, :duplicate_stage_name] or
            Regex.match?(~r{^#/stages/\d+/name$}, &1.path))
      )

    {unchanged, rest} = Enum.split_with(rest, &(&1.error == :unchanged))

    refused_machines = Enum.uniq(Draft.invalid_machines(draft) ++ unknown_machines(draft, errors))

    refused_stages = Enum.map(rest, &stage_at(draft, &1.path))

    # A refused machine type has its line from `banner/1`, while its rows show the mark.
    rest = Enum.reject(rest, &refused_machine?(&1.path, draft, refused_machines))

    stage_errors =
      Enum.reduce(at_stage, %{}, fn error, acc ->
        case stage_at(draft, error.path) do
          nil ->
            acc

          id ->
            Map.update(
              acc,
              id,
              [Words.refusal(error, draft)],
              &(&1 ++ [Words.refusal(error, draft)])
            )
        end
      end)

    selected = socket.assigns.selected

    first =
      Enum.find_value(draft["stages"], fn stage ->
        Map.has_key?(stage_errors, stage["id"]) && stage["id"]
      end) || if(selected in refused_stages, do: selected) ||
        Enum.find_value(draft["stages"], selected, &(&1["id"] in refused_stages && &1["id"]))

    socket
    |> field_errors_of(first)
    |> assign(
      stage_errors: stage_errors,
      refused_machines: refused_machines,
      machine_types: Apiary.MachineTypes.list(),
      save_note: if(unchanged != [], do: Words.refusal(hd(unchanged), draft)),
      save_errors: rest |> Enum.map(&Words.refusal(&1, draft)) |> Enum.uniq(),
      selected: first
    )
    |> refresh.()
  end

  defp unknown_machines(draft, errors) do
    for %{error: :unknown_machine_type, path: path} <- errors,
        machine = Draft.machine_at(draft, path),
        do: machine
  end

  # The error lines above the canvas: those of the last save, then one for each stage whose
  # rows show a refused machine type, so a line goes when its last mark goes.
  @doc false
  def banner(%{save_errors: errors, draft: draft, refused_machines: refused}) do
    marked =
      for stage <- draft["stages"],
          Draft.machine_in?(stage, refused),
          do: Words.fields_marked(stage["name"])

    Enum.uniq(errors ++ marked)
  end

  # Whether the error at `path` is a refused machine type alone. The schema reports that at
  # the sequence entry (`oneOf`), as it does a loop that is too long.
  defp refused_machine?(path, draft, refused) do
    case Draft.entry_at(draft, path) do
      %{} = entry -> Draft.machine_in?(entry, refused) and not Draft.loop_too_long?(entry)
      _other -> false
    end
  end

  # The rounds and workflow errors are by place on the selected stage, so another stage
  # starts without them, as it does when a person selects it.
  defp field_errors_of(%{assigns: %{selected: selected}} = socket, selected), do: socket

  defp field_errors_of(socket, _selected),
    do: assign(socket, rounds_errors: %{}, workflow_errors: %{})

  # JSV also reports each place above a wrong value (`#`, `#/stages`, `#/stages/0` for a
  # wrong `#/stages/0/name`), which says no more than "a value is not valid"; only the
  # deepest error of each place is shown.
  defp most_specific(errors) do
    Enum.reject(errors, fn error ->
      Enum.any?(errors, &String.starts_with?(&1.path, error.path <> "/"))
    end)
  end

  # The id of the stage at a place such as `#/stages/1/name`.
  defp stage_at(draft, path) do
    case Regex.run(~r{^#/stages/(\d+)/}, path) do
      [_all, index] -> (Enum.at(draft["stages"], String.to_integer(index)) || %{})["id"]
      nil -> nil
    end
  end

  defp edit(socket, fun, refresh),
    do:
      socket
      |> assign(
        draft: fun.(socket.assigns.draft),
        notice: nil,
        save_note: nil,
        rounds_errors: %{},
        workflow_errors: %{}
      )
      |> refresh.()

  # Each workflow field whose name breaks the pattern, by its entry's place: "0" for the
  # first entry, "1-0" for the first workflow of a loop in the second.
  defp workflow_errors(%{"sequence" => %{} = sequence}) do
    for {i, entry} <- sequence,
        is_map(entry),
        {place, name} <- workflow_names(i, entry),
        not Draft.workflow_name?(name),
        into: %{},
        do: {place, Words.workflow_refused()}
  end

  defp workflow_errors(_params), do: %{}

  defp workflow_names(i, %{"body" => %{} = body}),
    do: for({j, %{"workflow" => name}} <- body, do: {"#{i}-#{j}", name})

  defp workflow_names(i, %{"workflow" => name}), do: [{i, name}]
  defp workflow_names(_i, _entry), do: []

  defp rounds_errors(%{"sequence" => %{} = sequence}) do
    for {i, %{"rounds" => text}} <- sequence, not Draft.rounds?(text), into: %{} do
      {i, Words.rounds_refused()}
    end
  end

  defp rounds_errors(_params), do: %{}

  defp fits?(stage, %{"sequence" => %{} = form}),
    do: Draft.sequence_fits?(stage["sequence"], form)

  defp fits?(_stage, _params), do: true

  defp edit_selected(%{assigns: %{selected: nil}} = socket, _fun, _refresh), do: socket

  defp edit_selected(socket, fun, refresh),
    do: edit(socket, &Draft.update_stage(&1, socket.assigns.selected, fun), refresh)

  defp at(nil), do: nil

  defp at(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 -> n
      _other -> nil
    end
  end

  # The first workflow offered, else the first of the Qory harness at the commit the
  # workspace's harness settings choose (`Apiary.Harnesses.Qory.workspace_commit/1`), at
  # `main`'s on a page of no workspace.
  defp first_workflow(socket) do
    commit =
      case socket.assigns do
        %{current_scope: %{workspace: %Apiary.Organisations.Workspace{} = workspace}} ->
          Apiary.Harnesses.Qory.workspace_commit(workspace)

        _no_workspace ->
          Apiary.Harnesses.Qory.current()
      end

    List.first(socket.assigns.declared) ||
      List.first(Apiary.Processes.qory_workflows(commit))
  end

  defp first_type(socket), do: List.first(socket.assigns.types).name

  defp new_name(doc) do
    names = MapSet.new(doc["stages"], & &1["name"])

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> gettext("New stage")
      n -> gettext("New stage %{number}", number: n)
    end)
    |> Enum.find(&(not MapSet.member?(names, &1)))
  end
end
