defmodule ApiaryWeb.WorkspaceSetupLive do
  # The workspace set-up, `/:org/set-up`: the page every organisation with no workspace in
  # use lands on (`ApiaryWeb.UserAuth.signed_in_path/1`), in two steps of the set-up, in
  # its frame with the progress indicator (`ApiaryWeb.SetUpComponents.frame/1`):
  # Workspace, `?step=type`, and Work source, `?step=source`. Without a step, or with
  # `source` before the organisation has a workspace, the first of them that is not done.
  #
  # Workspace, while the organisation has no workspace in use
  # (`Apiary.Organisations.has_workspace?/1`), for a person `workspace.create` allows
  # there (`Apiary.Access`): the Type field (`ApiaryWeb.WorkspaceComponents.type_field/1`)
  # and Create workspace, which makes Main
  # (`Apiary.Organisations.create_first_workspace/2`); its context says what the workspace
  # is, with the edition's line on which workspace this is
  # (`c:Apiary.Edition.first_workspace_line/1`). Anyone else is told who sets it up
  # (`c:Apiary.Edition.first_workspace_waiting_line/1`), with the indicator where the
  # edition lists 2 steps or more (the core lists them none) and the context
  # where the edition has a line (`c:Apiary.Edition.set_up_context/2`). Where a workspace
  # marked for deletion still has the name Main, the page says to restore it.
  # The page listens to the organisation's workspaces
  # (`Apiary.Organisations.subscribe_workspaces/1`): once its first workspace is made, by
  # anyone, the page opens Work source as it would open now. Once the workspace exists,
  # the step shows what was made, read only, with Continue. Its title is the edition's
  # (`c:Apiary.Edition.set_up_title/2`).
  #
  # Work source, once the organisation has a workspace, for the workspace the person's
  # scope has, with the `factory` feature, for a person `adapter.connect` allows: the
  # instance's configured adapters that serve the workspace's type
  # (`Apiary.Adapters.list_configured/1`), each with Connect, the Install of Organisation
  # settings › Integrations (`ApiaryWeb.IntegrationComponents.install_form/1`), and Skip;
  # with none, that no work source for the type is set up on the instance, and Continue.
  # In the context column, for each adapter whose Connect can be pressed
  # (`ApiaryWeb.IntegrationComponents.ready?/1`) and whose guide gives steps for
  # connecting it (`Apiary.Adapters.guide/2`), those steps, under "On %{adapter}", and,
  # while the organisation has one workspace, a note that the workspace gets every
  # collection picked. Skip and Continue lead to the workspace's Overview, and so does
  # Create workspace without the feature. A person `adapter.connect` refuses sees the same
  # step where the edition says who may connect one
  # (`c:ApiaryWeb.Edition.who_may_sentence/2`), with no Connect and no steps: the
  # adapters, that sentence, and Skip; with none, the line and Continue. Anyone else, once
  # there is a workspace, is sent on: to the workspace's first page, or to the
  # organisation's page where they reach no workspace.
  #
  # Every step has Back to the step before it in the indicator, where that step has a
  # page. Work source is of the `factory` feature, and the module reference leaves the
  # module out.
  @moduledoc false

  use ApiaryWeb, :live_view

  alias Apiary.{Access, Adapters, Features, Organisations}
  alias Apiary.Lingo.Domain
  alias ApiaryWeb.{IntegrationComponents, SetUpComponents, SourceComponents, WorkspaceComponents}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket), do: Organisations.subscribe_workspaces(scope)

    {:ok, assign(socket, step: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    organisation = scope.organisation

    cond do
      not Organisations.has_workspace?(organisation) ->
        {:noreply, assign_type_step(socket)}

      is_nil(scope.workspace) ->
        {:noreply, push_navigate(socket, to: ~p"/#{organisation}")}

      params["step"] == "type" ->
        {:noreply, assign_made_step(socket)}

      source = source_access(scope) ->
        {:noreply, assign_source_step(socket, source)}

      true ->
        {:noreply, push_navigate(socket, to: Layouts.workspace_landing(scope))}
    end
  end

  # Work source, for the scope: `{:ok, nil}` for a person `adapter.connect` allows,
  # `{:ok, who_may}` with the edition's sentence for one it refuses, nil where the step is
  # not shown.
  defp source_access(scope) do
    cond do
      not Features.visible?(scope, :factory) -> nil
      Access.can?(scope, :"adapter.connect", scope.organisation) -> {:ok, nil}
      who_may = ApiaryWeb.Edition.who_may_sentence(:"adapter.connect", scope) -> {:ok, who_may}
      true -> nil
    end
  end

  defp assign_steps(socket, current) do
    steps = SetUpComponents.steps_for(socket.assigns.current_scope, current)
    assign(socket, steps: steps, current: Enum.find(steps, &(&1.id == current)))
  end

  # A person who may not create the workspace waits: the core lists them no step, so the
  # page shows no indicator unless the edition lists steps (`c:Apiary.Edition.set_up_steps/2`).
  defp assign_type_step(socket) do
    scope = socket.assigns.current_scope
    creates = Access.can?(scope, :"workspace.create", scope.organisation)

    socket =
      if creates,
        do: assign_steps(socket, :workspace),
        else: assign(socket, steps: Apiary.Edition.set_up_steps(scope, []), current: nil)

    assign(socket,
      page_title: Apiary.Edition.set_up_title(scope, socket.assigns.current),
      step: :type,
      creates: creates,
      refusal: nil,
      form: to_form(%{"domain" => nil}, as: "workspace")
    )
  end

  # Workspace, once the workspace exists: what was made, read only.
  defp assign_made_step(socket) do
    scope = socket.assigns.current_scope
    socket = assign_steps(socket, :workspace)

    assign(socket,
      page_title: Apiary.Edition.set_up_title(scope, socket.assigns.current),
      step: :made,
      continue:
        if(source_access(scope),
          do: {:patch, ~p"/#{scope.organisation}/set-up?step=source"},
          else: {:navigate, Layouts.workspace_landing(scope)}
        )
    )
  end

  # `who_may` is the edition's sentence of who may connect a work source, for a person
  # `adapter.connect` refuses, or nil for one it allows.
  defp assign_source_step(socket, {:ok, who_may}) do
    scope = socket.assigns.current_scope
    workspace = scope.workspace

    socket
    |> assign_steps(:source)
    |> assign(
      page_title: gettext("Connect a work source to %{workspace}", workspace: workspace.name),
      step: :source,
      adapters: Adapters.list_configured(Domain.for_workspace(workspace)),
      # The adapters connected to the workspace, by the Overview's rule for its Work
      # source step.
      connected: MapSet.new(Apiary.Edition.work_source_ready(workspace), & &1.adapter.id),
      one_workspace: match?([_one], Organisations.list_workspaces(scope)),
      sending: nil,
      who_may: who_may
    )
  end

  @impl true
  # With no type chosen, the Type field (a choice) checks no radio, and the form sends no
  # `workspace` params: the changeset then says to choose one.
  def handle_event("create", params, %{assigns: %{step: :type}} = socket) do
    domain =
      case params do
        %{"workspace" => %{"domain" => domain}} when is_binary(domain) -> domain
        _no_type -> ""
      end

    scope = socket.assigns.current_scope
    organisation = scope.organisation

    case Organisations.create_first_workspace(scope, %{"domain" => domain}) do
      {:ok, workspace} ->
        to =
          if Features.visible?(scope, :factory),
            do: ~p"/#{organisation}/set-up?step=source",
            else: ~p"/#{organisation}/#{workspace}"

        # Off the Type step, so the broadcast this page caused, of the new workspace
        # (`handle_info/2`), navigates no second time.
        {:noreply, socket |> assign(:step, :created) |> push_navigate(to: to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Keyword.has_key?(changeset.errors, :name),
          do: {:noreply, assign(socket, :refusal, :name_taken)},
          else:
            {:noreply,
             assign(socket, :form, to_form(changeset, as: "workspace", action: :insert))}

      {:error, :limit} ->
        {:noreply, assign(socket, :refusal, :limit)}

      # Made a moment before, or no longer theirs to make: the page as it would open now.
      {:error, _reason} ->
        {:noreply, push_navigate(socket, to: ~p"/#{organisation}/set-up")}
    end
  end

  # The type chosen, kept in the form, so that a later render of the page shows it. A
  # value that is no domain's keeps none.
  def handle_event("choose", params, %{assigns: %{step: :type}} = socket) do
    names = Enum.map(Domain.choices(), & &1.name())

    domain =
      case params do
        %{"workspace" => %{"domain" => domain}} -> if domain in names, do: domain
        _no_type -> nil
      end

    {:noreply, assign(socket, :form, to_form(%{"domain" => domain}, as: "workspace"))}
  end

  def handle_event(
        "install",
        %{"integration" => public_id},
        %{assigns: %{step: :source, who_may: nil}} = socket
      ) do
    if Enum.any?(socket.assigns.adapters, &(&1.public_id == public_id)),
      do: {:noreply, assign(socket, :sending, public_id)},
      else: {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  # The organisation's first workspace was made, by anyone: the page as it would open now,
  # Work source or on.
  def handle_info({:workspace_created, _ids}, %{assigns: %{step: :type}} = socket),
    do:
      {:noreply,
       push_navigate(socket,
         to: ~p"/#{socket.assigns.current_scope.organisation}/set-up?step=source"
       )}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:organisation}
      sidebar={false}
    >
      <.type_step
        :if={@step == :type}
        scope={@current_scope}
        steps={@steps}
        title={@page_title}
        creates={@creates}
        form={@form}
        refusal={@refusal}
      />
      <.made_step
        :if={@step == :made}
        scope={@current_scope}
        steps={@steps}
        title={@page_title}
        continue={@continue}
      />
      <.source_step
        :if={@step == :source}
        scope={@current_scope}
        steps={@steps}
        adapters={@adapters}
        connected={@connected}
        one_workspace={@one_workspace}
        sending={@sending}
        who_may={@who_may}
      />
    </Layouts.app>
    """
  end

  attr :scope, :map, required: true

  # Why the workspace exists, and the edition's line on which workspace it is.
  defp workspace_context(assigns) do
    ~H"""
    <p id="set-up-what">
      <%!-- The workspace type's context: read where the type is picked, in no domain's
      words yet (docs/lingo.md). --%>
      {pgettext(
        "workspace type",
        "%{workspace} is where Qory Apiary takes in tickets and runs agents on them. Its type sets which work sources it can connect, and whether each ticket needs a repository.",
        workspace: Organisations.default_workspace_name()
      )}
    </p>
    <p id="set-up-line">{Apiary.Edition.first_workspace_line(@scope.organisation)}</p>
    """
  end

  attr :scope, :map, required: true
  attr :steps, :list, required: true
  attr :title, :string, required: true
  attr :creates, :boolean, required: true
  attr :form, :any, required: true
  attr :refusal, :atom, required: true

  # The waiting line, for a person who may not create the workspace. The frame shows the
  # steps where the edition lists 2 or more (the core lists none),
  # and the column About this step where the edition has a line for it
  # (`c:Apiary.Edition.set_up_context/2`).
  defp type_step(%{creates: false} = assigns) do
    assigns = assign(assigns, :context, Apiary.Edition.set_up_context(assigns.scope, :workspace))

    ~H"""
    <SetUpComponents.frame
      steps={@steps}
      next={SetUpComponents.next?(@scope)}
      page={~p"/#{@scope.organisation}/set-up"}
    >
      <SetUpComponents.heading>{@title}</SetUpComponents.heading>
      <p id="set-up-waiting" class="text-sm/5 text-muted">
        {Apiary.Edition.first_workspace_waiting_line(@scope.organisation)}
      </p>
      <:context :if={@context}>
        <p id="set-up-what">{@context}</p>
      </:context>
    </SetUpComponents.frame>
    """
  end

  defp type_step(assigns) do
    assigns = assign(assigns, :workspace, Organisations.default_workspace_name())

    ~H"""
    <SetUpComponents.frame
      steps={@steps}
      next={SetUpComponents.next?(@scope)}
      page={~p"/#{@scope.organisation}/set-up"}
    >
      <SetUpComponents.heading>{@title}</SetUpComponents.heading>

      <.notice :if={@refusal == :name_taken} kind={:error}>
        <span id="set-up-name-taken">
          {gettext(
            "Restore %{workspace} in Organisation settings › Workspaces. A deleted workspace keeps its name until it is purged.",
            workspace: @workspace
          )}
        </span>
      </.notice>
      <.notice :if={@refusal == :limit} kind={:error}>
        <span id="set-up-limit">
          {gettext("%{organisation} may have no more workspaces.",
            organisation: @scope.organisation.name
          )}
        </span>
      </.notice>

      <.form
        for={@form}
        id="set-up-form"
        phx-change="choose"
        phx-submit="create"
        class="grid gap-5"
        novalidate
      >
        <WorkspaceComponents.type_field field={@form[:domain]} />
        <div class="q-su-acts">
          <SetUpComponents.back steps={@steps} page={~p"/#{@scope.organisation}/set-up"} />
          <.button variant="primary" size="md" loading_text={gettext("Creating")}>
            {gettext("Create workspace")}
          </.button>
        </div>
      </.form>

      <:context><.workspace_context scope={@scope} /></:context>
    </SetUpComponents.frame>
    """
  end

  attr :scope, :map, required: true
  attr :steps, :list, required: true
  attr :title, :string, required: true
  attr :continue, :any, required: true

  # Workspace once it exists: its type can't change, so the step shows what was made.
  defp made_step(assigns) do
    workspace = assigns.scope.workspace

    assigns =
      assign(assigns,
        workspace: workspace,
        type: Domain.for_workspace(workspace).type_name()
      )

    ~H"""
    <SetUpComponents.frame
      steps={@steps}
      next={SetUpComponents.next?(@scope)}
      page={~p"/#{@scope.organisation}/set-up"}
    >
      <SetUpComponents.heading>{@title}</SetUpComponents.heading>

      <p id="set-up-made" class="text-[13.5px]/5">
        {gettext("%{workspace} is a %{type} workspace.", workspace: @workspace.name, type: @type)}
        {gettext("You can't change the type after you create the workspace.")}
      </p>

      <div class="q-su-acts">
        <SetUpComponents.back steps={@steps} page={~p"/#{@scope.organisation}/set-up"} />
        <.button
          id="set-up-continue"
          variant="primary"
          size="md"
          patch={elem(@continue, 0) == :patch && elem(@continue, 1)}
          navigate={elem(@continue, 0) == :navigate && elem(@continue, 1)}
        >
          {gettext("Continue")}
        </.button>
      </div>

      <:context><.workspace_context scope={@scope} /></:context>
    </SetUpComponents.frame>
    """
  end

  attr :scope, :map, required: true
  attr :steps, :list, required: true
  attr :adapters, :list, required: true
  attr :connected, MapSet, required: true, doc: "the ids of the adapters connected to it"
  attr :one_workspace, :boolean, required: true
  attr :sending, :string, required: true
  attr :who_may, :string, required: true

  defp source_step(assigns) do
    assigns =
      assign(assigns,
        workspace: assigns.scope.workspace,
        ready:
          for(
            a <- assigns.adapters,
            is_nil(assigns.who_may),
            IntegrationComponents.ready?(a),
            into: MapSet.new(),
            do: a.id
          )
      )

    ~H"""
    <SetUpComponents.frame
      steps={@steps}
      next={SetUpComponents.next?(@scope)}
      page={~p"/#{@scope.organisation}/set-up"}
    >
      <SetUpComponents.heading>
        {gettext("Connect a work source to %{workspace}", workspace: @workspace.name)}
      </SetUpComponents.heading>

      <ul :if={@adapters != []} id="set-up-sources" class="grid gap-3">
        <li
          :for={adapter <- @adapters}
          id={"set-up-source-#{adapter.public_id}"}
          class="flex items-center gap-3 rounded-box border border-line bg-base-100 px-4 py-3"
        >
          <IntegrationComponents.mark class="size-5" />
          <div class="min-w-0 flex-1">
            <p class="truncate font-medium">{adapter.name}</p>
            <p class="text-[12.5px]/4 text-muted">{source_line(adapter)}</p>
          </div>
          <span
            :if={MapSet.member?(@connected, adapter.id)}
            id={"set-up-source-#{adapter.public_id}-connected"}
            class="q-sdot q-sdot-completed text-[13px]/5"
          >
            <i aria-hidden="true"></i><span>{gettext("Connected")}</span>
          </span>
          <IntegrationComponents.install_form
            :if={is_nil(@who_may)}
            id={"set-up-source-#{adapter.public_id}-connect"}
            adapter={adapter}
            variant={if MapSet.member?(@connected, adapter.id), do: "default", else: "primary"}
            action={IntegrationComponents.paths(@scope, adapter).install <> "?back=set-up"}
            ready={adapter.id in @ready}
            sending={@sending == adapter.public_id}
            label={gettext("Connect")}
          />
        </li>
      </ul>

      <p
        :if={@adapters != [] and @who_may}
        id="set-up-who-may"
        class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
      >
        {@who_may}
      </p>

      <div :if={@adapters != []} id="set-up-skip" class="q-su-acts">
        <SetUpComponents.back steps={@steps} page={~p"/#{@scope.organisation}/set-up"} />
        <.button
          :if={MapSet.size(@connected) > 0}
          id="set-up-continue"
          variant="primary"
          size="md"
          navigate={~p"/#{@scope.organisation}/#{@workspace}"}
        >
          {gettext("Continue")}
        </.button>
        <.button
          :if={MapSet.size(@connected) == 0}
          id="set-up-skip-button"
          variant="ghost"
          size="md"
          navigate={~p"/#{@scope.organisation}/#{@workspace}"}
        >
          {gettext("Skip")}
        </.button>
        <p
          :if={is_nil(@who_may) and MapSet.size(@connected) == 0}
          class="self-center text-[12.5px]/4 text-muted"
        >
          {gettext("You can connect one later from %{workspace}'s Overview.",
            workspace: @workspace.name
          )}
        </p>
      </div>

      <p
        :if={@adapters == []}
        id="set-up-no-source"
        class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
      >
        {gettext(
          "No work source for this type is set up on this instance. An instance admin sets one up in Instance settings › Adapters."
        )}
      </p>
      <div :if={@adapters == []} class="q-su-acts">
        <SetUpComponents.back steps={@steps} page={~p"/#{@scope.organisation}/set-up"} />
        <.button
          id="set-up-continue"
          variant="primary"
          size="md"
          navigate={~p"/#{@scope.organisation}/#{@workspace}"}
        >
          {gettext("Continue")}
        </.button>
      </div>

      <:context>
        <p id="set-up-what">
          {pgettext("plain", "Bring tickets in from a system this instance has set up.")}
        </p>
        <p id="set-up-backlog">
          {gettext("%{workspace}'s Backlog lists the tickets of the work sources it connects.",
            workspace: @workspace.name
          )}
          <span :for={adapter <- @adapters} :if={adapter.id in @ready}>
            {gettext(
              "Connect opens %{adapter} in this tab, and %{adapter} sends you back to Qory Apiary after its steps.",
              adapter: adapter.name
            )}
          </span>
        </p>
        <SetUpComponents.outside
          :for={{adapter, guide} <- guides(@adapters, @ready)}
          id={"set-up-help-#{adapter.public_id}"}
          title={gettext("On %{adapter}", adapter: adapter.name)}
          guide={guide}
        >
          <:note :if={@one_workspace and Adapters.items?(adapter)}>
            {gettext(
              "%{workspace} gets every %{collection} you picked, because %{organisation} has one workspace.",
              workspace: @workspace.name,
              collection: collection_word(adapter),
              organisation: @scope.organisation.name
            )}
          </:note>
        </SetUpComponents.outside>
      </:context>
    </SetUpComponents.frame>
    """
  end

  # Each adapter whose Connect can be pressed, among the ids `ready`, and whose guide gives
  # steps for connecting it, with them.
  defp guides(adapters, ready) do
    for adapter <- adapters,
        adapter.id in ready,
        guide = Adapters.guide(adapter, :connect),
        do: {adapter, guide}
  end

  # The adapter's word for one of its collections, as a text it sent is shown.
  defp collection_word(adapter),
    do:
      adapter
      |> Adapters.collection_noun()
      |> SourceComponents.collection()
      |> Apiary.ExternalText.line()

  # What an adapter brings in, in its words for its items where it names them.
  defp source_line(adapter) do
    case Adapters.item_noun(adapter) do
      nil ->
        gettext("Tickets from %{integration}.", integration: adapter.name)

      noun ->
        gettext("Tickets from %{integration} %{items}.",
          integration: adapter.name,
          items: SourceComponents.items(noun)
        )
    end
  end
end
