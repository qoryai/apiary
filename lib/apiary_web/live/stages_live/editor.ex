defmodule ApiaryWeb.StagesLive.Editor do
  # The edits of a process document on the Stages canvas and its inspector, for every
  # page that edits one: the Stages page and Instance settings › Workspace types. The
  # page's socket has `draft` (the document), `selected` (a stage's id), `declared` (the
  # workflows offered), `types` (the artifact types offered, each with a `name`),
  # `notice`, `save_note`, `save_errors`, `stage_errors` and `rounds_errors`. Each
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
  # the field: the form is novalidate, so the browser does not check them.
  def edit_event("edit_stage", %{"stage" => params}, socket, refresh) when is_map(params) do
    socket = edit_selected(socket, &Draft.apply_form(&1, params), refresh)
    assign(socket, rounds_errors: rounds_errors(params))
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
  # an unchanged document next to Save, and every other error above the canvas.
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

    first =
      Enum.find_value(draft["stages"], socket.assigns.selected, fn stage ->
        Map.has_key?(stage_errors, stage["id"]) && stage["id"]
      end)

    socket
    |> assign(
      stage_errors: stage_errors,
      save_note: if(unchanged != [], do: Words.refusal(hd(unchanged), draft)),
      save_errors: rest |> Enum.map(&Words.refusal(&1, draft)) |> Enum.uniq(),
      selected: first
    )
    |> refresh.()
  end

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
        rounds_errors: %{}
      )
      |> refresh.()

  defp rounds_errors(%{"sequence" => %{} = sequence}) do
    for {i, %{"rounds" => text}} <- sequence, not Draft.rounds?(text), into: %{} do
      {i, Words.rounds_refused()}
    end
  end

  defp rounds_errors(_params), do: %{}

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

  defp first_workflow(socket), do: List.first(socket.assigns.declared) || "explore-a-ticket"
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
