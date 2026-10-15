defmodule ApiaryWeb.AdapterLive.AccessKey do
  # An integration's Access key tab, `/:org/settings/integrations/:adapter_id/access-key`:
  # how its adapter enrols its key, and its keys, over `Apiary.AccessKeys` as a node's
  # Access key tab has them (`ApiaryWeb.NodeLive.AccessKey`). Its header and tabs are the
  # integration's page's (`ApiaryWeb.AdapterComponents`).
  #
  # An adapter's key is enrolled with a code, alone: never made in a browser, never with
  # stored secrets (`Apiary.AccessKeys` refuses both), so the tab offers one way. Make an
  # enrolment code makes one at once (`create_code`, with the defaults) and opens
  # `…/access-key/new-code`, which shows the server's address and the code apart, each
  # with its Copy, for the adapter's enrol command on its host.
  #
  # **A code is shown once.** It lives in the page's process alone, wrapped in a function
  # so no inspection of the process's state prints it, until the reader leaves the page
  # by any way, or the adapter has used it, or it expired or was cancelled: every path
  # starts without it, but for the one patch from Make an enrolment code to its page; no
  # path, flash or title carries it, and nothing logs it. A page opened again starts
  # without it.
  #
  # A code made and not yet used, cancelled or expired is listed under Enrol its key with
  # the node tab's pieces (`ApiaryWeb.NodeLive.AccessKey.waiting/1`): who got it and when,
  # until when it works, and Cancel the command…, confirmed in place at a path of its own
  # (`…/access-key/codes/:code_id/revoke`, the code's row id, never the code).
  #
  # The keys are the node's tab's cards (`ApiaryWeb.NodeLive.AccessKey.key_card/1`),
  # those in use first, without a Forager file or stored secrets. Owners and admins revoke
  # an active key, confirmed in place on its card, at a path of its own
  # (`…/access-key/keys/:key_id/revoke`), as a node's key is.
  #
  # Everyone in the organisation reads the tab (`adapter.read`); owners and admins act
  # (`access_key.create_code`, `access_key.revoke`). A member sees the keys, no button,
  # and the line that says who changes integrations; an act's path refuses them. Every act
  # is asked again by the context function.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory
  on_mount {ApiaryWeb.Access, :"adapter.read"}

  alias Apiary.{Access, AccessKeys, Adapters, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Contract.Enrolment
  alias Apiary.Nodes.Node
  alias ApiaryWeb.{AdapterComponents, NodeLive, SettingsComponents, UserAuth}

  # The page's acts, and the action of `Apiary.Access` each one asks.
  @acts [
    new_code: :"access_key.create_code",
    revoke: :"access_key.revoke",
    revoke_code: :"access_key.cancel_code"
  ]

  # The events that change something, and the act each is.
  @write_events %{"create_code" => :new_code, "revoke" => :revoke, "revoke_code" => :revoke_code}

  # The paths that show the tab, where Make an enrolment code is offered.
  @tab_actions [:index, :revoke, :revoke_code]

  @impl true
  def mount(%{"adapter_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Adapters.get_adapter(scope, public_id) do
      %Node{} = adapter ->
        if connected?(socket), do: AccessKeys.subscribe(scope, adapter)

        {:ok,
         socket
         |> assign(
           sections: SettingsComponents.sections(scope, :organisation),
           adapter: adapter,
           paths: AdapterComponents.paths(scope, adapter),
           server: ApiaryWeb.Endpoint.url()
         )
         |> assign(issued: nil, carry: false, key: nil, code: nil, expiry_timer: nil)
         |> assign_may()
         |> load()
         |> UserAuth.on_membership_change(&(&1 |> assign_may() |> load()))}

      nil ->
        raise ApiaryWeb.NotFound
    end
  end

  defp assign_may(socket) do
    %{current_scope: scope, adapter: adapter} = socket.assigns
    may = Map.new(@acts, fn {act, action} -> {act, Access.can?(scope, action, adapter)} end)

    # The key cards' acts are a node's tab's: revoking is the one an adapter's key has.
    assign(socket, may: may, card_may: %{revoke: may.revoke})
  end

  # The integration's keys, with who made and revoked each, its outstanding codes, and its
  # summary, which says whether a key is active.
  defp load(socket) do
    %{current_scope: scope, adapter: adapter} = socket.assigns

    keys =
      scope
      |> AccessKeys.list_for_node(adapter)
      |> Repo.preload([:created_by, :revoked_by])

    socket
    |> assign(
      keys: keys,
      codes: scope |> AccessKeys.list_enrolment_codes(adapter) |> Repo.preload(:created_by),
      intact: Map.new(keys, &{&1.id, AccessKey.verify_integrity(&1) == :ok}),
      summary: AdapterComponents.summary(adapter),
      now: DateTime.utc_now()
    )
    |> let_go_of_spent()
    |> schedule_expiry()
  end

  # The code shown, once it no longer works: the adapter used it, or it was cancelled or
  # expired. The page lets go of it and shows the tab, where the key it brought, if any, is
  # listed.
  defp let_go_of_spent(%{assigns: %{issued: %{row: %{id: id}}}} = socket) do
    if Enum.any?(socket.assigns.codes, &(&1.id == id)),
      do: socket,
      else:
        socket
        |> assign(:issued, nil)
        |> push_patch(to: socket.assigns.paths.access_key)
  end

  defp let_go_of_spent(socket), do: socket

  # The codes are read again the moment the code shown expires, so the page lets go of it.
  defp schedule_expiry(socket) do
    %{issued: issued, now: now, expiry_timer: timer} = socket.assigns
    if timer, do: Process.cancel_timer(timer)

    timer =
      case issued do
        %{row: %{expires_at: at}} ->
          if connected?(socket) do
            wait = DateTime.diff(at, now, :millisecond)
            Process.send_after(self(), :codes_expire, max(wait, 0) + 1)
          end

        nil ->
          nil
      end

    assign(socket, :expiry_timer, timer)
  end

  @impl true
  def handle_params(%{"adapter_id" => public_id}, _uri, %{assigns: %{adapter: adapter}} = socket)
      when public_id != adapter.public_id do
    scope = socket.assigns.current_scope
    {:noreply, push_navigate(socket, to: AdapterComponents.paths(scope, public_id).access_key)}
  end

  def handle_params(params, _uri, socket) do
    # What the reader leaves, for the focus to go back to the button that opened it.
    left = socket.assigns.key || socket.assigns.code
    action = socket.assigns.live_action

    # Every path starts without a code shown and without a confirmation open, but the code
    # just made, carried once to its page: a code shown is gone once the reader leaves it.
    issued = if socket.assigns.carry and action == :new_code, do: socket.assigns.issued
    socket = assign(socket, issued: issued, carry: false, key: nil, code: nil)

    {:noreply,
     socket
     |> apply_action(action, params)
     |> titled()
     |> return_focus(left)}
  end

  defp apply_action(socket, :index, _params), do: socket

  # The code's page, with the code just made (`create_code`). Opened any other way, there
  # is no code to show: it was shown once, so the reader is back on the tab.
  defp apply_action(socket, :new_code, _params) do
    cond do
      not socket.assigns.may.new_code -> refused(socket, :new_code)
      socket.assigns.issued -> socket
      true -> push_patch(socket, to: socket.assigns.paths.access_key)
    end
  end

  # A key's revocation, confirmed in place on its card, as a node's key's is.
  defp apply_action(socket, :revoke, %{"key_id" => key_id}) do
    key = Enum.find(socket.assigns.keys, &(&1.key_id == key_id))

    cond do
      not socket.assigns.may.revoke ->
        refused(socket, :revoke)

      is_nil(key) ->
        push_patch(socket, to: socket.assigns.paths.access_key)

      not is_nil(key.revoked_at) ->
        socket
        |> put_flash(:error, gettext("%{label} is revoked.", label: key.label))
        |> push_patch(to: socket.assigns.paths.access_key)

      true ->
        assign(socket, :key, key)
    end
  end

  # A waiting code's cancelling, confirmed in place in its row, as a node's code's is.
  defp apply_action(socket, :revoke_code, %{"code_id" => code_id}) do
    code = Enum.find(socket.assigns.codes, &(&1.id == code_id))

    cond do
      not socket.assigns.may.revoke_code ->
        refused(socket, :revoke_code)

      is_nil(code) ->
        socket
        |> put_flash(:error, outstanding_no_more())
        |> push_patch(to: socket.assigns.paths.access_key)

      true ->
        assign(socket, :code, code)
    end
  end

  # The window's title: the tab's, then the integration's name.
  defp titled(%{assigns: %{adapter: adapter, current_scope: scope}} = socket) do
    assign(
      socket,
      :page_title,
      AdapterComponents.page_title(scope, [gettext("Access key"), adapter.name])
    )
  end

  # Back on the tab, the focus goes to the revoked key's heading, or to the card's
  # Revoke… where the key is still active.
  defp return_focus(%{assigns: %{live_action: :index}} = socket, %AccessKey{key_id: key_id}) do
    id =
      case Enum.find(socket.assigns.keys, &(&1.key_id == key_id)) do
        %AccessKey{revoked_at: nil} -> "key-#{key_id}-revoke"
        _revoked_or_gone -> "key-#{key_id}-title"
      end

    push_event(socket, "run:focus", %{id: id})
  end

  # Back on the tab from a code's cancelling, the focus goes to the code's Cancel the
  # command… where it still waits, or to Make an enrolment code.
  defp return_focus(%{assigns: %{live_action: :index}} = socket, %EnrolmentCode{id: code_id}) do
    id =
      if Enum.any?(socket.assigns.codes, &(&1.id == code_id)),
        do: "code-#{code_id}-revoke",
        else: "adapter-code-new"

    push_event(socket, "run:focus", %{id: id})
  end

  defp return_focus(socket, _left), do: socket

  @impl true
  # Make an enrolment code: a code made at once, with the defaults, whatever the event
  # carries, and its page opened with the code. Only from the tab, from one who may make
  # codes, while the integration has room for a key.
  def handle_event(
        "create_code",
        _params,
        %{assigns: %{live_action: action, may: %{new_code: true}}} = socket
      )
      when action in @tab_actions do
    %{current_scope: scope, adapter: adapter, paths: paths} = socket.assigns

    if at_limit?(socket.assigns.keys) do
      {:noreply, load(socket)}
    else
      case AccessKeys.create_enrolment_code(scope, adapter, %{}) do
        {:ok, row, code} ->
          # The code as the adapter sends it, in a function: shown by the code's page once,
          # and printed by nothing else.
          code = Enrolment.issued_code(code, Apiary.SigningKey.fingerprint())

          {:noreply,
           socket
           |> assign(issued: %{row: row, code: fn -> code end}, carry: true)
           |> load()
           |> push_patch(to: paths.new_code)}

        {:error, :forbidden} ->
          {:noreply, refused(socket, :new_code)}

        {:error, :not_found} ->
          {:noreply, gone(socket)}

        {:error, _not_saved} ->
          {:noreply, load(socket)}
      end
    end
  end

  def handle_event(
        "revoke",
        _params,
        %{assigns: %{live_action: :revoke, key: %AccessKey{} = key, may: %{revoke: true}}} =
          socket
      ) do
    case AccessKeys.revoke_access_key(socket.assigns.current_scope, key) do
      {:ok, key} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{label} is revoked.", label: key.label))
         |> load()
         |> push_patch(to: socket.assigns.paths.access_key)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, :revoke)}

      {:error, :not_found} ->
        {:noreply, gone(socket)}

      {:error, _not_saved} ->
        {:noreply, socket |> load() |> push_patch(to: socket.assigns.paths.access_key)}
    end
  end

  def handle_event(
        "revoke_code",
        _params,
        %{
          assigns: %{
            live_action: :revoke_code,
            code: %EnrolmentCode{} = code,
            may: %{revoke_code: true}
          }
        } = socket
      ) do
    case AccessKeys.cancel_code(socket.assigns.current_scope, code) do
      {:ok, %EnrolmentCode{cancelled_at: %DateTime{}}} ->
        {:noreply,
         to_tab(socket, :info, gettext("The command is cancelled. It no longer works."))}

      # It expired before the act reached it: nothing was cancelled.
      {:ok, %EnrolmentCode{}} ->
        {:noreply, to_tab(socket, :error, outstanding_no_more())}

      {:error, :used} ->
        {:noreply, to_tab(socket, :error, gettext("That command was run already."))}

      {:error, :forbidden} ->
        {:noreply, refused(socket, :revoke_code)}

      {:error, :not_found} ->
        {:noreply, gone(socket)}

      {:error, _not_saved} ->
        {:noreply, to_tab(socket, :error, gettext("Nothing was changed. Try again."))}
    end
  end

  # An act without its page or its confirmation open, or from one the page offers no
  # button: one who may take the act is shown the page again; one who may not is refused,
  # and nothing is done.
  def handle_event(event, _params, socket) when is_map_key(@write_events, event) do
    act = Map.fetch!(@write_events, event)

    if socket.assigns.may[act],
      do: {:noreply, load(socket)},
      else: {:noreply, refused(socket, act)}
  end

  @impl true
  # A key arrived at the integration, or one of its codes was cancelled: the keys and
  # codes read again, under the reader's own scope.
  def handle_info({event, %{node_id: id}}, %{assigns: %{adapter: %{id: id}}} = socket)
      when event in [:key_enrolled, :code_cancelled],
      do: {:noreply, load(socket)}

  # The code shown expired (`schedule_expiry/1`).
  def handle_info(:codes_expire, socket), do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The tab, read again, with what was done or why nothing was.
  defp to_tab(socket, kind, message) do
    socket
    |> put_flash(kind, message)
    |> load()
    |> push_patch(to: socket.assigns.paths.access_key)
  end

  defp outstanding_no_more,
    do: gettext("That command no longer works: it was run, cancelled or expired.")

  defp at_limit?(keys),
    do: Enum.count(keys, &is_nil(&1.revoked_at)) >= AccessKeys.key_limit()

  ## Answers

  # The act was refused on the membership as the database has it now: the scope is read
  # again, and one who still reads the organisation is told who may, on the tab; one who
  # no longer reaches it, or from whom the page is hidden now, leaves
  # (`ApiaryWeb.UserAuth.reload_scope/1`).
  defp refused(socket, act) do
    socket = UserAuth.reload_scope(socket)

    if socket.redirected do
      socket
    else
      scope = socket.assigns.current_scope

      socket
      |> assign_may()
      |> assign(issued: nil, key: nil, code: nil)
      |> put_flash(:error, AdapterComponents.only_admins(scope, Keyword.fetch!(@acts, act)))
      |> push_patch(to: socket.assigns.paths.access_key)
    end
  end

  # The integration was removed, or left the reader's reach, since the page opened: the
  # list, where it is no longer; or, where the page is hidden from the reader now, where
  # `ApiaryWeb.UserAuth.reload_scope/1` sends them.
  defp gone(socket) do
    socket = UserAuth.reload_scope(socket)

    cond do
      socket.redirected ->
        socket

      Adapters.get_adapter(socket.assigns.current_scope, socket.assigns.adapter.public_id) ->
        socket |> load() |> push_patch(to: socket.assigns.paths.access_key)

      true ->
        push_navigate(socket, to: AdapterComponents.index_path(socket.assigns.current_scope))
    end
  end

  ## Render

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :full, at_limit?(assigns.keys))

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
      <:crumb navigate={@paths.collections}>{@adapter.name}</:crumb>

      <.settings_page section={:integrations} title={@adapter.name} measure="list">
        <:subtitle><AdapterComponents.state_line summary={@summary} /></:subtitle>

        <AdapterComponents.tabs
          scope={@current_scope}
          adapter={@adapter}
          current={:access_key}
          live={:access_key}
        />

        <div id="adapter-access-key" class="grid max-w-[72rem] gap-8">
          <p :if={!@may.new_code} id="adapter-readers" class="text-[13px]/5 text-muted">
            {AdapterComponents.only_admins(@current_scope, :"access_key.create_code")}
          </p>

          <SettingsComponents.part
            :if={@may.new_code}
            id="adapter-enrol"
            title={gettext("Enrol its key")}
            level={:h2}
          >
            <%= if @live_action == :new_code and @issued do %>
              <%!-- The code, shown once, takes the focus as it shows, read with what it is
                   for. --%>
              <div
                id="adapter-code"
                class="grid max-w-[46rem] gap-4 text-[13px]/5 outline-none"
                tabindex="-1"
                phx-mounted={JS.focus()}
                aria-describedby="adapter-code-text"
              >
                <p id="adapter-code-text" class="text-muted">
                  {gettext(
                    "Run the adapter's enrol command with the server and this code on the adapter's host. The code works once, for %{minutes} minutes.",
                    minutes: Format.number(AccessKeys.code_ttl_minutes())
                  )}
                </p>
                <dl class="grid gap-3">
                  <.value
                    id="adapter-code-server"
                    label={gettext("Server")}
                    value={@server}
                    copy={gettext("Copy the server")}
                  />
                  <.value
                    id="adapter-code-code"
                    label={gettext("Code")}
                    value={@issued.code.()}
                    copy={gettext("Copy the code")}
                  />
                </dl>
              </div>
            <% else %>
              <div class="grid gap-3">
                <NodeLive.AccessKey.waiting
                  :if={@codes != []}
                  codes={@codes}
                  code={@live_action == :revoke_code && @code}
                  node={@adapter}
                  may={@may}
                  paths={@paths}
                  class="max-w-[46rem]"
                  adapter
                />
                <div :if={!@full}>
                  <.button
                    id="adapter-code-new"
                    variant={if @keys == [], do: "primary", else: "default"}
                    phx-click="create_code"
                    phx-hook="FocusOn"
                  >
                    {gettext("Make an enrolment code")}
                  </.button>
                </div>
              </div>
            <% end %>
          </SettingsComponents.part>

          <SettingsComponents.part
            :if={@keys != []}
            id="adapter-keys"
            title={gettext("Keys")}
            count={length(@keys)}
            level={:h2}
          >
            <ul id="adapter-keys-list" class="grid gap-3">
              <NodeLive.AccessKey.key_card
                :for={key <- @keys}
                key={key}
                node={@adapter}
                scope={@current_scope}
                paths={@paths}
                may={@card_may}
                intact={@intact[key.id]}
                last_run={nil}
                hosts={nil}
                confirming={@key && @key.id == key.id && @live_action}
                adapter
              />
            </ul>
          </SettingsComponents.part>
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :copy, :string, required: true

  # One value of the enrolment: its label, the value, and its Copy, which names it.
  defp value(assigns) do
    ~H"""
    <div class="grid gap-1">
      <dt class="font-medium">{@label}</dt>
      <dd class="flex flex-wrap items-center gap-2">
        <code
          id={@id}
          class="block min-w-0 flex-1 select-all break-all rounded-field border border-line bg-code px-2.5 py-1 font-mono text-[12.5px]/5"
        >{@value}</code>
        <.copy_button id={"#{@id}-copy"} target={"##{@id}"} label={@copy} />
      </dd>
    </div>
    """
  end
end
