defmodule ApiaryWeb.AdapterLive.AccessKey do
  # An adapter's Access key tab in Instance settings › Adapters, at `…/keys`, for the
  # instance's admins: its keys and enrolment codes, with the acts on them that a node's
  # Access key tab has (`ApiaryWeb.NodeLive.AccessKey`); and Add for one entry of the
  # catalogue (`:new`, by the entry), which makes nothing: it answers Not Found at mount
  # until the catalogue exists. A page of the Instance level, with no organisation: its
  # gate asks the instance whether the feature is on (`use ApiaryWeb.Features, instance:
  # :factory`), and anyone but an instance admin is answered as a path that does not
  # exist, as on the Instance's other pages. The keys, the codes and their topic are an
  # instance admin's (`Apiary.Adapters.subscribe_keys/2`).
  #
  # An adapter's key is enrolled with a code alone, never made in a browser, so the tab
  # offers one way: Get the command makes a code at once and opens `…/keys/new-code`,
  # which waits for the key the code brings, says the adapter is connected once it
  # arrives, and says the code no longer works once it was cancelled or expired.
  #
  # **The page holds the code in its process only, and never shows it until the command
  # is drawn.** It is wrapped in a function so no inspection of the process's state prints
  # it, and held until the reader leaves the command's page by any way, or the adapter has
  # used it: every path starts without it, but for the one patch from Get the command to
  # its page; no path, flash or title carries it, and nothing logs it. A page opened again
  # starts without it.
  #
  # Each key is a node's key card in its adapter mode, and each waiting code a node's
  # waiting command in the same mode (`ApiaryWeb.NodeLive.AccessKey.key_card/1`,
  # `waiting/1`): without Forager's rows, its secret on the machine that ran the command.
  # The people they name are looked up by their accounts' ids (`with_people/2`).
  #
  # A key's revocation and a waiting code's cancelling are confirmed in place, each at its
  # path: `…/keys/:key_id/revoke`, by the key's id, and `…/keys/codes/:code_id/revoke`, by
  # the code's row id, never the code. A key's is drawn under its card, whose Revoke… it
  # takes the place of; a code's, by `waiting/1`, in place of its Cancel the command….
  # Revoking the adapter's last active key says that no tickets arrive for any
  # organisation until it has a new one. Every act is asked again by the context function.
  #
  # An adapter installed with Qory Apiary (`Apiary.Adapters.Installed`) gets its codes
  # from the instance and makes its key by itself: the tab says so in place of the way to
  # connect it, offers no Get the command, and leaves out the codes the instance made,
  # which name no maker. Under the keys' lead, for its first key (`first_key?/2`), it says
  # the adapter made the key at its first start with a code of the instance, and no
  # command was run, and the key's card says it was enrolled then; a key after a revoked
  # one says neither, its card saying it connected by itself. While it is listed, the tab
  # says that revoking the key makes the adapter enrol again with a new one, and there is
  # no Add a key. A Get the command asked anyway is refused, and said so: while it is
  # listed, that Qory Apiary gives it its codes; once it is not, that it gets no new code
  # until it is turned on again. Once its name is off the list
  # (`Apiary.Adapters.listed?/1`), the instance gives it no new code: the tab says it is
  # turned off there, and, under Add a key, that turning it on again gives it a new key.
  #
  # Add answers as a path that does not exist for every entry, as for an entry the
  # catalogue does not hold: the instance has no catalogue of adapters to add yet.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, instance: :factory

  alias Apiary.{Accounts, AccessKeys, Adapters}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.{AdapterComponents, SettingsComponents}

  # The events that change something.
  @write_events ~w(create_code revoke revoke_code)

  # The paths that show the tab, where Get the command is offered.
  @tab_actions [:index, :revoke, :revoke_code]

  @impl true
  def mount(_params, _session, %{assigns: %{live_action: :new}}), do: raise(ApiaryWeb.NotFound)

  def mount(%{"adapter_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with :ok <- Adapters.authorize_instance(scope),
         %Node{} = adapter <- Adapters.get_adapter(scope, public_id) do
      if connected?(socket), do: Adapters.subscribe_keys(scope, adapter)

      {:ok,
       socket
       |> assign(adapter: adapter, paths: AdapterComponents.paths(adapter))
       |> assign(listed: Adapters.listed?(adapter))
       |> assign(issued: nil, carry: false, key: nil, code: nil, expiry_timer: nil)
       |> load()}
    else
      _not_theirs -> raise ApiaryWeb.NotFound
    end
  end

  # The adapter's keys, those in use first, and its outstanding codes, with the people
  # they name, and whether each key's record matches its integrity code.
  defp load(socket) do
    %{current_scope: scope, adapter: adapter} = socket.assigns

    # The codes the instance made, which name no maker, are an installed adapter's, which
    # no person runs: they are not shown.
    codes = scope |> Adapters.list_codes(adapter) |> Enum.reject(&is_nil(&1.created_by_id))
    {keys, codes} = with_people(Adapters.list_keys(scope, adapter), codes)

    socket
    |> assign(
      keys: keys,
      codes: codes,
      intact: Map.new(keys, &{&1.id, AccessKey.verify_integrity(&1) == :ok}),
      now: DateTime.utc_now()
    )
    |> note_arrival()
    |> schedule_expiry()
  end

  # Who made each key and code, and who revoked a key, as the key card and the waiting
  # command name them: their accounts, looked up by id in one read. An id no account has
  # is nobody, which the card says as a former member where it names who made it.
  defp with_people(keys, codes) do
    users =
      (Enum.flat_map(keys, &[&1.created_by_id, &1.revoked_by_id]) ++
         Enum.map(codes, & &1.created_by_id))
      |> Accounts.list_users_by_id()
      |> Map.new(&{&1.id, &1})

    {Enum.map(
       keys,
       &%{&1 | created_by: users[&1.created_by_id], revoked_by: users[&1.revoked_by_id]}
     ), Enum.map(codes, &%{&1 | created_by: users[&1.created_by_id]})}
  end

  # The command's code, once the key it brings is among the adapter's: the page says the
  # adapter is connected, and lets go of the code, which is spent.
  defp note_arrival(%{assigns: %{issued: %{arrived: nil, row: %{id: code_id}} = issued}} = socket) do
    case Enum.find(socket.assigns.keys, &(&1.enrolment_code_id == code_id)) do
      nil -> socket
      key -> assign(socket, :issued, %{issued | arrived: key, code: nil})
    end
  end

  defp note_arrival(socket), do: socket

  # The codes are read again the moment the first of them, or the command's code, expires:
  # an expired code is no longer outstanding, and the command's page says it no longer
  # works.
  defp schedule_expiry(socket) do
    %{codes: codes, issued: issued, now: now, expiry_timer: timer} = socket.assigns
    if timer, do: Process.cancel_timer(timer)

    times =
      Enum.map(codes, & &1.expires_at) ++
        for %{row: %{expires_at: at}} <- [issued], DateTime.after?(at, now), do: at

    timer =
      if connected?(socket) and times != [] do
        wait = DateTime.diff(Enum.min(times, DateTime), now, :millisecond)
        Process.send_after(self(), :codes_expire, max(wait, 0) + 1)
      end

    assign(socket, :expiry_timer, timer)
  end

  @impl true
  def handle_params(%{"adapter_id" => public_id}, _uri, %{assigns: %{adapter: adapter}} = socket)
      when public_id != adapter.public_id,
      do: {:noreply, push_navigate(socket, to: AdapterComponents.paths(public_id).keys)}

  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action

    # Every path starts without a code and without a confirmation open, but the code just
    # made, carried once to its page: a code is gone once the reader leaves its page.
    issued = if socket.assigns.carry and action == :new_code, do: socket.assigns.issued
    socket = assign(socket, issued: issued, carry: false, key: nil, code: nil)

    {:noreply, socket |> apply_action(action, params) |> titled()}
  end

  defp apply_action(socket, :index, _params), do: socket

  # The command's page, with the code just made. Opened any other way, there is no code:
  # it was the page's once, so the reader is back on the tab.
  defp apply_action(%{assigns: %{issued: %{}}} = socket, :new_code, _params), do: socket

  defp apply_action(socket, :new_code, _params),
    do: push_patch(socket, to: socket.assigns.paths.keys)

  # A key's revocation, confirmed in place: of an active key of the adapter.
  defp apply_action(socket, :revoke, %{"key_id" => key_id}) do
    case Enum.find(socket.assigns.keys, &(&1.key_id == key_id)) do
      %AccessKey{revoked_at: nil} = key ->
        assign(socket, :key, key)

      %AccessKey{} = key ->
        to_tab(socket, :error, gettext("%{label} is revoked.", label: key.label))

      nil ->
        push_patch(socket, to: socket.assigns.paths.keys)
    end
  end

  # A waiting code's cancelling, confirmed in place.
  defp apply_action(socket, :revoke_code, %{"code_id" => code_id}) do
    case Enum.find(socket.assigns.codes, &(&1.id == code_id)) do
      %EnrolmentCode{} = code -> assign(socket, :code, code)
      nil -> to_tab(socket, :error, outstanding_no_more())
    end
  end

  # The window's title: the command's, or the tab's, then the adapter's name.
  defp titled(%{assigns: %{live_action: :new_code, issued: %{}}} = socket) do
    %{current_scope: scope, adapter: adapter} = socket.assigns
    assign(socket, :page_title, AdapterComponents.page_title(scope, [command_title(adapter)]))
  end

  defp titled(socket) do
    %{current_scope: scope, adapter: adapter} = socket.assigns

    assign(
      socket,
      :page_title,
      AdapterComponents.page_title(scope, [gettext("Access key"), adapter.name])
    )
  end

  @impl true
  # Get the command: a code made at once, whatever the event carries, and its page opened
  # with it. Only from the tab, while the adapter has room for a key.
  def handle_event("create_code", _params, %{assigns: %{live_action: action}} = socket)
      when action in @tab_actions do
    %{current_scope: scope, adapter: adapter, paths: paths} = socket.assigns

    if full?(socket.assigns.keys) do
      {:noreply, load(socket)}
    else
      case Adapters.create_code(scope, adapter) do
        {:ok, row, code} ->
          {:noreply,
           socket
           |> assign(issued: %{row: row, code: fn -> code end, arrived: nil}, carry: true)
           |> load()
           |> push_patch(to: paths.new_code)}

        {:error, :sudo} ->
          {:noreply, sign_in_again(socket)}

        {:error, :installed} ->
          {:noreply,
           to_tab(socket, :error, installed_refusal(Adapters.listed?(socket.assigns.adapter)))}

        {:error, :forbidden} ->
          {:noreply, not_theirs(socket)}

        {:error, :not_found} ->
          {:noreply, gone(socket)}

        {:error, _not_saved} ->
          {:noreply, to_tab(socket, :error, gettext("Nothing was changed. Try again."))}
      end
    end
  end

  def handle_event(
        "revoke",
        _params,
        %{assigns: %{live_action: :revoke, key: %AccessKey{} = key}} = socket
      ) do
    case Adapters.revoke_key(socket.assigns.current_scope, key) do
      {:ok, key} ->
        {:noreply, to_tab(socket, :info, gettext("%{label} is revoked.", label: key.label))}

      {:error, :forbidden} ->
        {:noreply, not_theirs(socket)}

      {:error, :not_found} ->
        {:noreply, gone(socket)}

      {:error, _not_saved} ->
        {:noreply, to_tab(socket, :error, gettext("Nothing was changed. Try again."))}
    end
  end

  def handle_event(
        "revoke_code",
        _params,
        %{assigns: %{live_action: :revoke_code, code: %EnrolmentCode{} = code}} = socket
      ) do
    case Adapters.cancel_code(socket.assigns.current_scope, code) do
      {:ok, %EnrolmentCode{cancelled_at: %DateTime{}}} ->
        {:noreply,
         to_tab(socket, :info, gettext("The command is cancelled. It no longer works."))}

      # It expired before the act reached it: nothing was cancelled.
      {:ok, %EnrolmentCode{}} ->
        {:noreply, to_tab(socket, :error, outstanding_no_more())}

      {:error, :used} ->
        {:noreply, to_tab(socket, :error, gettext("That command was run already."))}

      {:error, :forbidden} ->
        {:noreply, not_theirs(socket)}

      {:error, :not_found} ->
        {:noreply, gone(socket)}

      {:error, _not_saved} ->
        {:noreply, to_tab(socket, :error, gettext("Nothing was changed. Try again."))}
    end
  end

  # An act without its path or its confirmation open: nothing is done, and the page is
  # read again.
  def handle_event(event, _params, socket) when event in @write_events,
    do: {:noreply, load(socket)}

  @impl true
  # A key arrived at the adapter, or one of its codes was cancelled, here or on another
  # page: the keys and codes read again, under the reader's scope. The command's page
  # whose key it is turns to say the adapter is connected; a confirmation of a code no
  # longer waiting closes.
  def handle_info({event, %{node_id: id}}, %{assigns: %{adapter: %{id: id}}} = socket)
      when event in [:key_enrolled, :code_cancelled],
      do: {:noreply, socket |> load() |> close_gone_confirmation()}

  # A code expired (`schedule_expiry/1`). The timer the page holds stays for `load/1` to
  # cancel: a read in between may have set another while this one's message waited.
  def handle_info(:codes_expire, socket),
    do: {:noreply, socket |> load() |> close_gone_confirmation()}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The confirmation of a code no longer outstanding (run, cancelled or expired) closes,
  # and the reader is told so on the tab.
  defp close_gone_confirmation(socket) do
    case socket.assigns do
      %{live_action: :revoke_code, code: %EnrolmentCode{id: id}, codes: codes} ->
        if Enum.any?(codes, &(&1.id == id)),
          do: socket,
          else: to_tab(socket, :error, outstanding_no_more())

      _no_confirmation ->
        socket
    end
  end

  # The tab, read again, with what was done or why nothing was.
  # Why a Get the command for an adapter installed with Qory Apiary is refused: while it
  # is listed, the instance gives it its codes; once it is not, it gets none until it is
  # turned on again.
  defp installed_refusal(true), do: gettext("Qory Apiary gives this adapter its codes itself.")

  defp installed_refusal(false),
    do:
      gettext(
        "This adapter is turned off in the AWS stack or the Compose file; it gets no new code until it is turned on again."
      )

  defp to_tab(socket, kind, words) do
    socket
    |> put_flash(kind, words)
    |> load()
    |> push_patch(to: socket.assigns.paths.keys)
  end

  # The sign-in has grown old since the page opened: as the Instance's Mail page answers.
  defp sign_in_again(socket) do
    socket
    |> put_flash(:error, gettext("You must re-authenticate to access this page."))
    |> redirect(to: ~p"/users/log-in")
  end

  # No longer an instance admin: the page itself is not found now.
  defp not_theirs(socket), do: push_navigate(socket, to: socket.assigns.paths.keys)

  # The adapter was removed since the page opened: the list, where it is no longer.
  defp gone(socket) do
    %{current_scope: scope, adapter: adapter, paths: paths} = socket.assigns

    if Adapters.get_adapter(scope, adapter.public_id),
      do: socket |> load() |> push_patch(to: paths.keys),
      else: push_navigate(socket, to: paths.list)
  end

  defp outstanding_no_more,
    do: gettext("That command no longer works: it was run, cancelled or expired.")

  defp active(keys), do: Enum.filter(keys, &is_nil(&1.revoked_at))

  @doc false
  # Whether `key` is its adapter's first key: no revoked key of the adapter, among `keys`
  # (`Apiary.Adapters.list_keys/2`, revoked ones too), was received before it. A key that
  # came after a revoked one is not.
  @spec first_key?(AccessKey.t(), [AccessKey.t()]) :: boolean
  def first_key?(%AccessKey{id: id, received_at: at}, keys) do
    not Enum.any?(keys, fn other ->
      other.id != id and not is_nil(other.revoked_at) and
        DateTime.before?(other.received_at, at)
    end)
  end

  defp full?(keys), do: length(active(keys)) >= AccessKeys.key_limit()

  defp command_title(adapter),
    do: gettext("Connect %{name} with a command", name: adapter.name)

  # What the command's page says: waiting for the key, connected once it arrived, or that
  # the code no longer works.
  defp command_state(%{arrived: %AccessKey{}}, _codes), do: :connected

  defp command_state(%{row: %EnrolmentCode{id: id}}, codes),
    do: if(Enum.any?(codes, &(&1.id == id)), do: :waiting, else: :spent)

  # Whether `key`'s revocation is the one asked.
  defp asked?(%AccessKey{id: id}, %AccessKey{id: id}), do: true
  defp asked?(_asked, _key), do: false

  defp way_button([]), do: gettext("Get the command")
  defp way_button(_waiting), do: gettext("Get a new command")

  ## Render

  @impl true
  def render(%{live_action: :new_code, issued: %{}} = assigns) do
    assigns = assign(assigns, :state, command_state(assigns.issued, assigns.codes))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:adapters}
    >
      <:crumb navigate={@paths.overview}>{@adapter.name}</:crumb>
      <:crumb patch={@paths.keys}>{gettext("Access key")}</:crumb>
      <:crumb>{gettext("Command")}</:crumb>

      <.settings_page section={:adapters} title={command_title(@adapter)}>
        <:subtitle>
          {gettext(
            "The command connects %{name} by itself: it makes the adapter's key on its machine and sends Qory Apiary only the public half. The secret never leaves the machine.",
            name: @adapter.name
          )}
        </:subtitle>

        <div id="code-issued" class="grid gap-4">
          <%!-- What changes as the adapter's machine runs the command, said as it
               changes. --%>
          <div id="code-issued-state" class="grid gap-4" aria-live="polite">
            <%= case @state do %>
              <% :waiting -> %>
                <.listening id="code-issued-waiting">
                  {gettext(
                    "Waiting for the command to run. This page shows when the adapter is connected."
                  )}
                </.listening>
              <% :connected -> %>
                <div id="code-issued-connected">
                  <.notice kind={:success}>
                    <strong>{gettext("%{name} is connected.", name: @adapter.name)}</strong>
                    {gettext("Its key arrived at %{time} and is active.",
                      time: Format.time(@issued.arrived.received_at)
                    )}
                  </.notice>
                </div>
                <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-6 gap-y-2 text-[13px]/5">
                  <dt class="text-faint">{gettext("Key")}</dt>
                  <dd id="code-issued-key">
                    {@issued.arrived.label}
                    <span class="q-mono text-muted">{@issued.arrived.key_id}</span>
                  </dd>
                  <dt class="text-faint">{gettext("Fingerprint")}</dt>
                  <dd id="code-issued-fingerprint" class="q-mono break-all">
                    {AccessKey.fingerprint(@issued.arrived)}
                  </dd>
                </dl>
                <p id="code-issued-check" class="text-[13px]/5 text-muted">
                  {gettext(
                    "The command printed a fingerprint when it ran. If it isn't this one, revoke the key on the Access key tab."
                  )}
                </p>
                <p id="code-issued-install" class="text-[13px]/5 text-muted">
                  {gettext("Once it runs, organisations can install it.")}
                </p>
              <% :spent -> %>
                <div id="code-issued-spent">
                  <.notice kind={:warning}>{outstanding_no_more()}</.notice>
                </div>
            <% end %>
          </div>

          <%!-- Done alone: leaving cancels nothing, the code is made. --%>
          <SettingsComponents.save id="code-issued-done">
            <.button id="code-issued-done-button" variant="primary" patch={@paths.keys}>
              {gettext("Done")}
            </.button>
          </SettingsComponents.save>
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end

  def render(assigns) do
    active = active(assigns.keys)

    assigns =
      assign(assigns,
        active: length(active),
        full: length(active) >= AccessKeys.key_limit(),
        last: match?([_one], active),
        first: active != [] and first_key?(hd(active), assigns.keys)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:adapters}
    >
      <:crumb navigate={@paths.overview}>{@adapter.name}</:crumb>

      <.settings_page section={:adapters} title={@adapter.name}>
        <:subtitle>
          <AdapterComponents.adapter_meta
            adapter={@adapter}
            reader={@current_scope.user.email}
          />
        </:subtitle>

        <AdapterComponents.adapter_tabs adapter={@adapter} paths={@paths} current={:keys} />

        <div id="adapter-access-key" class="grid gap-8">
          <%!-- No key in use: what it means, and the one way to connect it. --%>
          <SettingsComponents.part
            :if={@active == 0}
            id="adapter-connect"
            title={gettext("Connect %{name}", name: @adapter.name)}
          >
            <p :if={@listed} id="adapter-connect-intro" class="text-[13px]/5 text-muted">
              {gettext(
                "This adapter is installed with Qory Apiary. While it has no key, Qory Apiary gives it a one-time code by itself, and it makes its key with it. No command is run."
              )}
            </p>
            <p
              :if={Adapters.installed?(@adapter) and !@listed}
              id="adapter-connect-intro"
              class="text-[13px]/5 text-muted"
            >
              {gettext(
                "This adapter was installed with Qory Apiary and is turned off there. Qory Apiary gives it no new code until it is turned on again."
              )}
            </p>
            <p
              :if={!@adapter.installed_as}
              id="adapter-connect-intro"
              class="text-[13px]/5 text-muted"
            >
              {gettext(
                "The adapter connects to Qory Apiary with a key that it makes on its machine. Until it has one, organisations can't install it."
              )}
            </p>
            <.way
              :if={!@adapter.installed_as}
              id="adapter-way"
              primary
              adapter={@adapter}
              codes={@codes}
              code={@code}
              paths={@paths}
              reader={@current_scope.user.email}
            >
              {gettext(
                "You get one command to run on the machine that runs the adapter. It carries a one-time code, not a key, which works once within 15 minutes."
              )}
              {gettext("The adapter makes the key there and sends Qory Apiary only its public half.")}
            </.way>
          </SettingsComponents.part>

          <SettingsComponents.part
            :if={@keys != []}
            id="adapter-keys"
            title={gettext("Keys")}
            count={length(@keys)}
          >
            <p id="adapter-keys-intro" class="text-[13px]/5 text-muted">
              {gettext(
                "The adapter signs every request with its key. Qory Apiary keeps only the public half."
              )}
            </p>
            <p
              :if={@adapter.installed_as && @first}
              id="adapter-keys-installed"
              class="max-w-[80ch] text-[13px]/5 text-muted"
            >
              {gettext(
                "The adapter made this key at its first start, and enrolled with a code that Qory Apiary handed it. No command was run."
              )}
            </p>
            <p
              :if={@listed && @active > 0}
              id="adapter-keys-revoking"
              class="text-[13px]/5 text-muted"
            >
              {gettext("Revoking it makes the adapter enrol again with a new key.")}
            </p>
            <%!-- Each key as a node's card, in its adapter mode. Its Revoke… leads to
                 `…/keys/:key_id/revoke` (`AdapterComponents.act_path/2`), which the card
                 writes as `access_key/keys/:key_id/revoke`, so it is given the adapter's
                 Overview as `access_key`. The card's confirmation (`confirming`) is not
                 used: this tab's says what revoking the adapter's last key means, and
                 goes back to the tab. --%>
            <ul id="adapter-keys-list" class="grid gap-3">
              <%= for key <- @keys do %>
                <ApiaryWeb.NodeLive.AccessKey.key_card
                  key={key}
                  node={@adapter}
                  scope={@current_scope}
                  paths={%{access_key: @paths.overview}}
                  may={%{revoke: !asked?(@key, key), revoke_code: false}}
                  intact={@intact[key.id]}
                  last_run={nil}
                  hosts={nil}
                  confirming={false}
                  first={first_key?(key, @keys)}
                  adapter
                />
                <li :if={asked?(@key, key)} id={"key-#{key.key_id}-asked"}>
                  <.inline_confirm
                    id={"key-#{key.key_id}-confirm"}
                    question={gettext("Revoke %{label}?", label: key.label)}
                    cancel={@paths.keys}
                  >
                    {gettext(
                      "It is revoked at once, and its public key can never be used again. This cannot be undone."
                    )}
                    <span
                      :if={@last}
                      id={"key-#{key.key_id}-last"}
                      class="mt-1 flex items-start gap-1.5 text-base-content"
                    >
                      <.icon
                        name="hero-exclamation-triangle-micro"
                        class="mt-0.5 size-4 flex-none"
                      />
                      <span :if={@listed}>
                        {gettext(
                          "It is the adapter's only key. Qory Apiary gives the adapter a new code at once; until it has made a new key, nothing it sends reaches any organisation."
                        )}
                      </span>
                      <span :if={Adapters.installed?(@adapter) and !@listed}>
                        {gettext(
                          "It is the adapter's only key. The adapter is turned off in the AWS stack or the Compose file, so it gets no new code: until it is turned on again, nothing it sends reaches any organisation."
                        )}
                      </span>
                      <span :if={!@adapter.installed_as}>
                        {gettext(
                          "It is the adapter's only key: until it gets a new one, nothing it sends reaches any organisation."
                        )}
                      </span>
                    </span>
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

          <%!-- A key in use: the same way, for moving to a new key, but at the
               limit. An adapter installed with Qory Apiary has none while it is listed:
               revoking its key brings a new one. --%>
          <SettingsComponents.part
            :if={@active > 0 and Adapters.installed?(@adapter) and !@listed}
            id="adapter-add"
            title={gettext("Add a key")}
          >
            <p id="adapter-add-intro" class="text-[13px]/5 text-muted">
              {gettext("Turn it on again in the AWS stack or the Compose file to give it a new key.")}
            </p>
          </SettingsComponents.part>
          <SettingsComponents.part
            :if={@active > 0 and !@adapter.installed_as}
            id="adapter-add"
            title={gettext("Add a key")}
          >
            <p id="adapter-add-intro" class="text-[13px]/5 text-muted">
              {gettext(
                "To move the adapter to a new key, get a new command and run it, then revoke the old key once the new one is in use. An adapter holds two keys at most."
              )}
            </p>
            <.way
              id="adapter-way"
              primary={false}
              offered={!@full}
              adapter={@adapter}
              codes={@codes}
              code={@code}
              paths={@paths}
              reader={@current_scope.user.email}
            >
              {gettext(
                "You get one command to run on the machine that runs the adapter. It carries a one-time code, not a key, which works once within 15 minutes."
              )}
            </.way>
          </SettingsComponents.part>
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :primary, :boolean, required: true
  attr :offered, :boolean, default: true, doc: "whether Get the command is offered"
  attr :adapter, Node, required: true
  attr :codes, :list, required: true, doc: "the adapter's codes still waiting to be run"
  attr :code, :any, required: true, doc: "the code whose cancelling is asked, or nil"
  attr :paths, :map, required: true, doc: "the adapter's `paths/1`"
  attr :reader, :string, default: nil, doc: "the reader's address"
  slot :inner_block, required: true, doc: "what happens, in sentences"

  # The one way to connect the adapter: its title, what happens, each command still
  # waiting to be run, as a node's waiting command in its adapter mode, with its
  # cancelling confirmed in place where it is asked, and its button. The waiting command
  # writes its paths as `access_key/codes/:code_id/revoke` and goes back to `access_key`,
  # so it is given the adapter's Access key tab as `access_key`
  # (`AdapterComponents.act_path/2`).
  defp way(assigns) do
    ~H"""
    <div
      id={@id}
      class="grid gap-3 rounded-box border border-line bg-base-100 p-4 text-[13px]/5 shadow-xs"
    >
      <h3 id={"#{@id}-title"} class="flex items-center gap-2 text-[14px]/5 font-medium">
        <.icon name="hero-command-line" class="size-4.5 text-muted" />
        {gettext("Connect with a command")}
      </h3>
      <p id={"#{@id}-happens"} class="text-muted">{render_slot(@inner_block)}</p>
      <ApiaryWeb.NodeLive.AccessKey.waiting
        codes={@codes}
        code={@code}
        node={@adapter}
        may={%{revoke_code: true}}
        paths={%{access_key: @paths.keys}}
        reader={@reader}
        adapter
      />
      <div :if={@offered}>
        <.button
          id="code-new-button"
          phx-click="create_code"
          variant={if @primary, do: "primary", else: "default"}
          class="max-[479px]:w-full"
        >
          {way_button(@codes)}
        </.button>
      </div>
    </div>
    """
  end
end
