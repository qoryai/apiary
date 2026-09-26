defmodule ApiaryWeb.AccessKeyLive.Index do
  @moduledoc """
  The workspace's access keys: list, create (reveal-once), rotate, retire the
  previous secret, revoke.
  """
  use ApiaryWeb, :live_view

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey

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
      <.header>
        {gettext("Access keys")}
        <:subtitle>
          {gettext(
            "A key lets the machines of this workspace post their runs. Create one per machine or environment and paste its server block into the runner file."
          )}
        </:subtitle>
        <:actions>
          <.button
            variant="primary"
            patch={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys/new"}
          >
            <.icon name="hero-plus-micro" class="size-4" /> {gettext("New access key")}
          </.button>
        </:actions>
      </.header>

      <.empty_state :if={@keys == []} icon="hero-key" title={gettext("No access keys yet")}>
        <p>
          {gettext(
            "Create a key and paste its server block into the runner file on a machine. It posts its runs to this workspace from then on."
          )}
        </p>
        <:actions>
          <.button patch={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys/new"}>{gettext(
            "Create an access key"
          )}</.button>
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
        <:col :let={key} label={gettext("Label")}>
          <span class="font-medium">{key.label}</span>
        </:col>
        <:col :let={key} label={gettext("Key id")}>
          <div class="relative w-fit">
            <.mono bare>{key.key_id}</.mono>
            <.copy_button
              :if={is_nil(key.revoked_at)}
              id={"copy-key-id-#{key.id}"}
              text={key.key_id}
              label={gettext("Copy key id")}
              placement="right"
              class="row-reveal !absolute left-full top-1/2 -translate-y-1/2 [&>button]:[--size:1.25rem] [&_.hero-clipboard-document-micro]:size-3.5"
              icon_only
            />
          </div>
        </:col>
        <:col :let={key} label={gettext("Status")}>
          <.status_badge status={AccessKey.status(key)} />
        </:col>
        <:col :let={key} label={gettext("Created")}>
          <span class={["tabular-nums", is_nil(key.revoked_at) && "text-muted"]}>
            {Format.date(key.inserted_at)}
          </span>
        </:col>
        <:col :let={key} label={gettext("Last used")}>
          <span :if={AccessKey.never_used?(key)} class="text-faint">{gettext("Never posted")}</span>
          <.time_ago
            :if={!AccessKey.never_used?(key)}
            at={key.last_used_at}
            class={["tabular-nums", is_nil(key.revoked_at) && "text-muted"]}
          />
        </:col>
        <:col :let={key} label={gettext("Last heartbeat")}>
          <span :if={is_nil(key.last_heartbeat_at)} class="text-faint">{gettext("Never")}</span>
          <.time_ago
            :if={key.last_heartbeat_at}
            at={key.last_heartbeat_at}
            class={["tabular-nums", is_nil(key.revoked_at) && "text-muted"]}
          />
        </:col>
        <:col :let={key} label={gettext("Runner")}>
          <span :if={key.last_runner_version} class="font-mono text-[12.5px]">
            {key.last_runner_version}
          </span>
          <span :if={!key.last_runner_version} class="text-faint">{gettext("n/a")}</span>
        </:col>
        <:action :let={key}>
          <%= case AccessKey.status(key) do %>
            <% :revoked -> %>
              <span class="whitespace-nowrap px-2 text-xs/6 text-faint">
                {gettext("Revoked %{date}", date: Format.date(key.revoked_at))}
              </span>
            <% status -> %>
              <.button
                :if={status == :rotating}
                variant="ghost"
                size="xs"
                phx-click="retire"
                phx-value-id={key.id}
                aria-label={gettext("Retire the previous secret of %{label}", label: key.label)}
              >
                {gettext("Retire previous secret")}
              </.button>
              <.button
                variant="ghost"
                size="xs"
                patch={
                  ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys/#{key.id}/rotate"
                }
                aria-label={gettext("Rotate %{label}", label: key.label)}
              >
                {gettext("Rotate")}
              </.button>
              <.button
                variant="danger-ghost"
                size="xs"
                patch={
                  ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys/#{key.id}/revoke"
                }
                aria-label={gettext("Revoke %{label}", label: key.label)}
              >
                {gettext("Revoke")}
              </.button>
          <% end %>
        </:action>
      </.table>

      <.modal
        :if={@live_action == :new && is_nil(@reveal)}
        id="new-key"
        title={gettext("New access key")}
        on_cancel={JS.patch(~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys")}
      >
        <.form
          for={@form}
          id="access-key-form"
          phx-change="validate"
          phx-submit="create"
          class="grid gap-4"
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
          <.button patch={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys"}>{gettext(
            "Cancel"
          )}</.button>
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
            patch={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys"}
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
        on_cancel={JS.patch(~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys")}
      >
        <p class="text-muted">
          {gettext(
            "Rotating issues a new secret and shows it once. The previous secret keeps working until you retire it, so machines can move over one at a time without a gap."
          )}
        </p>
        <:footer>
          <.button patch={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys"}>{gettext(
            "Cancel"
          )}</.button>
          <.button variant="primary" phx-click="rotate" loading_text={gettext("Rotating")}>
            {gettext("Rotate key")}
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@live_action == :revoke && @key}
        id="revoke-key"
        title={gettext("Revoke %{label}", label: @key.label)}
        on_cancel={JS.patch(~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys")}
      >
        <p class="text-muted">
          {gettext(
            "The key stops verifying at once. Machines still using it fail their next request and do not start new runs. This cannot be undone; create a new key to reconnect them."
          )}
        </p>
        <:footer>
          <.button
            patch={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys"}
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

  attr :status, :atom, required: true

  defp status_badge(%{status: :active} = assigns) do
    ~H"""
    <.badge color="success" dot>{gettext("Active")}</.badge>
    """
  end

  defp status_badge(%{status: :rotating} = assigns) do
    ~H"""
    <.badge color="warning" dot>{gettext("Rotating")}</.badge>
    """
  end

  defp status_badge(%{status: :revoked} = assigns) do
    ~H"""
    <.badge color="neutral" dot>{gettext("Revoked")}</.badge>
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
     |> assign(page_title: gettext("Access keys"), key: nil, reveal: nil, retire_key: nil)
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
    socket
    |> assign(key: nil, reveal: nil)
    |> assign_form(AccessKeys.change_access_key(%AccessKey{}))
  end

  defp apply_action(socket, action, %{"id" => id}) when action in [:rotate, :revoke] do
    key = AccessKeys.get_access_key!(socket.assigns.current_scope, id)

    if key.revoked_at do
      socket
      |> put_flash(:error, gettext("%{label} is already revoked.", label: key.label))
      |> push_patch(to: keys_path(socket))
    else
      assign(socket, key: key, reveal: nil)
    end
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

      {:error, :unauthorized} ->
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

      {:error, :unauthorized} ->
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

      {:error, :unauthorized} ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("retire", %{"id" => id}, socket) do
    key = AccessKeys.get_access_key!(socket.assigns.current_scope, id)
    {:noreply, assign(socket, :retire_key, key)}
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

      {:error, :unauthorized} ->
        {:noreply, unauthorized(socket)}
    end
  end

  defp keys_path(socket) do
    %{organisation: organisation, workspace: workspace} = socket.assigns.current_scope
    ~p"/#{organisation}/#{workspace}/keys"
  end

  # The membership this page was opened with is gone: `/` sends the user to where they
  # still belong.
  defp unauthorized(socket) do
    socket
    |> put_flash(:error, gettext("You are no longer a member of this workspace."))
    |> redirect(to: ~p"/")
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
