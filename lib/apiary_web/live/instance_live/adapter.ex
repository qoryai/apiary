defmodule ApiaryWeb.InstanceLive.Adapter do
  # An adapter's page in Instance settings › Adapters, for the instance's admins: its
  # Overview tab (`:overview`), its state, the install address it declared and how often
  # it pulls; and its Settings tab, how often it pulls, renaming it and removing it
  # (`:settings`, `:rename`, `:remove`). Its Access key tab is
  # `ApiaryWeb.AdapterLive.AccessKey`. A page of the Instance level, with no organisation:
  # its gate asks the instance whether the feature is on (`use ApiaryWeb.Features,
  # instance: :factory`), and anyone but an instance admin is answered as a path that does
  # not exist, as on the Instance's other pages.
  #
  # The Overview says the adapter's state, No key yet, with the way to connect it, or,
  # once it holds a key, when it was last seen or Never seen
  # (`ApiaryWeb.AdapterComponents.adapter_seen/1`), and reads it again as a key arrives
  # (`Apiary.Adapters.subscribe_keys/2`); the install address the adapter declared, and
  # how often it pulls (`Apiary.Adapters.sync_settings/2`), with Change, or that it
  # declared neither yet.
  #
  # The Settings tab holds how often the adapter pulls, chosen among the intervals its
  # declaration allows, its default marked, and saved with
  # `Apiary.Adapters.update_sync_interval/3`; before it declares, the choice is shown
  # disabled, with why. Then its name, with Rename…, and the danger zone, whose Remove
  # adapter… opens the Remove page. Rename and Remove are pages; each act is asked again
  # by the context function, and a removed adapter's pages leave for the list. A saved
  # interval and a rename are said on the Settings tab, a removal on the list.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, instance: :factory

  alias Apiary.{AccessKeys, Adapters}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.{AdapterComponents, SettingsComponents}

  @impl true
  def mount(%{"adapter_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with :ok <- Adapters.authorize_instance(scope),
         %Node{} = adapter <- Adapters.get_adapter(scope, public_id),
         {:ok, sync} <- Adapters.sync_settings(scope, adapter) do
      if connected?(socket), do: Adapters.subscribe_keys(scope, adapter)

      {:ok,
       socket
       |> assign(adapter: adapter, paths: AdapterComponents.paths(adapter), form: nil)
       |> assign(sync: sync, interval_form: nil)
       |> assign_connected()}
    else
      _not_theirs -> raise ApiaryWeb.NotFound
    end
  end

  # Whether the adapter holds an active key, and when one of its keys was last used.
  defp assign_connected(%{assigns: %{current_scope: scope, adapter: adapter}} = socket) do
    seen =
      case Adapters.last_seen(scope, adapter) do
        {:ok, seen} -> seen
        {:error, _reason} -> nil
      end

    assign(socket, connected: AccessKeys.active_key?(adapter), seen: seen)
  end

  @impl true
  def handle_params(%{"adapter_id" => public_id}, _uri, %{assigns: %{adapter: adapter}} = socket)
      when public_id != adapter.public_id,
      do: {:noreply, push_navigate(socket, to: AdapterComponents.paths(public_id).overview)}

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> apply_action(socket.assigns.live_action) |> titled()}
  end

  defp apply_action(socket, :rename),
    do: assign(socket, :form, rename_form(Adapters.change_adapter(socket.assigns.adapter)))

  defp apply_action(socket, :settings),
    do: assign(socket, form: nil, interval_form: interval_form(socket.assigns.sync))

  defp apply_action(socket, _action), do: assign(socket, :form, nil)

  # The interval choice, on how often the adapter pulls now: the default's choice, ""
  # (no setting), while none is set or the one set is the default; else the one set.
  defp interval_form(sync), do: to_form(%{"sync_interval" => chosen(sync)}, as: "sync")

  defp chosen(%{interval: interval, default: default})
       when is_nil(interval) or interval == default,
       do: ""

  defp chosen(%{interval: interval}), do: to_string(interval)

  # The interval to save from the choice: the default's choice sets none, but leaves an
  # interval set to the default as it is; any other, as chosen.
  defp to_save(%{"sync_interval" => ""}, %{interval: interval, default: interval})
       when is_integer(interval),
       do: %{"sync_interval" => interval}

  defp to_save(%{"sync_interval" => ""}, _sync), do: %{"sync_interval" => nil}
  defp to_save(params, _sync), do: Map.take(params, ["sync_interval"])

  # How often the adapter pulls, read again, with the choice on it.
  defp read_sync(%{assigns: %{current_scope: scope, adapter: adapter}} = socket) do
    case Adapters.sync_settings(scope, adapter) do
      {:ok, sync} -> assign(socket, sync: sync, interval_form: interval_form(sync))
      {:error, reason} -> refused(socket, reason)
    end
  end

  defp rename_form(changeset), do: to_form(changeset, as: "adapter")

  # The window's title: the page's words, then the adapter's name where they do not
  # hold it.
  defp titled(%{assigns: %{adapter: adapter, current_scope: scope}} = socket) do
    parts =
      case socket.assigns.live_action do
        :overview -> [adapter.name]
        :settings -> [gettext("Settings"), adapter.name]
        :rename -> [rename_title(adapter)]
        :remove -> [remove_title(adapter)]
      end

    assign(socket, :page_title, AdapterComponents.page_title(scope, parts))
  end

  defp rename_title(adapter), do: gettext("Rename %{name}", name: adapter.name)
  defp remove_title(adapter), do: gettext("Remove %{name}", name: adapter.name)

  @impl true
  def handle_event(
        "validate",
        %{"adapter" => params},
        %{assigns: %{live_action: :rename}} = socket
      )
      when is_map(params) do
    changeset =
      socket.assigns.adapter
      |> Adapters.change_adapter(Map.take(params, ["name"]))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, rename_form(changeset))}
  end

  def handle_event("rename", %{"adapter" => params}, %{assigns: %{live_action: :rename}} = socket)
      when is_map(params) do
    %{current_scope: scope, adapter: adapter, paths: paths} = socket.assigns

    case Adapters.rename_adapter(scope, adapter, Map.take(params, ["name"])) do
      {:ok, renamed} ->
        {:noreply,
         socket
         |> assign(:adapter, %{renamed | created_by: adapter.created_by})
         |> renamed_flash(adapter, renamed)
         |> push_patch(to: paths.settings)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, rename_form(changeset))}

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("remove", _params, %{assigns: %{live_action: :remove}} = socket) do
    %{current_scope: scope, adapter: adapter, paths: paths} = socket.assigns

    case Adapters.delete_adapter(scope, adapter) do
      {:ok, removed} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is removed.", name: removed.name))
         |> push_navigate(to: paths.list)}

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  def handle_event(
        "save_interval",
        %{"sync" => params},
        %{assigns: %{live_action: :settings}} = socket
      )
      when is_map(params) do
    %{current_scope: scope, adapter: adapter, sync: sync} = socket.assigns

    case Adapters.update_sync_interval(scope, adapter, to_save(params, sync)) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:adapter, %{updated | created_by: adapter.created_by})
         |> read_sync()
         |> put_flash(:info, gettext("%{name} is saved.", name: updated.name))}

      {:error, :not_declared} ->
        {:noreply, read_sync(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :interval_form, to_form(changeset, as: "sync"))}

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  # An act without its page open: nothing is done.
  def handle_event(event, _params, socket)
      when event in ~w(validate rename remove save_interval),
      do: {:noreply, socket}

  @impl true
  # A key arrived at the adapter: its state read again.
  def handle_info({:key_enrolled, %{node_id: id}}, %{assigns: %{adapter: %{id: id}}} = socket),
    do: {:noreply, assign_connected(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # No longer an instance admin, the page itself is not found now; the adapter removed
  # meanwhile, the list, where it is no longer.
  defp refused(socket, :not_found), do: push_navigate(socket, to: socket.assigns.paths.list)

  defp refused(socket, _forbidden),
    do: push_navigate(socket, to: socket.assigns.paths.overview)

  # A rename is said only when the name changed.
  defp renamed_flash(socket, %{name: name}, %{name: name}), do: socket

  defp renamed_flash(socket, _adapter, renamed),
    do: put_flash(socket, :info, gettext("%{name} is renamed.", name: renamed.name))

  ## Render

  @impl true
  def render(%{live_action: :rename} = assigns) do
    ~H"""
    <.frame
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      nav_counts={@nav_counts}
    >
      <:crumb navigate={@paths.overview}>{@adapter.name}</:crumb>
      <:crumb>{gettext("Rename")}</:crumb>

      <.settings_page section={:adapters} title={rename_title(@adapter)}>
        <:subtitle>
          {gettext(
            "Organisations see the new name on their Integrations page and when they install it."
          )}
        </:subtitle>

        <.form
          for={@form}
          id="adapter-rename-form"
          phx-change="validate"
          phx-submit="rename"
          class="q-form max-w-[26.25rem]"
          novalidate
        >
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            hint={gettext("At most 64 characters, and not the name of another adapter here.")}
            autocomplete="off"
          />
          <SettingsComponents.save id="adapter-rename-save" cancel={@paths.settings}>
            <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
              {gettext("Save")}
            </.button>
          </SettingsComponents.save>
        </.form>
      </.settings_page>
    </.frame>
    """
  end

  def render(%{live_action: :remove} = assigns) do
    ~H"""
    <.frame
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      nav_counts={@nav_counts}
    >
      <:crumb navigate={@paths.overview}>{@adapter.name}</:crumb>
      <:crumb>{gettext("Remove")}</:crumb>

      <.settings_page
        section={:adapters}
        title={gettext("Remove %{name}?", name: @adapter.name)}
      >
        <:subtitle>{gettext("This happens at once:")}</:subtitle>

        <ul id="adapter-remove-follows" class="grid list-disc gap-1.5 pl-5 text-[13.5px]/5">
          <li>
            {gettext(
              "Its keys are revoked, so the adapter can no longer reach Qory Apiary. A command still waiting is cancelled."
            )}
          </li>
          <li>{gettext("Qory Apiary tells the adapter nothing.")}</li>
          <li>{gettext("Its name is free again. This cannot be undone.")}</li>
        </ul>

        <SettingsComponents.save id="adapter-remove-save" cancel={@paths.settings}>
          <.button
            id="adapter-remove-button"
            variant="danger"
            phx-click="remove"
            loading_text={gettext("Removing")}
          >
            {remove_title(@adapter)}
          </.button>
        </SettingsComponents.save>
      </.settings_page>
    </.frame>
    """
  end

  def render(assigns) do
    ~H"""
    <.frame
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      nav_counts={@nav_counts}
    >
      <:crumb navigate={@live_action != :overview && @paths.overview}>{@adapter.name}</:crumb>

      <.settings_page section={:adapters} title={@adapter.name}>
        <:subtitle><AdapterComponents.adapter_meta adapter={@adapter} /></:subtitle>

        <AdapterComponents.adapter_tabs
          adapter={@adapter}
          paths={@paths}
          current={@live_action}
        />

        <.overview
          :if={@live_action == :overview}
          adapter={@adapter}
          paths={@paths}
          connected={@connected}
          seen={@seen}
          sync={@sync}
        />
        <.settings
          :if={@live_action == :settings}
          adapter={@adapter}
          paths={@paths}
          sync={@sync}
          interval_form={@interval_form}
        />
      </.settings_page>
    </.frame>
    """
  end

  attr :flash, :map, required: true
  attr :current_scope, :any, required: true
  attr :memberships, :list, required: true
  attr :nav_counts, :map, required: true

  slot :crumb do
    attr :navigate, :any
  end

  slot :inner_block, required: true

  # The frame of every page here: the Instance's, with Adapters current.
  defp frame(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:adapters}
    >
      <:crumb :for={crumb <- @crumb} navigate={crumb[:navigate] || nil}>
        {render_slot(crumb)}
      </:crumb>
      {render_slot(@inner_block)}
    </Layouts.app>
    """
  end

  attr :adapter, Node, required: true
  attr :paths, :map, required: true
  attr :connected, :boolean, required: true
  attr :seen, DateTime, default: nil
  attr :sync, :map, required: true, doc: "`Apiary.Adapters.sync_settings/2`'s"

  # The Overview: the adapter's state, the install address it declared, and how often it
  # pulls.
  defp overview(assigns) do
    ~H"""
    <dl
      id="adapter-overview"
      class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-8 gap-y-3 text-[13.5px]/5"
    >
      <dt class="text-faint">{gettext("State")}</dt>
      <dd id="adapter-overview-state" class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <AdapterComponents.adapter_seen
          id="adapter-state"
          adapter={@adapter}
          connected={@connected}
          seen={@seen}
        />
        <span :if={!@connected} class="text-faint">
          <span aria-hidden="true">·</span>
          {gettext("organisations can install it once it is connected and running")}
        </span>
        <span :if={!@connected} class="text-faint" aria-hidden="true">·</span>
        <.link
          :if={!@connected}
          id="adapter-connect-it"
          navigate={@paths.keys}
          class="text-accent hover:underline"
        >
          {gettext("Connect it")}
        </.link>
      </dd>
      <dt class="text-faint">{gettext("Install address")}</dt>
      <dd id="adapter-overview-install">
        <%= if @adapter.connect_url do %>
          <span class="q-mono break-all">{@adapter.connect_url}</span>
          <span class="text-faint">
            <span aria-hidden="true">·</span>
            {gettext("where organisations are sent to install it, as it declares")}
          </span>
        <% else %>
          <span class="text-faint">{gettext("Not declared yet")}</span>
        <% end %>
      </dd>
      <dt class="text-faint">{gettext("Pulls")}</dt>
      <dd id="adapter-overview-pulls" class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <%= if every = AdapterComponents.pulls_every(@sync) do %>
          <span :if={@sync.sends_changes}>
            {gettext("%{interval}, and changes are sent as they happen",
              interval: AdapterComponents.interval_label(every)
            )}
          </span>
          <span :if={!@sync.sends_changes}>{AdapterComponents.interval_label(every)}</span>
          <span aria-hidden="true" class="text-faint">·</span>
          <.link
            id="adapter-change-pulls"
            patch={@paths.settings}
            class="text-accent hover:underline"
          >
            {gettext("Change")}
          </.link>
        <% else %>
          <span class="text-faint">{gettext("Not declared yet")}</span>
        <% end %>
      </dd>
    </dl>
    """
  end

  attr :adapter, Node, required: true
  attr :paths, :map, required: true
  attr :sync, :map, required: true, doc: "`Apiary.Adapters.sync_settings/2`'s"
  attr :interval_form, Phoenix.HTML.Form, required: true

  # The Settings tab: how often the adapter pulls, its name, with Rename…, and the danger
  # zone.
  defp settings(assigns) do
    ~H"""
    <div id="adapter-settings" class="grid gap-8">
      <SettingsComponents.part id="adapter-interval" title={gettext("Pull interval")}>
        <.form
          :if={@sync.choices != []}
          for={@interval_form}
          id="adapter-interval-form"
          phx-submit="save_interval"
          class="q-form max-w-[26.25rem]"
          novalidate
        >
          <.input
            field={@interval_form[:sync_interval]}
            type="select"
            label={gettext("How often the adapter pulls what changed")}
            options={interval_options(@sync)}
            hint={interval_hint(@sync)}
          />
          <SettingsComponents.save id="adapter-interval-save">
            <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
              {gettext("Save")}
            </.button>
          </SettingsComponents.save>
        </.form>
        <div
          :if={@sync.choices == []}
          id="adapter-interval-undeclared"
          class="q-form max-w-[26.25rem]"
        >
          <.input
            type="select"
            id="adapter-interval-undeclared-choice"
            name="sync[sync_interval]"
            value=""
            label={gettext("How often the adapter pulls what changed")}
            options={[]}
            prompt={gettext("Not declared yet")}
            hint={
              gettext(
                "The adapter declares its default, and the most often it may pull, once it is connected and running. Until then this can't be set."
              )
            }
            disabled
          />
        </div>
      </SettingsComponents.part>
      <SettingsComponents.part id="adapter-name" title={gettext("Name")}>
        <p class="flex flex-wrap items-baseline gap-x-3 text-[13.5px]/5">
          <span id="adapter-name-value" class="font-medium">{@adapter.name}</span>
          <.link
            id="adapter-rename-link"
            patch={@paths.rename}
            class="text-accent hover:underline"
          >
            {gettext("Rename…")}
          </.link>
        </p>
      </SettingsComponents.part>

      <SettingsComponents.danger_zone id="adapter-danger">
        <SettingsComponents.danger_action id="adapter-remove" title={gettext("Remove this adapter")}>
          {gettext(
            "Its keys are revoked, and every organisation's installation of it ends. This cannot be undone."
          )}
          <:action>
            <.button id="adapter-remove-link" patch={@paths.remove}>
              {gettext("Remove adapter…")}
            </.button>
          </:action>
        </SettingsComponents.danger_action>
      </SettingsComponents.danger_zone>
    </div>
    """
  end

  # The intervals an instance admin may choose, each in words, in order: the adapter's
  # default marked, as no setting (""); and an interval set that is no longer among them,
  # so the choice shows it.
  defp interval_options(%{choices: choices, default: default} = sync) do
    for seconds <- Enum.sort(set_apart(sync) ++ choices) do
      label = AdapterComponents.interval_label(seconds)

      if seconds == default,
        do: {gettext("%{interval} (its default)", interval: label), ""},
        else: {label, seconds}
    end
  end

  defp set_apart(%{interval: interval, choices: choices}) when is_integer(interval) do
    if interval in choices, do: [], else: [interval]
  end

  defp set_apart(_sync), do: []

  # What the choice is for, with what the adapter declared, in a sentence's words.
  defp interval_hint(%{sends_changes: true} = sync) do
    gettext(
      "Changes are also sent to Qory Apiary as they happen; the pull catches what they missed. The adapter declares %{default} as its default, and %{minimum} as the most often. Organisations don't see this setting.",
      default: AdapterComponents.interval_words(sync.default),
      minimum: AdapterComponents.interval_words(sync.minimum)
    )
  end

  defp interval_hint(sync) do
    gettext(
      "The adapter declares %{default} as its default, and %{minimum} as the most often. Organisations don't see this setting.",
      default: AdapterComponents.interval_words(sync.default),
      minimum: AdapterComponents.interval_words(sync.minimum)
    )
  end
end
