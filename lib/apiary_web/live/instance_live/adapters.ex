defmodule ApiaryWeb.InstanceLive.Adapters do
  # Instance settings › Adapters, for the instance's admins: the instance's adapters
  # (`:index`). Add for one entry of the catalogue is `ApiaryWeb.AdapterLive.AccessKey`'s.
  # A page of the Instance level, with no organisation: its gate asks the instance whether
  # the feature is on (`use ApiaryWeb.Features, instance: :factory`), and anyone but an
  # instance admin is answered as a path that does not exist, as on the Instance's other
  # pages.
  #
  # Each adapter is a row, by name: its name, which leads to its Overview, its public id,
  # how often it pulls, or that it has not declared it yet, and its state
  # (`ApiaryWeb.AdapterComponents.adapter_seen/1`): No key yet, or when it was last seen,
  # or Never seen, all the rows' times read at once. Where the table is narrow, the Pulls
  # and State columns give way to one line under the name: how often it pulls, then its
  # state; or, before it declares, its state, then "not declared yet". With none, the page
  # says there is no adapter yet. The instance has no catalogue of adapters to add yet, so
  # the page lists none.
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

    list = Adapters.list_adapters(scope)
    {:ok, seen} = Adapters.last_seen(scope, list)

    adapters =
      for adapter <- list,
          do: %{
            adapter: adapter,
            connected: AccessKeys.active_key?(adapter),
            seen: Map.get(seen, adapter.id),
            every: AdapterComponents.pulls_every(AdapterComponents.sync_of(adapter))
          }

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
          {pgettext(
            "plain",
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
          <:col :let={%{adapter: adapter} = row} label={gettext("Adapter")} kind="title">
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
            <.narrow_line row={row} />
          </:col>
          <:col :let={row} label={gettext("Pulls")} from="sm">
            <span id={"adapter-#{row.adapter.public_id}-pulls"}>
              <%= if row.every do %>
                {AdapterComponents.interval_label(row.every)}
              <% else %>
                <span class="text-faint">{gettext("Not declared yet")}</span>
              <% end %>
            </span>
          </:col>
          <:col :let={row} sr_label={gettext("State")} class="text-right" from="sm">
            <AdapterComponents.adapter_seen
              id={"adapter-#{row.adapter.public_id}-state"}
              adapter={row.adapter}
              connected={row.connected}
              seen={row.seen}
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

  attr :row, :map, required: true

  # The row's line where the table is narrow, in place of the Pulls and State columns,
  # which show from the width that hides it: how often the adapter pulls, then its state;
  # before it declares, its state, then that it has not declared.
  defp narrow_line(%{row: %{adapter: adapter}} = assigns) do
    assigns = assign(assigns, :id, "adapter-#{adapter.public_id}-narrow")

    ~H"""
    <span
      id={@id}
      class="mt-0.5 flex flex-wrap items-baseline gap-x-1.5 text-[12.5px] text-muted @min-[600px]:hidden"
    >
      <%= if @row.every do %>
        <span>{AdapterComponents.interval_label(@row.every)}</span>
        <span aria-hidden="true" class="text-faint">·</span>
        <.narrow_state id={@id} row={@row} />
      <% else %>
        <.narrow_state id={@id} row={@row} />
        <span aria-hidden="true" class="text-faint">·</span>
        <span>{gettext("not declared yet")}</span>
      <% end %>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true

  defp narrow_state(assigns) do
    ~H"""
    <AdapterComponents.adapter_seen
      id={"#{@id}-state"}
      adapter={@row.adapter}
      connected={@row.connected}
      seen={@row.seen}
    />
    """
  end
end
