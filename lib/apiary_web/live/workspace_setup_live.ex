defmodule ApiaryWeb.WorkspaceSetupLive do
  # The workspace set-up, `/:org/set-up`: the page every organisation with no workspace in
  # use lands on (`ApiaryWeb.UserAuth.signed_in_path/1`), in two steps.
  #
  # Step 1, while the organisation has no workspace in use
  # (`Apiary.Organisations.has_workspace?/1`), for a person `workspace.create` allows
  # there (`Apiary.Access`): the edition's line on which workspace this is
  # (`c:Apiary.Edition.first_workspace_line/1`), the Type field
  # (`ApiaryWeb.WorkspaceComponents.type_field/1`), and Create workspace, which makes Main
  # (`Apiary.Organisations.create_first_workspace/2`). Anyone else is told who sets it up
  # (`c:Apiary.Edition.first_workspace_waiting_line/1`). Where a workspace marked for
  # deletion still has the name Main, the page says to restore it.
  #
  # Step 2, once the organisation has a workspace, for the workspace the person's scope
  # has, with the `factory` feature, for a person `adapter.connect` allows: the instance's
  # configured adapters that serve the workspace's type (`Apiary.Adapters.list_configured/1`),
  # each with Connect, the Install of Organisation settings › Integrations
  # (`ApiaryWeb.IntegrationComponents.install_form/1`), and Skip; with none, that no work
  # source for the type is set up on the instance, and Continue. Above the list, for each
  # adapter whose Connect can be pressed (`ApiaryWeb.IntegrationComponents.ready?/1`) and
  # whose guide gives steps for connecting it (`Apiary.Adapters.guide/2`), those
  # steps after a first step of Qory Apiary's, Connect, and, while the organisation has one
  # workspace, a note that the workspace gets every collection picked. Skip and Continue
  # lead to the workspace's Overview, and so does Create workspace without the feature. A
  # person `adapter.connect` refuses sees the same step where the edition says who may
  # connect one (`c:ApiaryWeb.Edition.who_may_sentence/2`), with no Connect and no steps:
  # the adapters, that sentence, and Skip; with none, the line and Continue. Anyone else,
  # once there is a workspace, is sent on: to the workspace's first page, or to the
  # organisation's page where they reach no workspace.
  #
  # Step 2 is of the `factory` feature, and the module reference leaves the module out.
  @moduledoc false

  use ApiaryWeb, :live_view

  alias Apiary.{Access, Adapters, Features, Organisations}
  alias Apiary.Lingo.Domain
  alias ApiaryWeb.{IntegrationComponents, SetUpComponents, SourceComponents, WorkspaceComponents}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    organisation = scope.organisation

    cond do
      not Organisations.has_workspace?(organisation) ->
        {:ok, assign_type_step(socket)}

      is_nil(scope.workspace) ->
        {:ok, push_navigate(socket, to: ~p"/#{organisation}")}

      not Features.visible?(scope, :factory) ->
        {:ok, push_navigate(socket, to: Layouts.workspace_landing(scope))}

      Access.can?(scope, :"adapter.connect", organisation) ->
        {:ok, assign_source_step(socket, nil)}

      who_may = ApiaryWeb.Edition.who_may_sentence(:"adapter.connect", scope) ->
        {:ok, assign_source_step(socket, who_may)}

      true ->
        {:ok, push_navigate(socket, to: Layouts.workspace_landing(scope))}
    end
  end

  defp assign_type_step(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      page_title: gettext("Set up your workspace"),
      step: :type,
      creates: Access.can?(scope, :"workspace.create", scope.organisation),
      refusal: nil,
      form: to_form(%{"domain" => nil}, as: "workspace")
    )
  end

  # `who_may` is the edition's sentence of who may connect a work source, for a person
  # `adapter.connect` refuses, or nil for one it allows.
  defp assign_source_step(socket, who_may) do
    scope = socket.assigns.current_scope
    workspace = scope.workspace

    assign(socket,
      page_title: gettext("Connect a work source to %{workspace}", workspace: workspace.name),
      step: :source,
      adapters: Adapters.list_configured(Domain.for_workspace(workspace)),
      one_workspace: match?([_one], Organisations.list_workspaces(scope)),
      sending: nil,
      who_may: who_may
    )
  end

  @impl true
  def handle_event(
        "create",
        %{"workspace" => %{"domain" => domain}},
        %{assigns: %{step: :type}} = socket
      )
      when is_binary(domain) do
    scope = socket.assigns.current_scope
    organisation = scope.organisation

    case Organisations.create_first_workspace(scope, %{"domain" => domain}) do
      {:ok, workspace} ->
        to =
          if Features.visible?(scope, :factory),
            do: ~p"/#{organisation}/set-up",
            else: ~p"/#{organisation}/#{workspace}"

        {:noreply, push_navigate(socket, to: to)}

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
      <div id="set-up" class="mx-auto grid w-full max-w-[480px] gap-4 md:pt-6">
        <.type_step
          :if={@step == :type}
          scope={@current_scope}
          creates={@creates}
          form={@form}
          refusal={@refusal}
        />
        <.source_step
          :if={@step == :source}
          scope={@current_scope}
          adapters={@adapters}
          one_workspace={@one_workspace}
          sending={@sending}
          who_may={@who_may}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :scope, :map, required: true
  attr :creates, :boolean, required: true
  attr :form, :any, required: true
  attr :refusal, :atom, required: true

  defp type_step(%{creates: false} = assigns) do
    ~H"""
    <SetUpComponents.heading>{gettext("Set up your workspace")}</SetUpComponents.heading>
    <p id="set-up-waiting" class="text-sm/5 text-muted">
      {Apiary.Edition.first_workspace_waiting_line(@scope.organisation)}
    </p>
    """
  end

  defp type_step(assigns) do
    assigns = assign(assigns, :workspace, Organisations.default_workspace_name())

    ~H"""
    <SetUpComponents.heading>
      {gettext("Set up your workspace")}
      <:subtitle>{Apiary.Edition.first_workspace_line(@scope.organisation)}</:subtitle>
    </SetUpComponents.heading>

    <SetUpComponents.help id="set-up-help">
      <ol>
        <li>
          <.rich text={
            rich_pgettext(
              "workspace type",
              "In %{field}, choose %{software} if %{workspace} works on code in repositories, or %{general} for any other work.",
              field: {:b, gettext("Type")},
              software: {:b, Domain.Software.type_name()},
              workspace: @workspace,
              general: {:b, Domain.General.type_name()}
            )
          } />
        </li>
        <li>
          <.rich text={rich_gettext("Press %{button}.", button: {:b, gettext("Create workspace")})} />
        </li>
      </ol>
    </SetUpComponents.help>

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

    <.form for={@form} id="set-up-form" phx-submit="create" class="grid gap-4" novalidate>
      <WorkspaceComponents.type_field field={@form[:domain]} />
      <.button
        variant="primary"
        size="md"
        class="btn-block"
        loading_text={gettext("Creating")}
      >
        {gettext("Create workspace")}
      </.button>
    </.form>
    """
  end

  attr :scope, :map, required: true
  attr :adapters, :list, required: true
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
    <SetUpComponents.heading step={2} total={2}>
      {gettext("Connect a work source to %{workspace}", workspace: @workspace.name)}
      <:subtitle>
        {pgettext("plain", "Bring tickets in from a system this instance has set up.")}
      </:subtitle>
    </SetUpComponents.heading>

    <SetUpComponents.guide
      :for={{adapter, guide} <- guides(@adapters, @ready)}
      id={"set-up-help-#{adapter.public_id}"}
      guide={guide}
    >
      <:first>
        <.rich text={
          rich_gettext("Press %{button} beside %{adapter}. %{name} opens.",
            button: {:b, gettext("Connect")},
            adapter: {:b, adapter.name},
            name: adapter.name
          )
        } />
      </:first>
      <:note :if={@one_workspace and Adapters.items?(adapter)}>
        {gettext(
          "%{workspace} gets every %{collection} you picked, because %{organisation} has one workspace.",
          workspace: @workspace.name,
          collection: collection_word(adapter),
          organisation: @scope.organisation.name
        )}
      </:note>
    </SetUpComponents.guide>

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
        <IntegrationComponents.install_form
          :if={is_nil(@who_may)}
          id={"set-up-source-#{adapter.public_id}-connect"}
          adapter={adapter}
          action={IntegrationComponents.paths(@scope, adapter).install}
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

    <div :if={@adapters != []} id="set-up-skip" class="flex flex-wrap items-center gap-3">
      <.button
        id="set-up-skip-button"
        variant="ghost"
        navigate={~p"/#{@scope.organisation}/#{@workspace}"}
      >
        {gettext("Skip")}
      </.button>
      <p :if={is_nil(@who_may)} class="text-[12.5px]/4 text-muted">
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
    <div :if={@adapters == []}>
      <.button
        id="set-up-continue"
        variant="primary"
        navigate={~p"/#{@scope.organisation}/#{@workspace}"}
      >
        {gettext("Continue")}
      </.button>
    </div>
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
