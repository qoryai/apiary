defmodule ApiaryWeb.HarnessLive do
  # Workspace settings › Harness (`/:org/:workspace/settings/harness`), with the
  # `factory` feature: the workspace's harness choice (`Apiary.Stacks.Sources.choose/3`),
  # and the workflow the workspace's runs follow, stored as the workspace-level document
  # for that workflow (`Apiary.Stacks.Sources.save/3`). A run's workflow comes from the
  # rows with a workflow, this one among them, whatever the choice. The walk reads no
  # document of a row with a workflow (`Apiary.Harnesses.Walk`), so Save sets which
  # workflow the runs follow, and the harness choices set which harness they use. The
  # page opens for whoever may save it (`harness.save`,
  # owners and admins), and is not found for anyone else, as the section is absent from
  # their list.
  #
  # Beside the form, About harnesses has what the page sets, which sources Workflow
  # source lists, and the paragraphs on the harness of the set-up's Harness step
  # (`ApiaryWeb.HarnessComponents.about/1`): what a harness is, the order of a run's
  # harness, a target's root harness file first, and what each version means. Under the
  # title, the rows Source, Stack and Version show the workspace's harness choice and its
  # version (`ApiaryWeb.HarnessUpdateComponents.rows/1`), else the harness the
  # organisation shares, else the Qory harness on main, and Change, which opens the two
  # choices of the set-up's Harness step (`ApiaryWeb.HarnessComponents.choices/1`) with
  # Save and Cancel. With the feature `workflow_model`, Version has the commit in use,
  # and under the rows are the switch Keep the process at the latest and Update from
  # harness (`ApiaryWeb.HarnessUpdateComponents`). Save stores the choice
  # (`Apiary.Stacks.Sources.choose/3`); a harness repository's exports are read outside
  # the page's process once it is chosen, and its save reads it outside the page's
  # process too; a read that failed shows its reason. Under the choice, Targets lists the
  # workspace's destinations, each with its Stack select, as the Harness step shows and
  # saves them (`ApiaryWeb.HarnessComponents.targets/1`, `ApiaryWeb.HarnessTargets`). The
  # select's options come from the saved choice; a save of the choice lists the
  # destinations again, and reads again the stacks of a harness repository whose address
  # or version differs from the one read last. Once a destination's save is refused
  # because `harness.save` no longer allows the person, the selects show disabled. A line
  # shows which workflow the runs follow, where the workspace has one.
  #
  # Workflow source is one choice in three groups
  # (`ApiaryWeb.HarnessComponents.source_options/2`):
  # the organisation's connected repositories (`Apiary.Stacks.Sources.repositories/1`),
  # listed with no call once the page connects, so the group shows Reading… until then;
  # the harness sources Qory Apiary provides to the organisation; and a public
  # address, which shows a field for it. Once a linked repository is listed, a search box narrows
  # the choice and keeps the public address in view. Choosing a source, or typing an
  # address, reads its stacks through the adapters, outside the page's process;
  # a source that cannot be read says why under the field. The address is read when its
  # field loses focus, not while it is typed; a read cancels the one before it, and a
  # person's reads are limited (`Apiary.Stacks.Sources`). Workflow lists the workflows
  # the chosen source's stacks list, grouped by stack where it has several. Save stores
  # the document and says so; a refused save says why.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory
  on_mount {ApiaryWeb.Access, :"harness.save"}

  alias Apiary.Processes
  alias Apiary.Lingo.Domain
  alias Apiary.Processes.HarnessUpdate
  alias Apiary.Stacks.Sources
  alias ApiaryWeb.{HarnessComponents, HarnessTargets, HarnessUpdateComponents, SettingsComponents}
  alias ApiaryWeb.StagesLive.Words, as: StagesWords

  @action :"harness.save"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(
        page_title:
          SettingsComponents.page_title(scope, :workspace, [SettingsComponents.harness_label()]),
        sections: SettingsComponents.sections(scope, :workspace),
        linked: nil,
        unplaced: [],
        harness_exports: nil,
        unread: 0,
        assigned: Sources.assigned(scope),
        current: Sources.current(scope.workspace),
        choice: "",
        address: "",
        address_error: nil,
        source: nil,
        reading: false,
        stacks: nil,
        read_error: nil,
        workflow: "",
        save_error: nil,
        chosen: Sources.chosen(scope.workspace),
        editing: false,
        harness_saving: false,
        harness_refusal: nil,
        target_edit: nil,
        workspace_stacks: nil,
        workspace_stacks_of: nil,
        # With the feature `workflow_model`, the stages replace the workflow choice
        # (decision D3): the page keeps the harness choice and links to Workflows.
        stages?: Apiary.Features.visible?(scope, :workflow_model),
        may_process:
          Apiary.Features.visible?(scope, :workflow_model) and
            Apiary.Access.can?(scope, :"process.edit", scope.workspace),
        update: nil,
        next: nil,
        update_reading: false,
        update_error: nil,
        update_notice: nil,
        branch_head: nil,
        branch_read: nil
      )
      |> assign_status()
      |> assign_harness_form(nil)
      |> load_targets()

    socket =
      if connected?(socket),
        do:
          socket
          |> cancel_async(:linked)
          |> start_async(:linked, fn ->
            {Sources.repositories(scope), Sources.unplaced(scope)}
          end)
          |> record_declared()
          |> read_branch_head()
          |> preselect_assigned(),
        else: socket

    {:ok, assign_form(socket)}
  end

  ## The harness in use and its process

  # The workspace's harness and its process (`Apiary.Processes.HarnessUpdate.status/1`),
  # with `edits`, whether the current version has edits saved on the Workflows page.
  defp assign_status(socket) do
    workspace = socket.assigns.current_scope.workspace
    current = Processes.current(workspace)

    status =
      workspace
      |> HarnessUpdate.status()
      |> Map.put(:edits, HarnessUpdateComponents.edits?(current))

    assign(socket, status: status, head: head(status, socket.assigns.branch_head))
  end

  # The commit the followed branch is at now: the Qory harness's at its last read, else
  # the one a read of the harness repository returned.
  defp head(%{source: :qory, head: head}, _branch_head), do: head
  defp head(_status, branch_head), do: branch_head

  # Where a harness repository follows a branch with Keep the process at the latest off,
  # its branch is read once the page connects, outside the page's process, as Update from
  # harness reads it, so Version shows the commit it is at now. The read is one of the
  # person's reads (`Apiary.Stacks.Sources`), so it runs once per harness choice: a
  # change of the switch reads nothing, and the first Update from harness shows the
  # difference this read returned (`kept_read/1`).
  defp read_branch_head(socket) do
    %{status: status, current_scope: scope, may_process: may} = socket.assigns

    if may and status.source == :repository and is_binary(status.following) and
         status.keep_latest == false and is_nil(socket.assigns.branch_head) do
      socket
      |> cancel_async(:branch_head)
      |> start_async(:branch_head, fn -> HarnessUpdate.read(scope, scope.workspace) end)
    else
      socket
    end
  end

  # The difference the read of the branch returned (`read_branch_head/1`), where the
  # current version is still the one it compared with; nil for none.
  defp kept_read(%{assigns: %{branch_read: %{base: base} = update}} = socket) do
    if Processes.current(socket.assigns.current_scope.workspace).id == base.id, do: update
  end

  defp kept_read(_socket), do: nil

  # The words a read of the harness that failed shows with: the harness repository's
  # source, else the Qory harness by its name.
  defp read_source(workspace) do
    case Sources.chosen_source(workspace) do
      {:ok, source, _stack} -> source
      {:error, _reason} -> %{label: HarnessComponents.harness_words(Sources.chosen(workspace))}
    end
  end

  # The number a version saved now gets: one more than the newest of the workspace's.
  defp next_number(workspace) do
    workspace
    |> Processes.list_versions()
    |> Enum.map(& &1.number)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  ## The current setting

  # The source of the current document, where an assignment is it, read as it is chosen.
  defp preselect_assigned(%{assigns: %{current: %{base: %{} = base}}} = socket) do
    case Enum.find(socket.assigns.assigned, &same_source?(&1, base)) do
      nil -> socket
      source -> choose(socket, source)
    end
  end

  defp preselect_assigned(socket), do: socket

  # Once the linked repositories are read, the source of a current document that no
  # assignment is: the linked repository at its address, else its address, at `HEAD`.
  defp preselect_linked(%{assigns: %{choice: "", current: %{base: %{} = base}}} = socket) do
    linked = Enum.find(socket.assigns.linked, &(&1.git == base["git"]))
    head? = base["ref"] == "HEAD"

    cond do
      head? and linked != nil -> choose(socket, linked)
      head? and not is_map_key(base, "path") -> address(socket, base["git"])
      true -> socket
    end
  end

  defp preselect_linked(socket), do: socket

  # An assignment of the base's stack or folder, or of its root, at the base's ref.
  defp same_source?(source, base) do
    source.git == base["git"] and source.ref == base["ref"] and
      source.narrowing in [Map.take(base, ["path", "stack"]), %{}]
  end

  ## The harness choice

  # The form of the three choices: `params` as sent, else the saved choice's.
  defp assign_harness_form(socket, nil),
    do:
      assign_harness_form(
        socket,
        HarnessComponents.form_params(socket.assigns.chosen, socket.assigns.linked)
      )

  defp assign_harness_form(socket, params),
    do: assign(socket, harness_form: to_form(params, as: :harness))

  defp harness_saved(socket, _choice, {:ok, _stack}) do
    chosen = Sources.chosen(socket.assigns.current_scope.workspace)

    socket
    |> assign(chosen: chosen, editing: false, harness_refusal: nil)
    |> assign(update: nil, update_error: nil, update_notice: nil)
    |> assign(branch_head: nil, branch_read: nil)
    |> assign_status()
    |> assign_harness_form(nil)
    |> load_targets()
    |> record_declared()
    |> read_branch_head()
  end

  defp harness_saved(socket, _choice, {:error, :forbidden}),
    do: put_flash(socket, :error, harness_who_may(socket.assigns.current_scope))

  defp harness_saved(socket, choice, {:error, reason}) do
    {source, ref} = HarnessComponents.refused(choice)

    scope = socket.assigns.current_scope

    case HarnessComponents.refusal_words(
           reason,
           source,
           ref,
           scope.organisation.name,
           scope.workspace.name
         ) do
      nil -> put_flash(socket, :error, gettext("Nothing was changed. Try again."))
      words -> assign(socket, :harness_refusal, words)
    end
  end

  defp harness_who_may(scope),
    do:
      ApiaryWeb.Access.who_may(
        scope,
        @action,
        gettext("Only owners and admins can change the workflow.")
      )

  ## The destinations

  # The workspace's destinations with the stack chosen for each, whether the person may
  # save, the edit of a destination while it is still listed, and the stacks the saved
  # choice exports (`ApiaryWeb.HarnessTargets`).
  defp load_targets(socket) do
    scope = socket.assigns.current_scope
    may = Apiary.Access.can?(scope, @action, scope.workspace)

    targets =
      HarnessTargets.targets(scope, scope.workspace, Domain.for_workspace(scope.workspace))

    socket
    |> assign(
      may: may,
      harness_targets: targets,
      target_edit: HarnessTargets.kept_edit(socket.assigns.target_edit, targets, may)
    )
    |> HarnessTargets.read_workspace_stacks()
  end

  # The answer to a save of the stack `choice` for a destination.
  defp target_saved(socket, _choice, {:ok, _stack}),
    do: socket |> assign(:target_edit, nil) |> load_targets()

  # The person may no longer save: the selects show disabled.
  defp target_saved(socket, _choice, {:error, :forbidden}),
    do:
      socket
      |> assign(target_edit: nil, may: false)
      |> put_flash(:error, harness_who_may(socket.assigns.current_scope))

  defp target_saved(socket, choice, {:error, reason}),
    do:
      HarnessTargets.refused(
        socket,
        choice,
        reason,
        socket.assigns.current_scope.organisation.name,
        socket.assigns.current_scope.workspace.name
      )

  ## Events

  @impl true
  def handle_event("change_harness", _params, socket),
    do: {:noreply, socket |> assign(editing: true) |> assign_harness_form(nil)}

  def handle_event("cancel_harness", _params, %{assigns: %{harness_saving: false}} = socket),
    do: {:noreply, assign(socket, editing: false, harness_refusal: nil)}

  def handle_event("choose_harness", %{"harness" => params}, socket) when is_map(params) do
    %{chosen: chosen, linked: linked, harness_form: form} = socket.assigns
    params = form.params |> Map.merge(params) |> HarnessComponents.fill(chosen, linked)

    {:noreply,
     socket |> assign(harness_refusal: nil) |> assign_harness_form(params) |> read_exports()}
  end

  def handle_event(
        "save_harness",
        %{"harness" => params},
        %{assigns: %{harness_saving: false}} = socket
      )
      when is_map(params) do
    %{current_scope: scope, linked: linked, chosen: chosen, harness_form: form} = socket.assigns
    params = Map.merge(form.params, params)
    socket = assign_harness_form(socket, params)

    case HarnessComponents.choice(params, linked, form_exports(socket.assigns)) do
      nil ->
        {:noreply, socket}

      choice ->
        cond do
          HarnessComponents.unchanged?(choice, chosen) ->
            {:noreply, assign(socket, editing: false, harness_refusal: nil)}

          # A save that reads a repository runs outside the page's process.
          match?({:repository, _source, _stack, _version}, choice) or
              match?({:qory, _version}, choice) ->
            {:noreply,
             socket
             |> assign(harness_saving: true, harness_refusal: nil)
             |> start_async(:harness_save, fn -> {choice, Sources.choose(scope, choice)} end)}

          true ->
            {:noreply, harness_saved(socket, choice, Sources.choose(scope, choice))}
        end
    end
  end

  def handle_event("change", %{"workflow" => params}, socket) when is_map(params) do
    source = Map.get(params, "source", socket.assigns.choice)

    # Another source's workflows are read anew, so the workflow chosen before goes.
    socket =
      cond do
        source != socket.assigns.choice ->
          socket |> assign(workflow: "") |> choose_id(source, params["address"])

        source == "address" ->
          socket
          |> assign(workflow: Map.get(params, "workflow", ""))
          |> address(params["address"])

        true ->
          assign(socket, workflow: Map.get(params, "workflow", ""))
      end

    {:noreply, assign_form(socket)}
  end

  def handle_event("save", %{"workflow" => params}, socket) when is_map(params) do
    %{current_scope: scope} = socket.assigns
    {base, workflow} = chosen(socket.assigns, Map.get(params, "workflow", ""))

    case Sources.save(scope, base, workflow) do
      {:ok, _stack} ->
        {:noreply,
         socket
         |> assign(current: Sources.current(scope.workspace), save_error: nil)
         |> put_flash(
           :info,
           gettext("Saved. Runs of %{workspace} now follow the workflow %{workflow}.",
             workspace: scope.workspace.name,
             workflow: workflow
           )
         )}

      {:error, :invalid} ->
        {:noreply,
         assign(socket, save_error: gettext("Choose a source and a workflow, then save."))}

      {:error, %Ecto.Changeset{errors: errors}} ->
        {:noreply, assign(socket, save_error: save_refusal(errors))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, harness_who_may(scope))}

      {:error, _not_found} ->
        raise ApiaryWeb.NotFound
    end
  end

  def handle_event(
        "choose_target_stack",
        %{"row" => %{"id" => id, "stack" => value}},
        %{assigns: %{may: true}} = socket
      )
      when is_binary(id) and is_binary(value),
      do: {:noreply, HarnessTargets.choose_row(socket, id, value, &target_saved/3)}

  def handle_event(
        "cancel_target",
        _params,
        %{assigns: %{target_edit: %{saving: false}}} = socket
      ),
      do: {:noreply, HarnessTargets.cancel(socket)}

  def handle_event(
        "pick_target",
        %{"target_stack" => params},
        %{assigns: %{may: true, target_edit: %{saving: false} = edit}} = socket
      )
      when is_map(params),
      do: {:noreply, HarnessTargets.pick(socket, edit, params, socket.assigns.assigned)}

  def handle_event(
        "save_target",
        %{"target_stack" => params},
        %{assigns: %{may: true, target_edit: %{saving: false} = edit}} = socket
      )
      when is_map(params),
      do: {:noreply, HarnessTargets.save(socket, edit, params, &target_saved/3)}

  def handle_event("keep_latest", _params, %{assigns: %{may_process: true}} = socket) do
    %{current_scope: scope, status: status} = socket.assigns

    case HarnessUpdate.set_keep_latest(scope, scope.workspace, !status.keep_latest) do
      {:ok, _workspace} ->
        {:noreply, socket |> assign(update_notice: nil) |> assign_status() |> read_branch_head()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, StagesWords.refusal(:forbidden, nil))}

      {:error, _pinned_or_gone} ->
        {:noreply, assign_status(socket)}
    end
  end

  def handle_event(
        "update",
        _params,
        %{assigns: %{may_process: true, update_reading: false}} = socket
      ) do
    scope = socket.assigns.current_scope
    socket = assign(socket, update: nil, update_error: nil, update_notice: nil)

    case kept_read(socket) do
      %{} = update ->
        {:noreply, socket |> assign(branch_read: nil) |> show_update(update)}

      nil ->
        {:noreply,
         socket
         |> assign(update_reading: true, branch_read: nil)
         |> start_async(:update, fn -> HarnessUpdate.read(scope, scope.workspace) end)}
    end
  end

  def handle_event("update_cancel", _params, socket),
    do: {:noreply, assign(socket, update: nil, update_error: nil)}

  def handle_event(
        "update_save",
        params,
        %{assigns: %{may_process: true, update: %{} = update}} = socket
      ) do
    scope = socket.assigns.current_scope
    trial? = params["trial"] == "true"

    case HarnessUpdate.save(scope, scope.workspace, update, trial: trial?) do
      {:ok, version} ->
        {:noreply,
         socket
         |> assign(update: nil, update_error: nil, update_notice: saved_words(version, trial?))
         |> assign_status()}

      {:error, reason} ->
        {:noreply, assign(socket, update_error: save_words(reason, update))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp saved_words(version, false),
    do:
      gettext("Saved as version %{number}. Work items taken in from now on use it.",
        number: version.number
      )

  defp saved_words(version, true),
    do:
      gettext(
        "Saved as version %{number}, a trial. Assign work items to it on the Workflows page.",
        number: version.number
      )

  # Why a save of Update from harness failed, the fix first.
  defp save_words(:stale, _update),
    do:
      gettext(
        "Press Update from harness again. The stages changed after you opened this difference."
      )

  defp save_words(:choice_changed, _update), do: StagesWords.choice_changed()

  defp save_words({:trial_exists, trial}, _update), do: StagesWords.trial_exists(trial)

  defp save_words(:shared, _update), do: StagesWords.shared_stack()

  defp save_words({:types, {:invalid, name}}, _update),
    do: gettext("Correct the artifact type %{type} in the harness, then save again.", type: name)

  defp save_words(errors, update) when is_list(errors),
    do: Enum.map_join(errors, " ", &StagesWords.refusal(&1, update.document))

  defp save_words(:forbidden, _update), do: StagesWords.refusal(:forbidden, nil)
  defp save_words(_reason, _update), do: gettext("Nothing was changed. Try again.")

  # The base and the workflow name of the option `value`, `<stack index>/<workflow>`,
  # among the stacks read for the chosen source; nil and nil for none.
  defp chosen(%{stacks: [_ | _] = stacks}, value) when is_binary(value) do
    with [index, name] <- String.split(value, "/", parts: 2),
         {index, ""} <- Integer.parse(index),
         %{base: base, workflows: workflows} <- Enum.at(stacks, index),
         true <- name in workflows do
      {base, name}
    else
      _none -> {nil, nil}
    end
  end

  defp chosen(_assigns, _value), do: {nil, nil}

  # The first refusal of the save rules, in their words.
  defp save_refusal(errors) do
    case Keyword.get(errors, :harness) || Keyword.get(errors, :workflow) do
      {message, values} -> translate_error({message, values})
      nil -> gettext("Choose a source and a workflow, then save.")
    end
  end

  ## Choosing a source

  defp choose_id(socket, "address", text) do
    socket
    |> assign(choice: "address", source: nil, stacks: nil, read_error: nil, reading: false)
    |> address(text || socket.assigns.address)
  end

  defp choose_id(socket, id, _text) do
    case Enum.find(sources(socket.assigns), &(&1.id == id)) do
      nil -> assign(socket, choice: "", source: nil, stacks: nil, read_error: nil, reading: false)
      source -> choose(socket, source)
    end
  end

  defp sources(assigns), do: (assigns.linked || []) ++ assigns.assigned

  # The address typed, checked, and read when it passes; nothing is read again for the
  # same address.
  defp address(socket, text) when is_binary(text) do
    socket = assign(socket, choice: "address")

    cond do
      text == socket.assigns.address and socket.assigns.source != nil ->
        socket

      String.trim(text) == "" ->
        assign(socket,
          address: text,
          address_error: nil,
          source: nil,
          stacks: nil,
          read_error: nil,
          reading: false
        )

      true ->
        case Sources.address(text) do
          {:ok, source} ->
            socket |> assign(address: text, address_error: nil) |> choose(source)

          {:error, error} ->
            assign(socket,
              address: text,
              address_error: translate_error(error),
              source: nil,
              stacks: nil,
              read_error: nil,
              reading: false
            )
        end
    end
  end

  defp address(socket, _text), do: socket

  # `source` chosen: its stacks read outside the page's process, and no workflow chosen
  # until they are; a later choice cancels this one's read.
  defp choose(socket, source) do
    scope = socket.assigns.current_scope
    choice = if source.kind == :address, do: "address", else: source.id

    socket
    |> assign(
      choice: choice,
      source: source,
      stacks: nil,
      workflow: "",
      read_error: nil,
      reading: true
    )
    |> cancel_async(:read)
    |> start_async(:read, fn -> {source.id, source.git, Sources.read(scope, source)} end)
  end

  @impl true
  def handle_async(:linked, {:ok, {linked, unplaced}}, socket) when is_list(linked) do
    {:noreply,
     socket
     |> assign(linked: linked, unplaced: unplaced, unread: 0)
     |> preselect_linked()
     |> assign_form()
     |> harness_listed()}
  end

  def handle_async(:linked, {:exit, _reason}, socket),
    do:
      {:noreply, socket |> assign(linked: [], unread: :all) |> assign_form() |> harness_listed()}

  def handle_async(:harness_exports, {:ok, {id, result}}, socket),
    do: {:noreply, exports_read(socket, id, result)}

  def handle_async(:harness_exports, {:exit, _reason}, socket) do
    case socket.assigns.harness_exports do
      %{id: id} -> {:noreply, exports_read(socket, id, {:error, :exited})}
      nil -> {:noreply, socket}
    end
  end

  def handle_async(:harness_save, {:ok, {choice, result}}, socket),
    do: {:noreply, socket |> assign(:harness_saving, false) |> harness_saved(choice, result)}

  def handle_async(:harness_save, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(:harness_saving, false)
       |> put_flash(:error, gettext("Nothing was changed. Try again."))}

  def handle_async(:read, {:ok, {id, git, result}}, socket) do
    socket =
      if match?(%{id: ^id, git: ^git}, socket.assigns.source) do
        case result do
          {:ok, stacks} ->
            socket
            |> assign(stacks: stacks, reading: false)
            |> preselect_workflow()

          {:error, reason} ->
            assign(socket, read_error: reason, reading: false)
        end
      else
        socket
      end

    {:noreply, assign_form(socket)}
  end

  def handle_async(:declared, {:ok, {chosen, {:ok, names}}}, socket) when is_list(names) do
    workspace = socket.assigns.current_scope.workspace

    if Sources.chosen(workspace) == chosen,
      do: :ok = Apiary.Processes.record_declared(workspace, names)

    {:noreply, socket}
  end

  def handle_async(:declared, _failed, socket), do: {:noreply, socket}

  def handle_async(:update, {:ok, {:ok, update}}, socket),
    do: {:noreply, socket |> assign(update_reading: false) |> show_update(update)}

  def handle_async(:update, {:ok, {:error, reason}}, socket),
    do: {:noreply, update_failed(socket, reason)}

  def handle_async(:update, {:exit, _reason}, socket),
    do: {:noreply, update_failed(socket, :exited)}

  def handle_async(:branch_head, {:ok, {:ok, %{commit: commit} = update}}, socket),
    do: {:noreply, socket |> assign(branch_head: commit, branch_read: update) |> assign_status()}

  # No commit to show: Update from harness shows why, once pressed.
  def handle_async(:branch_head, _failed, socket), do: {:noreply, socket}

  def handle_async(:read, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(read_error: :exited, reading: false) |> assign_form()}

  def handle_async(:workspace_stacks, {:ok, {of, result}}, socket),
    do: {:noreply, HarnessTargets.workspace_stacks_read(socket, of, result)}

  def handle_async(:workspace_stacks, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :workspace_stacks, [])}

  def handle_async(:target_read, {:ok, read}, socket),
    do: {:noreply, HarnessTargets.read_done(socket, read)}

  def handle_async(:target_read, {:exit, _reason}, socket),
    do: {:noreply, HarnessTargets.read_failed(socket)}

  def handle_async(:target_save, {:ok, {choice, result}}, socket),
    do: {:noreply, HarnessTargets.save_done(socket, choice, result, &target_saved/3)}

  def handle_async(:target_save, {:exit, _reason}, socket),
    do: {:noreply, HarnessTargets.save_failed(socket)}

  # The difference `update` shown under Update from harness; for a harness repository,
  # its commit is where the branch is now.
  defp show_update(socket, update) do
    workspace = socket.assigns.current_scope.workspace

    socket
    |> assign(update: update, next: next_number(workspace))
    |> assign(
      branch_head:
        if(update.source == :repository, do: update.commit, else: socket.assigns.branch_head)
    )
    |> assign_status()
  end

  defp update_failed(socket, reason) do
    scope = socket.assigns.current_scope

    words =
      HarnessUpdateComponents.reason_words(reason, read_source(scope.workspace), scope)

    assign(socket, update: nil, update_reading: false, update_error: words)
  end

  # Once the connected repositories are listed, a harness form with no repository chosen
  # yet takes the saved one, whose exports are then read.
  defp harness_listed(socket) do
    %{harness_form: %{params: params}, chosen: chosen, linked: linked} = socket.assigns

    socket
    |> assign_harness_form(HarnessComponents.fill(params, chosen, linked))
    |> read_exports()
  end

  # The read of the exports of the repository the harness form has chosen, nil for
  # another repository or none.
  defp form_exports(%{harness_exports: %{id: id, result: result}, harness_form: form}),
    do: if(form.params["source"] == id, do: result)

  defp form_exports(_assigns), do: nil

  # The stacks the repository chosen in the harness form exports, read outside the page's
  # process, once per repository chosen; a choice of another repository cancels the read
  # before it.
  defp read_exports(%{assigns: %{harness_form: %{params: params}, linked: linked}} = socket) do
    source =
      params["choice"] == "repository" &&
        Enum.find(linked || [], &(&1.id == params["source"]))

    case {source, socket.assigns.harness_exports} do
      {source, _read} when source in [nil, false] ->
        socket

      {%{id: id}, %{id: id}} ->
        socket

      {source, _read} ->
        scope = socket.assigns.current_scope

        socket
        |> assign(:harness_exports, %{id: source.id, result: :reading})
        |> cancel_async(:harness_exports)
        |> start_async(:harness_exports, fn -> {source.id, Sources.exports(scope, source)} end)
    end
  end

  # The exports of the repository `id` are read: kept where it is still the one read, and
  # the harness form's stack set to one it exports
  # (`ApiaryWeb.HarnessComponents.with_stack/2`).
  defp exports_read(socket, id, result) do
    case socket.assigns.harness_exports do
      %{id: ^id} ->
        socket = assign(socket, :harness_exports, %{id: id, result: result})

        case {socket.assigns.harness_form.params, result} do
          {%{"source" => ^id} = params, {:ok, names}} ->
            assign_harness_form(socket, HarnessComponents.with_stack(params, names))

          _other ->
            socket
        end

      _other ->
        socket
    end
  end

  # The workflows of the workspace's harness, read outside the page's process as Check
  # again on a work item reads them (`Apiary.Stacks.Sources.chosen_workflows/2`) and kept
  # as the workspace's snapshot (`Apiary.Processes.record_declared/2`): once the page is
  # connected, and again once a harness choice is saved. A read that fails, or a source
  # only tried in Source, changes no snapshot; a harness chosen while the read ran keeps
  # the snapshot of its later read.
  defp record_declared(socket) do
    %{current_scope: scope} = socket.assigns
    chosen = Sources.chosen(scope.workspace)

    socket
    |> cancel_async(:declared)
    |> start_async(:declared, fn -> {chosen, Sources.chosen_workflows(scope, scope.workspace)} end)
  end

  # The current workflow, where the chosen source's stacks have it under the current base.
  defp preselect_workflow(%{assigns: %{current: %{workflow: workflow, base: base}}} = socket) do
    socket.assigns.stacks
    |> Enum.with_index()
    |> Enum.find(fn {stack, _index} -> stack.base == base and workflow in stack.workflows end)
    |> case do
      {_stack, index} -> assign(socket, workflow: "#{index}/#{workflow}")
      nil -> socket
    end
  end

  defp preselect_workflow(socket), do: socket

  defp assign_form(socket) do
    %{choice: choice, address: address, workflow: workflow} = socket.assigns

    assign(
      socket,
      :form,
      to_form(%{"source" => choice, "address" => address, "workflow" => workflow}, as: :workflow)
    )
  end

  ## The page

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        organisation: assigns.current_scope.organisation.name,
        workspace: assigns.current_scope.workspace.name,
        exports: form_exports(assigns),
        stopped: HarnessUpdateComponents.stopped(assigns.status, assigns.head),
        harness_choice:
          HarnessComponents.choice(
            assigns.harness_form.params,
            assigns.linked,
            form_exports(assigns)
          )
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      sections={@sections}
      section={:harness}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:workspace}
        current={:harness}
        title={SettingsComponents.harness_label()}
      >
        <div id="workflow-harness" class="grid gap-3">
          <HarnessUpdateComponents.rows status={@status} process={@stages?} branch_head={@head}>
            <:change>
              <.button
                :if={!@editing}
                id="workflow-harness-change"
                type="button"
                size="sm"
                phx-click="change_harness"
              >
                {gettext("Change")}
              </.button>
            </:change>
          </HarnessUpdateComponents.rows>

          <.form
            :if={@editing}
            for={@harness_form}
            id="workflow-harness-form"
            phx-change="choose_harness"
            phx-submit="save_harness"
            class="grid gap-4"
            novalidate
          >
            <HarnessComponents.choices
              form={@harness_form}
              linked={@linked}
              unplaced={@unplaced}
              exports={@exports}
              organisation={@organisation}
              workspace_name={@workspace}
              disabled={@harness_saving}
            />
            <.notice :if={@harness_refusal} kind={:error}>
              <span id="workflow-harness-refusal"><.rich text={@harness_refusal} /></span>
            </.notice>
            <div class="flex gap-2">
              <.button
                id="workflow-harness-save"
                type="submit"
                variant="primary"
                disabled={is_nil(@harness_choice) or @harness_saving}
                loading_text={gettext("Saving")}
              >
                {if @harness_saving, do: gettext("Saving"), else: gettext("Save")}
              </.button>
              <.button
                id="workflow-harness-cancel"
                type="button"
                disabled={@harness_saving}
                phx-click="cancel_harness"
              >
                {gettext("Cancel")}
              </.button>
            </div>
          </.form>

          <HarnessComponents.targets
            targets={@harness_targets}
            may={@may}
            edit={@target_edit}
            workspace={@chosen}
            stacks={@workspace_stacks}
            linked={@linked}
            assigned={@assigned}
            organisation={@organisation}
            workspace_name={@workspace}
          />
        </div>

        <div :if={@stages?} id="harness-process" class="grid gap-5 border-t border-line pt-5">
          <.switch
            :if={@may_process and @status.following}
            id="harness-latest"
            label={gettext("Keep the process at the latest")}
            checked={@status.keep_latest}
            phx-click="keep_latest"
          >
            {HarnessUpdateComponents.latest_words(@status.following)}
          </.switch>
          <.notice :if={@stopped} kind={:warning}>
            <span id="harness-stopped"><.rich text={
              HarnessUpdateComponents.stopped_words(@status.following, @stopped)
            } /></span>
          </.notice>
          <.notice :if={@update_notice} kind={:success}>
            <span id="harness-update-notice">{@update_notice}</span>
          </.notice>
          <div :if={@may_process and !@update} id="harness-update-line" class="grid gap-2">
            <p class="text-[13.5px]/5">
              {HarnessUpdateComponents.compare_words(@status.number, @status.version)}
            </p>
            <div>
              <.button
                id="harness-update"
                size="sm"
                phx-click="update"
                disabled={@update_reading}
              >
                {gettext("Update from harness")}
              </.button>
            </div>
          </div>
          <.notice :if={@update_error} kind={:error}>
            <span id="harness-update-error"><.rich text={@update_error} /></span>
          </.notice>
          <HarnessUpdateComponents.update
            :if={@update}
            update={@update}
            next={@next}
            switch_off={is_binary(@status.following) and @status.keep_latest == false}
          />
        </div>

        <div :if={@stages?} id="workflow-stages" class="grid gap-2">
          <p class="text-[13.5px]/5">
            {gettext(
              "Set the stages of %{workspace}, and the workflows each stage runs, on the Workflows page.",
              workspace: @workspace
            )}
          </p>
          <div>
            <.button
              id="workflow-stages-link"
              navigate={
                ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/workflows"
              }
            >
              {gettext("Open Workflows")}
            </.button>
          </div>
        </div>

        <p :if={@current && !@stages?} id="workflow-current" class="text-[13px]/[20px]">
          {current_words(@current, @workspace)}
        </p>

        <.form
          :if={!@stages?}
          for={@form}
          id="workflow-form"
          phx-change="change"
          phx-submit="save"
          class="q-form"
          novalidate
        >
          <.input
            field={@form[:source]}
            type="choice"
            label={gettext("Workflow source")}
            prompt={gettext("Choose a source")}
            options={HarnessComponents.source_options(@linked, @assigned)}
            search={@linked not in [nil, []] || nil}
            hint={listing_words(assigns)}
          />
          <.input
            :if={@choice == "address"}
            id="workflow_address"
            name="workflow[address]"
            value={@address}
            type="text"
            label={gettext("Public address")}
            hint={pgettext("plain", "The repository's address, without a password or token in it.")}
            errors={List.wrap(@address_error)}
            debounce="blur"
            autocomplete="off"
            spellcheck="false"
            class="font-mono"
          />
          <p :if={@reading} id="workflow-reading" class="text-[13px]/[20px] text-muted">
            {gettext("Reading the stack of %{source}…", source: @source.label)}
          </p>
          <.notice :if={@read_error} kind={:error}>
            <span id="workflow-read-error"><.rich text={
              HarnessComponents.read_words(
                @read_error,
                @source,
                @organisation,
                @workspace
              )
            } /></span>
          </.notice>
          <.notice :if={@stacks && no_workflow?(@stacks)} kind={:error}>
            <span id="workflow-no-workflow">
              <.rich text={
                rich_gettext(
                  "The stack of %{source} lists no workflow: add one under %{key} in its %{file}.",
                  source: @source.label,
                  key: {:code, "workflows"},
                  file: {:code, "qory-stack.yaml"}
                )
              } />
            </span>
          </.notice>
          <.input
            field={@form[:workflow]}
            type="select"
            label={gettext("Workflow")}
            prompt={gettext("Choose a workflow")}
            options={workflow_options(@stacks)}
            disabled={workflow_options(@stacks) == []}
          />
          <.notice :if={@save_error} kind={:error}>
            <span id="workflow-save-error">{@save_error}</span>
          </.notice>
          <SettingsComponents.save id="workflow-save">
            <.button
              type="submit"
              variant="primary"
              disabled={elem(chosen(assigns, @workflow), 0) == nil}
              loading_text={gettext("Saving")}
            >
              {gettext("Save")}
            </.button>
          </SettingsComponents.save>
        </.form>
        <:context about={gettext("About harnesses")}>
          <p :if={!@stages?} id="workflow-what">
            {pgettext(
              "plain",
              "Runs in %{workspace} use the workflow you choose here, from a harness repository.",
              workspace: @workspace
            )}
          </p>
          <p :if={!@stages?} id="workflow-list">
            <.rich text={
              rich_pgettext(
                "plain",
                "The list shows the repositories connected to %{organisation}, and the harness sources Qory Apiary provides to %{organisation}. If your harness repository is missing, connect it to %{organisation}, or %{contact_support}.",
                organisation: @organisation,
                contact_support: ApiaryWeb.Support.rich(mid_sentence: true)
              )
            } />
          </p>
          <HarnessComponents.about process={@stages?} />
        </:context>
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end

  # The workflows of the chosen source's stacks, each `<stack index>/<workflow>`: one
  # list for one stack, a group per stack named for it where there are several.
  defp workflow_options(nil), do: []

  defp workflow_options([stack]),
    do: for(name <- stack.workflows, do: {name, "0/" <> name})

  defp workflow_options(stacks) do
    for {stack, index} <- Enum.with_index(stacks), stack.workflows != [] do
      {stack.name || "qory-stack.yaml",
       for(name <- stack.workflows, do: {name, "#{index}/#{name}"})}
    end
  end

  defp no_workflow?(stacks), do: Enum.all?(stacks, &(&1.workflows == []))

  # The hint under Source: the line for a list of the connected repositories that failed.
  defp listing_words(%{unread: unread}), do: unread_words(unread)

  defp unread_words(0), do: nil

  defp unread_words(:all),
    do:
      pgettext(
        "plain",
        "Qory Apiary could not read the linked repositories. Reload the page to try again."
      )

  defp current_words(%{workflow: workflow}, workspace),
    do:
      gettext("Runs of %{workspace} follow the workflow %{workflow}.",
        workspace: workspace,
        workflow: workflow
      )
end
