defmodule ApiaryWeb.AdapterLive.Show do
  # An integration's page in Organisation settings › Integrations (`:collections`), by its
  # adapter's public id (`na_…`), for whoever may read the instance's adapters in the
  # organisation (`adapter.read`, members), behind the `factory` feature. Its settings and
  # its keys are the instance admins' (`ApiaryWeb.InstanceLive.Adapter`,
  # `ApiaryWeb.AdapterLive.AccessKey`). An adapter the person does not find is a path that
  # does not exist.
  #
  # Under the integration's name, where the organisation's connection to it stands
  # (`Apiary.Adapters.Connections`):
  #
  #   * not installed: no connection, a pending one whose latest pass came back refused
  #     or cancelled, which the return's flash says why, or one started before today;
  #   * pending, started today, its pass still good: who started the install and when,
  #     and that it may be finished on the integration or started again; with the pass
  #     expired, that it expired;
  #   * installed: who installed it and when, then its collections, the section's heading
  #     in the adapter's words. Until the adapter's first listing names the connection, a
  #     line says the page waits for the integration to send them; a minute after the page
  #     opened so, it says to install again if nothing appears, beside Install.
  #
  # While it is not installed, the install block follows
  # (`ApiaryWeb.IntegrationComponents`), to whoever may connect one (`adapter.connect`,
  # owners and admins). The page follows the organisation's connections and collections
  # as they change
  # (`Apiary.Adapters.Collections.subscribe/1`).
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Access, :"adapter.read"}

  alias Apiary.{Access, Adapters}
  alias Apiary.Adapters.{Collections, Connection, Connections}
  alias ApiaryWeb.{IntegrationComponents, People, SettingsComponents}

  # How long the page waits for the first listing before it says to install again.
  @late_after :timer.minutes(1)

  @impl true
  def mount(%{"adapter_id" => adapter_id}, _session, socket) do
    scope = socket.assigns.current_scope
    adapter = Adapters.get_adapter(scope, adapter_id) || raise(ApiaryWeb.NotFound)

    if connected?(socket), do: :ok = Collections.subscribe(scope)

    {:ok,
     socket
     |> assign(
       page_title: IntegrationComponents.page_title(scope, [adapter.name]),
       sections: SettingsComponents.sections(scope, :organisation),
       paths: IntegrationComponents.paths(scope, adapter),
       adapter: adapter,
       connects: Access.can?(scope, :"adapter.connect", scope.organisation),
       late: false,
       timer: false
     )
     |> load()}
  end

  # The connection as it stands, the state it puts the page in, and who started it.
  defp load(socket) do
    %{current_scope: scope, adapter: adapter} = socket.assigns
    connection = Map.get(Connections.live_by_adapter(scope), adapter.id)
    state = state(connection)

    person =
      connection &&
        People.member(People.accounts([connection.created_by_id]), connection.created_by_id)

    socket
    |> assign(connection: connection, state: state, person: person)
    |> wait()
  end

  # Starts the minute the page waits for the first listing, once, as the page opens in
  # that state or comes to it.
  defp wait(%{assigns: %{state: :waiting, timer: false}} = socket) do
    if connected?(socket) do
      Process.send_after(self(), :late, @late_after)
      assign(socket, :timer, true)
    else
      socket
    end
  end

  defp wait(socket), do: socket

  defp state(nil), do: :not_installed

  defp state(%Connection{state: :connected, listed_at: nil}), do: :waiting
  defp state(%Connection{state: :connected}), do: :listed

  defp state(%Connection{state: :pending, pass_nonce_used_at: nil} = connection) do
    cond do
      not today?(connection.updated_at) -> :not_installed
      is_nil(connection.pass_expires_at) -> :not_installed
      DateTime.compare(connection.pass_expires_at, DateTime.utc_now()) == :gt -> :pending
      true -> :expired
    end
  end

  defp state(%Connection{}), do: :not_installed

  defp today?(at), do: DateTime.to_date(Format.local(at)) == Format.today()

  @impl true
  def handle_info(:late, socket) do
    {:noreply, assign(socket, :late, socket.assigns.state == :waiting)}
  end

  def handle_info({:connection_changed, %{adapter_id: id}}, socket)
      when id == socket.assigns.adapter.id,
      do: {:noreply, reload(socket)}

  def handle_info({:collections_changed, %{connection_id: id}}, socket) do
    case socket.assigns.connection do
      %Connection{id: ^id} -> {:noreply, reload(socket)}
      _other -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The adapter and its connection read again; an adapter deleted meanwhile leaves for the
  # list.
  defp reload(socket) do
    %{current_scope: scope, adapter: adapter, paths: paths} = socket.assigns

    case Adapters.get_adapter(scope, adapter.public_id) do
      nil -> push_navigate(socket, to: paths.list)
      adapter -> socket |> assign(:adapter, adapter) |> load()
    end
  end

  @impl true
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
      <:crumb title={@adapter.name}>{@adapter.name}</:crumb>

      <.settings_page
        section={:integrations}
        title={@adapter.name}
        measure={if @state in [:waiting, :listed], do: "list", else: "read"}
      >
        <:subtitle>
          <span id="integration-status">{status(assigns)}</span>
        </:subtitle>

        <IntegrationComponents.install_block
          :if={@connects && @state in [:not_installed, :pending, :expired]}
          id="integration-install"
          adapter={@adapter}
          organisation={@current_scope.organisation}
          collections={collection_word(@adapter, :other)}
          named={false}
        />

        <section :if={@state == :waiting} id="collections" aria-labelledby="collections-heading">
          <h2
            id="collections-heading"
            class="mt-2 mb-1.5 flex items-baseline gap-2 text-sm/5 font-semibold"
          >
            {collection_label(@adapter)}
          </h2>
          <p id="collections-waiting" role="status" class="mb-3 text-[13.5px]/5">
            <span class="q-sdot q-sdot-running">
              <i aria-hidden="true"></i><span>{gettext(
                "Waiting for %{integration} to send its %{collections}…",
                integration: @adapter.name,
                collections: collection_word(@adapter, :other)
              )}</span>
            </span>
          </p>
          <div
            :if={@late && @connects}
            id="collections-late"
            class="mb-3 flex flex-wrap items-center gap-2.5 text-[13.5px] text-muted"
          >
            <span>{gettext("If nothing appears, install again.")}</span>
            <.button id="collections-install" type="button" disabled>
              <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />{gettext("Install")}
            </.button>
          </div>
        </section>
      </.settings_page>
    </Layouts.app>
    """
  end

  # The line under the name: where the connection stands.
  defp status(%{state: state} = assigns) when state in [:waiting, :listed] do
    at = assigns.connection.connected_at

    if today?(at),
      do: gettext("Installed by %{person} today.", person: assigns.person),
      else:
        gettext("Installed by %{person} on %{date}.",
          person: assigns.person,
          date: Format.day(at)
        )
  end

  defp status(%{state: :pending} = assigns) do
    gettext(
      "Not installed. %{person} started an install today at %{time} that isn't finished: finish it on %{integration}, or press Install to start again.",
      person: assigns.person,
      time: Format.time(assigns.connection.updated_at),
      integration: assigns.adapter.name
    )
  end

  defp status(%{state: :expired} = assigns) do
    gettext(
      "Not installed. %{person}'s install, started today at %{time}, expired before it was finished. Press Install to start again.",
      person: assigns.person,
      time: Format.time(assigns.connection.updated_at)
    )
  end

  defp status(%{state: :not_installed}), do: gettext("Not installed.")

  # The section's heading: the word for many of the adapter's collections, its first
  # letter in upper case.
  defp collection_label(adapter) do
    {first, rest} = adapter |> collection_word(:other) |> String.split_at(1)
    String.upcase(first) <> rest
  end

  # The word for many of the adapter's collections: what it calls them
  # (`Apiary.Adapters.collection_noun/1`), else the domain's word.
  # Swap for SourceComponents.collection/1 and collections/1 once they're on next.
  defp collection_word(adapter, :other) do
    case Adapters.collection_noun(adapter) do
      %{other: other} -> other
      nil -> pgettext("source collection, when its adapter names none", "collections")
    end
  end
end
