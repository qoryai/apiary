defmodule ApiaryWeb.InstanceLive.Adapters do
  # Instance settings › Adapters, for the instance's admins: the instance's adapters, with
  # the catalogue of the ones it can add (`:index`). Add for one entry of the catalogue is
  # `ApiaryWeb.AdapterLive.AccessKey`'s. A page of the Instance level, with no
  # organisation: its gate asks the instance whether the feature is on (`use
  # ApiaryWeb.Features, instance: :factory`), and anyone but an instance admin is answered
  # as a path that does not exist, as on the Instance's other pages.
  #
  # Each adapter is a row, by name: its name, which leads to its Overview, its public id,
  # and its state (`ApiaryWeb.AdapterComponents.adapter_state/1`), No key yet or
  # Connected. With none, the page says there is no adapter yet. The instance has no
  # catalogue of adapters to add yet, so the page lists none.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, instance: :factory

  alias Apiary.{AccessKeys, Adapters}
  alias ApiaryWeb.AdapterComponents

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if Adapters.authorize_instance(scope) != :ok, do: raise(ApiaryWeb.NotFound)

    adapters =
      for adapter <- Adapters.list_adapters(scope),
          do: %{adapter: adapter, connected: AccessKeys.active_key?(adapter)}

    {:ok,
     assign(socket,
       page_title: AdapterComponents.page_title(scope, []),
       adapters: adapters
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:adapters}
    >
      <.settings_page section={:adapters} title={gettext("Adapters")} measure="list">
        <:subtitle>
          {gettext(
            "The adapters that bring work into Qory from other systems. Each organisation installs the ones it uses from its Integrations page; their keys and how often they pull are set here."
          )}
        </:subtitle>

        <.table
          :if={@adapters != []}
          id="adapters"
          label={gettext("Adapters")}
          rows={@adapters}
          row_id={&"adapter-#{&1.adapter.public_id}"}
        >
          <:col :let={%{adapter: adapter}} label={gettext("Adapter")} kind="title">
            <span class="inline-flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
              <.link
                id={"adapter-#{adapter.public_id}-name"}
                navigate={AdapterComponents.paths(adapter).overview}
                class="font-medium hover:underline"
              >
                {adapter.name}
              </.link>
              <span class="q-mono text-[12.5px] text-muted">{adapter.public_id}</span>
            </span>
          </:col>
          <:col :let={row} sr_label={gettext("State")} class="text-right">
            <AdapterComponents.adapter_state
              id={"adapter-#{row.adapter.public_id}-state"}
              connected={row.connected}
            />
          </:col>
        </.table>

        <.empty_state
          :if={@adapters == []}
          icon={nil}
          tone="neutral"
          title={gettext("No adapter yet")}
        />
      </.settings_page>
    </Layouts.app>
    """
  end
end
