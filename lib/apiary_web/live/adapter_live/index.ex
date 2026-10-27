defmodule ApiaryWeb.AdapterLive.Index do
  # Organisation settings › Integrations: the list of the instance's adapters, as the
  # organisation's people read them (`:index`), and Add an integration, where an owner or
  # an admin connects the organisation to one (`:new`). Making one is the instance
  # admins' (`ApiaryWeb.AdapterLive.AccessKey`, Add in Instance settings › Adapters).
  #
  # The list is for whoever may read the instance's adapters in the organisation
  # (`adapter.read`, members), behind the `factory` feature. Each adapter in use is a row,
  # by name: its name, and whether it is installed in the organisation, which it is while
  # the organisation's connection to it is connected (`Apiary.Adapters.Connections`); a
  # pending one is not installed yet. An installed one says how many collections it
  # reaches, in its words (`Apiary.Adapters.Collections.counts/2`), and, with several
  # workspaces, how many of them are assigned to none, when any is. Its name, and its
  # chevron, lead to its page (`ApiaryWeb.AdapterLive.Show`); one not installed offers Add
  # to whoever may connect one (`adapter.connect`, owners and admins), which leads to Add
  # an integration. With no adapter in the instance, an empty state takes the table's
  # place: "No integration yet", and that an instance admin adds them. Under the table,
  # what an integration installed here does, in each adapter's words for its collections,
  # joined where they differ; and under the table or the empty state, for whoever may not
  # connect one, who does: with several workspaces, who assigns their collections too, in
  # the adapters' words when they all name the same.
  #
  # Add an integration is for whoever may connect one (`adapter.connect`); to anyone else
  # it is a path that does not exist. It offers only the configured adapters that serve
  # the domain of one of the organisation's workspaces, or any domain while it has none
  # (`Apiary.Adapters.offered_domains/1`, `Apiary.Adapters.list_configured/1`), read after
  # that check; Install asks the same (`Apiary.Adapters.offered?/2`). Each one not
  # installed is a block
  # (`ApiaryWeb.IntegrationComponents.install_block/1`): what Install does, in its words
  # for its collections, then Install, which posts to the Install path and sends the
  # person on to the integration, and Cancel, back to the list. Once pressed, the block
  # says where the person is taken. In place of the lead, a line says that an instance
  # admin sets one up, where none is configured; that none serves the organisation's
  # workspaces, where some are configured and none serves those domains; or that every
  # one is installed.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Access, :"adapter.read"}

  alias Apiary.{Access, Adapters, Organisations}
  alias Apiary.Adapters.{Collections, Connections}
  alias Apiary.Lingo.Domain
  alias ApiaryWeb.{IntegrationComponents, SettingsComponents, SourceComponents}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    connects = Access.can?(scope, :"adapter.connect", scope.organisation)
    new? = socket.assigns.live_action == :new
    if new? and not connects, do: raise(ApiaryWeb.NotFound)

    workspaces = Organisations.list_workspaces(scope)

    adapters =
      if new?,
        do: configured(Adapters.offered_domains(scope)),
        else: Adapters.list_adapters(scope)

    live = Connections.live_by_adapter(scope)

    rows =
      for adapter <- adapters do
        connection = Map.get(live, adapter.id)

        installed = match?(%{state: :connected}, connection)

        %{
          adapter: adapter,
          installed: installed,
          counts: installed && Collections.counts(scope, connection),
          ready: new? and IntegrationComponents.ready?(adapter)
        }
      end

    {:ok,
     assign(socket,
       page_title: IntegrationComponents.page_title(scope, if(new?, do: [add_title()], else: [])),
       sections: SettingsComponents.sections(scope, :organisation),
       paths: IntegrationComponents.paths(scope),
       rows: rows,
       all_installed: rows != [] and Enum.all?(rows, & &1.installed),
       noun: Adapters.shared_collection_noun(adapters),
       nouns: Enum.map(adapters, &Adapters.collection_noun/1),
       connects: connects,
       several: length(workspaces) > 1,
       any_configured: new? and configured(Domain.choices()) != [],
       sending: nil
     )}
  end

  defp add_title, do: gettext("Add an integration")

  # The configured adapters that serve one of `domains`, each once, by name, as
  # `Apiary.Adapters.list_configured/1` orders them.
  defp configured(domains) do
    domains
    |> Enum.flat_map(&Adapters.list_configured/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{&1.name, &1.id})
  end

  @impl true
  def handle_event("install", %{"integration" => public_id}, socket) do
    case Enum.find(socket.assigns.rows, &(&1.adapter.public_id == public_id)) do
      %{installed: false, ready: true} -> {:noreply, assign(socket, :sending, public_id)}
      _none -> {:noreply, socket}
    end
  end

  @impl true
  def render(%{live_action: :new} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:organisation}
      sections={@sections}
      section={:integrations}
    >
      <:crumb>{add_title()}</:crumb>

      <.settings_page section={:integrations} title={add_title()}>
        <:subtitle :if={@rows != [] and !@all_installed}>
          {gettext("Install one of this instance's integrations for %{organisation}.",
            organisation: @current_scope.organisation.name
          )}
        </:subtitle>

        <p
          :if={@rows == [] and !@any_configured}
          id="add-none-set-up"
          class="text-[13.5px]/5 text-muted"
        >
          {gettext(
            "No integration is set up on this instance yet. An instance admin sets one up in Instance settings › Adapters."
          )}
        </p>

        <p
          :if={@rows == [] and @any_configured}
          id="add-none-for-type"
          class="text-[13.5px]/5 text-muted"
        >
          {gettext(
            "No integration that serves this organisation's workspaces is set up on this instance. An instance admin sets one up in Instance settings › Adapters."
          )}
        </p>

        <p
          :if={@all_installed}
          id="add-none"
          class="text-[13.5px]/5 text-muted"
        >
          {gettext("All integrations are installed.")}
        </p>

        <div :if={!@all_installed} class="grid gap-4">
          <IntegrationComponents.install_block
            :for={row <- @rows}
            :if={!row.installed}
            id={"add-#{row.adapter.public_id}"}
            adapter={row.adapter}
            organisation={@current_scope.organisation}
            collections={SourceComponents.collections(Adapters.collection_noun(row.adapter))}
            action={IntegrationComponents.paths(@current_scope, row.adapter).install}
            ready={row.ready}
            sending={@sending == row.adapter.public_id}
            cancel={@paths.list}
          />
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:organisation}
      sections={@sections}
      section={:integrations}
    >
      <.settings_page section={:integrations} title={gettext("Integrations")} measure="list">
        <:subtitle>
          {gettext("This instance's integrations, and whether each is installed for %{organisation}.",
            organisation: @current_scope.organisation.name
          )}
        </:subtitle>

        <.empty_state
          :if={@rows == []}
          icon={nil}
          tone="neutral"
          title={gettext("No integration yet")}
        >
          <p id="integrations-none">
            {gettext(
              "An instance admin adds integrations in Instance settings › Adapters. %{organisation} can install them here once they are added.",
              organisation: @current_scope.organisation.name
            )}
          </p>
        </.empty_state>

        <.table
          :if={@rows != []}
          id="integrations"
          label={gettext("Integrations")}
          rows={@rows}
          row_id={&"integration-#{&1.adapter.public_id}"}
        >
          <:col :let={row} label={gettext("Integration")} kind="title">
            <.link
              :if={row.installed}
              id={"integration-#{row.adapter.public_id}-name"}
              navigate={IntegrationComponents.paths(@current_scope, row.adapter).show}
              class="inline-flex min-w-0 items-center gap-2.5 hover:underline"
            >
              <IntegrationComponents.mark /><span class="truncate">{row.adapter.name}</span>
            </.link>
            <span
              :if={!row.installed}
              id={"integration-#{row.adapter.public_id}-name"}
              class="inline-flex min-w-0 items-center gap-2.5"
            >
              <IntegrationComponents.mark /><span class="truncate">{row.adapter.name}</span>
            </span>
          </:col>
          <:col
            :let={row}
            label={gettext("In %{organisation}", organisation: @current_scope.organisation.name)}
          >
            <span
              :if={!row.installed}
              id={"integration-#{row.adapter.public_id}-state"}
              class="q-sdot"
            >
              <i aria-hidden="true"></i><span>{gettext("Not installed")}</span>
            </span>
            <span
              :if={row.installed}
              id={"integration-#{row.adapter.public_id}-state"}
              class="q-sdot q-sdot-completed !items-start !whitespace-normal"
            >
              <i aria-hidden="true" class="mt-[5px]"></i>
              <span><.rich text={installed_words(row, @several)} /></span>
            </span>
          </:col>
          <:action :let={row}>
            <.button
              :if={!row.installed && @connects}
              id={"integration-#{row.adapter.public_id}-add"}
              size="xs"
              navigate={@paths.new}
            >
              {gettext("Add")}
            </.button>
            <.button
              :if={row.installed}
              id={"integration-#{row.adapter.public_id}-open"}
              variant="ghost"
              size="xs"
              class="btn-square"
              navigate={IntegrationComponents.paths(@current_scope, row.adapter).show}
              aria-label={gettext("Open %{integration}", integration: row.adapter.name)}
            >
              <.icon name="hero-chevron-right-micro" class="size-4" />
            </.button>
          </:action>
        </.table>

        <div class="grid gap-1.5">
          <p :if={@rows != []} id="integrations-serve" class="q-foot-note">
            {gettext(
              "An integration installed here serves each workspace through the %{collections} assigned to it.",
              collections: SourceComponents.collections(@nouns, :and)
            )}
          </p>
          <p :if={!@connects && !@several} id="integrations-who" class="q-foot-note">
            {gettext("Owners and admins of %{organisation} install integrations.",
              organisation: @current_scope.organisation.name
            )}
          </p>
          <p :if={!@connects && @several} id="integrations-who" class="q-foot-note">
            {gettext(
              "Owners and admins of %{organisation} install integrations and assign their %{collections} to workspaces.",
              organisation: @current_scope.organisation.name,
              collections: SourceComponents.collections(@noun)
            )}
          </p>
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end

  # An installed integration's state: how many collections it reaches, in its words, and,
  # with several workspaces, how many of them are assigned to none, when any is.
  defp installed_words(
         %{adapter: adapter, counts: %{total: total, unassigned: unassigned}},
         several
       ) do
    noun = Adapters.collection_noun(adapter)

    words = [
      collection: SourceComponents.collection(noun),
      collections: SourceComponents.collections(noun)
    ]

    if several and unassigned > 0 do
      rich_ngettext(
        "Installed · %{number} %{collection}, %{unassigned} unassigned",
        "Installed · %{number} %{collections}, %{unassigned} unassigned",
        total,
        number: Format.number(total),
        collection: words[:collection],
        collections: words[:collections],
        unassigned: {:b, Format.number(unassigned), "font-normal text-primary-soft-content"}
      )
    else
      rich_ngettext(
        "Installed · %{number} %{collection}",
        "Installed · %{number} %{collections}",
        total,
        number: Format.number(total),
        collection: words[:collection],
        collections: words[:collections]
      )
    end
  end
end
