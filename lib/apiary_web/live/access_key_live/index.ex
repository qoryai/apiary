defmodule ApiaryWeb.AccessKeyLive.Index do
  @moduledoc """
  The workspace's access keys, a section of its settings (`ApiaryWeb.SettingsComponents`),
  `/:org/:workspace/settings/keys`: list, create (reveal-once), rotate, retire the previous
  secret, revoke, the last three in modals over the list.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, AccessKeys}
  alias Apiary.AccessKeys.AccessKey
  alias ApiaryWeb.SettingsComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:keys}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:workspace}
        sections={@sections}
        current={:keys}
        measure="list"
        title={gettext("Access keys")}
      >
        <:subtitle>
          {gettext(
            "A key lets the machines of this workspace post their runs; one key can serve many hosts."
          )}
        </:subtitle>
        <:actions :if={Access.can?(@current_scope, :"access_key.create", @current_scope.workspace)}>
          <.button
            id="new-access-key"
            variant="primary"
            patch={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys/new"}
          >
            <.icon name="hero-plus-micro" class="size-4" /> {gettext("New access key")}
          </.button>
        </:actions>

        <.empty_state :if={@keys == []} icon="hero-key" title={gettext("No access keys yet")}>
          <p>
            {gettext(
              "Create a key and paste its server block into the runner file on a machine. It posts its runs to this workspace from then on."
            )}
          </p>
          <:actions :if={Access.can?(@current_scope, :"access_key.create", @current_scope.workspace)}>
            <.button patch={
              ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys/new"
            }>{gettext("Create an access key")}</.button>
          </:actions>
        </.empty_state>

        <.table
          :if={@keys != []}
          id="access-keys"
          label={gettext("Access keys")}
          rows={@keys}
          row_id={&"key-#{&1.id}"}
          row_class={&(&1.revoked_at && "row-off")}
        >
          <:col :let={key} label={gettext("Key")} kind="title">
            <span class="q-nm">
              <span class="q-title">{key.label}</span>
              <span class="q-side q-mono">{key.key_id}</span>
              <.copy_button
                :if={is_nil(key.revoked_at)}
                id={"copy-key-id-#{key.id}"}
                text={key.key_id}
                label={gettext("Copy key id")}
                placement="right"
                class="row-reveal [&>button]:[--size:1.25rem] [&_.hero-clipboard-document-micro]:size-3.5"
                icon_only
              />
            </span>
          </:col>
          <:col :let={key} label={gettext("Last used")} from="sm">
            <span :if={AccessKey.never_used?(key)} class="q-faint">
              {gettext("Never used; created %{date}", date: Format.day(key.inserted_at))}
            </span>
            <.time_ago
              :if={!AccessKey.never_used?(key)}
              at={key.last_used_at}
              class="tabular-nums"
            />
          </:col>
          <:col :let={key} label={gettext("Runner")} kind="faint" from="sm">
            <span :if={key.last_runner_version} class="q-mono">{key.last_runner_version}</span>
            <span :if={!key.last_runner_version}>{gettext("n/a")}</span>
          </:col>
          <:col :let={key} label={gettext("State")}>
            <.key_state
              key={key}
              can_retire={Access.can?(@current_scope, :"access_key.rotate", key)}
            />
          </:col>
          <:action :let={key}>
            <.row_menu
              :if={is_nil(key.revoked_at)}
              id={"key-#{key.id}-menu"}
              label={gettext("Actions for %{label}", label: key.label)}
            >
              <.menu_item
                :if={Access.can?(@current_scope, :"access_key.rotate", key)}
                id={"key-#{key.id}-rotate"}
                patch={
                  ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys/#{key.id}/rotate"
                }
                aria-label={gettext("Rotate %{label}", label: key.label)}
              >
                {gettext("Rotate…")}
              </.menu_item>
              <.menu_item
                :if={Access.can?(@current_scope, :"access_key.revoke", key)}
                id={"key-#{key.id}-revoke"}
                patch={
                  ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys/#{key.id}/revoke"
                }
                aria-label={gettext("Revoke %{label}", label: key.label)}
              >
                {gettext("Revoke…")}
              </.menu_item>
            </.row_menu>
          </:action>
        </.table>
        <p :if={@keys != []} class="text-[12.5px]/[18px] text-faint">
          {gettext(
            "A revoked key stays listed, so the runs it posted keep a name. Rotating shows the new secret once; the previous one works until you retire it."
          )}
        </p>
      </SettingsComponents.layout>

      <.modal
        :if={@live_action == :new && is_nil(@reveal)}
        id="new-key"
        title={gettext("New access key")}
        on_cancel={
          JS.patch(~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys")
        }
      >
        <.form
          for={@form}
          id="access-key-form"
          phx-change="validate"
          phx-submit="create"
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@form[:label]}
            type="text"
            label={gettext("Label")}
            placeholder={gettext("build-01")}
            hint={gettext("The machine or environment this key is for.")}
            autocomplete="off"
            spellcheck="false"
          />
        </.form>
        <:footer>
          <.button patch={
            ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys"
          }>{gettext("Cancel")}</.button>
          <.button
            variant="primary"
            type="submit"
            form="access-key-form"
            loading_text={gettext("Creating")}
          >
            {gettext("Create key")}
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@live_action in [:new, :rotate] && @reveal}
        id="reveal-key"
        title={
          if @live_action == :new,
            do: gettext("Your new access key"),
            else: gettext("New secret for %{label}", label: @reveal.key.label)
        }
        dismissable={false}
        size="lg"
      >
        <:aside>
          <.badge :if={@live_action == :new} color="success" dot>{@reveal.key.label}</.badge>
          <.badge :if={@live_action == :rotate} color="warning" dot>{gettext("Rotating")}</.badge>
        </:aside>
        <.reveal reveal={@reveal} rotated={@live_action == :rotate} />
        <:footer>
          <.button
            variant="primary"
            patch={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys"}
            data-autofocus
          >
            {gettext("I have copied the secret")}
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@live_action == :rotate && @key && is_nil(@reveal)}
        id="rotate-key"
        title={gettext("Rotate %{label}", label: @key.label)}
        on_cancel={
          JS.patch(~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys")
        }
      >
        <p class="text-muted">
          {gettext(
            "Rotating issues a new secret and shows it once. The previous secret keeps working until you retire it, so machines can move over one at a time without a gap."
          )}
        </p>
        <:footer>
          <.button patch={
            ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys"
          }>{gettext("Cancel")}</.button>
          <.button variant="primary" phx-click="rotate" loading_text={gettext("Rotating")}>
            {gettext("Rotate key")}
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@live_action == :revoke && @key}
        id="revoke-key"
        title={gettext("Revoke %{label}", label: @key.label)}
        on_cancel={
          JS.patch(~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys")
        }
      >
        <p class="text-muted">
          {gettext(
            "The key stops verifying at once. Machines still using it fail their next request and do not start new runs. This cannot be undone; create a new key to reconnect them."
          )}
        </p>
        <:footer>
          <.button
            patch={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/keys"}
            data-autofocus
          >{gettext("Cancel")}</.button>
          <.button variant="danger" phx-click="revoke" loading_text={gettext("Revoking")}>
            {gettext("Revoke key")}
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@retire_key}
        id="retire-secret"
        title={gettext("Retire the previous secret of %{label}", label: @retire_key.label)}
        on_cancel={JS.push("retire_cancel")}
      >
        <p class="text-muted">
          {gettext(
            "Only the secret issued at the last rotation keeps working. A machine still on the previous secret fails its next request."
          )}
        </p>
        <:footer>
          <.button phx-click="retire_cancel">{gettext("Cancel")}</.button>
          <.button variant="primary" phx-click="retire_confirm" loading_text={gettext("Retiring")}>
            {gettext("Retire previous secret")}
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  attr :key, AccessKey, required: true
  attr :can_retire, :boolean, required: true

  # The state is said only when it is not the usual one: a rotated key, with the one act
  # its state asks for, and a revoked key, with its date. An active key says so to a
  # screen reader alone.
  defp key_state(assigns) do
    ~H"""
    <%= case AccessKey.status(@key) do %>
      <% :active -> %>
        <span class="sr-only">{gettext("Active")}</span>
      <% :rotating -> %>
        <span class="inline-flex items-center gap-3">
          <.state_word id={"key-#{@key.id}-state"} hot>{gettext("Rotated")}</.state_word>
          <.button
            :if={@can_retire}
            variant="link"
            phx-click="retire"
            phx-value-id={@key.id}
            aria-label={gettext("Retire the previous secret of %{label}", label: @key.label)}
          >
            {gettext("Retire previous secret")}
          </.button>
        </span>
      <% :revoked -> %>
        <.state_word id={"key-#{@key.id}-state"}>
          {gettext("Revoked %{date}", date: Format.day(@key.revoked_at))}
        </.state_word>
    <% end %>
    """
  end

  attr :reveal, :map, required: true
  attr :rotated, :boolean, default: false

  defp reveal(assigns) do
    ~H"""
    <.notice kind={:warning}>
      <strong>{gettext("This secret is shown once.")}</strong>
      {gettext("Copy it now. Qory keeps only an encrypted copy and cannot show it again.")}
    </.notice>

    <dl class="grid grid-cols-[1fr_auto] items-center gap-x-3 gap-y-2 sm:grid-cols-[auto_1fr_auto]">
      <dt class="text-[13px] text-muted max-sm:col-span-2 max-sm:-mb-1">{gettext("Key id")}</dt>
      <dd class="min-w-0">
        <code class="block select-all break-all rounded-field border border-line bg-code px-2.5 py-1 font-mono text-[12.5px]/5">
          {@reveal.key.key_id}
        </code>
      </dd>
      <dd>
        <.copy_button
          id="copy-reveal-key-id"
          text={@reveal.key.key_id}
          label={gettext("Copy key id")}
          placement="left"
          icon_only
        />
      </dd>
      <dt class="text-[13px] text-muted max-sm:col-span-2 max-sm:-mb-1">{gettext("Secret")}</dt>
      <dd class="min-w-0">
        <code class="block select-all break-all rounded-field border border-line bg-code px-2.5 py-1 font-mono text-[12.5px]/5">
          {@reveal.secret}
        </code>
      </dd>
      <dd>
        <.copy_button
          id="copy-reveal-secret"
          text={@reveal.secret}
          label={gettext("Copy secret")}
          placement="left"
          icon_only
        />
      </dd>
    </dl>

    <div class="grid gap-2">
      <p class="text-[13px]/[18px] text-muted">
        <%= if @rotated do %>
          <.rich text={
            rich_gettext(
              "Update the %{server} block in the runner file of each machine that uses this key, then retire the previous secret.",
              server: {:code, "server", code_chip()}
            )
          } />
        <% else %>
          <.rich text={
            rich_gettext("Paste this %{server} block into the runner file on the machine.",
              server: {:code, "server", code_chip()}
            )
          } />
        <% end %>
      </p>
      <.code_block id="server-block" code={@reveal.block} label="~/.config/qory/runner.yaml" />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Access keys") <> " · " <> gettext("Workspace settings"),
       key: nil,
       reveal: nil,
       retire_key: nil
     )
     |> assign(:sections, SettingsComponents.sections(socket.assigns.current_scope, :workspace))
     |> load_keys()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, key: nil, reveal: nil)
  end

  defp apply_action(socket, :new, _params) do
    scope = socket.assigns.current_scope

    if Access.can?(scope, :"access_key.create", scope.workspace) do
      socket
      |> assign(key: nil, reveal: nil)
      |> assign_form(AccessKeys.change_access_key(%AccessKey{}))
    else
      refused(socket)
    end
  end

  defp apply_action(socket, action, %{"id" => id}) when action in [:rotate, :revoke] do
    key = AccessKeys.get_access_key!(socket.assigns.current_scope, id)

    cond do
      not Access.can?(socket.assigns.current_scope, key_action(action), key) ->
        refused(socket)

      key.revoked_at ->
        socket
        |> put_flash(:error, gettext("%{label} is already revoked.", label: key.label))
        |> push_patch(to: keys_path(socket))

      true ->
        assign(socket, key: key, reveal: nil)
    end
  end

  defp key_action(:rotate), do: :"access_key.rotate"
  defp key_action(:revoke), do: :"access_key.revoke"

  # A path for an action the reader may not take, which the page offers no button for.
  defp refused(socket) do
    socket
    |> put_flash(:error, gettext("You may not change this workspace's access keys."))
    |> push_patch(to: keys_path(socket))
  end

  @impl true
  def handle_event("validate", %{"access_key" => params}, socket) do
    changeset =
      %AccessKey{}
      |> AccessKeys.change_access_key(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("create", %{"access_key" => params}, socket) do
    case AccessKeys.create_access_key(socket.assigns.current_scope, params) do
      {:ok, key, secret} ->
        {:noreply, socket |> assign(reveal: reveal_for(key, secret)) |> load_keys()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("rotate", _params, %{assigns: %{key: %AccessKey{} = key}} = socket) do
    case AccessKeys.rotate_access_key(socket.assigns.current_scope, key) do
      {:ok, key, secret} ->
        {:noreply, socket |> assign(key: key, reveal: reveal_for(key, secret)) |> load_keys()}

      {:error, :revoked} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("%{label} is revoked and cannot be rotated.", label: key.label)
         )
         |> push_patch(to: keys_path(socket))}

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("revoke", _params, %{assigns: %{key: %AccessKey{} = key}} = socket) do
    case AccessKeys.revoke_access_key(socket.assigns.current_scope, key) do
      {:ok, key} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{label} is revoked. Machines using it fail their next request.",
             label: key.label
           )
         )
         |> load_keys()
         |> push_patch(to: keys_path(socket))}

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:noreply, unauthorized(socket)}
    end
  end

  # The key is looked up among the keys the page lists, which are the workspace's: an id
  # of another workspace's, or of none, finds nothing, and the list is read again.
  def handle_event("retire", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.keys, &(&1.id == id)) do
      %AccessKey{} = key -> {:noreply, assign(socket, :retire_key, key)}
      nil -> {:noreply, load_keys(socket)}
    end
  end

  def handle_event("retire_cancel", _params, socket) do
    {:noreply, assign(socket, :retire_key, nil)}
  end

  def handle_event(
        "retire_confirm",
        _params,
        %{assigns: %{retire_key: %AccessKey{} = key}} = socket
      ) do
    case AccessKeys.retire_previous_secret(socket.assigns.current_scope, key) do
      {:ok, key} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("The previous secret of %{label} is retired.", label: key.label)
         )
         |> assign(:retire_key, nil)
         |> load_keys()}

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:noreply, unauthorized(socket)}
    end
  end

  # A rotation, a revocation or a retirement without its modal open: a second click of a
  # button whose modal has closed. One who may take the action is shown the list again;
  # one who may not is refused, as a path the page offers no button for is.
  def handle_event(event, _params, socket) when event in ~w(rotate revoke retire_confirm) do
    scope = socket.assigns.current_scope
    action = if event == "revoke", do: :"access_key.revoke", else: :"access_key.rotate"

    if Access.can?(scope, action, scope.workspace),
      do: {:noreply, load_keys(socket)},
      else: {:noreply, refused(socket)}
  end

  defp keys_path(socket) do
    %{organisation: organisation, workspace: workspace} = socket.assigns.current_scope
    ~p"/#{organisation}/#{workspace}/settings/keys"
  end

  # The membership this page was opened with is gone, or the person no longer reaches the
  # workspace: `/` sends the user to where they still belong. A reader, who reads the
  # organisation through the edition's reach and changes nothing in it, as the database
  # has it now, stays and is told so.
  defp unauthorized(socket) do
    scope = Access.reload(socket.assigns.current_scope)

    if Access.reader(scope) do
      socket
      |> put_flash(:error, ApiaryWeb.Access.reads_only(scope))
      |> push_patch(to: keys_path(socket))
    else
      socket
      |> put_flash(:error, gettext("You are no longer a member of this workspace."))
      |> redirect(to: ~p"/")
    end
  end

  # The look of `CoreComponents.mono/1`, for a word of code inside a sentence.
  defp code_chip,
    do: "rounded-selector border border-line bg-code px-1.5 py-0.5 font-mono text-[12.5px]"

  defp reveal_for(key, secret) do
    %{
      key: key,
      secret: secret,
      block: AccessKeys.server_block(key, secret, ApiaryWeb.Endpoint.url())
    }
  end

  defp load_keys(socket) do
    keys = AccessKeys.list_access_keys(socket.assigns.current_scope)
    active = Enum.count(keys, &is_nil(&1.revoked_at))

    socket
    |> assign(:keys, keys)
    |> assign(:nav_counts, Map.put(socket.assigns.nav_counts || %{}, :keys, active))
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
