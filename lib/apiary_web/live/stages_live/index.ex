defmodule ApiaryWeb.StagesLive.Index do
  # Workspace settings › Workflows (`/:org/:workspace/settings/workflows`), with the
  # feature `workflow_model` (decision D2): the workspace's process (`Apiary.Processes`),
  # the stages every work item goes through, edited on a canvas. Not found while
  # `workflow_model` is off. With the feature, the sidebar's Workflows entry leads here,
  # and the Harness page keeps the harness choice that "Change" opens.
  #
  # The canvas is the editor (`assets/js/canvas.js`, React Flow, through the hook
  # `assets/js/hooks/stages_canvas.js`): it sends a selection, an order of stages, a move
  # by the arrow keys and a "+" (add_stage) as events; the inspector beside it edits the
  # selected stage. The page is the only writer of the document, and every save goes
  # through `Apiary.Processes.save/4`, which checks the document against its schema.
  #
  # Two tabs (`ApiaryWeb.PageComponents.page_tabs/1`): Stages, at the page's address, has
  # the canvas and the inspector; Details, at `?tab=details`, has every other setting, the
  # placement check, the trial and the history. The version line and its buttons are
  # beside the tabs, on both: one draft has the edits of both tabs, and a switch of tabs
  # keeps it.
  #
  # Owners and admins (`process.edit`) edit; members read the page with no edit controls.
  # Owners and admins also get Export process.yaml under the tabs' row, a link to
  # `ApiaryWeb.ProcessExportController`.
  #
  # A stage's workflow is a text field that suggests `Apiary.Processes.declared_workflows/1`
  # and takes any name the schema's pattern allows. Once the page is connected, for
  # whoever may save the harness (`harness.save`), it reads the workspace's harness as
  # Check again on a work item does (`Apiary.Stacks.Sources.chosen_workflows/2`, outside
  # the page's process): the choice, else the harness the organisation shares, else the
  # Qory harness. It records the names as the workspace's snapshot; a read that fails
  # keeps the list of the last read, with its error. With a snapshot, each workflow on
  # the canvas and in the inspector has a check when `declared_workflows/1` has it, else a
  # cross, the workflow a stage waits for (`Apiary.Stages`); before the first read, no
  # workflow has a mark and no stage waits.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :workflow_model

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Organisations, Processes, Repo, WorkItems}
  alias Apiary.Stacks.Sources
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.{MachineTypeWords, People, SettingsComponents}
  alias ApiaryWeb.StagesLive.{Canvas, Editor, Inspector, Words}

  @edits Editor.events()

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
        page_title:
          SettingsComponents.page_title(scope, :workspace, [
            SettingsComponents.workflows_label()
          ]),
        sections: SettingsComponents.sections(scope, :workspace),
        may: Apiary.Access.can?(scope, :"process.edit", workspace),
        harness: harness_name(Sources.chosen(workspace)),
        cross: cross(Sources.chosen(workspace)),
        qory_workflows: qory_workflows(Sources.chosen(workspace), workspace),
        may_harness: Apiary.Access.can?(scope, :"harness.save", workspace),
        declared: Processes.declared_workflows(workspace),
        snapshot: Processes.declared_snapshot(workspace),
        harness_source: nil,
        declared_error: nil,
        types: Apiary.Artifacts.types(workspace),
        machine_types: Apiary.MachineTypes.list(),
        members: members,
        people: Map.new(members, &{&1.user.id, People.short(People.email(&1.user))}),
        work_items: [],
        assign_errors: [],
        save_errors: [],
        stage_errors: %{},
        refused_machines: [],
        save_note: nil,
        rounds_errors: %{},
        workflow_errors: %{},
        assigned: nil,
        notice: nil
      )
      |> load(current)
      |> load_work_items()
      |> read_declared()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do:
      {:noreply, assign(socket, tab: if(params["tab"] == "details", do: :details, else: :stages))}

  ## The harness's workflows

  # The workspace's harness read again once the page is connected, for whoever may save
  # the harness: the source Check again reads (`Apiary.Stacks.Sources.chosen_source/1`).
  # An address that source cannot have reads nothing.
  defp read_declared(socket) do
    workspace = socket.assigns.current_scope.workspace

    with true <- connected?(socket) and socket.assigns.may_harness,
         {:ok, source, _stack} <- Sources.chosen_source(workspace) do
      scope = socket.assigns.current_scope
      chosen = Sources.chosen(workspace)

      socket
      |> assign(harness_source: %{source: source, chosen: chosen})
      |> start_async(:declared, fn -> Sources.chosen_workflows(scope, workspace) end)
    else
      _no_read -> socket
    end
  end

  @impl true
  def handle_async(:declared, {:ok, {:ok, names}}, socket) when is_list(names) do
    workspace = socket.assigns.current_scope.workspace

    # A harness chosen while the read ran has a newer snapshot, which this read does not
    # replace.
    if Sources.chosen(workspace) == socket.assigns.harness_source.chosen,
      do: :ok = Processes.record_declared(workspace, names)

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
  # Harness page uses for a read that failed.
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
      in_use: Apiary.Processes.HarnessUpdate.status(workspace).in_use,
      base: version,
      draft: version.document,
      selected: Editor.first_id(version.document),
      stage_errors: %{},
      refused_machines: [],
      rounds_errors: %{},
      workflow_errors: %{},
      save_note: nil
    )
    |> authors()
    |> refresh()
  end

  # The harness of the workspace's runs, as the Harness page names it.
  defp harness_name(%{choice: :qory} = chosen), do: ApiaryWeb.HarnessComponents.qory_line(chosen)
  defp harness_name(chosen), do: ApiaryWeb.HarnessComponents.chosen_line(chosen)

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
    %{draft: draft, declared: declared, types: types, snapshot: snapshot} = socket.assigns
    # Before the first read of the harness no stage waits for a workflow, so none is listed
    # as missing.
    problems =
      draft
      |> Processes.placement_check(declared, types)
      |> Enum.reject(&(is_nil(snapshot) and match?({:missing_workflow, _id, _name}, &1)))

    socket = assign(socket, problems: problems)
    push_event(socket, "stages:view", view(socket.assigns))
  end

  # The workflows a check marks: with a snapshot, the names a stage may run without
  # waiting; before the first read, nil, and no workflow has a mark.
  defp marks(%{snapshot: nil}), do: nil
  defp marks(%{declared: declared}), do: declared

  # Whether a gate of the current version lists people, which the export leaves out.
  defp exports_people?(versions) do
    case Enum.find(versions, &(&1.status == :current)) do
      nil -> false
      current -> Processes.Export.lists_people?(current)
    end
  end

  # The canvas's mode: owners and admins (`process.edit`) edit; members view.
  defp mode(%{may: true}), do: :edit
  defp mode(_assigns), do: :view

  # What the canvas draws (`ApiaryWeb.StagesLive.Canvas.view/3`).
  defp view(assigns) do
    Canvas.view(assigns.draft, mode(assigns),
      selected: assigns.selected,
      people: assigns.people,
      alerts: canvas_alerts(assigns),
      marks: marks(assigns)
    )
  end

  # Each stage's alert lines on its card: a workflow the harness does not declare, then a
  # refused name.
  defp canvas_alerts(assigns) do
    Map.new(assigns.draft["stages"], fn stage ->
      {stage["id"],
       Inspector.stage_alerts(assigns.problems, stage, assigns.cross) ++
         Map.get(assigns.stage_errors, stage["id"], [])}
    end)
  end

  ## Events

  @impl true
  def handle_event("select", %{"id" => id}, socket) when is_binary(id) do
    if Processes.stage(socket.assigns.draft, id),
      do:
        {:noreply,
         socket |> assign(selected: id, rounds_errors: %{}, workflow_errors: %{}) |> refresh()},
      else: {:noreply, socket}
  end

  def handle_event(_event, _params, %{assigns: %{may: false}} = socket) do
    {:noreply, put_flash(socket, :error, Words.refusal(:forbidden, nil))}
  end

  # A change of the draft from the canvas or the inspector (`ApiaryWeb.StagesLive.Editor`).
  def handle_event(event, params, socket) when event in @edits,
    do: {:noreply, Editor.edit_event(event, params, socket, &refresh/1)}

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
        {:noreply, Editor.refused_document(socket, errors, &refresh/1)}

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

  # Make current of a trial from the harness, with a stack for the shared harness.
  defp refused(socket, :shared),
    do: assign(socket, save_errors: [Words.shared_stack()])

  # Make current of a trial from the harness, after the harness choice changed.
  defp refused(socket, :choice_changed),
    do: assign(socket, save_errors: [Words.choice_changed()])

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
        workspace: assigns.current_scope.workspace.name,
        path:
          ~p"/#{assigns.current_scope.organisation}/#{assigns.current_scope.workspace}/settings/workflows"
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      sections={@sections}
      section={:workflows}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:workspace}
        current={:workflows}
        measure="list"
        title={SettingsComponents.workflows_label()}
      >
        <div id="stages" class={["grid", @tab == :details && "gap-6"]}>
          <%!-- One row: the tabs, then the version line and the buttons at its right end. One
          draft has the edits of both tabs, so the buttons are on both. --%>
          <div class="flex max-w-[60rem] flex-wrap items-end justify-between gap-x-6 border-b border-line [&>.q-tabs]:border-b-0">
            <.page_tabs id="stages-tabs" label={gettext("Stages")} current={@tab} place="section">
              <:tab key={:stages} patch={@path}>{gettext("Stages")}</:tab>
              <:tab key={:details} patch={"#{@path}?tab=details"}>{gettext("Details")}</:tab>
            </.page_tabs>
            <div id="stages-version" class="flex min-h-10 flex-wrap items-center gap-x-4 gap-y-2 py-1">
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
              </div>
              <p :if={@save_note} id="stages-save-note" class="text-[13px]/5 text-error">
                {@save_note}
              </p>
            </div>
          </div>
          <%!-- The download is of the current version, so it leaves out the draft and any
          trial. --%>
          <div
            :if={@may}
            id="stages-export"
            class={[
              "flex max-w-[60rem] flex-wrap items-center gap-x-3 gap-y-1",
              @tab == :stages && "py-2"
            ]}
          >
            <.button
              id="stages-export-button"
              href={
                ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/workflows/process.yaml"
              }
              download="process.yaml"
            >
              {gettext("Export process.yaml")}
            </.button>
            <p id="stages-export-line" class="min-w-0 flex-1 text-[13px]/5 text-muted">
              {pgettext(
                "plain",
                "Commit this file to a harness repository. Workspaces that use that harness get it at their next update."
              )}
              <span :if={exports_people?(@versions)} id="stages-export-people">
                {gettext("Gates that list people export as all members.")}
              </span>
            </p>
          </div>

          <div
            :if={
              (@may and @trial != nil and @dirty) or @notice != nil or Editor.banner(assigns) != []
            }
            class={["grid gap-3", @tab == :stages && "py-4"]}
          >
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
            <.notice :if={Editor.banner(assigns) != []} kind={:error}>
              <span :for={error <- Editor.banner(assigns)} class="block" data-save-error>{error}</span>
            </.notice>
          </div>

          <%!-- The canvas is the editor: a card selected on it opens in the inspector, beside
          it from 1328 px (from 1024 px in Focus and Full screen) and under it below that.
          The box takes the rest of the window (`.q-canvas-fill`), with no gap under the
          tabs. --%>
          <div :if={@tab == :stages} id="stages-editor" class="q-canvas-fill">
            <Canvas.canvas
              id="stages-canvas"
              document={@draft}
              mode={mode(assigns)}
              selected={@selected}
              people={@people}
              alerts={canvas_alerts(assigns)}
              marks={marks(assigns)}
            />
            <div class="q-canvas-side">
              <Inspector.stage_panel
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
                workflow_errors={@workflow_errors}
                refused_machines={@refused_machines}
                problems={@problems}
                harness={@cross}
                machine={@draft["machine"]}
                machine_types={@machine_types}
                marks={marks(assigns)}
              />
            </div>
          </div>

          <div :if={@tab == :details} id="stages-details" class="grid gap-6">
            <p id="stages-details-line" class="text-[13.5px]/5 text-muted">
              {gettext(
                "Every work item of %{workspace} goes through these stages, in order. Each save makes a new version.",
                workspace: @workspace
              )}
            </p>
            <p id="stages-harness" class="text-[13.5px]/5">
              <.rich :if={!@in_use} text={gettext("Harness: %{harness}", harness: @harness)} />
              <.rich
                :if={@in_use}
                text={
                  rich_gettext("Harness: %{harness}, version %{commit}",
                    harness: @harness,
                    commit: {:code, String.slice(@in_use, 0, 7)}
                  )
                }
              />
              <span :if={@may_harness} aria-hidden="true" class="text-muted">·</span>
              <.link
                :if={@may_harness}
                id="stages-harness-open"
                navigate={
                  ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/harness"
                }
                class="font-medium text-accent underline underline-offset-[3px]"
              >
                {gettext("Open Harness")}
              </.link>
            </p>
            <div id="stages-workflows" class="grid gap-1 text-[13.5px]/5">
              <p id="stages-workflows-list">{Words.workflows_line(@snapshot, @qory_workflows)}</p>
              <p :if={@declared_error} id="stages-workflows-error" class="text-error">
                <.rich text={Words.read_failed(@declared_error, @snapshot)} />
              </p>
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
                type="select"
                value={@draft["machine"] || "default"}
                label={gettext("Default machine type")}
                options={MachineTypeWords.default_options(@machine_types, @draft["machine"])}
                hint={Inspector.machine_hint()}
              />
            </.form>
            <p :if={!@may} id="stages-machine-read" class="text-[13.5px]/5">
              {gettext("Default machine type: %{machine}",
                machine: MachineTypeWords.default_words(@machine_types, @draft["machine"])
              )}
            </p>

            <section id="stages-check" aria-labelledby="stages-check-title" class="grid gap-2">
              <h2 id="stages-check-title" class="text-[15px]/6 font-semibold">
                {gettext("Placement check")}
              </h2>
              <p :if={@problems == []} id="stages-check-clear" class="text-[13.5px]/5">
                {check_clear(@snapshot, @cross)}
              </p>
              <ul :if={@problems != []} class="grid gap-1 text-[13.5px]/5">
                <li :for={problem <- @problems} data-problem={elem(problem, 0)}>
                  {problem_words(problem, @draft, @cross)}
                  <.link
                    :if={elem(problem, 0) == :missing_type and @may}
                    navigate={
                      ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/artifact-types"
                    }
                    class="ml-1 font-medium text-accent underline underline-offset-[3px]"
                  >
                    {type_fix(problem)}
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
                      <.rich text={author_line(version, @authors)} />
                    </span>
                  </p>
                  <ul
                    :if={change_lines(older, version, @people) != []}
                    class="grid gap-0.5 text-[13px]/5 text-muted"
                  >
                    <li :for={line <- change_lines(older, version, @people)}>{line}</li>
                  </ul>
                </li>
              </ol>
            </section>
          </div>
        </div>
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end

  ## Words

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

  # A version made from the harness (`Apiary.Processes.HarnessUpdate`): by the switch Keep
  # the process at the latest, with no author, or by a person's Update from harness.
  defp author_line(
         %{based_on_id: based_on, template: %{"commit" => commit} = template} = version,
         authors
       )
       when is_binary(based_on) and is_binary(commit) do
    commit = {:code, String.slice(commit, 0, 7)}
    date = Format.date(version.inserted_at)
    from = {template["ref_kind"], template["ref"]}

    case version.author_id do
      nil -> updated_line(from, commit, date)
      id -> updated_line(from, commit, date, authors |> People.account(id) |> People.short())
    end
  end

  defp author_line(%{author_id: nil, inserted_at: at}, _authors),
    do: gettext("Copied from the workspace type, %{date}", date: Format.date(at))

  # The author by the short form of their address, as the policy history shows people
  # (`ApiaryWeb.People`), whether or not they are still a member: "Former member" for an
  # account that is gone.
  defp author_line(%{author_id: id, inserted_at: at}, authors) do
    who = authors |> People.account(id) |> People.short()
    gettext("%{person}, %{date}", person: who, date: Format.date(at))
  end

  defp updated_line({"branch", branch}, commit, date),
    do:
      rich_gettext("Updated from %{branch} at %{commit}, %{date}",
        branch: branch,
        commit: commit,
        date: date
      )

  defp updated_line({"tag", tag}, commit, date),
    do:
      rich_gettext("Updated from tag %{tag} at %{commit}, %{date}",
        tag: tag,
        commit: commit,
        date: date
      )

  defp updated_line(_commit_pin, commit, date),
    do:
      rich_gettext("Updated from harness version %{commit}, %{date}", commit: commit, date: date)

  defp updated_line({"branch", branch}, commit, date, person),
    do:
      rich_gettext("%{person}, updated from %{branch} at %{commit}, %{date}",
        person: person,
        branch: branch,
        commit: commit,
        date: date
      )

  defp updated_line({"tag", tag}, commit, date, person),
    do:
      rich_gettext("%{person}, updated from tag %{tag} at %{commit}, %{date}",
        person: person,
        tag: tag,
        commit: commit,
        date: date
      )

  defp updated_line(_commit_pin, commit, date, person),
    do:
      rich_gettext("%{person}, updated from harness version %{commit}, %{date}",
        person: person,
        commit: commit,
        date: date
      )

  # Each version with the version its save started from (`based_on_id`), so a version
  # saved from v1 after a dropped trial v2 lists its changes against v1.
  defp with_older(versions) do
    by_id = Map.new(versions, &{&1.id, &1})
    for v <- versions, do: {v, v.based_on_id && Map.get(by_id, v.based_on_id)}
  end

  defp change_lines(nil, _version, _people), do: [gettext("The first version.")]

  # A version made from the harness lists no line where the process did not change, and
  # the artifact types its save added after its changes.
  defp change_lines(older, version, people) do
    from_harness? = is_binary((version.template || %{})["commit"])

    case {Processes.diff(older.document, version.document), from_harness?} do
      {[], false} ->
        [gettext("No change.")]

      {changes, _from_harness} ->
        Enum.map(changes, &Words.change(&1, older.document, version.document, people)) ++
          added_types_lines(version.template)
    end
  end

  defp added_types_lines(%{"added_types" => [_ | _] = names}),
    do: [
      ngettext(
        "Added the artifact type %{names}.",
        "Added the artifact types %{names}.",
        length(names),
        names: names_words(names)
      )
    ]

  defp added_types_lines(_template), do: []

  # "spec", "spec and demo-scenarios", "spec, plan and demo-scenarios".
  defp names_words([name]), do: name

  defp names_words(names) do
    {init, [last]} = Enum.split(names, -1)
    gettext("%{names} and %{last}", names: Enum.join(init, ", "), last: last)
  end

  # The placement check with nothing to list. Before the first read of the harness it
  # leaves the workflows out, as it does not check them. The Qory harness is never read:
  # its workflows are recorded once an owner or admin opens this page or Harness.
  defp check_clear(nil, :qory_workspace),
    do:
      gettext(
        "Every type exists, and every input is an output of an earlier stage. The workflows are checked once an owner or admin opens this page."
      )

  defp check_clear(nil, _harness),
    do:
      gettext(
        "Every type exists, and every input is an output of an earlier stage. The workflows are checked once the harness is read."
      )

  defp check_clear(_snapshot, _harness),
    do:
      gettext(
        "Every workflow is declared, every type exists, and every input is an output of an earlier stage."
      )

  # The cross's line for the workspace's harness: the Qory harness, whose workflows the
  # workspace cannot add to, or a harness repository (`Words.undeclared/3`).
  defp cross(%{choice: :qory}), do: :qory_workspace
  defp cross(_chosen), do: :workspace

  # The workflows of the workspace's Qory harness, at the commit the runs of its current
  # version compose (`Apiary.Processes.qory_workflows/2`); none for a harness repository.
  defp qory_workflows(%{choice: :qory} = chosen, workspace),
    do: Processes.qory_workflows(chosen, workspace)

  defp qory_workflows(_chosen, _workspace), do: []

  defp problem_words({:missing_workflow, id, name}, doc, cross),
    do: Words.undeclared(stage_name(doc, id), name, cross)

  defp problem_words(problem, doc, _cross), do: problem_words(problem, doc)

  defp problem_words({:missing_type, id, type}, doc),
    do: Words.missing_type(stage_name(doc, id), type)

  defp problem_words({:input_not_output, id, type}, doc),
    do: Words.input_not_output(stage_name(doc, id), type)

  defp stage_name(doc, id), do: (Processes.stage(doc, id) || %{})["name"]

  # The link beside a type the workspace does not have: a standard name is a hidden type,
  # which cannot be defined.
  defp type_fix({:missing_type, _id, type}) do
    if type in Apiary.Artifacts.Type.standard_names(),
      do: gettext("Switch it on"),
      else: gettext("Define it")
  end
end
