defmodule ApiaryWeb.AccessKeyLive.Index do
  @moduledoc """
  The hive's access keys: list, create (reveal-once), rotate, retire the
  previous secret, revoke.
  """
  use ApiaryWeb, :live_view

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} memberships={@memberships} nav={:keys}>
      <.header>
        Access keys
        <:subtitle>
          A key lets the machines of this <.term word="hive" /> post their runs. Create one per
          machine or environment and paste its server block into the runner file.
        </:subtitle>
        <:actions>
          <.button variant="primary" patch={~p"/hive/keys/new"}>
            <.icon name="hero-plus-micro" class="size-4" /> New access key
          </.button>
        </:actions>
      </.header>

      <.empty_state :if={@keys == []} icon="hero-key" title="No access keys yet">
        <p>
          Create a key and paste its server block into the runner file on a machine. The
          machine posts its runs to this <.term word="hive" /> from then on.
        </p>
        <:actions>
          <.button variant="primary" patch={~p"/hive/keys/new"}>Create an access key</.button>
        </:actions>
      </.empty_state>

      <.table :if={@keys != []} id="access-keys" rows={@keys} row_id={&"key-#{&1.id}"}>
        <:col :let={key} label="Label">
          <span class="font-medium">{key.label}</span>
        </:col>
        <:col :let={key} label="Key id">
          <div class="flex items-center gap-1.5">
            <.mono>{key.key_id}</.mono>
            <.copy_button
              id={"copy-key-id-#{key.id}"}
              text={key.key_id}
              label="Copy"
              class="!h-7 border-transparent shadow-none"
            />
          </div>
        </:col>
        <:col :let={key} label="Status">
          <.status_badge status={AccessKey.status(key)} />
        </:col>
        <:col :let={key} label="Created">
          <span class="text-ink-muted">{short_date(key.inserted_at)}</span>
        </:col>
        <:col :let={key} label="Last used">
          <span :if={AccessKey.never_used?(key)} class="text-ink-faint">never posted</span>
          <span :if={!AccessKey.never_used?(key)} class="text-ink-muted">
            {short_datetime(key.last_used_at)}
          </span>
        </:col>
        <:col :let={key} label="Runner">
          <span class="text-ink-muted">{key.last_runner_version || "—"}</span>
        </:col>
        <:action :let={key}>
          <%= case AccessKey.status(key) do %>
            <% :revoked -> %>
              <span class="whitespace-nowrap text-xs text-ink-faint">
                Revoked {short_date(key.revoked_at)}
              </span>
            <% status -> %>
              <.button
                :if={status == :rotating}
                variant="ghost"
                size="sm"
                phx-click="retire"
                phx-value-id={key.id}
              >
                Retire previous secret
              </.button>
              <.button variant="ghost" size="sm" patch={~p"/hive/keys/#{key.id}/rotate"}>
                Rotate
              </.button>
              <.button
                variant="ghost"
                size="sm"
                patch={~p"/hive/keys/#{key.id}/revoke"}
                class="text-danger hover:text-danger"
              >
                Revoke
              </.button>
          <% end %>
        </:action>
      </.table>

      <.modal
        :if={@live_action == :new && is_nil(@reveal)}
        id="new-key"
        title="New access key"
        on_cancel={JS.patch(~p"/hive/keys")}
      >
        <.form for={@form} id="access-key-form" phx-change="validate" phx-submit="create">
          <.input
            field={@form[:label]}
            type="text"
            label="Label"
            placeholder="build-server-1"
            hint="The machine or environment this key is for."
            autocomplete="off"
            phx-mounted={JS.focus()}
          />
        </.form>
        <:footer>
          <.button patch={~p"/hive/keys"}>Cancel</.button>
          <.button
            variant="primary"
            type="submit"
            form="access-key-form"
            phx-disable-with="Creating..."
          >
            Create key
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@live_action in [:new, :rotate] && @reveal}
        id="reveal-key"
        title={
          if @live_action == :new,
            do: "Your new access key",
            else: "New secret for #{@reveal.key.label}"
        }
        dismissable={false}
        size="lg"
      >
        <.reveal reveal={@reveal} rotated={@live_action == :rotate} />
        <:footer>
          <.button variant="primary" patch={~p"/hive/keys"}>Done</.button>
        </:footer>
      </.modal>

      <.modal
        :if={@live_action == :rotate && @key && is_nil(@reveal)}
        id="rotate-key"
        title={"Rotate #{@key.label}"}
        on_cancel={JS.patch(~p"/hive/keys")}
      >
        <p class="text-ink-muted">
          Rotating issues a new secret and shows it once. The previous secret keeps working
          until you retire it, so machines can move over one at a time without a gap.
        </p>
        <:footer>
          <.button patch={~p"/hive/keys"}>Cancel</.button>
          <.button variant="primary" phx-click="rotate" phx-disable-with="Rotating...">
            Rotate key
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@live_action == :revoke && @key}
        id="revoke-key"
        title={"Revoke #{@key.label}"}
        on_cancel={JS.patch(~p"/hive/keys")}
      >
        <p class="text-ink-muted">
          The key stops verifying at once. Machines still using it fail their next request
          and do not start new runs. This cannot be undone; create a new key to reconnect them.
        </p>
        <:footer>
          <.button patch={~p"/hive/keys"}>Cancel</.button>
          <.button variant="danger" phx-click="revoke" phx-disable-with="Revoking...">
            Revoke key
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@retire_key}
        id="retire-secret"
        title={"Retire the previous secret of #{@retire_key.label}"}
        on_cancel={JS.push("retire_cancel")}
      >
        <p class="text-ink-muted">
          Only the secret issued at the last rotation keeps working. A machine still on the
          previous secret fails its next request.
        </p>
        <:footer>
          <.button phx-click="retire_cancel">Cancel</.button>
          <.button variant="primary" phx-click="retire_confirm" phx-disable-with="Retiring...">
            Retire previous secret
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(%{status: :active} = assigns) do
    ~H"""
    <.badge color="success">Active</.badge>
    """
  end

  defp status_badge(%{status: :rotating} = assigns) do
    ~H"""
    <.badge color="warning">Rotating</.badge>
    """
  end

  defp status_badge(%{status: :revoked} = assigns) do
    ~H"""
    <.badge color="neutral">Revoked</.badge>
    """
  end

  attr :reveal, :map, required: true
  attr :rotated, :boolean, default: false

  defp reveal(assigns) do
    ~H"""
    <div class="space-y-4">
      <.notice kind={:warning}>
        <p>
          <strong>This secret is shown once.</strong>
          Copy it now. Apiary keeps only an encrypted copy and cannot show it again.
        </p>
      </.notice>

      <dl class="grid gap-3 sm:grid-cols-[auto_1fr] sm:items-center">
        <dt class="text-[13px] font-medium text-ink-muted">Key id</dt>
        <dd class="flex items-center gap-2">
          <.mono>{@reveal.key.key_id}</.mono>
          <.copy_button id="copy-reveal-key-id" text={@reveal.key.key_id} />
        </dd>
        <dt class="text-[13px] font-medium text-ink-muted">Secret</dt>
        <dd class="flex items-center gap-2">
          <.mono class="break-all">{@reveal.secret}</.mono>
          <.copy_button id="copy-reveal-secret" text={@reveal.secret} />
        </dd>
      </dl>

      <div>
        <p class="mb-2 text-[13px] text-ink-muted">
          <%= if @rotated do %>
            Update the <code class="font-mono">server</code>
            block in the runner file of each machine that uses this key, then retire the
            previous secret.
          <% else %>
            Paste this <code class="font-mono">server</code>
            block into the runner file on the machine.
          <% end %>
        </p>
        <.code_block id="server-block" code={@reveal.block} label="qory.yaml" />
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Access keys", key: nil, reveal: nil, retire_key: nil)
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
      |> put_flash(:error, "#{key.label} is already revoked.")
      |> push_patch(to: ~p"/hive/keys")
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
    end
  end

  def handle_event("rotate", _params, %{assigns: %{key: %AccessKey{} = key}} = socket) do
    case AccessKeys.rotate_access_key(socket.assigns.current_scope, key) do
      {:ok, key, secret} ->
        {:noreply, socket |> assign(key: key, reveal: reveal_for(key, secret)) |> load_keys()}

      {:error, :revoked} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{key.label} is revoked and cannot be rotated.")
         |> push_patch(to: ~p"/hive/keys")}
    end
  end

  def handle_event("revoke", _params, %{assigns: %{key: %AccessKey{} = key}} = socket) do
    {:ok, key} = AccessKeys.revoke_access_key(socket.assigns.current_scope, key)

    {:noreply,
     socket
     |> put_flash(:info, "#{key.label} is revoked. Machines using it fail their next request.")
     |> load_keys()
     |> push_patch(to: ~p"/hive/keys")}
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
    {:ok, key} = AccessKeys.retire_previous_secret(socket.assigns.current_scope, key)

    {:noreply,
     socket
     |> put_flash(:info, "The previous secret of #{key.label} is retired.")
     |> assign(:retire_key, nil)
     |> load_keys()}
  end

  defp reveal_for(key, secret) do
    %{
      key: key,
      secret: secret,
      block: AccessKeys.server_block(key, secret, ApiaryWeb.Endpoint.url())
    }
  end

  defp load_keys(socket) do
    assign(socket, :keys, AccessKeys.list_access_keys(socket.assigns.current_scope))
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
