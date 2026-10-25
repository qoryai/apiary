defmodule ApiaryWeb.InstanceLive.Node do
  # The page of the instance's node pool or gateway in Instance settings › Nodes, for the
  # instance's admins, by the node's public id. A page of the Instance level, with no
  # organisation: its gate asks the instance whether the feature is on (`use
  # ApiaryWeb.Features, instance: :factory`), and anyone but an instance admin is answered
  # as a path that does not exist, as on the Instance's other pages.
  #
  # Three tabs, each a patch of this LiveView (`ApiaryWeb.NodeComponents.node_tabs/1`,
  # `view: :all`):
  #
  #   * Overview (`:overview`): a pool's running instances, how many of its limit, and
  #     each one's start and Forager version; then About: the kind, the public id, a
  #     pool's instance limit and a gateway's URL. The runs are in the organisations'
  #     workspaces, so the page links to none.
  #   * Access key (`:access_key`, `:revoke`): what Qory Apiary does with the node's
  #     one-time code, then the node's keys as a node's key cards
  #     (`ApiaryWeb.NodeLive.AccessKey.key_card/1`). Revoke is the one act; its
  #     confirmation, at `…/keys/:key_id/revoke`, is drawn under the key's card. Qory
  #     Apiary writes the next code, so the tab makes none.
  #   * Settings (`:settings`): the kind, a pool's instance limit
  #     (`Apiary.Nodes.Installed.set_instance_limit/3`) and a gateway's URL, which comes
  #     from the instance's settings and is shown only.
  #
  # The page reads the node again as an instance reports (`Apiary.Nodes.Installed.subscribe/1`)
  # and as a key arrives or is revoked (`Apiary.AccessKeys.subscribe/2`).
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, instance: :factory

  alias Apiary.{AccessKeys, Accounts, Adapters, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Nodes.{Installed, Node}
  alias ApiaryWeb.{NodeComponents, SettingsComponents}

  @impl true
  def mount(%{"node_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with :ok <- Adapters.authorize_instance(scope),
         %Node{} = node <- Installed.get(scope, public_id) do
      node = Repo.preload(node, :created_by)

      if connected?(socket) do
        :ok = Installed.subscribe(scope)
        :ok = AccessKeys.subscribe(scope, node)
      end

      {:ok,
       socket
       |> assign(node: node, paths: paths(node), key: nil, form: nil)
       |> load()}
    else
      _not_theirs -> raise ApiaryWeb.NotFound
    end
  end

  @doc false
  # The paths of the node's page: its tabs and the list.
  def paths(%Node{public_id: public_id}) do
    overview = ~p"/instance/nodes/#{public_id}"

    %{
      list: ~p"/instance/nodes",
      overview: overview,
      access_key: overview <> "/keys",
      settings: overview <> "/settings"
    }
  end

  # What the node does now, and its keys, with who revoked each, as the key card names
  # them: their accounts, looked up by id in one read.
  defp load(%{assigns: %{current_scope: scope, node: node}} = socket) do
    keys = AccessKeys.list_for_node(scope, node)

    users =
      keys
      |> Enum.flat_map(&[&1.created_by_id, &1.revoked_by_id])
      |> Accounts.list_users_by_id()
      |> Map.new(&{&1.id, &1})

    keys =
      Enum.map(
        keys,
        &%{&1 | created_by: users[&1.created_by_id], revoked_by: users[&1.revoked_by_id]}
      )

    assign(socket,
      activity: Map.fetch!(Installed.activity(scope, [node]), node.id),
      keys: keys,
      intact: Map.new(keys, &{&1.id, AccessKey.verify_integrity(&1) == :ok})
    )
  end

  @impl true
  def handle_params(%{"node_id" => public_id}, _uri, %{assigns: %{node: node}} = socket)
      when public_id != node.public_id,
      do: {:noreply, push_navigate(socket, to: ~p"/instance/nodes/#{public_id}")}

  def handle_params(params, _uri, socket) do
    {:noreply, socket |> apply_action(socket.assigns.live_action, params) |> titled()}
  end

  defp apply_action(socket, :revoke, %{"key_id" => key_id}) do
    case Enum.find(socket.assigns.keys, &(&1.key_id == key_id and is_nil(&1.revoked_at))) do
      %AccessKey{} = key -> assign(socket, key: key, form: nil)
      nil -> push_patch(socket, to: socket.assigns.paths.access_key)
    end
  end

  defp apply_action(%{assigns: %{node: %Node{kind: :pool} = node}} = socket, :settings, _params),
    do: assign(socket, key: nil, form: limit_form(Installed.change_instance_limit(node)))

  defp apply_action(socket, _action, _params), do: assign(socket, key: nil, form: nil)

  defp limit_form(changeset), do: to_form(changeset, as: "node")

  defp titled(%{assigns: %{node: node, current_scope: scope}} = socket) do
    parts =
      case socket.assigns.live_action do
        :overview -> [node.name]
        action when action in [:access_key, :revoke] -> [gettext("Access key"), node.name]
        :settings -> [gettext("Settings"), node.name]
      end

    assign(
      socket,
      :page_title,
      SettingsComponents.page_title(scope, :instance, parts ++ [gettext("Nodes")])
    )
  end

  @impl true
  def handle_info({:nodes_touched, _place}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("validate", %{"node" => params}, %{assigns: %{form: %{}}} = socket) do
    changeset =
      socket.assigns.node
      |> Installed.change_instance_limit(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, limit_form(changeset))}
  end

  def handle_event("save", %{"node" => params}, %{assigns: %{form: %{}}} = socket) do
    %{current_scope: scope, node: node} = socket.assigns

    case Installed.set_instance_limit(scope, node, params) do
      {:ok, updated} ->
        updated = %{updated | created_by: node.created_by}

        {:noreply,
         socket
         |> assign(node: updated, form: limit_form(Installed.change_instance_limit(updated)))
         |> put_flash(:info, gettext("%{name} is saved.", name: updated.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, limit_form(changeset))}

      {:error, _reason} ->
        {:noreply, push_navigate(socket, to: socket.assigns.paths.list)}
    end
  end

  def handle_event("revoke", _params, %{assigns: %{key: %AccessKey{} = key}} = socket) do
    case Adapters.revoke_key(socket.assigns.current_scope, key) do
      {:ok, key} ->
        {:noreply, to_keys(socket, :info, gettext("%{label} is revoked.", label: key.label))}

      {:error, :forbidden} ->
        {:noreply, push_navigate(socket, to: socket.assigns.paths.list)}

      {:error, :not_found} ->
        {:noreply, push_navigate(socket, to: socket.assigns.paths.list)}

      {:error, _not_saved} ->
        {:noreply, to_keys(socket, :error, gettext("Nothing was changed. Try again."))}
    end
  end

  # A form's or a revocation's event once the page has left it: nothing to do.
  def handle_event(event, _params, socket) when event in ~w(validate save revoke),
    do: {:noreply, socket}

  defp to_keys(socket, kind, message) do
    socket
    |> load()
    |> put_flash(kind, message)
    |> push_patch(to: socket.assigns.paths.access_key)
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:nodes}
    >
      <:crumb navigate={@live_action != :overview && @paths.overview}>{@node.name}</:crumb>

      <.settings_page section={:nodes} title={@node.name}>
        <:subtitle>
          <span id="node-meta" class="inline-flex flex-wrap items-baseline gap-x-2 gap-y-1">
            <span id="node-kind">{NodeComponents.kind_label(@node.kind)}</span>
            <span class="text-faint" aria-hidden="true">·</span>
            <NodeComponents.node_state id="node-state" node={@node} activity={@activity} />
            <span class="text-faint" aria-hidden="true">·</span>
            <span id="node-public-id" class="q-mono">{@node.public_id}</span>
          </span>
        </:subtitle>

        <NodeComponents.node_tabs
          node={@node}
          paths={@paths}
          current={tab(@live_action)}
          view={:all}
        />

        <.overview :if={@live_action == :overview} node={@node} activity={@activity} />

        <.keys
          :if={@live_action in [:access_key, :revoke]}
          node={@node}
          keys={@keys}
          intact={@intact}
          asked={@key}
          paths={@paths}
          scope={@current_scope}
        />

        <.settings :if={@live_action == :settings} node={@node} form={@form} />
      </.settings_page>
    </Layouts.app>
    """
  end

  defp tab(:revoke), do: :access_key
  defp tab(action), do: action

  attr :node, Node, required: true
  attr :activity, :map, required: true

  # A pool's running instances, then About.
  defp overview(assigns) do
    ~H"""
    <div id="node-overview" class="grid max-w-[60rem] gap-8">
      <SettingsComponents.part
        :if={@node.kind == :pool}
        id="node-instances"
        title={gettext("Running instances")}
        level={:h2}
      >
        <p :if={@activity.running != []} id="node-instances-count" class="text-[13px]/5 text-muted">
          {NodeComponents.running_words(@node, length(@activity.running))}
        </p>

        <.table
          :if={@activity.running != []}
          id="node-running"
          label={gettext("Running instances")}
          rows={@activity.running}
          row_id={&"instance-#{&1.instance_id}"}
        >
          <:col :let={instance} label={gettext("Instance")} kind="title">
            <span class="q-nm">
              <span class="q-cut" title={instance_label(instance)}>
                <bdi>{instance_label(instance)}</bdi>
              </span>
              <span
                :if={instance.name}
                class="q-side q-mono"
                title={Apiary.ExternalText.sent(instance.instance_id)}
              >
                <.external_text text={instance.instance_id} />
              </span>
            </span>
          </:col>
          <:col :let={instance} label={gettext("Running since")}>
            <.relative_time format="clock" at={instance.since} />
          </:col>
          <:col :let={instance} label={gettext("Forager")} kind="faint" from="md">
            <.external_text text={instance.forager_version} />{if !instance.forager_version,
              do: gettext("n/a")}
          </:col>
        </.table>

        <p :if={@activity.running == []} id="node-instances-none" class="text-[13px]/5 text-muted">
          {if NodeComponents.seen_at(@activity) != nil,
            do: gettext("No instance of this pool is running. An instance shows here while it runs."),
            else:
              gettext(
                "No instance of this pool has reported yet. An instance shows here while it runs."
              )}
        </p>
      </SettingsComponents.part>

      <SettingsComponents.part id="node-about" title={gettext("About")} level={:h2}>
        <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-6 gap-y-2 text-[13px]/5">
          <dt class="text-faint">{gettext("Kind")}</dt>
          <dd id="node-about-kind">{kind_sentence(@node.kind)}</dd>
          <dt class="text-faint">{gettext("Id")}</dt>
          <dd class="q-mono">{@node.public_id}</dd>
          <dt :if={@node.kind == :pool} class="text-faint">{gettext("Instance limit")}</dt>
          <dd :if={@node.kind == :pool} id="node-about-limit">{limit_words(@node)}</dd>
          <dt :if={@node.kind == :gateway} class="text-faint">{gettext("URL")}</dt>
          <dd :if={@node.kind == :gateway} id="node-about-url" class="q-mono">{@node.url}</dd>
        </dl>
      </SettingsComponents.part>
    </div>
    """
  end

  attr :node, Node, required: true
  attr :keys, :list, required: true
  attr :intact, :map, required: true
  attr :asked, :any, required: true, doc: "the key whose revocation is asked, or nil"
  attr :paths, :map, required: true
  attr :scope, :map, required: true

  # What Qory Apiary does with the node's code, then its keys. Each card's Revoke… leads
  # to `…/keys/:key_id/revoke`, which the card writes from `access_key`; its confirmation
  # is this tab's, under the card, and goes back to the tab. The installer acts by kind:
  # it writes a code for the node of a kind a setting declares, renaming it to the
  # declared name if it has another (`Apiary.Nodes.Installed.install/2`), and cancels
  # the codes of a kind no setting declares (`Apiary.Nodes.Installed.undeclared/0`).
  defp keys(assigns) do
    assigns = assign(assigns, :declared, Installed.name(assigns.node.kind) != nil)

    ~H"""
    <div id="node-access-key" class="grid max-w-[60rem] gap-8">
      <p id="node-access-key-intro" class="max-w-[80ch] text-[13px]/5 text-muted">
        <%= if @declared do %>
          {gettext(
            "Qory Apiary writes this node's one-time code to its folder. When you revoke the key, Qory Apiary writes a new code to the node's code file, and the node enrols with it when it reads the file."
          )}
        <% else %>
          {gettext(
            "This instance has no setting for this node, so Qory Apiary writes no new code after a revoke."
          )}
        <% end %>
      </p>

      <SettingsComponents.part
        :if={@keys != []}
        id="node-keys"
        title={gettext("Keys")}
        count={length(@keys)}
      >
        <ul id="node-keys-list" class="grid gap-3">
          <%= for key <- @keys do %>
            <ApiaryWeb.NodeLive.AccessKey.key_card
              key={key}
              node={@node}
              scope={@scope}
              paths={%{access_key: @paths.overview}}
              may={%{revoke: !asked?(@asked, key), revoke_code: false}}
              intact={@intact[key.id]}
              last_run={nil}
              hosts={nil}
              confirming={false}
              first={ApiaryWeb.AdapterLive.AccessKey.first_key?(key, @keys)}
            />
            <li :if={asked?(@asked, key)} id={"key-#{key.key_id}-asked"}>
              <.inline_confirm
                id={"key-#{key.key_id}-confirm"}
                question={gettext("Revoke %{label}?", label: key.label)}
                cancel={@paths.access_key}
              >
                {gettext(
                  "It is revoked at once, and its public key can never be used again. This cannot be undone."
                )}
                <:action>
                  <.button
                    id={"key-#{key.key_id}-confirm-button"}
                    variant="danger"
                    size="xs"
                    phx-click="revoke"
                    loading_text={gettext("Revoking")}
                  >
                    {gettext("Yes, revoke")}
                  </.button>
                </:action>
              </.inline_confirm>
            </li>
          <% end %>
        </ul>
      </SettingsComponents.part>
    </div>
    """
  end

  defp asked?(%AccessKey{id: id}, %AccessKey{id: id}), do: true
  defp asked?(_asked, _key), do: false

  attr :node, Node, required: true
  attr :form, :any, required: true

  # The kind, then a pool's instance limit, or a gateway's URL, shown only.
  defp settings(assigns) do
    ~H"""
    <SettingsComponents.part id="node-general">
      <div class="q-form">
        <div id="node-kind-field" class="grid gap-1 text-[13px]/5">
          <span class="font-medium">{gettext("Kind")}</span>
          <span>
            {kind_sentence(@node.kind)}
            <span class="text-muted">{gettext("It can't be changed.")}</span>
          </span>
        </div>
        <div :if={@node.kind == :gateway} id="node-url-field" class="grid gap-1 text-[13px]/5">
          <span class="font-medium">{gettext("URL")}</span>
          <span class="q-mono">{@node.url}</span>
        </div>
      </div>

      <.form
        :if={@form}
        for={@form}
        id="node-form"
        phx-change="validate"
        phx-submit="save"
        class="q-form"
        novalidate
      >
        <.input
          field={@form[:instance_limit]}
          type="text"
          inputmode="numeric"
          label={gettext("Instance limit")}
          hint={
            gettext(
              "Empty means no limit. Lowering it stops nothing running now; new instances wait until fewer run."
            )
          }
          autocomplete="off"
          optional
        />
        <div>
          <.button id="node-save" variant="primary" type="submit" loading_text={gettext("Saving")}>
            {gettext("Save")}
          </.button>
        </div>
      </.form>
    </SettingsComponents.part>
    """
  end

  defp instance_label(instance),
    do: instance.name || Apiary.ExternalText.sent(instance.instance_id)

  defp kind_sentence(:pool),
    do: gettext("Node pool: short-lived instances that share one access key.")

  defp kind_sentence(:gateway),
    do: gettext("Gateway: the runs of nodes and node pools that choose it go through it.")

  defp limit_words(%Node{instance_limit: nil}), do: gettext("No limit")
  defp limit_words(%Node{instance_limit: limit}), do: Format.number(limit)
end
