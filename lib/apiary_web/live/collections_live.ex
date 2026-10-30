defmodule ApiaryWeb.CollectionsLive do
  # Workspace settings › Work sources (`/:org/:workspace/settings/work-sources`,
  # `:sources`) and › Destinations (`/:org/:workspace/settings/destinations`,
  # `:destinations`), with the `factory` feature: the cards of the set-up's steps Work
  # sources and Destinations, under a question, with the same behaviour. A card per live
  # grant of the organisation's connections (`Apiary.WorkspaceSetup.cards/4`,
  # `ApiaryWeb.IntegrationComponents.grant_card/1`): the adapter's title and the
  # account's, how many of the grant's collections are chosen for the workspace, of how
  # many, or All, and Choose, which opens the chooser at
  # `/:org/:workspace/settings/choose` (`ApiaryWeb.ChooseCollectionsLive`, `:settings`),
  # whose Save and Back return here. An adapter connected with no grant yet shows
  # Connected. Connect another source, or Connect another destination, lists the
  # instance's configured adapters that serve the type
  # (`Apiary.Adapters.list_configured/1`) and that the organisation has not connected,
  # each Connecting… while its connection is pending, with Connect, the Install of
  # Organisation settings › Integrations (`ApiaryWeb.IntegrationComponents.install_form/1`),
  # whose return leads to the set-up's step of the workspace
  # (`ApiaryWeb.ConnectSession.back?/1`); it is open while the page has no card and no
  # connected adapter.
  #
  # Every member reads them (`adapter.read`, which the cards need); a person whom
  # `adapter.connect` does not allow sees the adapters with no Connect, and who may
  # connect; a person whom `collection.assign` does not allow sees who may assign. The
  # page listens to the organisation's collections and connections
  # (`Apiary.Adapters.Collections.subscribe/1`) and reads the cards again on each change.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Access, :"adapter.read"}

  alias Apiary.{Access, Adapters, WorkspaceSetup}
  alias Apiary.Adapters.Collections
  alias Apiary.Adapters.Connections, as: AdapterConnections
  alias Apiary.Lingo.Domain
  alias ApiaryWeb.{IntegrationComponents, SettingsComponents}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      _subscribed = Collections.subscribe(scope)
    end

    {:ok,
     assign(socket,
       sections: SettingsComponents.sections(scope, :workspace),
       domain: Domain.for_workspace(scope.workspace),
       sending: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    title = title(socket.assigns.live_action)

    {:noreply,
     socket
     |> assign(
       list: socket.assigns.live_action,
       title: title,
       page_title:
         SettingsComponents.page_title(socket.assigns.current_scope, :workspace, [title])
     )
     |> load()}
  end

  defp title(:sources), do: gettext("Work sources")
  defp title(:destinations), do: gettext("Destinations")

  # The cards of the list's grants; the configured adapters for the list, those connected
  # with no card yet, and those not connected, each with Connect. `may` and `who_may` are
  # of the chooser's Save (`collection.assign`); `may_connect` and `who_connects` of
  # Connect (`adapter.connect`).
  defp load(socket) do
    %{current_scope: scope, domain: domain, list: list} = socket.assigns
    role = if list == :sources, do: :items, else: :targets
    may_connect = Access.can?(scope, :"adapter.connect", scope.organisation)

    adapters =
      for adapter <- Adapters.list_configured(domain),
          if(role == :items, do: Adapters.items?(adapter), else: adapter.targets == true),
          do: adapter

    connecting =
      for {adapter_id, %{state: :pending}} <- AdapterConnections.live_by_adapter(scope),
          into: MapSet.new(),
          do: adapter_id

    connected = WorkspaceSetup.connected_ids(scope.organisation, domain, role)
    cards = WorkspaceSetup.cards(scope, domain, list, scope.workspace)
    carded = MapSet.new(cards, & &1.adapter.id)

    assign(socket,
      cards: cards,
      adapters: adapters,
      waiting: for(a <- adapters, a.id in connected, a.id not in carded, do: a),
      unconnected: for(a <- adapters, a.id not in connected, do: a),
      connecting: connecting,
      ready:
        for(
          a <- adapters,
          may_connect,
          IntegrationComponents.ready?(a),
          into: MapSet.new(),
          do: a.id
        ),
      may: Access.can?(scope, :"collection.assign", scope.organisation),
      who_may: IntegrationComponents.who_assigns(scope, Enum.map(cards, & &1.adapter)),
      may_connect: may_connect,
      who_connects:
        ApiaryWeb.Access.who_may(
          scope,
          :"adapter.connect",
          gettext("Only owners and admins change the integrations of the organisation.")
        )
    )
  end

  @impl true
  # Connect, pressed for an adapter the page lists as not connected: the form then posts
  # to Install's path.
  def handle_event(
        "install",
        %{"integration" => public_id},
        %{assigns: %{may_connect: true}} = socket
      ) do
    if Enum.any?(socket.assigns.unconnected, &(&1.public_id == public_id)),
      do: {:noreply, assign(socket, :sending, public_id)},
      else: {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  # A collection or a connection of the organisation changed: the cards read again.
  def handle_info({event, _ids}, socket)
      when event in [:collections_changed, :connection_changed],
      do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The step's question, above the cards.
  defp question(:sources, workspace),
    do: gettext("Which work sources does %{workspace} use?", workspace: workspace.name)

  defp question(:destinations, workspace),
    do: gettext("Which targets may runs in %{workspace} change?", workspace: workspace.name)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        id: section_id(assigns.list),
        back: "set-up:#{assigns.list}:workspace=#{assigns.current_scope.workspace.public_id}"
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      sections={@sections}
      section={section(@list)}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        kind={:workspace}
        current={section(@list)}
        title={@title}
      >
        <:subtitle>{question(@list, @current_scope.workspace)}</:subtitle>
        <div class="grid gap-3">
          <ul :if={@cards != [] or @waiting != []} id={"#{@id}-grants"} class="grid gap-3">
            <IntegrationComponents.grant_card
              :for={card <- @cards}
              id={"#{@id}-grant-#{card.grant.public_id}"}
              card={card}
              list={@list}
              workspace={@current_scope.workspace}
              choose={chooser_path(@current_scope, @list, card)}
            />
            <li
              :for={adapter <- @waiting}
              id={"#{@id}-adapter-#{adapter.public_id}"}
              class="flex items-center gap-3 rounded-box border border-line bg-base-100 px-4 py-3"
            >
              <IntegrationComponents.mark class="size-5" />
              <p class="min-w-0 flex-1 truncate font-medium">{Adapters.title(adapter)}</p>
              <span
                id={"#{@id}-adapter-#{adapter.public_id}-connected"}
                class="q-sdot q-sdot-completed text-[13px]/5"
              >
                <i aria-hidden="true"></i><span>{gettext("Connected")}</span>
              </span>
            </li>
          </ul>

          <details
            :if={@unconnected != []}
            id={"#{@id}-connect"}
            class="grid gap-3"
            open={@cards == [] and @waiting == []}
          >
            <summary id={"#{@id}-connect-another"} class="btn btn-sm w-fit">
              <span :if={@list == :sources}>{gettext("Connect another source")}</span>
              <span :if={@list == :destinations}>{gettext("Connect another destination")}</span>
            </summary>
            <ul id={"#{@id}-adapters"} class="mt-3 grid gap-3">
              <li
                :for={adapter <- @unconnected}
                id={"#{@id}-adapter-#{adapter.public_id}"}
                class="flex items-center gap-3 rounded-box border border-line bg-base-100 px-4 py-3"
              >
                <IntegrationComponents.mark class="size-5" />
                <p class="min-w-0 flex-1 truncate font-medium">{Adapters.title(adapter)}</p>
                <span
                  :if={MapSet.member?(@connecting, adapter.id)}
                  id={"#{@id}-adapter-#{adapter.public_id}-connecting"}
                  role="status"
                  class="q-sdot q-sdot-pending text-[13px]/5"
                >
                  <i aria-hidden="true"></i><span>{gettext("Connecting…")}</span>
                </span>
                <span
                  :if={not MapSet.member?(@connecting, adapter.id)}
                  id={"#{@id}-adapter-#{adapter.public_id}-not-connected"}
                  class="q-sdot text-[13px]/5 text-muted"
                >
                  <i aria-hidden="true"></i><span>{gettext("Not connected")}</span>
                </span>
                <IntegrationComponents.install_form
                  :if={@may_connect}
                  id={"#{@id}-adapter-#{adapter.public_id}-connect"}
                  adapter={adapter}
                  action={IntegrationComponents.paths(@current_scope, adapter).install <> "?" <> URI.encode_query(back: @back)}
                  ready={adapter.id in @ready}
                  sending={@sending == adapter.public_id}
                  label={gettext("Connect")}
                />
              </li>
            </ul>
          </details>

          <p
            :if={!@may and @cards != []}
            id={"#{@id}-who-may"}
            class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
          >
            {@who_may}
          </p>

          <p
            :if={@adapters == [] and @list == :sources}
            id={"#{@id}-no-adapter"}
            class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
          >
            {gettext(
              "No work source for this type is set up on this instance. An instance admin sets one up in Instance settings › Adapters."
            )}
          </p>

          <p
            :if={@adapters == [] and @list == :destinations}
            id={"#{@id}-no-adapter"}
            class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
          >
            {gettext(
              "No work destination for this type is set up on this instance. An instance admin sets one up in Instance settings › Adapters."
            )}
          </p>

          <p
            :if={!@may_connect}
            id={"#{@id}-connect-who-may"}
            class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
          >
            {@who_connects}
          </p>
        </div>
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end

  # The chooser of `card`'s grant for the list `list`, in the scope's workspace's
  # settings.
  defp chooser_path(%{organisation: organisation, workspace: workspace}, list, card),
    do:
      ~p"/#{organisation}/#{workspace}/settings/choose?#{[step: list, grant: card.grant.public_id]}"

  # The key of the page's section in the settings' list.
  defp section(:sources), do: :work_sources
  defp section(:destinations), do: :destinations

  defp section_id(:sources), do: "work-sources"
  defp section_id(:destinations), do: "destinations"
end
