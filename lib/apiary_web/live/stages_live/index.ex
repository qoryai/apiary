defmodule ApiaryWeb.StagesLive.Index do
  # Workspace settings › Stages (`/:org/:workspace/settings/stages`), with the feature
  # `workflow_model` (decision D2): the workspace's process (`Apiary.Processes`), the
  # stages every work item goes through, edited on a canvas. Not found while
  # `workflow_model` is off. With the feature, the sidebar's Stages entry leads here, and
  # the Workflow page keeps the harness choice that "Change" opens.
  #
  # The canvas is the editor (`assets/js/canvas.js`, React Flow, through the hook
  # `assets/js/hooks/stages_canvas.js`): it sends a selection, an order of stages, a move
  # by the arrow keys and a "+" (add_stage) as events; the inspector under it edits the
  # selected stage. The page is the only writer of the document, and every save goes
  # through `Apiary.Processes.save/4`, which checks the document against its schema.
  #
  # Owners and admins (`process.edit`) edit; members read the page with no edit controls.
  #
  # The workflow picker offers `Apiary.Processes.declared_workflows/1`. Once the page is
  # connected, for whoever may save the harness (`harness.save`), it reads the workspace's
  # saved harness source again (`Apiary.Stacks.Sources.read/2`, outside the page's
  # process) and records the workflows of the stack the saved document extends, as the
  # Workflow page does; a read that fails keeps the list of the last read, with its error.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :workflow_model

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Organisations, Processes, Repo, WorkItems}
  alias Apiary.Stacks.{Document, Sources}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.{People, SettingsComponents}
  alias ApiaryWeb.StagesLive.{ArtifactTypes, Draft, Words}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    workspace = scope.workspace
    members = Organisations.list_workspace_members(scope)

    unless Apiary.Access.can?(scope, :"work_item.read", workspace),
      do: raise(ApiaryWeb.Features.NotFound)

    current = Processes.current(workspace)

    socket =
      socket
      |> assign(
        page_title: SettingsComponents.page_title(scope, :workspace, [gettext("Stages")]),
        sections: SettingsComponents.sections(scope, :workspace),
        may: Apiary.Access.can?(scope, :"process.edit", workspace),
        harness: harness_name(Sources.chosen(workspace)),
        may_harness: Apiary.Access.can?(scope, :"harness.save", workspace),
        declared: Processes.declared_workflows(workspace),
        snapshot: Processes.declared_snapshot(workspace),
        harness_source: nil,
        declared_error: nil,
        types: ArtifactTypes.types(workspace),
        members: members,
        people: Map.new(members, &{&1.user.id, People.short(People.email(&1.user))}),
        work_items: [],
        assign_errors: [],
        save_errors: [],
        stage_errors: %{},
        save_note: nil,
        rounds_errors: %{},
        assigned: nil,
        notice: nil
      )
      |> load(current)
      |> load_work_items()
      |> read_declared(Sources.current(workspace))

    {:ok, socket}
  end

  ## The harness's workflows

  # The saved harness source read again once the page is connected, for whoever may save
  # the harness: the source of the base the workspace's saved document extends, and no
  # other. With no saved document, or one with no base, nothing is read.
  defp read_declared(socket, %{base: %{} = base}) do
    if connected?(socket) and socket.assigns.may_harness do
      scope = socket.assigns.current_scope
      source = saved_source(base)

      socket
      |> assign(harness_source: %{source: source, base: base})
      |> start_async(:declared, fn -> Sources.read(scope, source) end)
    else
      socket
    end
  end

  defp read_declared(socket, _none), do: socket

  # The source a document's base is read from: its address and version, narrowed to its
  # folder where it has one, as a source the Workflow page offers
  # (`t:Apiary.Stacks.Sources.source/0`). A base with a stack name is read at the root,
  # every stack the root exports, as the Workflow page reads a connected repository; the
  # base then picks its stack.
  defp saved_source(base) do
    %{
      id: "saved",
      kind: :address,
      label: Document.shown(base["git"]),
      git: base["git"],
      ref: base["ref"],
      narrowing: Map.take(base, ["path"]),
      location: nil,
      version: nil,
      stacks: nil
    }
  end

  @impl true
  def handle_async(:declared, {:ok, {:ok, stacks}}, socket) when is_list(stacks) do
    workspace = socket.assigns.current_scope.workspace
    base = socket.assigns.harness_source.base

    # Only the stack the saved document extends, as the Workflow page records it
    # (`ApiaryWeb.WorkflowLive`); with none, nothing is recorded. A harness saved while
    # the read ran has a newer snapshot, which this read does not replace.
    with %{base: ^base} <- Sources.current(workspace),
         %{workflows: workflows} <- Enum.find(stacks, &(&1.base == base)) do
      :ok = Processes.record_declared(workspace, workflows)
    end

    {:noreply,
     socket
     |> assign(
       declared: Processes.declared_workflows(workspace),
       snapshot: Processes.declared_snapshot(workspace),
       declared_error: nil
     )
     |> refresh()}
  end

  def handle_async(:declared, {:ok, {:error, reason}}, socket),
    do: {:noreply, declared_failed(socket, reason)}

  def handle_async(:declared, {:ok, other}, socket),
    do: {:noreply, declared_failed(socket, other)}

  def handle_async(:declared, {:exit, _reason}, socket),
    do: {:noreply, declared_failed(socket, :exited)}

  # The list of the last read stays; the line under it gives the cause, in the words the
  # Workflow page uses for a read that failed.
  defp declared_failed(socket, reason) do
    words =
      ApiaryWeb.HarnessComponents.read_words(
        reason,
        socket.assigns.harness_source.source,
        socket.assigns.current_scope.organisation.name
      )

    assign(socket, declared_error: words)
  end

  # The editor on `version`: its document as the draft, its first stage selected.
  defp load(socket, version) do
    workspace = socket.assigns.current_scope.workspace

    socket
    |> assign(
      versions: Processes.list_versions(workspace),
      base: version,
      draft: version.document,
      selected: first_id(version.document),
      stage_errors: %{},
      save_note: nil
    )
    |> authors()
    |> refresh()
  end

  # The harness of the workspace's runs, as the Workflow page names it.
  defp harness_name(%{choice: :qory}), do: gettext("Qory harness")
  defp harness_name(chosen), do: ApiaryWeb.HarnessComponents.chosen_line(chosen)

  defp first_id(%{"stages" => [%{"id" => id} | _]}), do: id
  defp first_id(_doc), do: nil

  defp load_work_items(socket) do
    scope = socket.assigns.current_scope

    # The open work items of the list's first page, newest first, each with the version it
    # runs under. By creation, so an assign, which changes a work item, keeps the order.
    items =
      if socket.assigns.may do
        for row <- WorkItems.list_work_items(scope, %{sort: :created}).rows,
            item = WorkItems.get_by_public_id(scope, row.id),
            item != nil,
            do: item
      else
        []
      end

    assign(socket, work_items: items)
  end

  # The check and the canvas follow every change of the draft.
  defp refresh(socket) do
    %{draft: draft, declared: declared, types: types} = socket.assigns
    # Every workflow writes any type until the harness declares `writes` (spec addition 9),
    # so an output that nothing writes is not listed.
    problems =
      draft
      |> Processes.placement_check(declared, types)
      |> Enum.reject(&match?({:output_not_written, _id, _type}, &1))

    socket = assign(socket, problems: problems)
    push_event(socket, "stages:view", view(socket.assigns))
  end

  # What the canvas draws: each stage's name and lines, as text.
  defp view(assigns) do
    %{
      editable: assigns.may,
      selected: assigns.selected,
      first:
        case assigns.draft["stages"] do
          [first | _] -> Words.add_before(first["name"])
          [] -> nil
        end,
      stages:
        for stage <- assigns.draft["stages"] do
          %{
            id: stage["id"],
            name: stage["name"],
            label: Words.card_label(stage, assigns.people),
            sequence: Words.card_sequence(stage),
            gate: Words.gate_line(stage, assigns.people),
            add: Words.add_after(stage["name"]),
            alerts:
              alerts(assigns.problems, stage) ++ Map.get(assigns.stage_errors, stage["id"], [])
          }
        end
    }
  end

  defp alerts(problems, stage) do
    for {:missing_workflow, id, name} <- problems,
        id == stage["id"],
        do: Words.undeclared(stage["name"], name)
  end

  ## Events

  @impl true
  def handle_event("select", %{"id" => id}, socket) when is_binary(id) do
    if Processes.stage(socket.assigns.draft, id),
      do: {:noreply, socket |> assign(selected: id, rounds_errors: %{}) |> refresh()},
      else: {:noreply, socket}
  end

  def handle_event(_event, _params, %{assigns: %{may: false}} = socket) do
    {:noreply, put_flash(socket, :error, Words.refusal(:forbidden, nil))}
  end

  def handle_event("reorder", %{"ids" => ids}, socket),
    do: {:noreply, edit(socket, &Draft.reorder(&1, ids))}

  def handle_event("move", %{"id" => id, "by" => by}, socket) when by in ["-1", "1"],
    do: {:noreply, edit(socket, &Draft.move(&1, id, String.to_integer(by)))}

  # A "+" on the canvas: a new stage at place `at`, after the stage before it.
  def handle_event("add_stage", params, socket) do
    draft = socket.assigns.draft
    {draft, id} = Draft.add_stage(draft, new_name(draft), at(params["at"]))

    {:noreply,
     socket |> assign(draft: draft, selected: id, save_errors: [], notice: nil) |> refresh()}
  end

  def handle_event("remove_stage", %{"id" => id}, socket) do
    socket = edit(socket, &Draft.remove_stage(&1, id))

    selected =
      if Processes.stage(socket.assigns.draft, socket.assigns.selected),
        do: socket.assigns.selected,
        else: first_id(socket.assigns.draft)

    {:noreply, socket |> assign(selected: selected) |> refresh()}
  end

  # A loop's rounds outside 1 to 10 keep the rounds the loop had, and show an error under
  # the field: the form is novalidate, so the browser does not check them.
  def handle_event("edit_stage", %{"stage" => params}, socket) when is_map(params) do
    socket = edit_selected(socket, &Draft.apply_form(&1, params))
    {:noreply, assign(socket, rounds_errors: rounds_errors(params))}
  end

  def handle_event("edit_process", %{"process" => %{"machine" => machine}}, socket),
    do: {:noreply, edit(socket, &Draft.put_machine(&1, machine))}

  def handle_event("add_entry", params, socket),
    do:
      {:noreply,
       edit_selected(socket, &Draft.add_entry(&1, first_workflow(socket), at(params["loop"])))}

  def handle_event("remove_entry", params, socket),
    do:
      {:noreply,
       edit_selected(socket, &Draft.remove_entry(&1, at(params["at"]), at(params["loop"])))}

  def handle_event("add_loop", _params, socket),
    do: {:noreply, edit_selected(socket, &Draft.add_loop(&1, first_workflow(socket)))}

  def handle_event("remove_loop", %{"at" => at}, socket),
    do: {:noreply, edit_selected(socket, &Draft.remove_loop(&1, at(at)))}

  def handle_event("add_artifact", %{"key" => key}, socket) when key in ["inputs", "outputs"],
    do: {:noreply, edit_selected(socket, &Draft.add_artifact(&1, key, first_type(socket)))}

  def handle_event("remove_artifact", %{"key" => key, "at" => at}, socket)
      when key in ["inputs", "outputs"],
      do: {:noreply, edit_selected(socket, &Draft.remove_artifact(&1, key, at(at)))}

  def handle_event("discard", _params, socket),
    do: {:noreply, socket |> fresh() |> load(socket.assigns.base)}

  def handle_event("save", params, socket) do
    socket = fresh(socket)
    %{current_scope: scope, draft: draft} = socket.assigns
    trial? = params["trial"] == "true"

    case save(scope, draft, trial?, socket.assigns.base) do
      {:ok, version} ->
        notice =
          if trial?,
            do:
              gettext("Saved as version %{number}, a trial. Assign work items to it below.",
                number: version.number
              ),
            else:
              gettext("Saved as version %{number}. Work items taken in from now on use it.",
                number: version.number
              )

        {:noreply, socket |> assign(save_errors: [], notice: notice) |> load(version)}

      {:error, {:trial_exists, trial}} ->
        {:noreply, socket |> reload() |> assign(save_errors: [Words.trial_exists(trial)])}

      {:error, errors} when is_list(errors) ->
        {:noreply, refused_document(socket, errors)}

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("assign", params, socket) do
    socket = fresh(socket)
    %{current_scope: scope, work_items: items} = socket.assigns

    case trial(socket.assigns.versions) do
      nil ->
        {:noreply, socket}

      trial ->
        chosen = List.wrap(get_in(params, ["assign", "items"]))

        results =
          for item <- items, item.public_id in chosen do
            case Processes.assign(scope, item, trial) do
              {:ok, _item} ->
                if item.process_version_id == trial.id, do: :kept, else: :assigned

              {:error, {:missing_stage, stage_id}} ->
                {:missing, missing_stage(item, stage_id, trial)}

              {:error, reason} ->
                {:refused, reason}
            end
          end

        case for({:refused, reason} <- results, do: reason) do
          [] ->
            {:noreply,
             socket
             |> assign(
               assign_errors: for({:missing, error} <- results, do: error),
               assigned: assigned(Enum.count(results, &(&1 == :assigned)), trial)
             )
             |> load_work_items()}

          [reason | _] ->
            {:noreply, refused(socket, reason)}
        end
    end
  end

  def handle_event("make_current", _params, socket) do
    socket = fresh(socket)
    scope = socket.assigns.current_scope

    with %{} = trial <- trial(socket.assigns.versions),
         {:ok, version} <- Processes.make_current(scope, trial) do
      notice =
        gettext("Version %{number} is now current. Work items taken in from now on use it.",
          number: version.number
        )

      {:noreply, socket |> assign(notice: notice, assign_errors: []) |> load(version)}
    else
      nil -> {:noreply, socket}
      {:error, reason} -> {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("drop_trial", _params, socket) do
    socket = fresh(socket)
    scope = socket.assigns.current_scope

    case trial(socket.assigns.versions) do
      nil ->
        {:noreply, socket}

      trial ->
        had_items? = Repo.exists?(from w in WorkItem, where: w.process_version_id == ^trial.id)

        case Processes.drop_trial(scope, trial) do
          {:ok, version} ->
            notice =
              if had_items?,
                do:
                  gettext(
                    "Dropped version %{number}. Its work items are back on the current version.",
                    number: version.number
                  ),
                else: gettext("Dropped version %{number}.", number: version.number)

            current = Processes.current(scope.workspace)

            {:noreply,
             socket
             |> assign(notice: notice, assign_errors: [])
             |> load(current)
             |> load_work_items()}

          {:error, {:missing_stage, stage_id}} ->
            {:noreply, assign(socket, assign_errors: not_dropped(socket, trial, stage_id))}

          {:error, reason} ->
            {:noreply, refused(socket, reason)}
        end
    end
  end

  # A document Apiary.Processes.save/4 refused. A duplicate id or name shows next to the
  # name of the stage it is in (the first such stage is selected), an unchanged document
  # next to Save, and every other error above the canvas.
  defp refused_document(socket, errors) do
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
    |> refresh()
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

  # The accounts of the versions' authors, by user id (`ApiaryWeb.People.accounts/1`).
  defp authors(socket),
    do:
      assign(socket, authors: People.accounts(Enum.map(socket.assigns.versions, & &1.author_id)))

  # Each action starts with no message from an earlier one.
  defp fresh(socket),
    do:
      assign(socket,
        notice: nil,
        save_errors: [],
        save_note: nil,
        assign_errors: [],
        assigned: nil
      )

  defp assigned(0, _trial), do: nil

  defp assigned(count, trial),
    do:
      ngettext(
        "Assigned %{count} work item to version %{number}.",
        "Assigned %{count} work items to version %{number}.",
        count,
        number: trial.number
      )

  # One trial at a time (the canvas edits one): a trial save while the workspace has a
  # trial, made on this page or elsewhere, is refused here, as Apiary.Processes allows several.
  defp save(scope, draft, true, base) do
    with :ok <- Apiary.Access.check(scope, :"process.edit", scope.workspace),
         nil <- trial(Processes.list_versions(scope.workspace)) do
      Processes.save(scope, scope.workspace, draft, trial: true, based_on: base)
    else
      %Processes.Version{} = trial -> {:error, {:trial_exists, trial}}
      error -> error
    end
  end

  defp save(scope, draft, false, base),
    do: Processes.save(scope, scope.workspace, draft, trial: false, based_on: base)

  # A refusal of Apiary.Processes that is no error in the document. `:forbidden` is the
  # person's role; any other reason (a trial dropped or made current in another tab, a
  # version gone) means the page is behind, so it reads the versions and work items again.
  defp refused(socket, :forbidden),
    do: assign(socket, save_errors: [Words.refusal(:forbidden, nil)])

  defp refused(socket, _reason),
    do: socket |> reload() |> assign(save_errors: [Words.stale()])

  defp reload(socket) do
    versions = Processes.list_versions(socket.assigns.current_scope.workspace)

    socket
    |> assign(versions: versions, assign_errors: [])
    |> authors()
    |> refresh()
    |> load_work_items()
  end

  # The trial was not dropped: each of its work items in a stage that the current version
  # does not have, with the stage's name from the trial.
  defp not_dropped(socket, trial, stage_id) do
    current = Processes.current(socket.assigns.current_scope.workspace)

    stuck =
      for item <- socket.assigns.work_items,
          item.process_version_id == trial.id,
          item.stage_id != nil,
          Processes.stage(current, item.stage_id) == nil,
          do: item

    stuck = if stuck == [], do: [%{number: nil, title: nil, stage_id: stage_id}], else: stuck

    for item <- stuck do
      Words.not_dropped(
        item,
        (Processes.stage(trial, item.stage_id) || %{})["name"] || gettext("a removed stage")
      )
    end
  end

  defp edit(socket, fun),
    do:
      socket
      |> assign(
        draft: fun.(socket.assigns.draft),
        notice: nil,
        save_note: nil,
        rounds_errors: %{}
      )
      |> refresh()

  defp rounds_errors(%{"sequence" => %{} = sequence}) do
    for {i, %{"rounds" => text}} <- sequence, not Draft.rounds?(text), into: %{} do
      {i, Words.rounds_refused()}
    end
  end

  defp rounds_errors(_params), do: %{}

  defp edit_selected(%{assigns: %{selected: nil}} = socket, _fun), do: socket

  defp edit_selected(socket, fun),
    do: edit(socket, &Draft.update_stage(&1, socket.assigns.selected, fun))

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

  # The workflows the harness declares (`Apiary.Processes.declared_workflows/1`). A
  # workflow it no longer declares stays shown as the entry's value, and cannot be chosen.
  defp workflow_options(declared, workflow) do
    if workflow in declared,
      do: declared,
      else: declared ++ [[key: workflow, value: workflow, disabled: true]]
  end

  # The newest trial: Apiary.Processes allows several, and the page edits one.
  defp trial(versions), do: Enum.find(versions, &(&1.status == :trial))

  defp missing_stage(item, stage_id, trial) do
    stage = Processes.stage(Processes.version_for(item), stage_id) || %{"name" => stage_id}

    gettext(
      "Work item %{number}, %{title}, stays on its version: its stage %{stage} is not in version %{version}.",
      number: item.number,
      title: item.title,
      stage: stage["name"],
      version: trial.number
    )
  end

  ## Render

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        stage: Processes.stage(assigns.draft, assigns.selected),
        dirty: assigns.draft != assigns.base.document,
        trial: trial(assigns.versions),
        workspace: assigns.current_scope.workspace.name
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      sections={@sections}
      section={:stages}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:workspace}
        current={:stages}
        measure="list"
        title={gettext("Stages")}
      >
        <:subtitle>
          {gettext(
            "Every work item of %{workspace} goes through these stages, in order. Each save makes a new version.",
            workspace: @workspace
          )}
        </:subtitle>

        <div id="stages" class="grid gap-6">
          <p id="stages-harness" class="text-[13.5px]/5">
            {gettext("Harness: %{harness}", harness: @harness)}
            <span :if={@may_harness} aria-hidden="true" class="text-muted">·</span>
            <.link
              :if={@may_harness}
              id="stages-harness-change"
              navigate={
                ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/workflow"
              }
              class="font-medium text-accent underline underline-offset-[3px]"
              aria-label={gettext("Change the harness")}
            >
              {gettext("Change")}
            </.link>
          </p>
          <div id="stages-workflows" class="grid gap-1 text-[13.5px]/5">
            <p id="stages-workflows-list">{Words.workflows_line(@declared, @snapshot)}</p>
            <p :if={@declared_error} id="stages-workflows-error" class="text-error">
              {Words.read_failed(@declared_error, @snapshot)}
            </p>
          </div>
          <div id="stages-version" class="flex flex-wrap items-center gap-x-4 gap-y-2">
            <p class="text-[13.5px]/5">
              {version_line(@base, @may)}
              <span :if={@dirty} id="stages-dirty" class="badge badge-sm badge-warning ml-2">
                {gettext("Unsaved changes")}
              </span>
            </p>
            <div :if={@may} class="flex flex-wrap gap-2">
              <.button
                id="stages-save"
                variant="primary"
                phx-click="save"
                phx-value-trial="false"
                disabled={!@dirty}
              >
                {gettext("Save")}
              </.button>
              <.button
                id="stages-save-trial"
                phx-click="save"
                phx-value-trial="true"
                disabled={!@dirty or @trial != nil}
              >
                {gettext("Save as trial")}
              </.button>
              <.button id="stages-discard" variant="ghost" phx-click="discard" disabled={!@dirty}>
                {gettext("Discard changes")}
              </.button>
              <p :if={@save_note} id="stages-save-note" class="self-center text-[13px]/5 text-error">
                {@save_note}
              </p>
            </div>
          </div>
          <p
            :if={@may and @trial != nil and @dirty}
            id="stages-trial-first"
            class="text-[13px]/5 text-muted"
          >
            {gettext("Make the trial current, or drop it, before you save another trial.")}
          </p>
          <.notice :if={@notice} kind={:success}>
            <span id="stages-notice">{@notice}</span>
          </.notice>
          <.notice :if={@save_errors != []} kind={:error}>
            <span :for={error <- @save_errors} class="block" data-save-error>{error}</span>
          </.notice>

          <%!-- The canvas is the editor: a card selected on it opens in the inspector under it.
          The canvas takes the column's full width (60rem at most, `.q-settings-main-list`)
          and draws the cards at zoom 1; beside it the inspector would leave the canvas
          less than the 1000 px both need. --%>
          <div id="stages-editor" class="grid items-start gap-4">
            <div
              id="stages-canvas"
              phx-hook=".StagesCanvas"
              phx-update="ignore"
              data-script={~p"/assets/js/canvas.js"}
              data-stylesheet={~p"/assets/js/canvas.css"}
              data-view={Jason.encode!(view(assigns))}
              data-words={Jason.encode!(canvas_words())}
              class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-200"
            >
              <%!-- The canvas sets its height to the tallest card's, with margins. --%>
              <div data-canvas class="h-44 w-full"></div>
              <p data-canvas-failed hidden class="p-4 text-[13px]/5 text-muted">
                {gettext("The canvas did not load. Reload the page to edit the stages.")}
              </p>
            </div>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".StagesCanvas">
              import {StagesCanvas} from "@/js/hooks/stages_canvas"
              export default StagesCanvas
            </script>

            <.stage_panel
              :if={@stage}
              stage={@stage}
              may={@may}
              last={length(@draft["stages"]) == 1}
              declared={@declared}
              types={@types}
              members={@members}
              people={@people}
              stage_errors={@stage_errors}
              rounds_errors={@rounds_errors}
              problems={@problems}
              machine={@draft["machine"]}
            />
          </div>

          <.form
            :if={@may}
            for={%{}}
            as={:process}
            id="stages-process-form"
            phx-change="edit_process"
            novalidate
            class="max-w-md"
          >
            <.input
              id="stages-machine"
              name="process[machine]"
              value={@draft["machine"]}
              label={gettext("Default machine type")}
              hint={machine_hint()}
              autocomplete="off"
              spellcheck="false"
            />
          </.form>
          <p :if={!@may} id="stages-machine-read" class="text-[13.5px]/5">
            {gettext("Default machine type: %{machine}", machine: @draft["machine"])}
          </p>

          <section id="stages-check" aria-labelledby="stages-check-title" class="grid gap-2">
            <h2 id="stages-check-title" class="text-[15px]/6 font-semibold">
              {gettext("Placement check")}
            </h2>
            <p :if={@problems == []} id="stages-check-clear" class="text-[13.5px]/5">
              {gettext(
                "Every workflow is declared, every type exists, and every input is an output of an earlier stage."
              )}
            </p>
            <ul :if={@problems != []} class="grid gap-1 text-[13.5px]/5">
              <li :for={problem <- @problems} data-problem={elem(problem, 0)}>
                {problem_words(problem, @draft)}
                <.link
                  :if={elem(problem, 0) == :missing_type and @may}
                  navigate={ArtifactTypes.path(@current_scope)}
                  class="ml-1 font-medium text-accent underline underline-offset-[3px]"
                >
                  {gettext("Define it")}
                </.link>
              </li>
            </ul>
          </section>

          <section
            :if={@may and @trial}
            id="stages-trial"
            aria-labelledby="stages-trial-title"
            class="grid gap-3"
          >
            <h2 id="stages-trial-title" class="text-[15px]/6 font-semibold">
              {gettext("Trial: version %{number}", number: @trial.number)}
            </h2>
            <p class="text-[13.5px]/5">
              {gettext(
                "Work items you assign here follow version %{number}. Every other work item stays on its version.",
                number: @trial.number
              )}
            </p>
            <.form
              for={%{}}
              as={:assign}
              id="stages-assign-form"
              phx-submit="assign"
              novalidate
              class="grid gap-2"
            >
              <p :if={@work_items == []} id="stages-no-work-items" class="text-[13px]/5 text-muted">
                {gettext("No open work items.")}
              </p>
              <label
                :for={item <- @work_items}
                class="inline-flex items-center gap-2 text-[13.5px]/5"
              >
                <input
                  type="checkbox"
                  name="assign[items][]"
                  value={item.public_id}
                  checked={item.process_version_id == @trial.id}
                  class="checkbox checkbox-sm checkbox-primary"
                />
                <span>{gettext("Work item %{number}: %{title}",
                  number: item.number,
                  title: item.title
                )}</span>
              </label>
              <div :if={@work_items != []}>
                <.button id="stages-assign" type="submit">{gettext("Assign to the trial")}</.button>
              </div>
            </.form>
            <%!-- Here, next to the button, not under Save at the top of the page. --%>
            <.notice :if={@assigned} kind={:success}>
              <span id="stages-assigned">{@assigned}</span>
            </.notice>
            <.notice :if={@assign_errors != []} kind={:warning}>
              <span :for={error <- @assign_errors} class="block" data-assign-error>{error}</span>
            </.notice>
            <div class="flex flex-wrap gap-2">
              <.button id="stages-make-current" variant="primary" phx-click="make_current">
                {gettext("Make current")}
              </.button>
              <.button id="stages-drop-trial" variant="danger-ghost" phx-click="drop_trial">
                {gettext("Drop trial")}
              </.button>
            </div>
          </section>

          <section id="stages-history" aria-labelledby="stages-history-title" class="grid gap-2">
            <h2 id="stages-history-title" class="text-[15px]/6 font-semibold">
              {gettext("History")}
            </h2>
            <ol class="grid gap-3">
              <li
                :for={{version, older} <- with_older(@versions)}
                id={"stages-version-#{version.number}"}
                class="grid gap-1"
              >
                <p class="text-[13.5px]/5">
                  <span class="font-medium">
                    {gettext("Version %{number}", number: version.number)}
                  </span>
                  <span class="ml-2 badge badge-sm">{status_word(version.status)}</span>
                  <span class="ml-2 text-muted">
                    {author_line(version, @authors)}
                  </span>
                </p>
                <ul class="grid gap-0.5 text-[13px]/5 text-muted">
                  <li :for={line <- change_lines(older, version, @people)}>{line}</li>
                </ul>
              </li>
            </ol>
          </section>
        </div>
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end

  attr :stage, :map, required: true
  attr :may, :boolean, required: true
  attr :last, :boolean, default: false, doc: "whether the stage is the only one"
  attr :declared, :list, required: true
  attr :types, :list, required: true
  attr :members, :list, required: true
  attr :people, :map, required: true, doc: "each member's name by user id"
  attr :stage_errors, :map, default: %{}, doc: "refusals of a save, by stage id"
  attr :rounds_errors, :map, default: %{}, doc: "refused rounds, by the loop's place"
  attr :problems, :list, required: true
  attr :machine, :string, required: true

  defp stage_panel(%{may: false} = assigns) do
    ~H"""
    <section
      id="stage-panel"
      aria-labelledby="stage-panel-title"
      class="grid gap-3 rounded-box border border-base-300 p-4"
    >
      <h2 id="stage-panel-title" class="text-[15px]/6 font-semibold">{@stage["name"]}</h2>
      <.alerts stage={@stage} problems={@problems} />
      <dl class="grid gap-2 text-[13.5px]/5">
        <dt class="font-medium">{gettext("Sequence")}</dt>
        <dd :for={line <- sequence_lines(@stage, @machine)}>{line}</dd>
        <dd :if={@stage["sequence"] == []}>{gettext("No workflow")}</dd>
        <dt class="font-medium">{gettext("Inputs")}</dt>
        <dd :for={item <- @stage["inputs"]}>{artifact_line(item)}</dd>
        <dd :if={@stage["inputs"] == []}>{gettext("None")}</dd>
        <dt class="font-medium">{gettext("Outputs")}</dt>
        <dd :for={item <- @stage["outputs"]}>{artifact_line(item)}</dd>
        <dd :if={@stage["outputs"] == []}>{gettext("None")}</dd>
        <dt class="font-medium">{gettext("Gate")}</dt>
        <dd>{Words.gate_value(@stage, @people)}</dd>
      </dl>
    </section>
    """
  end

  defp stage_panel(assigns) do
    ~H"""
    <section
      id="stage-panel"
      aria-labelledby="stage-panel-title"
      class="grid gap-4 rounded-box border border-base-300 p-4"
    >
      <div class="flex items-start justify-between gap-3">
        <h2 id="stage-panel-title" class="min-w-0 break-words text-[15px]/6 font-semibold">
          {gettext("Edit %{stage}", stage: @stage["name"])}
        </h2>
        <.button
          id="stage-remove"
          size="xs"
          variant="danger-ghost"
          phx-click="remove_stage"
          phx-value-id={@stage["id"]}
          disabled={@last}
          aria-label={gettext("Remove %{stage}", stage: @stage["name"])}
        >
          {gettext("Remove")}
        </.button>
      </div>
      <.alerts stage={@stage} problems={@problems} />
      <.form
        for={%{}}
        as={:stage}
        id="stage-form"
        phx-change="edit_stage"
        novalidate
        class="grid gap-5"
      >
        <.input
          id="stage-name"
          name="stage[name]"
          value={@stage["name"]}
          errors={Map.get(@stage_errors, @stage["id"], [])}
          label={gettext("Name")}
          maxlength="60"
          autocomplete="off"
        />

        <fieldset id="stage-sequence" class="grid gap-2">
          <legend class="mb-1 text-[13.5px]/5 font-medium">{gettext("Sequence")}</legend>
          <p :if={@stage["sequence"] == []} class="text-[13px]/5 text-muted">
            {gettext("No workflow")}
          </p>
          <%= for {entry, i} <- Enum.with_index(@stage["sequence"]) do %>
            <%= if loop = entry["loop"] do %>
              <div
                id={"stage-loop-#{i}"}
                class="grid gap-2 rounded-box border border-dashed border-base-300 p-3"
              >
                <div class="flex flex-wrap items-end gap-3">
                  <.input
                    id={"stage-loop-#{i}-rounds"}
                    name={"stage[sequence][#{i}][rounds]"}
                    type="number"
                    min="1"
                    max="10"
                    value={loop["rounds"]}
                    errors={List.wrap(@rounds_errors[to_string(i)])}
                    label={gettext("Loop: rounds at most")}
                    class="w-20"
                  />
                  <.button
                    type="button"
                    size="xs"
                    variant="danger-ghost"
                    phx-click="remove_loop"
                    phx-value-at={i}
                  >
                    {gettext("Remove loop")}
                  </.button>
                </div>
                <.entry
                  :for={{inner, j} <- Enum.with_index(loop["body"])}
                  entry={inner}
                  name={"stage[sequence][#{i}][body][#{j}]"}
                  id={"stage-entry-#{i}-#{j}"}
                  declared={@declared}
                  machine={@machine}
                  remove={length(loop["body"]) > 1 && %{"at" => j, "loop" => i}}
                />
                <div>
                  <.button type="button" size="xs" phx-click="add_entry" phx-value-loop={i}>
                    {gettext("Add workflow to the loop")}
                  </.button>
                </div>
              </div>
            <% else %>
              <.entry
                entry={entry}
                name={"stage[sequence][#{i}]"}
                id={"stage-entry-#{i}"}
                declared={@declared}
                machine={@machine}
                remove={%{"at" => i}}
              />
            <% end %>
          <% end %>
          <div class="flex flex-wrap gap-2">
            <.button id="stage-add-entry" type="button" size="xs" phx-click="add_entry">
              {gettext("Add workflow")}
            </.button>
            <.button id="stage-add-loop" type="button" size="xs" phx-click="add_loop">
              {gettext("Add loop")}
            </.button>
          </div>
        </fieldset>

        <.artifacts key="inputs" stage={@stage} types={@types} />
        <.artifacts key="outputs" stage={@stage} types={@types} />

        <fieldset id="stage-gate" class="grid gap-2">
          <legend class="mb-1 text-[13.5px]/5 font-medium">{gettext("Gate")}</legend>
          <label
            for="stage-gate-kind-0"
            class="inline-flex w-fit cursor-pointer items-center gap-2 text-[13.5px]/5 max-md:min-h-10"
          >
            <input
              type="radio"
              id="stage-gate-kind-0"
              name="stage[gate][kind]"
              value="person"
              checked={@stage["gate"]["kind"] == "person"}
              class="radio radio-sm radio-primary"
            />
            <span>{gettext("A person approves before the work item moves on")}</span>
          </label>
          <div :if={@stage["gate"]["kind"] == "person"} class="grid gap-2 pl-6">
            <.input
              id="stage-gate-approvers"
              name="stage[gate][approvers]"
              type="radio"
              value={if is_map(@stage["gate"]["approvers"]), do: "named", else: "members"}
              options={[
                {gettext("Any member"), "members"},
                {gettext("Named members"), "named"}
              ]}
            />
            <div
              :if={is_map(@stage["gate"]["approvers"])}
              id="stage-gate-named"
              class="grid gap-1 pl-6"
            >
              <input type="hidden" name="stage[gate][named][]" value="" />
              <label :for={m <- @members} class="inline-flex items-center gap-2 text-[13.5px]/5">
                <input
                  type="checkbox"
                  name="stage[gate][named][]"
                  value={m.user.id}
                  checked={m.user.id in @stage["gate"]["approvers"]["members"]}
                  class="checkbox checkbox-sm checkbox-primary"
                />
                {m.user.email}
              </label>
              <%!-- A named approver who is no longer a member stays chosen until unticked. --%>
              <label
                :for={id <- @stage["gate"]["approvers"]["members"]}
                :if={not Map.has_key?(@people, id)}
                class="inline-flex items-center gap-2 text-[13.5px]/5"
              >
                <input
                  type="checkbox"
                  name="stage[gate][named][]"
                  value={id}
                  checked
                  class="checkbox checkbox-sm checkbox-primary"
                />
                {Words.person_first(@people, id)}
              </label>
            </div>
          </div>
          <label
            for="stage-gate-kind-1"
            class="inline-flex w-fit cursor-pointer items-center gap-2 text-[13.5px]/5 max-md:min-h-10"
          >
            <input
              type="radio"
              id="stage-gate-kind-1"
              name="stage[gate][kind]"
              value="none"
              checked={@stage["gate"]["kind"] == "none"}
              class="radio radio-sm radio-primary"
            />
            <span>{gettext("No gate: the work item moves on when the sequence ends")}</span>
          </label>
        </fieldset>
      </.form>
    </section>
    """
  end

  attr :stage, :map, required: true
  attr :problems, :list, required: true

  defp alerts(assigns) do
    ~H"""
    <.notice :for={line <- alerts(@problems, @stage)} kind={:warning}>
      <span data-stage-alert>{line}</span>
    </.notice>
    """
  end

  attr :entry, :map, required: true
  attr :name, :string, required: true
  attr :id, :string, required: true
  attr :declared, :list, required: true
  attr :machine, :string, required: true
  attr :remove, :any, required: true

  defp entry(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-end gap-3">
      <.input
        id={"#{@id}-workflow"}
        name={"#{@name}[workflow]"}
        type="select"
        value={@entry["workflow"]}
        label={gettext("Workflow")}
        options={workflow_options(@declared, @entry["workflow"])}
      />
      <.input
        id={"#{@id}-machine"}
        name={"#{@name}[machine]"}
        value={@entry["machine"]}
        label={gettext("Machine type")}
        placeholder={@machine}
        autocomplete="off"
        spellcheck="false"
        class="w-36"
      />
      <.button
        :if={@remove}
        type="button"
        size="xs"
        variant="danger-ghost"
        phx-click="remove_entry"
        phx-value-at={@remove["at"]}
        phx-value-loop={@remove["loop"]}
        aria-label={gettext("Remove %{workflow}", workflow: @entry["workflow"])}
      >
        {gettext("Remove")}
      </.button>
    </div>
    """
  end

  attr :key, :string, required: true
  attr :stage, :map, required: true
  attr :types, :list, required: true

  defp artifacts(assigns) do
    ~H"""
    <fieldset id={"stage-#{@key}"} class="grid gap-2">
      <legend class="mb-1 text-[13.5px]/5 font-medium">
        {if @key == "inputs", do: gettext("Inputs"), else: gettext("Outputs")}
      </legend>
      <p :if={@stage[@key] == []} class="text-[13px]/5 text-muted">{gettext("None")}</p>
      <div
        :for={{item, i} <- Enum.with_index(@stage[@key])}
        id={"stage-#{@key}-#{i}"}
        class="flex flex-wrap items-end gap-3"
      >
        <.input
          id={"stage-#{@key}-#{i}-type"}
          name={"stage[#{@key}][#{i}][type]"}
          type="select"
          value={item["type"]}
          label={gettext("Type")}
          options={Enum.uniq(Enum.map(@types, & &1.name) ++ [item["type"]])}
        />
        <.input
          id={"stage-#{@key}-#{i}-required"}
          name={"stage[#{@key}][#{i}][required]"}
          type="checkbox"
          value={item["required"] == true}
          label={gettext("Required")}
        />
        <.button
          type="button"
          size="xs"
          variant="danger-ghost"
          phx-click="remove_artifact"
          phx-value-key={@key}
          phx-value-at={i}
          aria-label={gettext("Remove %{type}", type: item["type"])}
        >
          {gettext("Remove")}
        </.button>
      </div>
      <div>
        <.button
          id={"stage-add-#{@key}"}
          type="button"
          size="xs"
          phx-click="add_artifact"
          phx-value-key={@key}
        >
          {if @key == "inputs", do: gettext("Add input"), else: gettext("Add output")}
        </.button>
      </div>
    </fieldset>
    """
  end

  ## Words

  # Under "Default machine type" only (Vito's text, 2026-10-31).
  defp machine_hint,
    do:
      gettext(
        "Qory Apiary stores the machine type with each run of the workflow. It does not choose the machine that runs it."
      )

  defp canvas_words do
    %{
      label: gettext("Stages, in order"),
      node:
        gettext(
          "Press Enter to open the stage under the canvas. Move it with the left and right arrow keys."
        ),
      node_read: gettext("Press Enter to open the stage under the canvas."),
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

  defp version_line(version, true),
    do:
      gettext("Editing version %{number}, %{status}.",
        number: version.number,
        status: status_word(version.status)
      )

  defp version_line(version, false),
    do:
      gettext("Version %{number}, %{status}.",
        number: version.number,
        status: status_word(version.status)
      )

  defp status_word(:current), do: gettext("current")
  defp status_word(:trial), do: gettext("trial")
  defp status_word(:past), do: gettext("past")
  defp status_word(:dropped), do: gettext("dropped")

  defp author_line(%{author_id: nil, inserted_at: at}, _authors),
    do: gettext("Copied from the workspace type, %{date}", date: Format.date(at))

  # The author by the short form of their address, as the policy history shows people
  # (`ApiaryWeb.People`), whether or not they are still a member: "Former member" for an
  # account that is gone.
  defp author_line(%{author_id: id, inserted_at: at}, authors) do
    who = authors |> People.account(id) |> People.short()
    gettext("%{person}, %{date}", person: who, date: Format.date(at))
  end

  # Each version with the version its save started from (`based_on_id`), so a version
  # saved from v1 after a dropped trial v2 lists its changes against v1.
  defp with_older(versions) do
    by_id = Map.new(versions, &{&1.id, &1})
    for v <- versions, do: {v, v.based_on_id && Map.get(by_id, v.based_on_id)}
  end

  defp change_lines(nil, _version, _people), do: [gettext("The first version.")]

  defp change_lines(older, version, people) do
    case Processes.diff(older.document, version.document) do
      [] -> [gettext("No change.")]
      changes -> Enum.map(changes, &Words.change(&1, older.document, version.document, people))
    end
  end

  defp problem_words({:missing_workflow, id, name}, doc),
    do: Words.undeclared(stage_name(doc, id), name)

  defp problem_words({:missing_type, id, type}, doc),
    do: Words.missing_type(stage_name(doc, id), type)

  defp problem_words({:input_not_output, id, type}, doc),
    do: Words.input_not_output(stage_name(doc, id), type)

  defp stage_name(doc, id), do: (Processes.stage(doc, id) || %{})["name"]

  defp sequence_lines(stage, machine) do
    Enum.flat_map(stage["sequence"], fn
      %{"loop" => %{"rounds" => rounds, "body" => body}} ->
        [
          ngettext("Loop: at most %{number} round", "Loop: at most %{number} rounds", rounds,
            number: rounds
          )
          | Enum.map(body, &entry_line(&1, machine))
        ]

      entry ->
        [entry_line(entry, machine)]
    end)
  end

  defp entry_line(entry, machine),
    do:
      gettext("%{workflow}, machine type %{machine}",
        workflow: entry["workflow"],
        machine: entry["machine"] || machine
      )

  defp artifact_line(%{"type" => type, "required" => true}),
    do: gettext("%{type}, required", type: type)

  defp artifact_line(%{"type" => type}), do: gettext("%{type}, optional", type: type)
end
