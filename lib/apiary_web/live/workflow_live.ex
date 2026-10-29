defmodule ApiaryWeb.WorkflowLive do
  # Workspace settings › Workflow (`/:org/:workspace/settings/workflow`), with the
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
  # Beside the form, About this step says what the page sets and which sources Source
  # lists. Under the title, Harness shows the workspace's harness choice and its pin
  # (`ApiaryWeb.HarnessComponents.line/1`), else the harness the organisation shares,
  # else the Qory harness, and Change, which opens the line on what a harness is and the
  # two choices of the set-up's Harness step (`ApiaryWeb.HarnessComponents.choices/1`)
  # with Save and Cancel. Save stores the choice (`Apiary.Stacks.Sources.choose/3`); a
  # harness repository is read outside the page's process, through the linked
  # repositories Source lists, and a read that failed says why. Under it, where the
  # choice is the Qory harness, saved or not, in a workspace whose domain has harness
  # files (`Apiary.Lingo.Domain.harness_file?/1`), a notice says that a repository's
  # harness file comes first. A line says which workflow the runs follow, where the
  # workspace has one.
  #
  # Source is one choice in three groups (`ApiaryWeb.HarnessComponents.source_options/3`):
  # the organisation's linked repositories that have a stack, read through the adapters
  # when the page connects, so the group shows Reading… until then, and the line that
  # none has a stack where the listing read every linked repository and lists none; the
  # harness sources an instance admin assigned to the organisation; and a public address,
  # which shows a field for it. Once a linked repository is listed, a search box narrows
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

  alias Apiary.Lingo.Domain
  alias Apiary.Stacks.Sources
  alias ApiaryWeb.{HarnessComponents, SettingsComponents}

  @action :"harness.save"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(
        page_title: SettingsComponents.page_title(scope, :workspace, [gettext("Workflow")]),
        sections: SettingsComponents.sections(scope, :workspace),
        harness_file: Domain.harness_file?(scope.workspace),
        linked: nil,
        unread: 0,
        left_out: 0,
        listing_limited: nil,
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
        harness_refusal: nil
      )
      |> assign_harness_form(nil)

    socket =
      if connected?(socket),
        do:
          socket
          |> cancel_async(:linked)
          |> start_async(:linked, fn -> Sources.linked(scope) end)
          |> preselect_assigned(),
        else: socket

    {:ok, assign_form(socket)}
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
    |> assign_harness_form(nil)
  end

  defp harness_saved(socket, _choice, {:error, :forbidden}),
    do: put_flash(socket, :error, harness_who_may(socket.assigns.current_scope))

  defp harness_saved(socket, choice, {:error, reason}) do
    {source, ref} =
      case choice do
        {:repository, source, ref} -> {source, ref}
        _other -> {nil, nil}
      end

    organisation = socket.assigns.current_scope.organisation.name

    case HarnessComponents.refusal_words(reason, source, ref, organisation) do
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

  ## Events

  @impl true
  def handle_event("change_harness", _params, socket),
    do: {:noreply, socket |> assign(editing: true) |> assign_harness_form(nil)}

  def handle_event("cancel_harness", _params, %{assigns: %{harness_saving: false}} = socket),
    do: {:noreply, assign(socket, editing: false, harness_refusal: nil)}

  def handle_event("choose_harness", %{"harness" => params}, socket) when is_map(params) do
    params = HarnessComponents.fill(params, socket.assigns.chosen, socket.assigns.linked)
    {:noreply, socket |> assign(harness_refusal: nil) |> assign_harness_form(params)}
  end

  def handle_event(
        "save_harness",
        %{"harness" => params},
        %{assigns: %{harness_saving: false}} = socket
      )
      when is_map(params) do
    %{current_scope: scope, linked: linked, chosen: chosen} = socket.assigns
    socket = assign_harness_form(socket, params)

    case HarnessComponents.choice(params, linked) do
      nil ->
        {:noreply, socket}

      choice ->
        cond do
          HarnessComponents.unchanged?(choice, chosen) ->
            {:noreply, assign(socket, editing: false, harness_refusal: nil)}

          match?({:repository, _source, _ref}, choice) ->
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

  def handle_event(_event, _params, socket), do: {:noreply, socket}

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
  def handle_async(:linked, {:ok, {:ok, listing}}, socket) do
    %{sources: linked, unread: unread, left_out: left_out} = listing

    {:noreply,
     socket
     |> assign(linked: linked, unread: unread, left_out: left_out)
     |> preselect_linked()
     |> assign_form()
     |> harness_listed()}
  end

  def handle_async(:linked, {:ok, {:error, {:limited, seconds}}}, socket),
    do:
      {:noreply,
       socket |> assign(linked: [], listing_limited: seconds) |> assign_form() |> harness_listed()}

  def handle_async(:linked, {:exit, _reason}, socket),
    do:
      {:noreply, socket |> assign(linked: [], unread: :all) |> assign_form() |> harness_listed()}

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
            socket |> assign(stacks: stacks, reading: false) |> preselect_workflow()

          {:error, reason} ->
            assign(socket, read_error: reason, reading: false)
        end
      else
        socket
      end

    {:noreply, assign_form(socket)}
  end

  def handle_async(:read, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(read_error: :unreadable, reading: false) |> assign_form()}

  # Once the linked repositories are read, a harness form with no repository chosen yet
  # takes the saved one, else the first.
  defp harness_listed(socket) do
    %{harness_form: %{params: params}, chosen: chosen, linked: linked} = socket.assigns
    assign_harness_form(socket, HarnessComponents.fill(params, chosen, linked))
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
        qory_chosen: assigns.chosen.choice == :qory,
        harness_choice: HarnessComponents.choice(assigns.harness_form.params, assigns.linked)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      sections={@sections}
      section={:workflow}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:workspace}
        current={:workflow}
        title={gettext("Workflow")}
      >
        <div id="workflow-harness" class="grid gap-3">
          <div class="flex flex-wrap items-start gap-x-6 gap-y-1 text-[13.5px]/5">
            <p class="w-24 font-medium">{gettext("Harness")}</p>
            <div class="min-w-0 flex-1"><HarnessComponents.line chosen={@chosen} /></div>
            <.button
              :if={!@editing}
              id="workflow-harness-change"
              type="button"
              size="sm"
              phx-click="change_harness"
            >
              {gettext("Change")}
            </.button>
          </div>

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
              chosen={@chosen}
              qory={HarnessComponents.qory(@chosen, @current_scope.workspace)}
              linked={@linked}
              complete={complete?(assigns)}
              organisation={@organisation}
              workspace={@workspace}
              disabled={@harness_saving}
            />
            <.notice :if={@harness_refusal} kind={:error}>
              <span id="workflow-harness-refusal">{@harness_refusal}</span>
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
        </div>

        <.notice :if={@harness_file and @qory_chosen} kind={:info}>
          <span id="workflow-file-first">
            <.rich text={
              rich_pgettext("plain", "A repository's %{harness} or %{qory} comes first.",
                harness: {:code, "harness.yaml"},
                qory: {:code, "qory.yaml"}
              )
            } />
          </span>
        </.notice>

        <p :if={@current} id="workflow-current" class="text-[13px]/[20px]">
          {current_words(@current, @workspace)}
        </p>

        <.form
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
            label={gettext("Source")}
            prompt={gettext("Choose a source")}
            options={HarnessComponents.source_options(@linked, @assigned, complete?(assigns))}
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
            <span id="workflow-read-error">{read_words(@read_error, @source, @organisation)}</span>
          </.notice>
          <.notice :if={@stacks && no_workflow?(@stacks)} kind={:error}>
            <span id="workflow-no-workflow">
              <.rich text={
                rich_gettext(
                  "The stack of %{source} lists no workflow: add one under %{key} in its %{file}, or choose another source.",
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
        <:context>
          <p id="workflow-what">
            {pgettext(
              "plain",
              "Runs in %{workspace} use the workflow you choose here, from a harness repository.",
              workspace: @workspace
            )}
          </p>
          <p id="workflow-list">
            <.rich text={
              rich_pgettext(
                "plain",
                "The list shows the repositories linked to %{organisation} that have a stack (a %{file} file), and the harness sources an instance admin assigned to %{organisation}. If your harness repository is missing, link it to %{organisation}, or ask an instance admin to assign it.",
                organisation: @organisation,
                file: {:code, "qory-stack.yaml"}
              )
            } />
          </p>
        </:context>
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end

  # Whether the listing read every linked repository: no limit, no read that failed, and
  # none past the most a listing reads.
  defp complete?(%{linked: linked, listing_limited: nil, unread: 0, left_out: 0}),
    do: is_list(linked)

  defp complete?(_assigns), do: false

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

  # The hint under Source: a listing past the person's limit, else the linked
  # repositories not read and those past the most a listing reads.
  defp listing_words(%{listing_limited: seconds}) when is_integer(seconds),
    do:
      pngettext(
        "plain",
        "Wait %{count} second, then reload the page to list the linked repositories. Qory Apiary limits how often a person can list them.",
        "Wait %{count} seconds, then reload the page to list the linked repositories. Qory Apiary limits how often a person can list them.",
        seconds
      )

  defp listing_words(%{unread: unread, left_out: left_out}) do
    case Enum.reject([unread_words(unread), left_out_words(left_out)], &is_nil/1) do
      [] -> nil
      words -> Enum.join(words, " ")
    end
  end

  defp left_out_words(0), do: nil

  defp left_out_words(count),
    do:
      pngettext(
        "plain",
        "Ask an instance admin to assign your harness repository if the list leaves it out: Qory Apiary reads the first %{limit} linked repositories by title and lists those that have a stack, and %{count} more is linked.",
        "Ask an instance admin to assign your harness repository if the list leaves it out: Qory Apiary reads the first %{limit} linked repositories by title and lists those that have a stack, and %{count} more are linked.",
        count,
        limit: Sources.limit(:listed)
      )

  defp unread_words(0), do: nil

  defp unread_words(:all),
    do:
      pgettext(
        "plain",
        "Qory Apiary could not read the linked repositories. Reload the page to try again."
      )

  defp unread_words(count),
    do:
      pngettext(
        "plain",
        "Qory Apiary could not read %{count} linked repository, so the list leaves it out. Reload the page to try again.",
        "Qory Apiary could not read %{count} linked repositories, so the list leaves them out. Reload the page to try again.",
        count
      )

  defp read_words(:not_covered, source, organisation),
    do:
      pgettext(
        "plain",
        "Link %{source} to %{organisation}, or ask an instance admin to assign it: Qory Apiary reads a harness repository that is not public only through a linked repository or an assignment.",
        source: source.label,
        organisation: organisation
      )

  defp read_words(:no_stack, source, _organisation),
    do:
      gettext(
        "Add a qory-stack.yaml file to %{source}, or choose another source: %{source} has no stack.",
        source: source.label
      )

  defp read_words({:limited, seconds}, source, _organisation),
    do:
      ngettext(
        "Wait %{count} second, then reload the page to read %{source} again. Qory Apiary limits how often a person can read sources.",
        "Wait %{count} seconds, then reload the page to read %{source} again. Qory Apiary limits how often a person can read sources.",
        seconds,
        source: source.label
      )

  defp read_words(_unreadable, source, _organisation),
    do:
      gettext(
        "Reload the page to read %{source} again, or choose another source. Qory Apiary could not read its stack: the call to its integration failed, or a file in it is not valid.",
        source: source.label
      )

  defp current_words(%{workflow: workflow}, workspace),
    do:
      gettext("Runs of %{workspace} follow the workflow %{workflow}.",
        workspace: workspace,
        workflow: workflow
      )
end
