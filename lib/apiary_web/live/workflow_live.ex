defmodule ApiaryWeb.WorkflowLive do
  # Workspace settings › Workflow (`/:org/:workspace/settings/workflow`), with the
  # `factory` feature: the workflow the workspace's runs follow and the harness source its
  # stack comes from, stored as the workspace-level document (`Apiary.Stacks.Sources`).
  # It opens for whoever may save it (`harness.save`, owners and admins), and is not found
  # for anyone else, as the section is absent from their list.
  #
  # Under the title, what the page sets and its steps, and in a workspace whose domain has harness
  # files (`Apiary.Lingo.Domain.harness_file?/1`), that a repository's harness file comes
  # first. A line says which workflow the runs follow now, where the workspace has one.
  #
  # Source is one select in three groups: the organisation's linked repositories that
  # have a stack, read through the adapters when the page connects, so the group says it
  # is reading until then; the harness sources an instance admin assigned to the
  # organisation; and a public address, which shows a field for it. Choosing a source, or
  # typing an address, reads its stacks through the adapters, outside the page's process;
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
  alias ApiaryWeb.SettingsComponents

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
        save_error: nil
      )

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

  ## Events

  @impl true
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
        {:noreply,
         put_flash(
           socket,
           :error,
           ApiaryWeb.Access.who_may(
             scope,
             @action,
             gettext("Only owners and admins can change the workflow.")
           )
         )}

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
     |> assign_form()}
  end

  def handle_async(:linked, {:ok, {:error, {:limited, seconds}}}, socket),
    do: {:noreply, socket |> assign(linked: [], listing_limited: seconds) |> assign_form()}

  def handle_async(:linked, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(linked: [], unread: :all) |> assign_form()}

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
      section={:workflow}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:workspace}
        current={:workflow}
        title={gettext("Workflow")}
      >
        <div id="workflow-help" class="grid max-w-[72ch] gap-2 text-[13px]/[20px] text-muted">
          <p id="workflow-what">
            {pgettext(
              "plain",
              "%{workspace}'s runs follow the workflow you choose here, from a harness repository.",
              workspace: @workspace
            )}
          </p>
          <ol class="list-decimal space-y-1 pl-5">
            <li>
              <.rich text={
                rich_gettext("Open %{place}.",
                  place: {:b, gettext("Workspace settings") <> " › " <> gettext("Workflow")}
                )
              } />
            </li>
            <li>
              <.rich text={
                rich_pgettext(
                  "plain",
                  "In %{field}, choose the harness repository, such as %{example}.",
                  field: {:b, gettext("Source")},
                  example: {:code, "example-org/harness"}
                )
              } />
            </li>
            <li>
              <.rich text={
                rich_pgettext(
                  "plain",
                  "If the repository is public and not in the list, enter its address instead, such as %{example}, without a password or token in it.",
                  example: {:code, "https://github.com/example-org/harness"}
                )
              } />
            </li>
            <li>
              <.rich text={
                rich_pgettext(
                  "plain",
                  "In %{field}, choose one of the workflows the repository's stack lists, such as %{example}.",
                  field: {:b, gettext("Workflow")},
                  example: {:code, "triage"}
                )
              } />
            </li>
            <li>
              <.rich text={rich_gettext("Press %{button}.", button: {:b, gettext("Save")})} />
            </li>
          </ol>
          <p>
            <.rich text={
              rich_pgettext(
                "plain",
                "The list shows the repositories linked to %{organisation} that have a stack (a %{file} file), and the harness sources an instance admin assigned to %{organisation}. If your harness repository is missing, link it to %{organisation}, or ask an instance admin to assign it.",
                organisation: @organisation,
                file: {:code, "qory-stack.yaml"}
              )
            } />
          </p>
        </div>

        <.notice :if={@harness_file} kind={:info} class="mt-4">
          <span id="workflow-file-first">
            <.rich text={
              rich_pgettext("plain", "A repository's %{harness} or %{qory} comes first.",
                harness: {:code, "harness.yaml"},
                qory: {:code, "qory.yaml"}
              )
            } />
          </span>
        </.notice>

        <p :if={@current} id="workflow-current" class="mt-4 text-[13px]/[20px]">
          {current_words(@current, @workspace)}
        </p>

        <.form
          for={@form}
          id="workflow-form"
          phx-change="change"
          phx-submit="save"
          class="q-form mt-4"
          novalidate
        >
          <.input
            field={@form[:source]}
            type="select"
            label={gettext("Source")}
            prompt={gettext("Choose a source")}
            options={source_options(assigns)}
            hint={listing_words(assigns)}
          />
          <.input
            :if={@choice == "address"}
            id="workflow_address"
            name="workflow[address]"
            value={@address}
            type="text"
            label={gettext("Public address")}
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
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end

  # The groups of Source: the linked repositories, read when the page connects; the
  # assigned sources; and the public address. Each group shows, an empty one too.
  defp source_options(assigns) do
    linked =
      case assigns.linked do
        nil ->
          [[key: gettext("Reading…"), value: "", disabled: true]]

        linked ->
          for source <- linked, do: {source.label, source.id}
      end

    [
      {pgettext("plain", "Linked repositories"), linked},
      {gettext("Assigned by an instance admin"),
       for(source <- assigns.assigned, do: {source.label, source.id})},
      {gettext("Public address"), [{gettext("Enter an address"), "address"}]}
    ]
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

  defp current_words(%{workflow: workflow, base: %{"git" => git}}, workspace) when is_binary(git),
    do:
      gettext("Runs of %{workspace} follow the workflow %{workflow} of %{source}.",
        workspace: workspace,
        workflow: workflow,
        source: Apiary.Stacks.Document.shown(git)
      )

  defp current_words(%{workflow: workflow}, workspace),
    do:
      gettext("Runs of %{workspace} follow the workflow %{workflow}.",
        workspace: workspace,
        workflow: workflow
      )
end
