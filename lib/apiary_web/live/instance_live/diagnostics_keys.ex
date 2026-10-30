defmodule ApiaryWeb.InstanceLive.DiagnosticsKeys do
  @moduledoc """
  Instance settings › Diagnostics keys, `/instance/diagnostics-keys`: the keys that read
  any run's diagnostics (`Apiary.AccessKeys.create_diagnostics_code/2`), for the
  instance's admins on an instance with the feature `observability`
  (`Apiary.AccessKeys.authorize_diagnostics/2`); anyone else is answered as a path that
  does not exist. A page of the Instance level: its gate asks the instance whether the
  feature is on (`use ApiaryWeb.Features, instance: :observability`).

  A key is made on the computer that uses it, with a command that carries a one-time code:
  Get the command makes a code at once and opens `…/new-code`, which shows the command,
  waits for the key the code brings, and says the key is active once it arrives. The page
  lists the keys in use, newest first: each key's name, who made it, when, and when it
  was last used, with Revoke…, confirmed in place at `…/:key_id/revoke`.

  **The page holds the code in its process only.** It is wrapped in a function so no
  inspection of the process's state prints it, and held until the reader leaves the
  command's page: every path starts without it, but for the one patch from Get the
  command to its page. No path, flash or title carries it, and nothing logs it.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, instance: :observability

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.Enrolment
  alias ApiaryWeb.{NodeComponents, SettingsComponents}

  @index "/instance/diagnostics-keys"
  @new_code "/instance/diagnostics-keys/new-code"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    case AccessKeys.authorize_diagnostics(scope) do
      :ok ->
        {:ok,
         socket
         |> assign(issued: nil, carry: false, key: nil, subscribed: nil)
         |> load()}

      {:error, _not_theirs} ->
        raise ApiaryWeb.NotFound
    end
  end

  # The keys in use, and the diagnostics node's topic, once the node is there: a key that
  # arrives is listed at once.
  defp load(socket) do
    scope = socket.assigns.current_scope
    keys = AccessKeys.list_diagnostics_keys(scope)

    socket
    |> assign(keys: keys, full: length(keys) >= AccessKeys.diagnostics_key_limit())
    |> subscribe()
    |> note_arrival()
  end

  defp subscribe(%{assigns: %{subscribed: nil}} = socket) do
    with true <- connected?(socket),
         %{} = node <- AccessKeys.diagnostics_node(socket.assigns.current_scope),
         :ok <- AccessKeys.subscribe(socket.assigns.current_scope, node) do
      assign(socket, :subscribed, node.id)
    else
      _not_yet -> socket
    end
  end

  defp subscribe(socket), do: socket

  # The command's code, once the key it brings is listed: the page says the key is active,
  # and lets go of the code, which is spent.
  defp note_arrival(%{assigns: %{issued: %{arrived: nil, row: %{id: code_id}} = issued}} = socket) do
    case Enum.find(socket.assigns.keys, &(&1.enrolment_code_id == code_id)) do
      nil -> socket
      key -> assign(socket, :issued, %{issued | arrived: key, code: nil})
    end
  end

  defp note_arrival(socket), do: socket

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action
    issued = if socket.assigns.carry and action == :new_code, do: socket.assigns.issued
    socket = assign(socket, issued: issued, carry: false, key: nil)

    {:noreply, socket |> apply_action(action, params) |> titled()}
  end

  defp apply_action(socket, :index, _params), do: socket
  defp apply_action(%{assigns: %{issued: %{}}} = socket, :new_code, _params), do: socket
  defp apply_action(socket, :new_code, _params), do: push_patch(socket, to: @index)

  defp apply_action(socket, :revoke, %{"key_id" => key_id}) do
    case Enum.find(socket.assigns.keys, &(&1.key_id == key_id)) do
      %AccessKey{} = key -> assign(socket, :key, key)
      nil -> push_patch(socket, to: @index)
    end
  end

  defp titled(socket) do
    assign(
      socket,
      :page_title,
      SettingsComponents.page_title(socket.assigns.current_scope, :instance, [
        gettext("Diagnostics keys")
      ])
    )
  end

  @impl true
  def handle_event("create_code", _params, %{assigns: %{live_action: action}} = socket)
      when action in [:index, :revoke] do
    if socket.assigns.full do
      {:noreply, load(socket)}
    else
      case AccessKeys.create_diagnostics_code(socket.assigns.current_scope) do
        {:ok, row, code} ->
          # The code as the computer sends it, in a function: shown by the command's page
          # once, and printed by nothing else.
          code = Enrolment.issued_code(code, Apiary.SigningKey.fingerprint())

          {:noreply,
           socket
           |> assign(issued: %{row: row, code: fn -> code end, arrived: nil}, carry: true)
           |> load()
           |> push_patch(to: @new_code)}

        {:error, :sudo} ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("You must re-authenticate to access this page."))
           |> redirect(to: ~p"/users/log-in")}

        {:error, reason} when reason in [:forbidden, :not_found] ->
          {:noreply, push_navigate(socket, to: @index)}

        {:error, _not_saved} ->
          {:noreply, to_index(socket, :error, gettext("Nothing was changed. Try again."))}
      end
    end
  end

  def handle_event(
        "revoke",
        _params,
        %{assigns: %{live_action: :revoke, key: %AccessKey{} = key}} = socket
      ) do
    case AccessKeys.revoke_diagnostics_key(socket.assigns.current_scope, key) do
      {:ok, key} ->
        {:noreply, to_index(socket, :info, gettext("%{label} is revoked.", label: key.label))}

      {:error, :forbidden} ->
        {:noreply, push_navigate(socket, to: @index)}

      {:error, _not_saved} ->
        {:noreply, to_index(socket, :error, gettext("Nothing was changed. Try again."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_info({:key_enrolled, %{node_id: id}}, %{assigns: %{subscribed: id}} = socket),
    do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp to_index(socket, kind, words) do
    socket
    |> put_flash(kind, words)
    |> load()
    |> push_patch(to: @index)
  end

  defp command(code),
    do: "qory apiary enrol " <> NodeComponents.shell_word(ApiaryWeb.Endpoint.url()) <> " " <> code

  defp maker(%AccessKey{created_by: %{email: email}}), do: email
  defp maker(%AccessKey{}), do: gettext("Former member")

  defp asked?(%AccessKey{id: id}, %AccessKey{id: id}), do: true
  defp asked?(_asked, _key), do: false

  ## Render

  @impl true
  def render(%{live_action: :new_code, issued: %{}} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:diagnostics_keys}
    >
      <:crumb patch={~p"/instance/diagnostics-keys"}>{gettext("Diagnostics keys")}</:crumb>
      <:crumb>{gettext("Command")}</:crumb>

      <.settings_page section={:diagnostics_keys} title={gettext("Make a diagnostics key")}>
        <:subtitle>
          {gettext(
            "The command makes the key on the computer that runs it and sends Qory Apiary only the public half. The secret never leaves that computer."
          )}
        </:subtitle>

        <div id="code-issued" class="grid gap-4" aria-live="polite">
          <%= if @issued.arrived do %>
            <div id="code-issued-arrived">
              <.notice kind={:success}>
                <strong>{gettext("%{label} is active.", label: @issued.arrived.label)}</strong>
                {gettext("It arrived at %{time}.", time: Format.time(@issued.arrived.received_at))}
              </.notice>
            </div>
          <% else %>
            <div class="grid gap-1.5">
              <p id="code-issued-run" class="text-[13px]/5">
                {gettext("On the computer that reads run diagnostics, run:")}
              </p>
              <div tabindex="-1" phx-mounted={JS.focus(to: "#code-issued-command")}>
                <.code_block
                  id="code-issued-command"
                  code={command(@issued.code.())}
                  copy_label={gettext("Copy command")}
                  wrap
                />
              </div>
            </div>
            <.listening id="code-issued-waiting">
              {gettext("Waiting for the command to run. This page shows when the key arrives.")}
            </.listening>
            <p id="code-issued-works" class="text-[13px]/5 text-muted">
              {gettext(
                "It works once, until %{time}, %{minutes} minutes from when you got it. This is the only time it is shown.",
                time: Format.time(@issued.row.expires_at),
                minutes: Format.number(AccessKeys.code_ttl_minutes())
              )}
            </p>
          <% end %>

          <SettingsComponents.save id="code-issued-done">
            <.button
              id="code-issued-done-button"
              variant="primary"
              patch={~p"/instance/diagnostics-keys"}
            >
              {gettext("Done")}
            </.button>
          </SettingsComponents.save>
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
      place={:instance}
      section={:diagnostics_keys}
    >
      <.settings_page section={:diagnostics_keys} title={gettext("Diagnostics keys")}>
        <:subtitle>
          {gettext(
            "With a diagnostics key, a computer reads the diagnostics of any run on this instance, and nothing else."
          )}
        </:subtitle>

        <div id="diagnostics-keys" class="grid gap-8">
          <SettingsComponents.part
            id="diagnostics-keys-list"
            title={gettext("Keys")}
            count={length(@keys)}
          >
            <p :if={@keys == []} id="diagnostics-keys-empty" class="text-[13px]/5 text-muted">
              {gettext("This instance has no diagnostics key.")}
            </p>
            <ul :if={@keys != []} class="grid gap-3">
              <%= for key <- @keys do %>
                <li
                  id={"key-#{key.key_id}"}
                  class="grid gap-2 rounded-box border border-line bg-base-100 p-4 text-[13px]/5"
                >
                  <div class="flex flex-wrap items-center justify-between gap-2">
                    <span id={"key-#{key.key_id}-label"} class="font-medium">{key.label}</span>
                    <.button
                      :if={!asked?(@key, key)}
                      id={"key-#{key.key_id}-revoke"}
                      size="xs"
                      patch={~p"/instance/diagnostics-keys/#{key.key_id}/revoke"}
                    >
                      {gettext("Revoke…")}
                    </.button>
                  </div>
                  <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-6 gap-y-1">
                    <dt class="text-faint">{gettext("Made by")}</dt>
                    <dd id={"key-#{key.key_id}-maker"}>{maker(key)}</dd>
                    <dt class="text-faint">{gettext("Made")}</dt>
                    <dd id={"key-#{key.key_id}-made"}>{Format.time(key.received_at)}</dd>
                    <dt class="text-faint">{gettext("Last used")}</dt>
                    <dd id={"key-#{key.key_id}-used"}>
                      {if key.last_used_at, do: Format.time(key.last_used_at), else: gettext("Never")}
                    </dd>
                  </dl>
                  <.inline_confirm
                    :if={asked?(@key, key)}
                    id={"key-#{key.key_id}-confirm"}
                    question={gettext("Revoke %{label}?", label: key.label)}
                    cancel={~p"/instance/diagnostics-keys"}
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

          <SettingsComponents.part id="diagnostics-keys-add" title={gettext("Add a key")}>
            <p id="diagnostics-keys-add-intro" class="text-[13px]/5 text-muted">
              <%!-- "The code" is the one-time code, the plain word (`pgettext("plain", …)`). --%>
              {pgettext(
                "plain",
                "You get one command to run on the computer that reads run diagnostics. It contains a one-time code, not a key. The code works once, within %{minutes} minutes. The computer makes the key and sends Qory Apiary only its public half.",
                minutes: AccessKeys.code_ttl_minutes()
              )}
            </p>
            <p :if={@full} id="diagnostics-keys-full" class="text-[13px]/5 text-muted">
              {gettext(
                "This instance has at most %{count} diagnostics keys. Revoke one to add another.",
                count: AccessKeys.diagnostics_key_limit()
              )}
            </p>
            <div :if={!@full}>
              <.button id="code-new-button" phx-click="create_code" variant="primary">
                {gettext("Get the command")}
              </.button>
            </div>
          </SettingsComponents.part>
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end
end
