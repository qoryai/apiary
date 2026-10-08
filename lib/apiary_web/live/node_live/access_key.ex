defmodule ApiaryWeb.NodeLive.AccessKey do
  @moduledoc """
  A node's Access key tab, `/:org/:workspace/nodes/:node_id/access-key`: how to connect
  the node, its access keys, and the commands that wait to be run on it, over
  `Apiary.AccessKeys` as it is. Its header and tabs are the node's page's
  (`ApiaryWeb.NodeComponents`).

  **The two ways.** A node gets a key one of two ways, and the tab offers both wherever it
  offers one, the node's kind deciding only the order and the primary button: a node, one
  machine of its own, leads with **Connect with a command**, a pool with **Generate a
  key**.

  - **Connect with a command** makes an enrolment code at once, in one click (`create_code`,
    with the defaults: stored secrets not allowed, no label hint), and opens the command's
    page (`…/access-key/new-code`): the whole command, `qory access-key enrol <server>
    <code>`, wrapped, with Copy; until when it works; and "Waiting for … to run it". The
    code exists only inside the command. The page hears the key arrive (`Apiary.AccessKeys`'
    topic of the node, `{:key_enrolled, …}`, sent once the enrolment committed) and turns
    to "… is connected", with the key and its fingerprint to check. A command that no longer
    works, expired or cancelled, says so. Where the server's address is a loopback one, a
    notice says machines can't reach it and names `PUBLIC_URL`.
  - **Generate a key** (`…/access-key/generate`), a page of its own: the key's name alone,
    prefilled with the node's. The browser makes the key (the `GenerateKey` hook,
    `assets/js/hooks/generate_key.js`) and sends Qory its public half alone, in the one
    event `generate_key` (`{"key" => %{"label", "public_key"}}`); the form has no field for
    anything else, and no `phx-submit`. The event is taken only on that page, with its
    form open, from one who may add keys, and only as exactly those two strings: any other
    field, a stored-secrets flag among them, or a label holding `qak_` (an access key's
    secret, in any case), is refused before anything is stored, and the public key passes
    the strict decoding of the key checks, which no secret passes. Every key is added with
    stored secrets not allowed (`Apiary.AccessKeys.add_access_key/3`, `arrived_by:
    :browser`), and the page patches to **Key for a node** (`…/access-key/keys/:key_id/
    generated`), rendered by the same clause so that the hook's `<section
    id="key-generate">` lives through the patch, with no flash. It is four numbered steps:
    store the secret, its slot `phx-update="ignore"`, empty from the server, carrying the
    public key the server stored (`data-public-key`), its ids the key's, so that a patch to
    another key's page replaces it; set the key's ID; set Qory Apiary's public key; point
    qory at Qory Apiary, the runner file's address. The hook writes the secret into the
    slot only beside its own public key, empties a slot that shows a secret for another
    public key, and empties it as the page goes. The server never has the secret: not in
    assigns, a render, a log line or the record. What the page says of the secret follows
    what the browser holds, not the server, whose render is the same whether the page made
    the key, was opened again or was joined again after a dropped connection: the notice
    that the secret is shown once, the secret's Copy and the note beside Done come hidden
    (`data-secret-shown`), and the hook shows them while the slot shows the secret; while
    it holds nothing for the key, it shows the slot's "Not shown" line instead. A
    reconnect never empties the slot. It is the page of an active key the reader made in a
    browser, while they may add keys; any other key's address goes to its runner file, or
    back to the tab.

  **The tab.** While the node holds no active key, owners and admins read "How do you want
  to connect …?" and the two ways as two equal options, side by side and of one height:
  each its title, when to choose it, what happens, the same four facts in the same rows
  (Key made, Secret, By hand, Needs), and one button at its foot; no steps and nothing to
  copy, each way's detail being on the page it opens. A member reads that an owner or
  admin connects it. A command not yet run shows in the command's option, above its
  button, never as a list of codes: who got it and when, until when it works, and "Cancel the command…", confirmed in place
  (`…/access-key/codes/:code_id/revoke`, the code's row id, never the code); the button
  becomes "Get a new command". The page reads the codes again the moment the first of them
  expires, so an expired one leaves at once, with its confirmation.

  - **Keys**, those in use first, then the revoked, newest first: each its label and state,
    Active or Revoked (read from `revoked_at` alone: a key is active from the moment it
    arrives), its key id with Copy, how and by whom it was added, where its secret is, its
    use where the record holds any, its fingerprint and its stored-secrets flag, and who
    revoked it and when. A key whose row does not match its integrity code says so: it
    can't be used. Owners and admins revoke an active key, confirmed in place, at a path of
    its own (`…/access-key/keys/:key_id/revoke`).
  - **Add a key**, once the node holds an active key: the same two ways as rows, in the
    same order, for moving to a new key; at the limit, only the line that says to revoke
    one first, and a command still waiting, which can still be cancelled.
  - **Configure a machine**, once the node holds an active key, for everyone, at the limit
    too: four numbered steps, point qory at Qory Apiary (the runner file's address), set
    Qory Apiary's public key, set the key's ID (its value while one key is active, else a
    pointer to the key's card), keep the key's secret in a secret store (never shown).
  - **Runner file for a key** (`…/access-key/keys/:key_id/runner-file`), a page of its own
    for an active key, linked from its card for everyone who reads the node, since nothing
    on it is secret. What it says follows how the key came: a key connected with a command
    has the runner file's `server` lines the command wrote, each marked as Qory Apiary's or
    this key's; a generated key has four numbered steps: keep the secret in a secret
    store, set its id, set Qory Apiary's public key, point qory at Qory Apiary. Either way
    it says truly where the key's secret is.

  **The server's part.** The address and `QORY_APIARY_PUBLIC_KEY`, the instance's own
  signing key, are Qory Apiary's, the same for every machine connected to it, so the pages
  name them as Qory Apiary's, apart from the key's own values, from
  `Apiary.AccessKeys.server_lines/2` and `server_variable/1`, which ask for no key.

  Leaving a page or a confirmation gives the focus back to the button that opened it, or,
  where the act took that button away, to the key's heading or to the command's button.

  **A command is shown once.** Its code lives in the page's process alone, wrapped in a
  function so no inspection of the process's state prints it, until the reader leaves the
  page by any way, or the machine has run it: every path starts without it, but for the
  one patch from Get the command to its page; no path, flash or title carries it, and
  nothing logs it. A page opened again starts without it.

  Everyone in the workspace reads the tab (`node.read`); owners and admins act
  (`access_key.add`, `access_key.create_code`, `access_key.revoke`,
  `access_key.cancel_code`). A member sees no button and the line that says who connects
  the node, or who manages its keys; an act's path refuses them. Every act is asked of
  `Apiary.Access` again by the context function, with the membership as the database has
  it, and an event that comes without its page or its confirmation open acts on nothing.
  """
  use ApiaryWeb, :live_view
  on_mount {ApiaryWeb.Access, :"node.read"}

  alias Apiary.{Access, AccessKeys, Nodes, Repo, Runs}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Contract.Enrolment
  alias Apiary.Nodes.Node
  alias ApiaryWeb.{NodeComponents, People, SettingsComponents, UserAuth}

  # The page's acts, and the action of `Apiary.Access` each one asks.
  @acts [
    add_key: :"access_key.add",
    new_code: :"access_key.create_code",
    revoke: :"access_key.revoke",
    revoke_code: :"access_key.cancel_code"
  ]

  # The events that change something, and the act each is.
  @write_events %{
    "create_code" => :new_code,
    "revoke" => :revoke,
    "revoke_code" => :revoke_code
  }

  # The paths that show the tab, where Get the command is offered.
  @tab_actions [:index, :revoke, :revoke_code]

  @hosts_days 14

  @impl true
  def mount(%{"node_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Nodes.get_node(scope, public_id) do
      %Node{} = node ->
        if connected?(socket) do
          Nodes.subscribe(scope)
          AccessKeys.subscribe(scope, node)
        end

        {:ok,
         socket
         |> assign(node: node, paths: paths(scope, node.public_id))
         |> assign(issued: nil, carry: false, form: nil, key: nil, code: nil)
         |> assign(shown: nil, expiry_timer: nil)
         |> assign_may()
         |> assign_activity()
         |> load()
         |> UserAuth.on_membership_change(&(&1 |> assign_may() |> load()))}

      nil ->
        raise Ecto.NoResultsError, queryable: Node
    end
  end

  defp assign_may(socket) do
    %{current_scope: scope, node: node} = socket.assigns
    may = Map.new(@acts, fn {act, action} -> {act, Access.can?(scope, action, node)} end)

    assign(socket,
      may: may,
      manages: Enum.any?(Map.values(may)),
      may_runs: Access.can?(scope, :"run.read", scope.workspace)
    )
  end

  defp assign_activity(socket) do
    %{current_scope: scope, node: node} = socket.assigns
    assign(socket, :activity, Map.fetch!(Nodes.activity(scope, [node]), node.id))
  end

  # The node's keys and outstanding codes, with who made and revoked each, and
  # what the record holds of their use.
  defp load(socket) do
    %{current_scope: scope, node: node} = socket.assigns

    keys =
      scope
      |> AccessKeys.list_for_node(node)
      |> Repo.preload([:created_by, :revoked_by])

    codes = scope |> AccessKeys.list_enrolment_codes(node) |> Repo.preload(:created_by)
    ids = Enum.map(keys, & &1.id)

    {last_runs, hosts} =
      if socket.assigns.may_runs do
        since = DateTime.add(DateTime.utc_now(), -@hosts_days * 86_400, :second)
        {Runs.last_runs_by_key(scope, ids), Runs.hosts_by_key(scope, ids, since)}
      else
        {%{}, %{}}
      end

    socket
    |> assign(
      keys: keys,
      codes: codes,
      intact: Map.new(keys, &{&1.id, AccessKey.verify_integrity(&1) == :ok}),
      last_runs: last_runs,
      hosts: hosts,
      now: DateTime.utc_now()
    )
    |> note_arrival()
    |> schedule_expiry()
  end

  # The command shown, once the key it brings is among the node's: the page says the
  # machine is connected, and lets go of the code, which is spent.
  defp note_arrival(%{assigns: %{issued: %{arrived: nil, row: %{id: code_id}} = issued}} = socket) do
    case Enum.find(socket.assigns.keys, &(&1.enrolment_code_id == code_id)) do
      nil -> socket
      key -> assign(socket, :issued, %{issued | arrived: key, code: nil})
    end
  end

  defp note_arrival(socket), do: socket

  # The codes are read again the moment the first of them, or the command shown, expires:
  # an expired code is no longer outstanding, so the tab stops showing it waiting, and the
  # command shown says it no longer works.
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
  def handle_params(%{"node_id" => public_id}, _uri, %{assigns: %{node: node}} = socket)
      when public_id != node.public_id do
    {:noreply,
     push_navigate(socket, to: paths(socket.assigns.current_scope, public_id).access_key)}
  end

  def handle_params(params, _uri, socket) do
    # What the reader leaves, for the focus to go back to the button that opened it.
    opener = opener(socket.assigns)
    action = socket.assigns.live_action

    # Every path starts without a command shown and without a confirmation or a form
    # open, but the command just got, carried once to its page: a command shown is gone
    # once the reader leaves its page.
    issued = if socket.assigns.carry and action == :new_code, do: socket.assigns.issued

    socket = assign(socket, issued: issued, carry: false, form: nil, key: nil, code: nil)

    {:noreply,
     socket
     |> apply_action(action, params)
     |> titled()
     |> return_focus(opener)
     |> assign(:shown, action)}
  end

  # The button that opened the form, the command shown or the confirmation the page shows.
  defp opener(%{shown: :generate}), do: :generate
  defp opener(%{shown: :new_code}), do: :new_code

  defp opener(%{shown: :revoke, key: %AccessKey{key_id: key_id}}),
    do: {:key, key_id, :revoke}

  defp opener(%{shown: :revoke_code, code: %EnrolmentCode{id: id}}), do: {:code, id}

  defp opener(%{shown: :runner_file, key: %AccessKey{key_id: key_id}}),
    do: {:key, key_id, :runner_file}

  defp opener(%{shown: :generated, key: %AccessKey{key_id: key_id}}),
    do: {:key, key_id, :generated}

  defp opener(_assigns), do: nil

  # Back on the tab, the focus goes to the opener where it is still there; where the act
  # took it away, to the key's heading, or to the command's button for a command gone.
  defp return_focus(%{assigns: %{live_action: :index} = assigns} = socket, opener) do
    case focus_id(assigns, opener) do
      nil -> socket
      id -> push_event(socket, "run:focus", %{id: id})
    end
  end

  defp return_focus(socket, _opener), do: socket

  defp focus_id(%{may: may} = assigns, :generate),
    do: if(may.add_key and not at_limit?(assigns.keys), do: "key-generate-button")

  defp focus_id(%{may: may} = assigns, :new_code),
    do: if(may.new_code and not at_limit?(assigns.keys), do: "code-new-button")

  defp focus_id(assigns, {:key, key_id, act}) do
    case Enum.find(assigns.keys, &(&1.key_id == key_id)) do
      nil ->
        nil

      _key when act == :generated ->
        "key-#{key_id}-title"

      key ->
        if act in key_acts(key, assigns.may) or
             (act == :runner_file and state(key) == :active),
           do: "key-#{key_id}-#{String.replace(to_string(act), "_", "-")}",
           else: "key-#{key_id}-title"
    end
  end

  defp focus_id(%{may: may, codes: codes} = assigns, {:code, id}) do
    cond do
      may.revoke_code and Enum.any?(codes, &(&1.id == id)) -> "code-#{id}-revoke"
      may.new_code and not at_limit?(assigns.keys) -> "code-new-button"
      true -> nil
    end
  end

  defp focus_id(_assigns, nil), do: nil

  defp apply_action(socket, :index, _params), do: socket

  defp apply_action(socket, :generate, _params) do
    %{keys: keys, node: node} = socket.assigns

    cond do
      not socket.assigns.may.add_key ->
        refused(socket, gettext("Only owners and admins add a node's keys."))

      at_limit?(keys) ->
        to_tab(socket, :error, limit_reached_words(node))

      true ->
        changeset = AccessKeys.change_new_key(%{"label" => fresh_label(node, keys)})
        assign_form(socket, fresh(changeset), :key)
    end
  end

  # The key made in this browser: the page Generate a key patches to, and what a reload
  # of it shows. Only for an active key of this node the reader made so, while they may
  # add keys; any other active key's address leads to its runner file, which shows the
  # same id to everyone who reads the node.
  defp apply_action(socket, :generated, %{"key_id" => key_id}) do
    %{current_scope: scope, may: may} = socket.assigns

    case Enum.find(socket.assigns.keys, &(&1.key_id == key_id)) do
      nil ->
        to_tab(socket, :error, gettext("This node has no such key."))

      %AccessKey{} = key ->
        cond do
          state(key) != :active ->
            to_tab(socket, :error, revoked_words(key))

          key.arrived_by == :browser and key.created_by_id == scope.user.id and may.add_key ->
            assign(socket, :key, key)

          true ->
            push_patch(socket, to: key_path(socket.assigns.paths, key, "runner-file"))
        end
    end
  end

  # The command's page, with the command just got (`create_code`). Opened any other way,
  # there is no command to show: it was shown once, so the reader is back on the tab,
  # where a command not yet run waits.
  defp apply_action(socket, :new_code, _params) do
    cond do
      not socket.assigns.may.new_code ->
        refused(socket, gettext("Only owners and admins connect a node."))

      socket.assigns.issued ->
        socket

      true ->
        socket |> load() |> push_patch(to: socket.assigns.paths.access_key)
    end
  end

  defp apply_action(socket, :revoke, %{"key_id" => key_id}) do
    key = Enum.find(socket.assigns.keys, &(&1.key_id == key_id))

    cond do
      not socket.assigns.may.revoke ->
        refused(socket, gettext("Only owners and admins manage a node's keys."))

      is_nil(key) ->
        to_tab(socket, :error, gettext("This node has no such key."))

      state(key) != :active ->
        to_tab(socket, :error, revoked_words(key))

      true ->
        assign(socket, :key, key)
    end
  end

  # A key's runner file, for anyone who reads the node: nothing on it is secret.
  defp apply_action(socket, :runner_file, %{"key_id" => key_id}) do
    case Enum.find(socket.assigns.keys, &(&1.key_id == key_id)) do
      nil ->
        to_tab(socket, :error, gettext("This node has no such key."))

      key ->
        if state(key) == :active,
          do: assign(socket, :key, key),
          else: to_tab(socket, :error, revoked_words(key))
    end
  end

  defp apply_action(socket, :revoke_code, %{"code_id" => code_id}) do
    code = Enum.find(socket.assigns.codes, &(&1.id == code_id))

    cond do
      not socket.assigns.may.revoke_code ->
        refused(socket, gettext("Only owners and admins manage a node's keys."))

      is_nil(code) ->
        to_tab(socket, :error, outstanding_no_more())

      true ->
        assign(socket, :code, code)
    end
  end

  @impl true
  # Generate a key's form, as it is typed: the key's name. No key exists yet, and the form
  # has no other field.
  def handle_event(
        "validate_generate",
        %{"key" => params},
        %{assigns: %{live_action: :generate, form: %{}}} = socket
      ) do
    changeset =
      params
      |> form_params()
      |> Map.take(["label"])
      |> AccessKeys.change_new_key()
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset, :key)}
  end

  # The key the browser made, by its public half: exactly the label and the public key,
  # each a string, the label holding no access key's secret. Anything else, a stored-secrets
  # flag among it, is refused before anything is stored, and logged by nothing here. The
  # reply carries the key id once it is added, which tells the hook to keep the secret for
  # the page it patches to; any other reply tells it to drop the secret.
  def handle_event(
        "generate_key",
        params,
        %{assigns: %{live_action: :generate, form: %{}, may: %{add_key: true}}} = socket
      ) do
    case generated_key_params(params) do
      {:ok, attrs} -> add_generated_key(socket, attrs)
      :error -> {:reply, %{}, to_tab(socket, :error, not_added_words())}
    end
  end

  # A key pushed without its page and its form open, or by one who may not add keys:
  # nothing is added, and the hook drops what it made.
  def handle_event("generate_key", _params, socket) do
    if socket.assigns.may.add_key,
      do: {:reply, %{}, to_tab(socket, :error, not_added_words())},
      else:
        {:reply, %{}, refused(socket, gettext("Only owners and admins manage a node's keys."))}
  end

  # Get the command: a code made at once, with the defaults (stored secrets not allowed,
  # no label hint), whatever the event carries, and its page opened with the command. Only
  # from the tab, from one who may make codes, while the node has room for a key.
  def handle_event(
        "create_code",
        _params,
        %{assigns: %{live_action: action, may: %{new_code: true}}} = socket
      )
      when action in @tab_actions do
    %{current_scope: scope, node: node, paths: paths} = socket.assigns

    if at_limit?(socket.assigns.keys) do
      {:noreply, to_tab(socket, :error, limit_reached_words(node))}
    else
      case AccessKeys.create_enrolment_code(scope, node, %{}) do
        {:ok, row, code} ->
          # The code as the machine sends it, in a function: shown by the command's page
          # once, and printed by nothing else.
          code = Enrolment.issued_code(code, Apiary.SigningKey.fingerprint())

          {:noreply,
           socket
           |> assign(issued: %{row: row, code: fn -> code end, arrived: nil}, carry: true)
           |> load()
           |> push_patch(to: paths.new_code)}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, to_tab(socket, :error, gettext("Nothing was changed. Try again."))}

        {:error, :not_found} ->
          {:noreply, not_found(socket)}

        {:error, :forbidden} ->
          {:noreply, refused(socket, gettext("Only owners and admins connect a node."))}
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
        {:noreply, to_tab(socket, :info, gettext("%{label} is revoked.", label: key.label))}

      {:error, :not_found} ->
        {:noreply, not_found(socket)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, gettext("Only owners and admins manage a node's keys."))}

      {:error, _not_saved} ->
        {:noreply, to_tab(socket, :error, gettext("Nothing was changed. Try again."))}
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

      {:error, :not_found} ->
        {:noreply, not_found(socket)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, gettext("Only owners and admins manage a node's keys."))}

      {:error, _not_saved} ->
        {:noreply, to_tab(socket, :error, gettext("Nothing was changed. Try again."))}
    end
  end

  # An act without its page or its confirmation open, or from one the page offers no
  # button: a second click of a button whose confirmation is gone, a command asked for on
  # a page that offers none, or an event the page never sent. One who may take the act is
  # shown the page again; one who may not is refused, and nothing is done.
  def handle_event(event, _params, socket) when is_map_key(@write_events, event) do
    act = Map.fetch!(@write_events, event)

    if socket.assigns.may[act],
      do: {:noreply, load(socket)},
      else: {:noreply, refused(socket, gettext("Only owners and admins manage a node's keys."))}
  end

  # A form's change with no form open: nothing to do.
  def handle_event("validate_generate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:nodes_touched, _workspace_id}, socket) do
    %{current_scope: scope, node: node} = socket.assigns

    case Nodes.get_node(scope, node.public_id) do
      %Node{} = current -> {:noreply, socket |> assign(:node, current) |> assign_activity()}
      nil -> {:noreply, gone(socket)}
    end
  end

  # A machine enrolled a key on this node: the keys and codes read again, under the
  # reader's own scope, and the command's page, if the key is the one its command brings,
  # turns to say the machine is connected. A confirmation of the code it used closes.
  def handle_info(
        {:key_enrolled, %{node_id: node_id}},
        %{assigns: %{node: %{id: node_id}}} = socket
      ),
      do: {:noreply, socket |> load() |> close_gone_confirmation()}

  # A code of this node was cancelled, here or on another page: the codes read again. The
  # command's page whose command it was leaves for the tab, saying it no longer works, and
  # a confirmation of it closes.
  def handle_info(
        {:code_cancelled, %{node_id: node_id, code_id: code_id}},
        %{assigns: %{node: %{id: node_id}}} = socket
      ) do
    case socket.assigns do
      %{live_action: :new_code, issued: %{row: %{id: ^code_id}, arrived: nil}} ->
        {:noreply, to_tab(socket, :error, outstanding_no_more())}

      _other ->
        {:noreply, socket |> load() |> close_gone_confirmation()}
    end
  end

  # A code expired (`schedule_expiry/1`): the codes read again, and a confirmation of the
  # code that expired closed, since there is nothing left to cancel. The timer the page
  # holds stays for `load/1` to cancel: a read in between may have set another while this
  # one's message waited.
  def handle_info(:codes_expire, socket),
    do: {:noreply, socket |> load() |> close_gone_confirmation()}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The confirmation of a code no longer outstanding (run, cancelled or expired) closes:
  # there is nothing left to cancel, and the reader is told so on the tab.
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

  ## A key made in a browser

  # The event's parameters as the hook sends them, and nothing else: one key, `key`, a map
  # of exactly `label` and `public_key`, each a string. The label holds no `qak_` in any
  # case (the runner's rule for a value that holds a secret). The public key is not read
  # for it: a random one holds `qak_` now and then, and its decoding
  # (`Apiary.Contract.Ed25519.decode_public_key/1`, in the key checks) takes 43 characters
  # of base64url alone, which a secret, `qak_` and 43 more, never is. No stored-secrets
  # flag is taken: there is no choice, and every key is added with them not allowed.
  defp generated_key_params(%{"key" => %{} = key} = params) when map_size(params) == 1 do
    fields = ~w(label public_key)

    if key |> Map.keys() |> Enum.sort() == fields and
         Enum.all?(key, fn {_name, value} -> is_binary(value) end) and
         not holds_secret?(key["label"]),
       do: {:ok, key |> Map.take(fields) |> Map.put("allow_secrets", "false")},
       else: :error
  end

  defp generated_key_params(_params), do: :error

  defp holds_secret?(value), do: value |> String.downcase() |> String.contains?("qak_")

  defp add_generated_key(socket, attrs) do
    %{current_scope: scope, node: node} = socket.assigns

    case AccessKeys.add_access_key(scope, node, attrs) do
      {:ok, key} ->
        {:reply, %{key_id: key.key_id},
         socket
         |> load()
         |> push_patch(to: key_path(socket.assigns.paths, key, "generated"))}

      # A public key refused by the checks or the ledger is none the browser made.
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :public_key),
          do: {:reply, %{}, to_tab(socket, :error, not_added_words())},
          else: {:reply, %{}, assign_form(socket, %{changeset | action: :insert}, :key)}

      {:error, :key_limit} ->
        {:reply, %{}, to_tab(socket, :error, limit_reached_words(node))}

      {:error, :not_found} ->
        {:reply, %{}, not_found(socket)}

      {:error, :forbidden} ->
        {:reply, %{}, refused(socket, gettext("Only owners and admins add a node's keys."))}
    end
  end

  # The name a new key's form starts from: the node's, or the node's with `-2`, `-3` and
  # on, the first no key of the node in use has, as an enrolment names a key.
  defp fresh_label(%Node{name: name}, keys) do
    taken = for key <- keys, state(key) == :active, into: MapSet.new(), do: key.label

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> name
      n -> "#{name}-#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp at_limit?(keys),
    do: Enum.count(keys, &(state(&1) == :active)) >= AccessKeys.key_limit()

  ## Answers

  # Back to the tab, with a flash, the keys and codes read again.
  defp to_tab(socket, kind, words) do
    socket
    |> put_flash(kind, words)
    |> load()
    |> push_patch(to: socket.assigns.paths.access_key)
  end

  # What the act named is not there for it: the key or the command, or the node itself,
  # or the workspace's, now. A node the reader still reads says so on the tab; one gone
  # sends them to the list.
  defp not_found(socket) do
    %{current_scope: scope, node: node} = socket.assigns

    if Nodes.get_node(scope, node.public_id),
      do:
        to_tab(
          socket,
          :error,
          gettext("That key or code is gone: this node's keys changed meanwhile.")
        ),
      else: gone(socket)
  end

  # The node was deleted, or left the reader's reach, since the page opened.
  defp gone(socket) do
    %{organisation: organisation, workspace: workspace} = socket.assigns.current_scope

    socket
    |> put_flash(:error, gettext("This node is gone: it was deleted."))
    |> push_navigate(to: ~p"/#{organisation}/#{workspace}/nodes")
  end

  # An act the reader may not take, as the database has their membership now: one who
  # still reads the workspace is told why on the tab, and offered no act from then on;
  # one who reads the organisation through the edition's reach is told so; anyone else is
  # sent to `/`.
  defp refused(socket, why) do
    scope = Access.reload(socket.assigns.current_scope)

    cond do
      Access.reader(scope) ->
        socket
        |> assign(may: Map.new(@acts, fn {act, _} -> {act, false} end), manages: false)
        |> put_flash(:error, ApiaryWeb.Access.reads_only(scope))
        |> push_patch(to: socket.assigns.paths.access_key)

      Access.can?(scope, :"node.read", scope.workspace) ->
        socket
        |> assign(may: Map.new(@acts, fn {act, _} -> {act, false} end), manages: false)
        |> put_flash(:error, why)
        |> push_patch(to: socket.assigns.paths.access_key)

      true ->
        socket
        |> put_flash(:error, gettext("You are no longer a member of this workspace."))
        |> redirect(to: ~p"/")
    end
  end

  ## Forms

  defp assign_form(socket, changeset, as), do: assign(socket, :form, to_form(changeset, as: as))

  # A form as its page opens: nothing is typed yet, so nothing is wrong yet.
  defp fresh(%Ecto.Changeset{} = changeset), do: %{changeset | errors: [], valid?: true}

  # A form's parameters as a form sends them, each a string: anything else, which only a
  # crafted event sends, is not there, and a form that is no map is an empty one.
  defp form_params(%{} = params),
    do:
      for(
        {name, value} <- params,
        is_binary(name) and is_binary(value),
        into: %{},
        do: {name, value}
      )

  defp form_params(_params), do: %{}

  ## Words and paths

  defp paths(%{organisation: organisation, workspace: workspace}, public_id) do
    base = ~p"/#{organisation}/#{workspace}/nodes/#{public_id}"

    %{
      overview: base,
      access_key: base <> "/access-key",
      settings: base <> "/settings",
      generate: base <> "/access-key/generate",
      new_code: base <> "/access-key/new-code"
    }
  end

  defp key_path(paths, key, act), do: "#{paths.access_key}/keys/#{key.key_id}/#{act}"
  defp code_path(paths, code), do: "#{paths.access_key}/codes/#{code.id}/revoke"

  # The window's title: the page's, then the node's name where the page's does not say it.
  defp titled(%{assigns: %{node: node} = assigns} = socket) do
    title =
      case assigns do
        %{live_action: :new_code, issued: %{}} ->
          command_title(node)

        %{live_action: :generate, form: %{}} ->
          gettext("Generate a key") <> " · " <> node.name

        %{live_action: :generated, key: %AccessKey{}} ->
          values_title(node)

        %{live_action: :runner_file, key: %AccessKey{} = key} ->
          runner_file_title(key) <> " · " <> node.name

        _tab ->
          gettext("Access key") <> " · " <> node.name
      end

    assign(socket, :page_title, title)
  end

  defp command_title(node), do: gettext("Connect %{name} with a command", name: node.name)

  defp values_title(node), do: gettext("Key for %{name}", name: node.name)

  defp runner_file_title(key), do: gettext("Runner file for %{label}", label: key.label)

  defp revoked_words(key), do: gettext("%{label} is revoked.", label: key.label)

  defp limit_reached_words(node),
    do:
      gettext("%{name} holds two keys already. Revoke one before you add another.",
        name: node.name
      )

  defp not_added_words, do: gettext("The key wasn't added. Try again.")

  defp outstanding_no_more,
    do: gettext("That command no longer works: it was run, cancelled or expired.")

  # The acts a key's card offers the reader: revoking an active one.
  defp key_acts(%AccessKey{} = key, may),
    do: if(state(key) == :active and may.revoke, do: [:revoke], else: [])

  # A key is active from the moment it arrives, until it is revoked.
  defp state(%AccessKey{revoked_at: nil}), do: :active
  defp state(%AccessKey{}), do: :revoked

  defp state_words(:active), do: gettext("Active")
  defp state_words(:revoked), do: gettext("Revoked")

  defp secrets_words(true), do: gettext("Allowed")
  defp secrets_words(_false), do: gettext("Not allowed")

  defp when_words(person, at) do
    if person,
      do:
        gettext("by %{person}, %{date}", person: People.email(person), date: Format.datetime(at)),
      else: Format.datetime(at)
  end

  defp person_words(person), do: People.email(person) || People.former_member()

  defp added_words(%AccessKey{arrived_by: :code} = key),
    do:
      gettext("Connected with a command by %{person}, %{date}",
        person: person_words(key.created_by),
        date: Format.datetime(key.received_at)
      )

  defp added_words(%AccessKey{arrived_by: :browser} = key),
    do:
      gettext("Generated in a browser by %{person}, %{date}",
        person: person_words(key.created_by),
        date: Format.datetime(key.received_at)
      )

  defp secret_words(%AccessKey{arrived_by: :code}, node),
    do: gettext("On %{name}, saved there by the command", name: node.name)

  defp secret_words(%AccessKey{arrived_by: :browser}, _node),
    do:
      gettext(
        "Shown once when it was generated; kept where you put it, such as your CI's secret store"
      )

  # The state of the command shown: waiting to be run, the machine connected with it, or
  # no longer working (expired or cancelled before any key came).
  defp command_state(%{arrived: %AccessKey{}}, _codes), do: :connected

  defp command_state(%{row: %EnrolmentCode{id: id}}, codes),
    do: if(Enum.any?(codes, &(&1.id == id)), do: :waiting, else: :spent)

  ## The server's part
  #
  # The server's address and its public key, `QORY_APIARY_PUBLIC_KEY`, the instance's own
  # signing key (`Apiary.SigningKey`): the same for every machine connected to this Qory
  # Apiary, never part of a node's key, and said so wherever they show (`same_note/0`).

  defp same_note, do: gettext("The same for every machine connected to this Qory Apiary.")

  # A command key's runner file: which of its lines are the key's, which the server's.
  defp parts_note do
    gettext(
      "Only the key ID is this key's. The address and the public key are Qory Apiary's, the same for every machine connected to it."
    )
  end

  defp server_variable, do: AccessKeys.server_variable()

  defp server_lines, do: AccessKeys.server_lines(ApiaryWeb.Endpoint.url())

  # The runner file's two lines a machine needs beside its key's own variables: the
  # address alone.
  defp address_file, do: "server:\n" <> server_lines().url <> "\n"

  # A key connected with a command: the runner file's `server` section as the command
  # wrote it, each line marked as the server's or the key's.
  defp command_file(key) do
    %{url: url, public_key: [pin_head | pins]} = server_lines()

    marked = [
      {url, "# Qory Apiary"},
      {AccessKeys.key_line(key), "# this key"},
      {pin_head, "# Qory Apiary's public key"}
    ]

    width = marked |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max()

    lines =
      Enum.map(marked, fn {line, mark} -> String.pad_trailing(line, width + 2) <> mark end)

    Enum.join(["server:" | lines] ++ pins, "\n") <> "\n"
  end

  defp variable_line({name, value}), do: "#{name}=#{value}\n"

  ## Ways

  # The ways to connect the node the reader may take, the kind's own first: a node is one
  # machine of its own, best connected with a command, which keeps the secret on it; a pool
  # is a fleet, typically a CI, whose secret goes into a secret store anyway.
  defp ways(%Node{kind: kind}, may) do
    order =
      if kind == :pool,
        do: [:generate, :new_code],
        else: [:new_code, :generate]

    Enum.filter(order, fn
      :new_code -> may.new_code
      :generate -> may.add_key
    end)
  end

  defp way_icon(:new_code), do: "hero-command-line"
  defp way_icon(:generate), do: "hero-key"

  defp way_title(:new_code), do: gettext("Connect with a command")
  defp way_title(:generate), do: gettext("Generate a key in the browser")

  # When to choose a way: first on its card and its row, since it is the goal.
  defp way_when(:new_code, node),
    do:
      gettext(
        "Choose it when you can open a terminal on %{name}: a laptop, or a server of your own.",
        name: node.name
      )

  defp way_when(:generate, node),
    do:
      gettext(
        "Choose it when %{name} runs in a CI job, or on a machine you can't open a terminal on.",
        name: node.name
      )

  # What happens, in two sentences.
  defp way_happens(:new_code, node),
    do: [
      gettext(
        "You get one command to run on %{name}. It carries a one-time code, not a key, which works once within 15 minutes.",
        name: node.name
      ),
      gettext(
        "qory makes the key on %{name}, sends Qory Apiary only its public half, and saves everything else there itself.",
        name: node.name
      )
    ]

  defp way_happens(:generate, node),
    do: [
      gettext("This browser makes the key, and Qory Apiary receives only its public half."),
      gettext(
        "The next page shows the secret once, with everything else the machine needs, for you to set where %{name} runs.",
        name: node.name
      )
    ]

  # The same four facts for each way, in the same rows, so the two compare row by row.
  defp way_facts(:new_code, node),
    do: [
      {gettext("Key made"), gettext("On %{name}, by qory", name: node.name)},
      {gettext("Secret"), gettext("Stays on %{name}; it is never shown", name: node.name)},
      {gettext("By hand"), gettext("Nothing")},
      {gettext("Needs"), gettext("A terminal on %{name}", name: node.name)}
    ]

  defp way_facts(:generate, _node),
    do: [
      {gettext("Key made"), gettext("In this browser")},
      {gettext("Secret"),
       gettext("Shown to you once, for the machine's or the CI's secret store")},
      {gettext("By hand"),
       gettext("The key's ID, its secret, Qory Apiary's public key and address")},
      {gettext("Needs"), gettext("This page open over HTTPS")}
    ]

  defp way_button(:new_code, []), do: gettext("Get the command")
  defp way_button(:new_code, _waiting), do: gettext("Get a new command")
  defp way_button(:generate, _waiting), do: gettext("Generate a key")

  defp nodes_path(paths), do: String.replace(paths.overview, ~r{/[^/]+$}, "")

  ## Render

  @impl true
  # The command just got: shown once, on its own page, until the machine runs it.
  def render(%{live_action: :new_code, issued: %{}} = assigns) do
    assigns =
      assign(assigns,
        server: ApiaryWeb.Endpoint.url(),
        state: command_state(assigns.issued, assigns.codes)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:nodes}
      place={:workspace}
      width="read"
    >
      <:crumb navigate={nodes_path(@paths)}>{gettext("Nodes")}</:crumb>
      <:crumb navigate={@paths.overview}>{@node.name}</:crumb>
      <:crumb navigate={@paths.access_key}>{gettext("Access key")}</:crumb>
      <:crumb>{gettext("Command")}</:crumb>

      <section id="code-issued" class="q-form-page" aria-labelledby="code-issued-header-title">
        <.page_header id="code-issued-header" title={command_title(@node)}>
          <:description>
            {gettext(
              "The command connects %{name} by itself: it makes the machine's key there, saves it, and writes Qory Apiary's address and public key into the runner file. The secret never leaves the machine.",
              name: @node.name
            )}
          </:description>
        </.page_header>

        <div class="grid gap-4">
          <%!-- What changes as the machine runs the command, said as it changes. --%>
          <div id="code-issued-state" class="grid gap-4" aria-live="polite">
            <%= case @state do %>
              <% :waiting -> %>
                <NodeComponents.unreachable_server id="code-issued-unreachable" url={@server} />
                <div class="grid gap-1.5">
                  <p id="code-issued-run" class="text-[13px]/5">
                    {gettext("On %{name}, run:", name: @node.name)}
                  </p>
                  <%!-- The command takes the focus as it shows, read with what it is for. --%>
                  <div tabindex="-1" phx-mounted={JS.focus(to: "#code-issued-command")}>
                    <.code_block
                      id="code-issued-command"
                      code={NodeComponents.enrol_command(@server, @issued.code.())}
                      copy_label={gettext("Copy command")}
                      wrap
                    />
                  </div>
                </div>
                <.listening id="code-issued-waiting">
                  {gettext("Waiting for %{name} to run it. This page shows when it is connected.",
                    name: @node.name
                  )}
                </.listening>
                <p id="code-issued-works" class="text-[13px]/5 text-muted">
                  {gettext(
                    "It works once, until %{time}, %{minutes} minutes from when you got it. This is the only time it is shown.",
                    time: Format.time(@issued.row.expires_at),
                    minutes: Format.number(AccessKeys.code_ttl_minutes())
                  )}
                </p>
              <% :connected -> %>
                <div id="code-issued-connected">
                  <.notice kind={:success}>
                    <strong>{gettext("%{name} is connected.", name: @node.name)}</strong>
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
                    "qory printed a fingerprint on %{name} when it ran the command. If it isn't this one, revoke the key on the Access key tab.",
                    name: @node.name
                  )}
                </p>
              <% :spent -> %>
                <div id="code-issued-spent">
                  <.notice kind={:warning}>{outstanding_no_more()}</.notice>
                </div>
            <% end %>
          </div>

          <%!-- Done alone: leaving cancels nothing, the code is made. --%>
          <SettingsComponents.save id="code-issued-done">
            <.button id="code-issued-done-button" variant="primary" patch={@paths.access_key}>
              {gettext("Done")}
            </.button>
            <:note :if={@state == :waiting}>
              {gettext(
                "Once you leave this page, the command is not shown again. Cancel it from the Access key tab if you won't run it."
              )}
            </:note>
          </SettingsComponents.save>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # Generate a key, then the key it made: one clause, so the hook's section
  # (`#key-generate`) is the same element across the patch from the form to the key, and
  # carries the secret, which only the browser has, into its slot.
  def render(%{live_action: action, form: form, key: key} = assigns)
      when (action == :generate and is_map(form)) or
             (action == :generated and is_struct(key, AccessKey)) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:nodes}
      place={:workspace}
      width="read"
    >
      <:crumb navigate={nodes_path(@paths)}>{gettext("Nodes")}</:crumb>
      <:crumb navigate={@paths.overview}>{@node.name}</:crumb>
      <:crumb navigate={@paths.access_key}>{gettext("Access key")}</:crumb>
      <:crumb :if={@live_action == :generate}>{gettext("Generate a key")}</:crumb>
      <:crumb :if={@live_action == :generated}>{@key.label}</:crumb>

      <section
        id="key-generate"
        phx-hook="GenerateKey"
        class="q-form-page"
        aria-labelledby={
          if @live_action == :generate,
            do: "key-generate-header-title",
            else: "key-generated-header-title"
        }
      >
        <.page_header
          :if={@live_action == :generate}
          id="key-generate-header"
          title={gettext("Generate a key for %{name}", name: @node.name)}
        >
          <:description>
            {if @node.kind == :pool,
              do:
                gettext(
                  "This browser makes a key for %{name}. You see its secret once, to copy into your CI's secret store, or the settings of whatever runs the instances; Qory Apiary receives only the public half. The key's ID stays on the Access key tab.",
                  name: @node.name
                ),
              else:
                pgettext(
                  "plain",
                  "This browser makes a key for %{name}. You see its secret once, to copy into your CI's secret store, or the settings of the system that runs it; Qory Apiary receives only the public half. The key's ID stays on the Access key tab.",
                  name: @node.name
                )}
          </:description>
        </.page_header>
        <.page_header
          :if={@live_action == :generated}
          id="key-generated-header"
          title={values_title(@node)}
        >
          <:description>
            {gettext("Do these where %{name} runs. Only the secret can't be seen again.",
              name: @node.name
            )}
          </:description>
        </.page_header>

        <div class="q-form-page-body text-[13px]/5">
          <%!-- Shown by the hook alone, which says why no key can be made here, or that
               one was lost on its way: hidden by the class, which the hook's show
               overrides. --%>
          <div id="key-generate-notices" phx-update="ignore" class="contents">
            <div id="key-generate-insecure" class="hidden">
              <.notice kind={:warning}>
                {gettext(
                  "This browser makes keys only on a page served over HTTPS. Open Qory Apiary over HTTPS, or connect the machine with a command."
                )}
              </.notice>
            </div>
            <div id="key-generate-unsupported" class="hidden">
              <.notice kind={:warning}>
                {gettext(
                  "This browser can't make an Ed25519 key. Use a current Chrome, Edge, Firefox or Safari, or connect the machine with a command."
                )}
              </.notice>
            </div>
            <div id="key-generate-lost" class="hidden">
              <.notice kind={:error}>
                {gettext(
                  "The connection to Qory Apiary dropped before the key was confirmed, and its secret is gone. If a new key shows on the Access key tab, revoke it, then generate another."
                )}
              </.notice>
            </div>
          </div>

          <%!-- No `phx-submit`: the hook takes the submit, makes the key and sends its
               public half alone. The action is the page's own address, so a form whose
               hook did not start posts its name to the console alone, and never puts it
               in an address. --%>
          <.form
            :if={@live_action == :generate}
            for={@form}
            id="key-generate-form"
            action={@paths.generate}
            phx-change="validate_generate"
            class="grid gap-4"
            novalidate
          >
            <.input
              field={@form[:label]}
              type="text"
              label={gettext("Name of the key")}
              hint={gettext("Shown on the Access key tab, so you can tell its keys apart.")}
              autocomplete="off"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <.page_form_foot id="key-generate-save" cancel={@paths.access_key} cancel_by="patch">
              <.button
                id="key-generate-submit"
                variant="primary"
                type="submit"
                loading_text={gettext("Generating")}
              >
                {gettext("Generate key")}
              </.button>
            </.page_form_foot>
          </.form>

          <%!-- What says the secret is shown once (this notice, the secret's Copy, the note
               beside Done) comes hidden, `data-secret-shown`: the hook shows it while the
               slot shows the secret it wrote, and the slot's gone line while it holds
               nothing for this key. The server's render is the same whether the page made
               the key, was opened again, or joined again after a dropped connection. --%>
          <div
            :if={@live_action == :generated}
            id="key-generated-once"
            data-secret-shown
            class="hidden"
          >
            <.notice kind={:warning}>
              <strong>{gettext("The secret is shown once.")}</strong>
              {gettext(
                "Copy QORY_ACCESS_KEY_SECRET now: it was made in this browser, Qory Apiary never received it, and it can't be shown again."
              )}
            </.notice>
          </div>

          <.how_to :if={@live_action == :generated} id="key-generated-steps">
            <:step title={gettext("Store the secret.")}>
              <p class="text-muted">
                {pgettext(
                  "plain",
                  "In the secret store of the system that runs %{name}, such as your CI's.",
                  name: @node.name
                )}
              </p>
              <dl class="grid gap-3">
                <div class="grid gap-1">
                  <dt class="flex flex-wrap items-center gap-2">
                    <span class="q-mono">QORY_ACCESS_KEY_SECRET</span>
                    <.value_tag secret>{gettext("secret · shown once")}</.value_tag>
                  </dt>
                  <dd class="flex items-center gap-2">
                    <%!-- The secret's slot: never patched or read by LiveView, empty from the
                         server. The hook writes the secret it holds into the value, as text,
                         only if this public key, the one the server stored, is its own. Its
                         ids are the key's: a patch to another key's page (a history jump
                         between two of them) replaces the slot, and so takes the other key's
                         secret, and its gone line, out of the page. Opened again, the gone
                         line shows from the server. --%>
                    <div
                      id={"key-generated-secret-#{@key.key_id}"}
                      phx-update="ignore"
                      data-secret-slot
                      data-public-key={Base.url_encode64(@key.public_key, padding: false)}
                      class="grid min-w-0 flex-1 gap-1"
                    >
                      <code
                        id={"key-generated-secret-#{@key.key_id}-value"}
                        data-secret-value
                        tabindex="-1"
                        class="block min-h-7 min-w-0 select-all break-all rounded-field border border-line bg-code px-2.5 py-1 font-mono text-[12.5px]/5 empty:hidden"
                      ></code>
                      <p
                        id={"key-generated-secret-#{@key.key_id}-gone"}
                        data-secret-gone
                        class="hidden text-muted"
                      >
                        {gettext(
                          "Not shown: only the page that made the key held its secret, and this one was opened again. If you didn't copy it, revoke %{label} and generate another key.",
                          label: @key.label
                        )}
                      </p>
                    </div>
                    <span
                      id="key-generated-secret-copy-shown"
                      data-secret-shown
                      class="hidden flex-none"
                    >
                      <.copy_button
                        id="key-generated-secret-copy"
                        target={"#key-generated-secret-#{@key.key_id}-value"}
                        label={gettext("Copy %{name}", name: "QORY_ACCESS_KEY_SECRET")}
                        placement="left"
                        icon_only
                      />
                    </span>
                  </dd>
                </div>
              </dl>
            </:step>
            <:step title={gettext("Set the key's ID.")}>
              <p class="text-muted">
                {gettext("As a plain setting. It stays on the Access key tab.")}
              </p>
              <dl class="grid gap-3">
                <.value_row
                  id="key-generated-id"
                  name="QORY_ACCESS_KEY_ID"
                  value={@key.key_id}
                />
              </dl>
            </:step>
            <:step title={gettext("Set Qory Apiary's public key.")}>
              <p class="text-muted">
                {gettext("As a plain setting.")} {same_note()} {gettext(
                  "It stays on the Access key tab."
                )}
              </p>
              <dl class="grid gap-3">
                <.value_row
                  id="key-generated-pin"
                  name={elem(server_variable(), 0)}
                  value={elem(server_variable(), 1)}
                />
              </dl>
            </:step>
            <:step title={gettext("Point qory at Qory Apiary.")}>
              <p class="text-muted">
                {gettext(
                  "In the runner file. It is required: without it, qory ignores the three variables."
                )}
              </p>
              <.code_block
                id="key-generated-yaml"
                label="runner.yaml"
                code={address_file()}
                copy_label={gettext("Copy lines")}
              />
            </:step>
          </.how_to>

          <%!-- Done alone: leaving cancels nothing, the key is added. --%>
          <SettingsComponents.save :if={@live_action == :generated} id="key-generated-done">
            <.button id="key-generated-done-button" variant="primary" patch={@paths.access_key}>
              {gettext("Done")}
            </.button>
            <:note>
              <span id="key-generated-done-note" data-secret-shown class="hidden">
                {gettext("Once you leave this page, the secret is not shown again.")}
              </span>
            </:note>
          </SettingsComponents.save>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # A key's runner file: what the machine holding it is given, nothing of it secret, as
  # the key came.
  def render(%{live_action: :runner_file, key: %AccessKey{}} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:nodes}
      place={:workspace}
      width="read"
    >
      <:crumb navigate={nodes_path(@paths)}>{gettext("Nodes")}</:crumb>
      <:crumb navigate={@paths.overview}>{@node.name}</:crumb>
      <:crumb navigate={@paths.access_key}>{gettext("Access key")}</:crumb>
      <:crumb>{@key.label}</:crumb>

      <section
        id="key-runner-file"
        class="q-form-page"
        aria-labelledby="key-runner-file-header-title"
        phx-mounted={JS.focus(to: "#key-runner-file-header-title")}
      >
        <.page_header id="key-runner-file-header" title={runner_file_title(@key)}>
          <:description>
            {if @key.arrived_by == :code,
              do: gettext("The runner file's lines for this key. Nothing here is secret."),
              else:
                gettext("What %{name} needs, besides the secret. Nothing here is secret.",
                  name: @node.name
                )}
          </:description>
        </.page_header>

        <div class="grid gap-6 text-[13px]/5">
          <%= if @key.arrived_by == :code do %>
            <div class="grid gap-1.5">
              <p>
                <.rich text={
                  rich_gettext(
                    "The command wrote these lines to %{file} on %{name} when it connected. They are here to check, or to write the file again:",
                    file: {:m, "~/.config/qory/runner.yaml"},
                    name: @node.name
                  )
                } />
              </p>
              <.code_block
                id="key-runner-file-yaml"
                label="runner.yaml"
                code={command_file(@key)}
                copy_label={gettext("Copy lines")}
              />
            </div>
            <p id="key-runner-file-parts" class="text-muted">{parts_note()}</p>
            <p id="key-runner-file-secret" class="text-muted">
              <.rich text={
                rich_gettext(
                  "The key's secret is on %{name}, in %{file}, where the command saved it. It has never been on a screen.",
                  name: @node.name,
                  file: {:m, "~/.config/qory/access-key-secret"}
                )
              } />
            </p>
          <% else %>
            <.how_to id="key-runner-file-steps">
              <:step title={gettext("Keep the secret in a secret store.")}>
                <p id="key-runner-file-secret" class="text-muted">
                  <.rich text={
                    rich_pgettext(
                      "plain",
                      "It was shown once, when the key was generated, and belongs in %{variable} in the secret store of the system that runs qory. If it is lost, generate a new key and revoke this one.",
                      variable: {:m, "QORY_ACCESS_KEY_SECRET"}
                    )
                  } />
                </p>
              </:step>
              <:step title={gettext("Set the key's ID.")}>
                <p class="text-muted">{gettext("As a plain setting.")}</p>
                <.code_block
                  id="key-runner-file-key-env"
                  code={variable_line(AccessKeys.key_variable(@key))}
                  copy_label={gettext("Copy variable")}
                  wrap
                />
              </:step>
              <:step title={gettext("Set Qory Apiary's public key.")}>
                <p class="text-muted">{gettext("As a plain setting.")}</p>
                <.code_block
                  id="key-runner-file-server-env"
                  code={variable_line(server_variable())}
                  copy_label={gettext("Copy variable")}
                  wrap
                />
                <p id="key-runner-file-belongs" class="text-muted">{same_note()}</p>
              </:step>
              <:step title={gettext("Point qory at Qory Apiary.")}>
                <.code_block
                  id="key-runner-file-url"
                  label="runner.yaml"
                  code={address_file()}
                  copy_label={gettext("Copy lines")}
                />
              </:step>
            </.how_to>
          <% end %>

          <SettingsComponents.save id="key-runner-file-done">
            <.button id="key-runner-file-done-button" variant="primary" patch={@paths.access_key}>
              {gettext("Done")}
            </.button>
          </SettingsComponents.save>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # The tab.
  def render(assigns) do
    active = Enum.count(assigns.keys, &(state(&1) == :active))

    assigns =
      assign(assigns,
        ways: ways(assigns.node, assigns.may),
        active: active,
        full: active >= AccessKeys.key_limit()
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:nodes}
      place={:workspace}
    >
      <:crumb navigate={nodes_path(@paths)}>{gettext("Nodes")}</:crumb>
      <:crumb navigate={@paths.overview}>{@node.name}</:crumb>

      <NodeComponents.node_header node={@node} activity={@activity} />
      <NodeComponents.node_tabs node={@node} paths={@paths} current={:access_key} view={:access_key} />

      <div id="node-access-key" class="grid max-w-[72rem] gap-8">
        <%!-- No key in use: the question, and the ways as cards, the kind's own first and
             primary. --%>
        <SettingsComponents.part
          :if={@active == 0 and @ways != []}
          id="node-connect"
          title={gettext("How do you want to connect %{name}?", name: @node.name)}
          level={:h2}
        >
          <p id="node-connect-intro" class="text-[13px]/5 text-muted">
            {if @node.kind == :pool,
              do:
                gettext(
                  "%{name} needs a key before it can start runs; its instances share one. Choose one of two ways to give it one.",
                  name: @node.name
                ),
              else:
                gettext(
                  "%{name} needs a key before it can start runs. Choose one of two ways to give it one.",
                  name: @node.name
                )}
          </p>
          <div
            id="node-ways"
            class={["grid items-stretch gap-3", length(@ways) > 1 && "md:grid-cols-2"]}
          >
            <.way_card
              :for={{way, index} <- Enum.with_index(@ways)}
              way={way}
              primary={index == 0}
              node={@node}
              codes={@codes}
              code={@code}
              may={@may}
              paths={@paths}
            />
          </div>
        </SettingsComponents.part>

        <SettingsComponents.part
          :if={@active == 0 and @ways == []}
          id="node-connect"
          title={gettext("Connect %{name}", name: @node.name)}
          level={:h2}
        >
          <p id="node-keys-members" class="text-[13px]/5 text-muted">
            {gettext("%{name} has no key yet, so it can't start runs. An owner or admin connects it.",
              name: @node.name
            )}
          </p>
        </SettingsComponents.part>

        <SettingsComponents.part
          :if={@keys != []}
          id="node-keys"
          title={gettext("Keys")}
          count={length(@keys)}
          level={:h2}
        >
          <p id="node-keys-intro" class="text-[13px]/5 text-muted">
            {if @node.kind == :pool,
              do:
                gettext(
                  "The instances of %{name} sign every request with the pool's key. Qory Apiary keeps only the public half.",
                  name: @node.name
                ),
              else:
                gettext(
                  "%{name} signs every request with its key. Qory Apiary keeps only the public half.",
                  name: @node.name
                )}
          </p>
          <p
            :if={!@manages and @active > 0}
            id="node-keys-members"
            class="text-[13px]/5 text-muted"
          >
            {gettext("Only owners and admins manage a node's keys.")}
          </p>
          <ul id="node-keys-list" class="grid gap-3">
            <.key_card
              :for={key <- @keys}
              key={key}
              node={@node}
              scope={@current_scope}
              paths={@paths}
              may={@may}
              intact={@intact[key.id]}
              last_run={@last_runs[key.id]}
              hosts={@hosts[key.id]}
              confirming={@key && @key.id == key.id && @live_action}
            />
          </ul>
        </SettingsComponents.part>

        <%!-- A key in use: the same ways, as rows, for moving to a new key; at the limit,
             the line that says to revoke one first, and a command still waiting. --%>
        <SettingsComponents.part
          :if={@active > 0 and @ways != []}
          id="node-add"
          title={gettext("Add a key")}
          level={:h2}
        >
          <p :if={@full} id="node-add-full" class="text-[13px]/5 text-muted">
            {if @node.kind == :pool,
              do:
                gettext(
                  "%{name} holds two keys, the most a node pool can. Revoke the one it no longer uses to add another.",
                  name: @node.name
                ),
              else:
                gettext(
                  "%{name} holds two keys, the most a node can. Revoke the one it no longer uses to add another.",
                  name: @node.name
                )}
          </p>
          <%!-- At the limit, no way is offered, but a command still waiting stays, with
               its Cancel the command…: it can still be run, so it can still be
               cancelled. --%>
          <.waiting
            :if={@full}
            codes={@codes}
            code={@code}
            node={@node}
            may={@may}
            paths={@paths}
          />
          <p :if={!@full} id="node-add-intro" class="text-[13px]/5 text-muted">
            {if @node.kind == :pool,
              do:
                gettext(
                  "To move %{name} to a new key, add it the same way as the first, or the other way, then revoke the old one once the new one is in use. A node pool holds two keys at most.",
                  name: @node.name
                ),
              else:
                gettext(
                  "To move %{name} to a new key, add it the same way as the first, or the other way, then revoke the old one once the new one is in use. A node holds two keys at most.",
                  name: @node.name
                )}
          </p>
          <div
            :if={!@full}
            id="node-ways"
            class="grid rounded-box border border-line bg-base-100 text-[13px]/5 shadow-xs"
          >
            <.way_row
              :for={{way, index} <- Enum.with_index(@ways)}
              way={way}
              first={index == 0}
              node={@node}
              codes={@codes}
              code={@code}
              may={@may}
              paths={@paths}
            />
          </div>
        </SettingsComponents.part>

        <%!-- Once the node holds a key: what a machine is configured with, for everyone,
             at the limit too; nothing in it is secret. --%>
        <.configure_part
          :if={@active > 0}
          id="node-configure"
          keys={Enum.filter(@keys, &(state(&1) == :active))}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :way, :atom, required: true
  attr :primary, :boolean, required: true
  attr :node, Node, required: true
  attr :codes, :list, required: true
  attr :code, :any, required: true, doc: "the code whose cancelling is being confirmed, or nil"
  attr :may, :map, required: true
  attr :paths, :map, required: true

  # A way to connect the node, as one of two equal options: when to choose it, what
  # happens, the same four facts as the other's, a command still waiting where it is the
  # command's, and its one button at the foot. No steps and nothing to copy: each way's
  # detail is on the page it opens.
  defp way_card(assigns) do
    ~H"""
    <div
      id={"way-#{@way}"}
      class="flex min-w-0 flex-col gap-3 rounded-box border border-line bg-base-100 p-4 text-[13px]/5 shadow-xs"
    >
      <div class="flex items-center gap-3">
        <span class="grid size-8 flex-none place-items-center rounded-field bg-base-200 text-muted">
          <.icon name={way_icon(@way)} class="size-4.5" />
        </span>
        <h3 id={"way-#{@way}-title"} class="text-[14px]/5 font-medium">{way_title(@way)}</h3>
      </div>
      <p id={"way-#{@way}-when"}>{way_when(@way, @node)}</p>
      <p id={"way-#{@way}-happens"} class="text-muted">
        {Enum.join(way_happens(@way, @node), " ")}
      </p>
      <dl
        id={"way-#{@way}-facts"}
        class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-1"
      >
        <%= for {label, value} <- way_facts(@way, @node) do %>
          <dt class="text-faint">{label}</dt>
          <dd class="min-w-0">{value}</dd>
        <% end %>
      </dl>
      <.waiting
        :if={@way == :new_code}
        codes={@codes}
        code={@code}
        node={@node}
        may={@may}
        paths={@paths}
      />
      <div class="mt-auto pt-1">
        <.way_button
          way={@way}
          primary={@primary}
          codes={@codes}
          paths={@paths}
          class="max-[479px]:w-full"
        />
      </div>
    </div>
    """
  end

  attr :way, :atom, required: true
  attr :first, :boolean, required: true
  attr :node, Node, required: true
  attr :codes, :list, required: true
  attr :code, :any, required: true
  attr :may, :map, required: true
  attr :paths, :map, required: true

  # A way to connect the node, as a compact row of Add a key.
  defp way_row(assigns) do
    ~H"""
    <div
      id={"way-#{@way}"}
      class={[
        "flex flex-wrap items-start gap-x-3 gap-y-2 px-4 py-3",
        !@first && "border-t border-line"
      ]}
    >
      <.icon name={way_icon(@way)} class="mt-0.5 size-4.5 flex-none text-muted" />
      <div class="grid min-w-0 flex-1 basis-64 gap-0.5">
        <h3 id={"way-#{@way}-title"} class="font-medium">{way_title(@way)}</h3>
        <p class="text-muted">{way_when(@way, @node)}</p>
        <.waiting
          :if={@way == :new_code}
          codes={@codes}
          code={@code}
          node={@node}
          may={@may}
          paths={@paths}
          class="mt-2"
        />
      </div>
      <.way_button
        way={@way}
        primary={false}
        codes={@codes}
        paths={@paths}
        class="flex-none max-[479px]:ml-7.5"
      />
    </div>
    """
  end

  attr :way, :atom, required: true
  attr :primary, :boolean, required: true
  attr :codes, :list, required: true
  attr :paths, :map, required: true
  attr :class, :any, default: nil

  # Get the command makes the code at once, an event; Generate a key opens its page.
  defp way_button(%{way: :new_code} = assigns) do
    ~H"""
    <.button
      id="code-new-button"
      phx-click="create_code"
      variant={if @primary, do: "primary", else: "default"}
      phx-hook="FocusOn"
      class={@class}
    >
      {way_button(@way, @codes)}
    </.button>
    """
  end

  defp way_button(%{way: :generate} = assigns) do
    ~H"""
    <.button
      id="key-generate-button"
      patch={@paths.generate}
      variant={if @primary, do: "primary", else: "default"}
      phx-hook="FocusOn"
      class={@class}
    >
      {way_button(@way, @codes)}
    </.button>
    """
  end

  attr :codes, :list, required: true
  attr :code, :any, required: true
  attr :node, Node, required: true
  attr :may, :map, required: true
  attr :paths, :map, required: true
  attr :class, :any, default: nil

  # The commands got and not yet run, neither cancelled nor expired: who got each and
  # when, until when it works, and Cancel the command…, confirmed in place.
  defp waiting(assigns) do
    ~H"""
    <div
      :for={code <- @codes}
      id={"code-#{code.id}"}
      class={["grid gap-2 rounded-field border border-line bg-base-200 p-3 text-[13px]/5", @class]}
    >
      <.listening>
        {gettext("A command is waiting to be run on %{name}.", name: @node.name)}
      </.listening>
      <p class="text-muted">
        {gettext(
          "%{person} got it at %{time}. It works once, until %{expires}. It was shown once: if it's lost, cancel it and get a new one.",
          person: person_words(code.created_by),
          time: Format.time(code.inserted_at),
          expires: Format.time(code.expires_at)
        )}
      </p>
      <%= if @code && @code.id == code.id do %>
        <.inline_confirm
          id={"code-#{code.id}-confirm"}
          question={gettext("Cancel the command from %{time}?", time: Format.time(code.inserted_at))}
          cancel={@paths.access_key}
          cancel_label={gettext("Keep it")}
        >
          {gettext("It stops working at once. A machine that runs it after this is refused.")}
          <:action>
            <.button
              id={"code-#{code.id}-confirm-button"}
              variant="danger"
              size="xs"
              phx-click="revoke_code"
              loading_text={gettext("Cancelling")}
            >
              {gettext("Yes, cancel it")}
            </.button>
          </:action>
        </.inline_confirm>
      <% else %>
        <p :if={@may.revoke_code}>
          <.button
            id={"code-#{code.id}-revoke"}
            variant="link"
            patch={code_path(@paths, code)}
            phx-hook="FocusOn"
          >
            <span aria-hidden="true">{gettext("Cancel the command…")}</span>
            <span class="sr-only">
              {gettext("Cancel the command from %{time}", time: Format.time(code.inserted_at))}
            </span>
          </.button>
        </p>
      <% end %>
    </div>
    """
  end

  attr :secret, :boolean, default: false
  slot :inner_block, required: true

  # What a value is to the system that runs qory: a plain setting, or a secret.
  defp value_tag(assigns) do
    ~H"""
    <span class={[
      "rounded-selector px-1.5 py-0.5 text-[11.5px]/4",
      if(@secret,
        do: "bg-primary-soft font-medium text-primary-soft-content",
        else: "bg-base-200 text-muted"
      )
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :class, :any, default: nil

  slot :step, required: true do
    attr :title, :string, required: true
  end

  # What to do, as numbered steps: each a short title, and what the step needs, its value
  # to copy inside it.
  defp how_to(assigns) do
    ~H"""
    <ol id={@id} class={["q-steps", @class]}>
      <li :for={{step, n} <- Enum.with_index(@step, 1)} id={"#{@id}-#{n}"}>
        <span class="q-step-disc" aria-hidden="true">{n}</span>
        <div class="grid min-w-0 gap-2">
          <p class="text-[13.5px]/6 font-medium">{step.title}</p>
          {render_slot(step)}
        </div>
      </li>
    </ol>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true

  # A plain setting: its name, tagged so, and its value with Copy.
  defp value_row(assigns) do
    ~H"""
    <div class="grid gap-1">
      <dt class="flex flex-wrap items-center gap-2">
        <span class="q-mono">{@name}</span>
        <.value_tag>{gettext("plain setting")}</.value_tag>
      </dt>
      <dd class="flex items-center gap-2">
        <code
          id={@id}
          class="block min-w-0 flex-1 select-all break-all rounded-field border border-line bg-code px-2.5 py-1 font-mono text-[12.5px]/5"
        >{@value}</code>
        <.copy_button
          id={"#{@id}-copy"}
          target={"##{@id}"}
          label={gettext("Copy %{name}", name: @name)}
          placement="left"
          icon_only
        />
      </dd>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :keys, :list, required: true, doc: "the node's active keys"

  # Configure a machine, once the node holds a key: what a machine with a generated key is
  # set with, as four steps, each value with Copy but the secret, which is never shown
  # here. The key's ID is given only while one key is active; with two, the step points
  # to the key's card.
  defp configure_part(assigns) do
    {name, pin} = server_variable()
    assigns = assign(assigns, pin: pin, pin_name: name)

    ~H"""
    <SettingsComponents.part id={@id} title={gettext("Configure a machine")} level={:h2}>
      <div class="grid max-w-[46rem] gap-4 text-[13px]/5">
        <div id={"#{@id}-lead"} class="grid gap-1 text-muted">
          <p>
            {gettext(
              "A machine connected with the command needs nothing more: qory saved all of this on it. Don't set these again there; qory refuses a key ID or a public key set twice."
            )}
          </p>
          <p>{gettext("With a generated key, set these where the machine runs qory.")}</p>
        </div>
        <.how_to id={"#{@id}-steps"}>
          <:step title={gettext("Point qory at Qory Apiary.")}>
            <p class="text-muted">
              {gettext(
                "In the runner file. It is required: without it, qory ignores the three variables below."
              )}
            </p>
            <.code_block
              id={"#{@id}-yaml"}
              label="runner.yaml"
              code={address_file()}
              copy_label={gettext("Copy lines")}
            />
          </:step>
          <:step title={gettext("Set Qory Apiary's public key.")}>
            <p class="text-muted">
              {gettext(
                "QORY_APIARY_PUBLIC_KEY, a plain setting. The same for every machine connected to this Qory Apiary."
              )}
            </p>
            <.value_field id={"#{@id}-pin"} name={@pin_name} value={@pin} />
          </:step>
          <:step title={gettext("Set the key's ID.")}>
            <%= case @keys do %>
              <% [key] -> %>
                <p class="text-muted">{gettext("QORY_ACCESS_KEY_ID, a plain setting.")}</p>
                <.value_field id={"#{@id}-key-id"} name="QORY_ACCESS_KEY_ID" value={key.key_id} />
              <% _keys -> %>
                <p id={"#{@id}-key-id-pointer"} class="text-muted">
                  {gettext(
                    "QORY_ACCESS_KEY_ID, a plain setting: the ID of the key the machine uses, on its card above."
                  )}
                </p>
            <% end %>
          </:step>
          <:step title={gettext("Keep the key's secret in a secret store.")}>
            <p class="text-muted">
              {gettext(
                "QORY_ACCESS_KEY_SECRET. It was shown once, when the key was generated, and is never shown here. If it is lost, generate a new key and revoke the old one."
              )}
            </p>
          </:step>
        </.how_to>
      </div>
    </SettingsComponents.part>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true

  # A value alone, with Copy: its name is said in the line above it.
  defp value_field(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <code
        id={@id}
        class="block min-w-0 flex-1 select-all break-all rounded-field border border-line bg-code px-2.5 py-1 font-mono text-[12.5px]/5"
      >{@value}</code>
      <.copy_button
        id={"#{@id}-copy"}
        target={"##{@id}"}
        label={gettext("Copy %{name}", name: @name)}
        placement="left"
        icon_only
      />
    </div>
    """
  end

  attr :key, AccessKey, required: true
  attr :node, Node, required: true
  attr :scope, :map, required: true
  attr :paths, :map, required: true
  attr :may, :map, required: true
  attr :intact, :boolean, required: true
  attr :last_run, :any, required: true
  attr :hosts, :any, required: true
  attr :confirming, :any, required: true, doc: "the act asked of this key, or false"

  # A key: what it is, how it came and what was done to it, and the acts its state allows.
  # An act asked of it is confirmed in place of the acts.
  defp key_card(assigns) do
    %{key: key, may: may} = assigns

    assigns =
      assign(assigns,
        state: state(key),
        dom: "key-#{key.key_id}",
        acts: key_acts(key, may)
      )

    ~H"""
    <li
      id={@dom}
      class="grid gap-3 rounded-box border border-line bg-base-100 p-4 text-[13px]/5 shadow-xs"
    >
      <h3
        id={"#{@dom}-title"}
        tabindex="-1"
        phx-hook="FocusOn"
        class="flex flex-wrap items-baseline gap-x-3 gap-y-1 outline-none"
      >
        <span id={"#{@dom}-label"} class="font-medium">{@key.label}</span>
        <.state_word id={"#{@dom}-state"}>
          {state_words(@state)}
        </.state_word>
      </h3>

      <%!-- A lasting state, said as the card is read, not an alert. The look is the error
           notice's. --%>
      <div
        :if={!@intact}
        id={"#{@dom}-integrity"}
        role="note"
        class="alert alert-soft bg-error-soft text-error-soft-content"
      >
        <.icon name="hero-exclamation-circle-micro" class="mt-px size-4" />
        <div class="min-w-0">
          {gettext(
            "This key's record doesn't match its integrity code: it was changed outside the application. It can't be used."
          )}
        </div>
      </div>

      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] items-baseline gap-x-6 gap-y-1">
        <dt class="text-faint">{gettext("Key ID")}</dt>
        <dd class="flex items-center gap-1">
          <span id={"#{@dom}-id"} class="q-mono">{@key.key_id}</span>
          <.copy_button
            id={"#{@dom}-id-copy"}
            text={@key.key_id}
            label={gettext("Copy the key ID of %{label}", label: @key.label)}
            placement="right"
            icon_only
          />
        </dd>
        <dt class="text-faint">{gettext("Added")}</dt>
        <dd id={"#{@dom}-added"}>{added_words(@key)}</dd>
        <dt class="text-faint">{gettext("Secret")}</dt>
        <dd id={"#{@dom}-secret"}>{secret_words(@key, @node)}</dd>
        <dt :if={@state == :revoked} class="text-faint">{state_words(@state)}</dt>
        <dd :if={@state == :revoked}>{when_words(@key.revoked_by, @key.revoked_at)}</dd>
        <dt class="text-faint">{gettext("Last used")}</dt>
        <dd id={"#{@dom}-used"}>
          <%= if @key.last_used_at do %>
            {Format.datetime(@key.last_used_at)}
            <span :if={@key.last_runner_version} class="text-muted">
              {gettext("runner %{version}", version: @key.last_runner_version)}
            </span>
          <% else %>
            {gettext("Not yet")}
          <% end %>
        </dd>
        <dt :if={@key.last_heartbeat_at} class="text-faint">{gettext("Last heartbeat")}</dt>
        <dd :if={@key.last_heartbeat_at}>{Format.datetime(@key.last_heartbeat_at)}</dd>
        <dt :if={@last_run} class="text-faint">{gettext("Last run")}</dt>
        <dd :if={@last_run}>
          <.link
            navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{@last_run.run_id}"}
            class="q-mono text-accent hover:underline"
          >
            {gettext("run %{id}", id: short_id(@last_run.run_id))}
          </.link>
        </dd>
        <dt :if={@hosts} class="text-faint">{gettext("Hosts, 14 days")}</dt>
        <dd :if={@hosts}>
          {@hosts.host ||
            ngettext("%{number} host", "%{number} hosts", @hosts.count,
              number: Format.number(@hosts.count)
            )}
        </dd>
        <dt :if={@key.rate} class="text-faint">{gettext("Rate")}</dt>
        <dd :if={@key.rate}>
          {gettext("%{rate}, bursts of %{burst}",
            rate: Format.number(@key.rate),
            burst: Format.number(@key.burst)
          )}
        </dd>
        <dt class="text-faint">{gettext("Fingerprint")}</dt>
        <dd id={"#{@dom}-fingerprint"} class="q-mono break-all">{AccessKey.fingerprint(@key)}</dd>
        <dt class="text-faint">{gettext("Stored secrets")}</dt>
        <dd>
          {secrets_words(@key.allow_secrets)}
          <span class="text-muted">{gettext("Fixed when the key was made.")}</span>
        </dd>
      </dl>

      <%= case @confirming do %>
        <% :revoke -> %>
          <.inline_confirm
            id={"#{@dom}-confirm"}
            question={gettext("Revoke %{label}?", label: @key.label)}
            cancel={@paths.access_key}
          >
            {gettext(
              "It is revoked at once, and its public key can never be used again. This cannot be undone."
            )}
            <:action>
              <.button
                id={"#{@dom}-confirm-button"}
                variant="danger"
                size="xs"
                phx-click="revoke"
                loading_text={gettext("Revoking")}
              >
                {gettext("Yes, revoke")}
              </.button>
            </:action>
          </.inline_confirm>
        <% _none -> %>
          <p :if={@state == :active} class="flex flex-wrap gap-3">
            <.button
              id={"#{@dom}-runner-file"}
              variant="link"
              patch={key_path(@paths, @key, "runner-file")}
              phx-hook="FocusOn"
            >
              <span aria-hidden="true">{gettext("Runner file")}</span>
              <span class="sr-only">
                {gettext("Runner file for %{label}", label: @key.label)}
              </span>
            </.button>
            <.button
              :if={:revoke in @acts}
              id={"#{@dom}-revoke"}
              variant="link"
              patch={key_path(@paths, @key, "revoke")}
              phx-hook="FocusOn"
            >
              <span aria-hidden="true">{gettext("Revoke…")}</span>
              <span class="sr-only">{gettext("Revoke %{label}", label: @key.label)}</span>
            </.button>
          </p>
      <% end %>
    </li>
    """
  end
end
