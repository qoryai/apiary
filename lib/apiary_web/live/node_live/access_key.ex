defmodule ApiaryWeb.NodeLive.AccessKey do
  @moduledoc """
  A node's Access key tab, `/:org/:workspace/nodes/:node_id/access-key`: the node's access
  keys and its outstanding enrolment codes, over `Apiary.AccessKeys` as it is. Its header
  and tabs are the node's page's (`ApiaryWeb.NodeComponents`).

  - **Keys**, under the line that a machine signs with its own key and Qory keeps only
    the public half, those in use first, then the revoked, newest first: each its label,
    key id and state, Active or Revoked (read from `revoked_at` alone: a key is active
    from the moment it arrives, enrolled with a code or pasted), its fingerprint, its
    stored-secrets flag, how and when it arrived, who revoked it and when, and its use
    where the record holds any. A key whose row does not match its integrity code says
    so: it can't be used. Owners and admins revoke an active key, confirmed in place, at
    a path of its own (`…/access-key/keys/:key_id/revoke`), a key named by its key id.
    While the node holds no active key, the Keys part leads owners and admins with the
    way that suits its kind, a heading, one sentence and three buttons, that way first
    and primary: a node with enrolling the machine with qory (New enrolment code), a pool
    with Generate a key; then the other two (Generate a key or New enrolment code, and
    Add a public key). Once it holds an active key, the three buttons stay, plain, the
    kind's way first. A member reads only that there is no key yet.
  - **Runner file for a key** (`…/access-key/keys/:key_id/runner-file`), a page of its
    own for an active key, linked from its card for everyone who reads the node, since
    nothing on it is secret: the runner file's `server` section (`url`, `access_key_id`,
    `apiary_public_key`) and, for CI, the two variables in place of the last two
    (`Apiary.AccessKeys.runner_lines/3`), each with Copy, where the key's secret is, and
    Done back to the tab.
  - **Generate a key** (`…/access-key/generate`), a page of its own: a label and the
    stored-secrets flag. The browser makes the key (the `GenerateKey` hook,
    `assets/js/hooks/generate_key.js`) and sends Qory its public half alone, in the one
    event `generate_key` (`{"key" => %{"label", "allow_secrets", "public_key"}}`); the
    form has no field for anything else, and no `phx-submit`. The event is taken only on
    that page, with its form open, from one who may add keys, and only as exactly those
    three strings: any other field, or any value holding `qak_` (an access key's secret,
    in any case), is refused before anything is stored. The key is added as a paste is
    (`Apiary.AccessKeys.add_access_key/4`, `arrived_by: :browser`), and the page patches
    to **Variables for a key** (`…/access-key/keys/:key_id/generated`), rendered by the
    same clause so that the hook's `<section id="key-generate">` lives through the patch:
    the key id and the pin (`Apiary.AccessKeys.variables/2`), each with Copy, and the
    secret's slot, `phx-update="ignore"`, empty from the server, carrying the public key
    the server stored (`data-public-key`). The hook writes the secret into it only beside
    its own public key, and empties it as the page goes. The server never has the secret:
    not in assigns, a render, a log line or the record. Opened again, the page shows the
    id and the pin, and the hook says the secret is gone. It is the page of an active key
    the reader made in a browser, while they may add keys; any other key's address goes
    to its runner file, or back to the tab.
  - **Add a public key** (`…/access-key/add`), a page of its own: a label, the
    stored-secrets flag and the public key, whose fingerprint shows as soon as it reads as
    one; the key is active as it is added (`Apiary.AccessKeys.add_access_key/4`), and
    the page goes on to the key's runner file.
  - **Enrolment codes**: the node's outstanding codes, who made each and when, when it
    expires, and the settings of the key it would bring; owners and admins revoke one in
    place (`…/access-key/codes/:code_id/revoke`, the code's row id, never the code). The
    page reads the codes again the moment the first of them expires, so an expired code
    leaves the list, and its confirmation, at once.
  - **New enrolment code** (`…/access-key/new-code`), a page of its own: the stored-secrets
    flag and a label hint. Once made, the page is the code, shown once and given the
    focus, as the machine sends it, with the server key's fingerprint after it
    (`Apiary.Contract.Enrolment.issued_code/2`); the command that enrols the machine with
    it, `qory access-key enrol <server> <code>`, with Copy; its expiry ("Expired" once
    past); and Done back to the tab.

  Leaving a form or a confirmation gives the focus back to the button that opened it, or,
  where the act took that button away, to the key's heading or to New enrolment code;
  leaving a key's variables, to the key's heading.

  **A code is shown once.** It lives in the page's process alone, wrapped in a function so
  no inspection of the process's state prints it, until the reader leaves the page by any
  way: every path starts without it, no path, flash or title carries it, and nothing logs
  it. A page opened again starts without it.

  Everyone in the workspace reads the tab (`node.read`); owners and admins act
  (`access_key.add`, `access_key.create_code`, `access_key.revoke`,
  `access_key.cancel_code`). A member sees no button and the line that
  says who manages the keys; an act's path refuses them. Every act is asked of
  `Apiary.Access` again by the context function, with the membership as the database has
  it, and an event that comes without its page or its confirmation open acts on nothing.
  """
  use ApiaryWeb, :live_view
  on_mount {ApiaryWeb.Access, :"node.read"}

  alias Apiary.{Access, AccessKeys, Nodes, Repo, Runs}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Contract.{Ed25519, Enrolment}
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
    "add_key" => :add_key,
    "create_code" => :new_code,
    "revoke" => :revoke,
    "revoke_code" => :revoke_code
  }

  @hosts_days 14

  @impl true
  def mount(%{"node_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Nodes.get_node(scope, public_id) do
      %Node{} = node ->
        if connected?(socket), do: Nodes.subscribe(scope)

        {:ok,
         socket
         |> assign(node: node, paths: paths(scope, node.public_id))
         |> assign(issued: nil, form: nil, preview: nil, key: nil, code: nil)
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
    |> schedule_expiry()
  end

  # The codes are read again the moment the first of them, or the code shown, expires: an
  # expired code is no longer outstanding, so the tab stops offering to revoke it, and the
  # code shown says it expired.
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

    # Every path starts without a code shown and without a confirmation or a form open: a
    # code shown is gone once the reader leaves its page.
    socket = assign(socket, issued: nil, form: nil, preview: nil, key: nil, code: nil)
    action = socket.assigns.live_action

    {:noreply,
     socket
     |> apply_action(action, params)
     |> titled()
     |> return_focus(opener)
     |> assign(:shown, action)}
  end

  # The button that opened the form, the code shown or the confirmation the page shows.
  defp opener(%{shown: :add_key}), do: :add_key
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
  # took it away, to the key's heading, or to New enrolment code for a code that is gone.
  defp return_focus(%{assigns: %{live_action: :index} = assigns} = socket, opener) do
    case focus_id(assigns, opener) do
      nil -> socket
      id -> push_event(socket, "run:focus", %{id: id})
    end
  end

  defp return_focus(socket, _opener), do: socket

  defp focus_id(%{may: may}, :add_key), do: if(may.add_key, do: "key-add-button")
  defp focus_id(%{may: may}, :generate), do: if(may.add_key, do: "key-generate-button")
  defp focus_id(%{may: may}, :new_code), do: if(may.new_code, do: "code-new-button")

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

  defp focus_id(%{may: may, codes: codes}, {:code, id}) do
    cond do
      may.revoke_code and Enum.any?(codes, &(&1.id == id)) -> "code-#{id}-revoke"
      may.new_code -> "code-new-button"
      true -> nil
    end
  end

  defp focus_id(_assigns, nil), do: nil

  defp apply_action(socket, :index, _params), do: socket

  defp apply_action(socket, :add_key, _params) do
    if socket.assigns.may.add_key,
      do: assign_form(socket, fresh(AccessKeys.change_new_key()), :key),
      else: refused(socket, gettext("Only owners and admins add a node's keys."))
  end

  defp apply_action(socket, :generate, _params) do
    cond do
      not socket.assigns.may.add_key ->
        refused(socket, gettext("Only owners and admins add a node's keys."))

      at_limit?(socket.assigns.keys) ->
        to_tab(socket, :error, limit_reached_words(socket.assigns.node))

      true ->
        assign_form(socket, fresh(AccessKeys.change_new_key()), :key)
    end
  end

  # The variables of a key made in this browser: the page Generate a key patches to, and
  # what a reload of it shows. Only for an active key of this node the reader made so,
  # while they may add keys; any other active key's address leads to its runner file,
  # which shows the same id and pin to everyone who reads the node.
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

  defp apply_action(socket, :new_code, _params) do
    if socket.assigns.may.new_code,
      do: assign_form(socket, fresh(code_changeset(%{})), :code),
      else: refused(socket, gettext("Only owners and admins make enrolment codes."))
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
  def handle_event(
        "validate_key",
        %{"key" => params},
        %{assigns: %{live_action: :add_key, form: %{}}} = socket
      ) do
    params = form_params(params)
    changeset = params |> AccessKeys.change_new_key() |> Map.put(:action, :validate)
    {:noreply, socket |> assign_form(changeset, :key) |> assign(:preview, preview(params))}
  end

  def handle_event(
        "add_key",
        %{"key" => params},
        %{assigns: %{live_action: :add_key, form: %{}, may: %{add_key: true}}} = socket
      ) do
    %{current_scope: scope, node: node} = socket.assigns

    # The key as its fingerprint was shown: without the spaces and the line ends a paste
    # brings around it.
    params =
      case form_params(params) do
        %{"public_key" => public_key} = params ->
          %{params | "public_key" => String.trim(public_key)}

        params ->
          params
      end

    case AccessKeys.add_access_key(scope, node, params) do
      # On to what the machine is given, the key's runner file.
      {:ok, key} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{label} is added.", label: key.label))
         |> load()
         |> push_patch(to: key_path(socket.assigns.paths, key, "runner-file"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign_form(changeset, :key) |> assign(:preview, preview(params))}

      {:error, :key_limit} ->
        {:noreply, put_flash(socket, :error, limit_reached_words(node))}

      {:error, :not_found} ->
        {:noreply, not_found(socket)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, gettext("Only owners and admins add a node's keys."))}
    end
  end

  # Generate a key's form, as it is typed: the label and the stored-secrets flag. No key
  # exists yet, and the form has no other field.
  def handle_event(
        "validate_generate",
        %{"key" => params},
        %{assigns: %{live_action: :generate, form: %{}}} = socket
      ) do
    changeset =
      params
      |> form_params()
      |> Map.take(["label", "allow_secrets"])
      |> AccessKeys.change_new_key()
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset, :key)}
  end

  # The key the browser made, by its public half: exactly the label, the stored-secrets
  # flag and the public key, each a string, none holding an access key's secret. Anything
  # else is refused before anything is stored, and logged by nothing here. The reply
  # carries the key id once it is added, which tells the hook to keep the secret for the
  # page it patches to; any other reply tells it to drop the secret.
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

  def handle_event(
        "validate_code",
        %{"code" => params},
        %{assigns: %{live_action: :new_code, form: %{}, issued: nil}} = socket
      ) do
    changeset = params |> form_params() |> code_changeset() |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset, :code)}
  end

  def handle_event(
        "create_code",
        %{"code" => params},
        %{assigns: %{live_action: :new_code, form: %{}, issued: nil, may: %{new_code: true}}} =
          socket
      ) do
    %{current_scope: scope, node: node} = socket.assigns

    case AccessKeys.create_enrolment_code(scope, node, form_params(params)) do
      {:ok, row, code} ->
        # The code as the machine sends it, in a function: shown by this page once, and
        # printed by nothing else.
        code = Enrolment.issued_code(code, Apiary.SigningKey.fingerprint())

        {:noreply,
         socket
         |> assign(form: nil, issued: %{row: row, code: fn -> code end})
         |> titled()
         |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset, :code)}

      {:error, :not_found} ->
        {:noreply, not_found(socket)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, gettext("Only owners and admins make enrolment codes."))}
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
        {:noreply, to_tab(socket, :info, gettext("The enrolment code is revoked."))}

      # It expired before the act reached it: nothing was revoked.
      {:ok, %EnrolmentCode{}} ->
        {:noreply, to_tab(socket, :error, outstanding_no_more())}

      {:error, :used} ->
        {:noreply, to_tab(socket, :error, gettext("The enrolment code was used already."))}

      {:error, :not_found} ->
        {:noreply, not_found(socket)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, gettext("Only owners and admins manage a node's keys."))}

      {:error, _not_saved} ->
        {:noreply, to_tab(socket, :error, gettext("Nothing was changed. Try again."))}
    end
  end

  # An act without its page or its confirmation open, or from one the page offers no
  # button: a second click of a button whose confirmation is gone, a code asked for once
  # it is shown, or an event the page never sent. One who may take the act is shown the
  # tab again; one who may not is refused, and nothing is done.
  def handle_event(event, _params, socket) when is_map_key(@write_events, event) do
    act = Map.fetch!(@write_events, event)

    if socket.assigns.may[act],
      do: {:noreply, load(socket)},
      else: {:noreply, refused(socket, gettext("Only owners and admins manage a node's keys."))}
  end

  # A form's change with no form open: nothing to do.
  def handle_event(event, _params, socket)
      when event in ~w(validate_key validate_generate validate_code),
      do: {:noreply, socket}

  @impl true
  def handle_info({:nodes_touched, _workspace_id}, socket) do
    %{current_scope: scope, node: node} = socket.assigns

    case Nodes.get_node(scope, node.public_id) do
      %Node{} = current -> {:noreply, socket |> assign(:node, current) |> assign_activity()}
      nil -> {:noreply, gone(socket)}
    end
  end

  # A code expired (`schedule_expiry/1`): the codes read again, and a confirmation of the
  # code that expired closed, since there is nothing left to revoke. The timer the page
  # holds stays for `load/1` to cancel: a read in between may have set another while this
  # one's message waited.
  def handle_info(:codes_expire, socket) do
    socket = load(socket)

    case socket.assigns do
      %{code: %EnrolmentCode{id: id}, codes: codes} ->
        if Enum.any?(codes, &(&1.id == id)),
          do: {:noreply, socket},
          else: {:noreply, to_tab(socket, :error, outstanding_no_more())}

      _no_confirmation ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## A key made in a browser

  # The event's parameters as the hook sends them, and nothing else: one key, `key`, a map
  # of exactly `label`, `allow_secrets` and `public_key`, each a string, none holding
  # `qak_` in any case (the runner's rule for a value that holds a secret).
  defp generated_key_params(%{"key" => %{} = key} = params) when map_size(params) == 1 do
    fields = ~w(allow_secrets label public_key)

    if key |> Map.keys() |> Enum.sort() == fields and
         Enum.all?(key, fn {_name, value} -> is_binary(value) and not holds_secret?(value) end),
       do: {:ok, Map.take(key, fields)},
       else: :error
  end

  defp generated_key_params(_params), do: :error

  defp holds_secret?(value), do: value |> String.downcase() |> String.contains?("qak_")

  defp add_generated_key(socket, attrs) do
    %{current_scope: scope, node: node} = socket.assigns

    case AccessKeys.add_access_key(scope, node, attrs, arrived_by: :browser) do
      {:ok, key} ->
        {:reply, %{key_id: key.key_id},
         socket
         |> put_flash(:info, gettext("%{label} is added.", label: key.label))
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

  # What the act named is not there for it: the key or the code, or the node itself, or
  # the workspace's, now. A node the reader still reads says so on the tab; one gone sends
  # them to the list.
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

  defp code_changeset(params),
    do: EnrolmentCode.settings_changeset(%EnrolmentCode{}, params)

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

  # The fingerprint of the public key typed, once it reads as one: what the person compares
  # with the machine's before they add it. Reading it says nothing of other keys.
  defp preview(%{"public_key" => value}) when is_binary(value) do
    case Ed25519.decode_public_key(String.trim(value)) do
      {:ok, public_key} -> Ed25519.fingerprint(public_key)
      {:error, _refusal} -> nil
    end
  end

  defp preview(_params), do: nil

  ## Words and paths

  defp paths(%{organisation: organisation, workspace: workspace}, public_id) do
    base = ~p"/#{organisation}/#{workspace}/nodes/#{public_id}"

    %{
      overview: base,
      access_key: base <> "/access-key",
      settings: base <> "/settings",
      add_key: base <> "/access-key/add",
      generate: base <> "/access-key/generate",
      new_code: base <> "/access-key/new-code"
    }
  end

  defp key_path(paths, key, act), do: "#{paths.access_key}/keys/#{key.key_id}/#{act}"
  defp code_path(paths, code), do: "#{paths.access_key}/codes/#{code.id}/revoke"

  defp titled(%{assigns: assigns} = socket) do
    title =
      case assigns do
        %{issued: %{}} -> gettext("New enrolment code")
        %{live_action: :add_key, form: %{}} -> gettext("Add a public key")
        %{live_action: :generate, form: %{}} -> gettext("Generate a key")
        %{live_action: :generated, key: %AccessKey{} = key} -> variables_title(key)
        %{live_action: :new_code, form: %{}} -> gettext("New enrolment code")
        %{live_action: :runner_file, key: %AccessKey{} = key} -> runner_file_title(key)
        _tab -> gettext("Access key")
      end

    assign(socket, :page_title, title <> " · " <> assigns.node.name)
  end

  defp revoked_words(key), do: gettext("%{label} is revoked.", label: key.label)

  defp limit_reached_words(node),
    do:
      gettext("%{name} holds two keys already. Revoke one before you add another.",
        name: node.name
      )

  defp not_added_words, do: gettext("The key wasn't added. Try again.")

  defp variables_title(key), do: gettext("Variables for %{label}", label: key.label)

  defp runner_file_title(key), do: gettext("Runner file for %{label}", label: key.label)

  defp outstanding_no_more, do: gettext("This enrolment code is no longer outstanding.")

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

  defp secrets_options,
    do: [{gettext("Not allowed"), "false"}, {gettext("Allowed"), "true"}]

  defp when_words(person, at) do
    if person,
      do:
        gettext("by %{person}, %{date}", person: People.email(person), date: Format.datetime(at)),
      else: Format.datetime(at)
  end

  defp arrived_words(%AccessKey{arrived_by: :code} = key),
    do:
      gettext("With an enrolment code %{person} made, %{date}",
        person: People.email(key.created_by) || gettext("Former member"),
        date: Format.datetime(key.received_at)
      )

  defp arrived_words(%AccessKey{arrived_by: :browser} = key),
    do:
      gettext("Made in a browser by %{person}, %{date}",
        person: People.email(key.created_by) || gettext("Former member"),
        date: Format.datetime(key.received_at)
      )

  defp arrived_words(%AccessKey{} = key),
    do:
      gettext("Pasted by %{person}, %{date}",
        person: People.email(key.created_by) || gettext("Former member"),
        date: Format.datetime(key.received_at || key.inserted_at)
      )

  defp limits_words do
    gettext("A node holds at most %{keys} keys at a time.",
      keys: Format.number(AccessKeys.key_limit())
    )
  end

  ## Render

  @impl true
  # The code just made: shown once, on the page that made it, with Done back to the tab.
  def render(%{issued: %{}} = assigns) do
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
      <:crumb>{gettext("New enrolment code")}</:crumb>

      <section id="code-issued" class="q-form-page" aria-labelledby="code-issued-header-title">
        <.page_header id="code-issued-header" title={gettext("New enrolment code")}>
          <:description>{gettext("For %{name}.", name: @node.name)}</:description>
        </.page_header>

        <div class="grid gap-4">
          <div id="code-issued-once">
            <.notice kind={:warning}>
              <strong>{gettext("This code is shown once.")}</strong>
              {gettext("Copy it now: only a hash of it is kept, and it can't be shown again.")}
            </.notice>
          </div>

          <%!-- The code takes the focus as it shows, read with its name, its expiry and
               that it is shown once. --%>
          <div
            id="code-issued-code"
            role="group"
            aria-labelledby="code-issued-label"
            aria-describedby="code-issued-expires-label code-issued-expires code-issued-once"
            class="grid gap-1.5"
          >
            <p id="code-issued-label" class="text-[13px]/5 text-faint">
              {gettext("Enrolment code")}
            </p>
            <div class="flex items-center gap-2">
              <code
                id="code-issued-value"
                tabindex="-1"
                phx-mounted={JS.focus()}
                class="block min-w-0 flex-1 select-all break-all rounded-field border border-line bg-code px-2.5 py-1 font-mono text-[12.5px]/5"
              >{@issued.code.()}</code>
              <.copy_button
                id="code-issued-copy"
                target="#code-issued-value"
                label={gettext("Copy code")}
                placement="left"
                icon_only
              />
            </div>
          </div>

          <div class="grid gap-1.5">
            <p class="text-[13px]/5">{gettext("On the machine, run:")}</p>
            <.code_block
              id="code-issued-command"
              code={"qory access-key enrol #{ApiaryWeb.Endpoint.url()} #{@issued.code.()}"}
              copy_label={gettext("Copy command")}
            />
            <p id="code-issued-works" class="text-[13px]/5 text-muted">
              {gettext("It works once, for %{minutes} minutes.",
                minutes: Format.number(AccessKeys.code_ttl_minutes())
              )}
            </p>
            <p id="code-issued-key" class="text-[13px]/5 text-muted">
              {gettext(
                "The key it brings is active as soon as it arrives here. If its fingerprint is not the one qory prints, revoke it."
              )}
            </p>
          </div>

          <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-6 gap-y-2 text-[13px]/5">
            <NodeComponents.code_expiry
              id="code-issued-expires"
              at={@issued.row.expires_at}
              now={@now}
            >
              {gettext("%{time}, %{minutes} minutes after it was made",
                time: Format.datetime(@issued.row.expires_at),
                minutes: Format.number(AccessKeys.code_ttl_minutes())
              )}
            </NodeComponents.code_expiry>
            <dt class="text-faint">{gettext("Stored secrets")}</dt>
            <dd id="code-issued-secrets">{secrets_words(@issued.row.allow_secrets)}</dd>
            <dt :if={@issued.row.label_hint} class="text-faint">{gettext("Label hint")}</dt>
            <dd :if={@issued.row.label_hint} class="q-mono">{@issued.row.label_hint}</dd>
          </dl>

          <%!-- Done alone: leaving cancels nothing, the code is made. --%>
          <SettingsComponents.save id="code-issued-done">
            <.button id="code-issued-done-button" variant="primary" patch={@paths.access_key}>
              {gettext("Done")}
            </.button>
            <:note>{gettext("Once you leave this page, the code is not shown again.")}</:note>
          </SettingsComponents.save>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # Generate a key, then the variables of the key it made: one clause, so the hook's
  # section (`#key-generate`) is the same element across the patch from the form to the
  # variables, and carries the secret, which only the browser has, into its slot.
  def render(%{live_action: action, form: form, key: key} = assigns)
      when (action == :generate and is_map(form)) or
             (action == :generated and is_struct(key, AccessKey)) do
    assigns =
      assign(assigns,
        variables: if(action == :generated, do: AccessKeys.variables(key), else: [])
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
          title={gettext("Generate a key")}
        >
          <:description>
            {if @node.kind == :pool,
              do:
                gettext(
                  "A key for %{name}, made in this browser. Only its public half is sent to Qory, and you see the secret once, as soon as it is made.",
                  name: @node.name
                ),
              else:
                gettext(
                  "A key for %{name}, made in this browser. Only its public half is sent to Qory, and you see the secret once, as soon as it is made. For a machine of your own, enrolling it with qory keeps the secret off every screen.",
                  name: @node.name
                )}
          </:description>
        </.page_header>
        <.page_header
          :if={@live_action == :generated}
          id="key-generated-header"
          title={variables_title(@key)}
        >
          <:description>
            {gettext("For %{name}. Set these three variables where the runner starts.",
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
                  "This browser makes keys only on a page served over HTTPS. Open Qory over HTTPS, or enrol the machine with qory."
                )}
              </.notice>
            </div>
            <div id="key-generate-unsupported" class="hidden">
              <.notice kind={:warning}>
                {gettext(
                  "This browser can't make an Ed25519 key. Use a current Chrome, Edge, Firefox or Safari, or enrol the machine with qory."
                )}
              </.notice>
            </div>
            <div id="key-generate-lost" class="hidden">
              <.notice kind={:error}>
                {gettext(
                  "The connection to Qory dropped before the key was confirmed, and its secret is gone. If a new key shows on the Access key tab, revoke it, then generate another."
                )}
              </.notice>
            </div>
          </div>

          <%!-- No `phx-submit`: the hook takes the submit, makes the key and sends its
               public half alone. The action is the page's own address, so a form whose
               hook did not start posts its label and choice to the console alone, and
               never puts them in an address. --%>
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
              label={gettext("Label")}
              placeholder={if @node.kind == :pool, do: "spot-runners", else: "build-01"}
              hint={gettext("Up to 80 characters, unique among this node's keys.")}
              autocomplete="off"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <.input
              field={@form[:allow_secrets]}
              type="radio"
              label={gettext("Stored secrets")}
              options={secrets_options()}
              hint={gettext("Fixed for the key once it is added. Runs don't receive secrets yet.")}
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

          <div :if={@live_action == :generated} id="key-generated-once">
            <.notice kind={:warning}>
              <strong>{gettext("The secret is shown once.")}</strong>
              {gettext(
                "Copy it now: it was made in this browser, Qory never received it, and it can't be shown again."
              )}
            </.notice>
          </div>

          <dl :if={@live_action == :generated} id="key-generated-variables" class="grid gap-3">
            <div class="grid gap-1">
              <dt class="q-mono text-faint">QORY_ACCESS_KEY_ID</dt>
              <dd class="flex items-center gap-2">
                <code
                  id="key-generated-id"
                  class="block min-w-0 flex-1 select-all break-all rounded-field border border-line bg-code px-2.5 py-1 font-mono text-[12.5px]/5"
                >{variable(@variables, "QORY_ACCESS_KEY_ID")}</code>
                <.copy_button
                  id="key-generated-id-copy"
                  target="#key-generated-id"
                  label={gettext("Copy %{name}", name: "QORY_ACCESS_KEY_ID")}
                  placement="left"
                  icon_only
                />
              </dd>
            </div>
            <div class="grid gap-1">
              <dt class="q-mono text-faint">QORY_ACCESS_KEY_SECRET</dt>
              <dd class="flex items-center gap-2">
                <%!-- The secret's slot: never patched or read by LiveView, empty from the
                     server. The hook writes the secret it holds into the value, as text,
                     only if this public key, the one the server stored, is its own. --%>
                <div
                  id="key-generated-secret"
                  phx-update="ignore"
                  data-public-key={Base.url_encode64(@key.public_key, padding: false)}
                  class="grid min-w-0 flex-1 gap-1"
                >
                  <code
                    id="key-generated-secret-value"
                    tabindex="-1"
                    class="block min-h-7 min-w-0 select-all break-all rounded-field border border-line bg-code px-2.5 py-1 font-mono text-[12.5px]/5 empty:hidden"
                  ></code>
                  <p id="key-generated-secret-gone" class="hidden text-muted">
                    {gettext(
                      "Not shown: only the page that made the key held its secret, and this one was opened again. If you didn't copy it, revoke %{label} and generate another key.",
                      label: @key.label
                    )}
                  </p>
                </div>
                <.copy_button
                  id="key-generated-secret-copy"
                  target="#key-generated-secret-value"
                  label={gettext("Copy %{name}", name: "QORY_ACCESS_KEY_SECRET")}
                  placement="left"
                  icon_only
                />
              </dd>
            </div>
            <div class="grid gap-1">
              <dt class="q-mono text-faint">QORY_APIARY_PUBLIC_KEY</dt>
              <dd class="flex items-center gap-2">
                <code
                  id="key-generated-pin"
                  class="block min-w-0 flex-1 select-all break-all rounded-field border border-line bg-code px-2.5 py-1 font-mono text-[12.5px]/5"
                >{variable(@variables, "QORY_APIARY_PUBLIC_KEY")}</code>
                <.copy_button
                  id="key-generated-pin-copy"
                  target="#key-generated-pin"
                  label={gettext("Copy %{name}", name: "QORY_APIARY_PUBLIC_KEY")}
                  placement="left"
                  icon_only
                />
              </dd>
            </div>
          </dl>

          <p :if={@live_action == :generated} id="key-generated-where" class="text-muted">
            <.rich text={
              rich_gettext(
                "Only QORY_ACCESS_KEY_SECRET belongs in your CI's secret store; the other two are plain settings. The runner file then needs only %{url}.",
                url: {:m, "url"}
              )
            } />
          </p>

          <%!-- Done alone: leaving cancels nothing, the key is added. --%>
          <SettingsComponents.save :if={@live_action == :generated} id="key-generated-done">
            <.button id="key-generated-done-button" variant="primary" patch={@paths.access_key}>
              {gettext("Done")}
            </.button>
            <:note>{gettext("Once you leave this page, the secret is not shown again.")}</:note>
          </SettingsComponents.save>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # Add a public key: a page of its own.
  def render(%{live_action: :add_key, form: %{}} = assigns) do
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
      <:crumb>{gettext("Add a public key")}</:crumb>

      <.page_form
        id="key-add"
        title={gettext("Add a public key")}
        cancel={@paths.access_key}
        cancel_by="patch"
      >
        <:description>
          {gettext("A key for %{name}. It is active as soon as you add it.",
            name: @node.name
          )}
        </:description>
        <.form
          for={@form}
          id="key-add-form"
          phx-change="validate_key"
          phx-submit="add_key"
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@form[:label]}
            type="text"
            label={gettext("Label")}
            placeholder="build-01"
            hint={gettext("Up to 80 characters, unique among this node's keys.")}
            autocomplete="off"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:allow_secrets]}
            type="radio"
            label={gettext("Stored secrets")}
            options={secrets_options()}
            hint={gettext("Fixed for the key once it is added. Runs don't receive secrets yet.")}
          />
          <.input
            field={@form[:public_key]}
            type="textarea"
            label={gettext("Public key")}
            hint={
              gettext(
                "An Ed25519 public key: its 32 bytes in base64url, without padding. qory access-key create prints it on the machine."
              )
            }
            autocomplete="off"
            spellcheck="false"
            rows="2"
            class="font-mono"
            required
          />
          <div>
            <%!-- Always there, so the fingerprint is read out as it shows. --%>
            <div id="key-add-fingerprint" aria-live="polite" class="text-[13px]/5">
              <p :if={@preview} class="mb-4">
                <span class="text-faint">{gettext("Fingerprint")}</span>
                <span class="q-mono">{@preview}</span>
                <span class="text-muted">
                  {gettext("Compare it with the one on the machine before you add the key.")}
                </span>
              </p>
            </div>
            <.page_form_foot id="key-add-save" cancel={@paths.access_key} cancel_by="patch">
              <.button
                id="key-add-submit"
                variant="primary"
                type="submit"
                loading_text={gettext("Adding")}
                aria-describedby="key-add-fingerprint"
              >
                {gettext("Add key")}
              </.button>
            </.page_form_foot>
          </div>
        </.form>
      </.page_form>
    </Layouts.app>
    """
  end

  # New enrolment code: a page of its own, then the code.
  def render(%{live_action: :new_code, form: %{}} = assigns) do
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
      <:crumb>{gettext("New enrolment code")}</:crumb>

      <.page_form
        id="code-new"
        title={gettext("New enrolment code")}
        cancel={@paths.access_key}
        cancel_by="patch"
      >
        <:description>
          {gettext(
            "A code for %{name}. It is shown once, as soon as it is made, and expires %{minutes} minutes later.",
            name: @node.name,
            minutes: Format.number(AccessKeys.code_ttl_minutes())
          )}
        </:description>
        <.form
          for={@form}
          id="code-new-form"
          phx-change="validate_code"
          phx-submit="create_code"
          phx-mounted={JS.focus(to: "#code-new-title")}
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@form[:allow_secrets]}
            type="radio"
            label={gettext("Stored secrets")}
            options={secrets_options()}
            hint={gettext("Fixed for the key the code brings. Runs don't receive secrets yet.")}
          />
          <.input
            field={@form[:label_hint]}
            type="text"
            label={gettext("Label hint")}
            placeholder="build-01"
            hint={
              gettext(
                "A label for the key to start from: letters, digits, dots, underscores and hyphens, up to 64."
              )
            }
            autocomplete="off"
            spellcheck="false"
            optional
          />
          <.page_form_foot id="code-new-save" cancel={@paths.access_key} cancel_by="patch">
            <.button
              id="code-new-submit"
              variant="primary"
              type="submit"
              loading_text={gettext("Making")}
            >
              {gettext("Make code")}
            </.button>
          </.page_form_foot>
        </.form>
      </.page_form>
    </Layouts.app>
    """
  end

  # A key's runner file: what the machine holding it is given, nothing of it secret.
  def render(%{live_action: :runner_file, key: %AccessKey{}} = assigns) do
    assigns =
      assign(assigns, :lines, AccessKeys.runner_lines(assigns.key, ApiaryWeb.Endpoint.url()))

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
            {gettext("For %{name}. Nothing here is secret: the key's secret stays on the machine.",
              name: @node.name
            )}
          </:description>
        </.page_header>

        <div class="grid gap-4 text-[13px]/5">
          <div class="grid gap-1.5">
            <p>
              <.rich text={
                rich_gettext("Put these lines in %{file} on the machine:",
                  file: {:m, "~/.config/qory/runner.yaml"}
                )
              } />
            </p>
            <.code_block
              id="key-runner-file-yaml"
              label="runner.yaml"
              code={@lines.file}
              copy_label={gettext("Copy lines")}
            />
          </div>

          <div class="grid gap-1.5">
            <p>
              <.rich text={
                rich_gettext(
                  "For CI, keep %{url} in the file and set these instead of the other two lines:",
                  url: {:m, "url"}
                )
              } />
            </p>
            <.code_block
              id="key-runner-file-env"
              code={@lines.env}
              copy_label={gettext("Copy variables")}
            />
          </div>

          <p id="key-runner-file-secret" class="text-muted">
            <.rich text={
              rich_gettext(
                "The key's secret is where %{create} put it: %{file}, or QORY_ACCESS_KEY_SECRET in CI.",
                create: {:m, "qory access-key create"},
                file: {:m, "~/.config/qory/access-key-secret"}
              )
            } />
          </p>

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
    ways = ways(assigns.node, assigns.may)

    assigns =
      assign(assigns,
        ways: ways,
        lead: ways != [] and not Enum.any?(assigns.keys, &(state(&1) == :active))
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

      <div id="node-access-key" class="grid max-w-[60rem] gap-8">
        <SettingsComponents.part id="node-keys" title={gettext("Keys")} level={:h2}>
          <p id="node-keys-intro" class="text-[13px]/5 text-muted">
            {gettext(
              "A machine signs every request with its own key. Qory keeps only the public half."
            )}
          </p>
          <p class="text-[13px]/5 text-muted">{limits_words()}</p>
          <p :if={!@manages} id="node-keys-members" class="text-[13px]/5 text-muted">
            {gettext("Only owners and admins manage a node's keys.")}
          </p>
          <%!-- While the node holds no active key, the way that suits its kind leads:
               a heading, one sentence, and its button first and primary. --%>
          <div :if={@lead} id="node-keys-lead" class="grid gap-2">
            <h3 id="node-keys-lead-title" class="text-[14px]/5 font-medium">
              {if @node.kind == :pool,
                do: gettext("Generate a key for this pool"),
                else: gettext("Enrol this machine with qory")}
            </h3>
            <p :if={@node.kind == :pool} class="text-[13px]/5 text-muted">
              {gettext(
                "The pool's instances share one key. This browser makes it and shows you the secret once, for your CI's secret store; Qory receives only the public half."
              )}
            </p>
            <p :if={@node.kind != :pool} class="text-[13px]/5 text-muted">
              <.rich text={
                rich_gettext(
                  "Make a code, then run %{enrol} with it on the machine. The machine makes its own key, and the secret never shows on a screen.",
                  enrol: {:m, "qory access-key enrol"}
                )
              } />
            </p>
          </div>
          <div :if={@ways != []} id="node-keys-ways" class="flex flex-wrap gap-2">
            <.button
              :for={{way, index} <- Enum.with_index(@ways)}
              id={way_id(way)}
              patch={way_path(@paths, way)}
              variant={if @lead and index == 0, do: "primary", else: "default"}
              phx-hook="FocusOn"
            >
              <.icon name="hero-plus-micro" class="size-4" />{way_words(way)}
            </.button>
          </div>

          <p :if={@keys == [] and @ways == []} id="node-keys-none" class="text-[13px]/5 text-muted">
            {gettext("No key yet.")}
          </p>

          <ul :if={@keys != []} id="node-keys-list" class="grid gap-3">
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

        <SettingsComponents.part id="node-codes" title={gettext("Enrolment codes")} level={:h2}>
          <p class="text-[13px]/5 text-muted">
            {gettext(
              "A code expires %{minutes} minutes after it is made, and is shown only then. Listed here: the codes neither used, revoked nor expired.",
              minutes: Format.number(AccessKeys.code_ttl_minutes())
            )}
          </p>
          <p :if={@codes == []} id="node-codes-none" class="text-[13px]/5 text-muted">
            {gettext("No enrolment code is outstanding.")}
          </p>
          <ul :if={@codes != []} id="node-codes-list" class="grid gap-3">
            <li
              :for={code <- @codes}
              id={"code-#{code.id}"}
              class="grid gap-2 rounded-box border border-line bg-base-100 p-4 text-[13px]/5 shadow-xs"
            >
              <%= if @code && @code.id == code.id do %>
                <.inline_confirm
                  id={"code-#{code.id}-confirm"}
                  question={
                    gettext("Revoke the code made %{time}?", time: Format.time(code.inserted_at))
                  }
                  cancel={@paths.access_key}
                >
                  {gettext("It is revoked at once. This cannot be undone.")}
                  <:action>
                    <.button
                      id={"code-#{code.id}-confirm-button"}
                      variant="danger"
                      size="xs"
                      phx-click="revoke_code"
                      loading_text={gettext("Revoking")}
                    >
                      {gettext("Yes, revoke")}
                    </.button>
                  </:action>
                </.inline_confirm>
              <% else %>
                <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-6 gap-y-1">
                  <dt class="text-faint">{gettext("Made")}</dt>
                  <dd>{when_words(code.created_by, code.inserted_at)}</dd>
                  <NodeComponents.code_expiry
                    id={"code-#{code.id}-expires"}
                    at={code.expires_at}
                    now={@now}
                  />
                  <dt class="text-faint">{gettext("Stored secrets")}</dt>
                  <dd>{secrets_words(code.allow_secrets)}</dd>
                  <dt :if={code.label_hint} class="text-faint">{gettext("Label hint")}</dt>
                  <dd :if={code.label_hint} class="q-mono">{code.label_hint}</dd>
                </dl>
                <p :if={@may.revoke_code}>
                  <.button
                    id={"code-#{code.id}-revoke"}
                    variant="link"
                    patch={code_path(@paths, code)}
                    phx-hook="FocusOn"
                  >
                    <span aria-hidden="true">{gettext("Revoke…")}</span>
                    <span class="sr-only">
                      {gettext("Revoke the code made %{time}", time: Format.time(code.inserted_at))}
                    </span>
                  </.button>
                </p>
              <% end %>
            </li>
          </ul>
        </SettingsComponents.part>
      </div>
    </Layouts.app>
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
        <span class="q-mono text-muted">{@key.key_id}</span>
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

      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-6 gap-y-1">
        <dt class="text-faint">{gettext("Fingerprint")}</dt>
        <dd id={"#{@dom}-fingerprint"} class="q-mono break-all">{AccessKey.fingerprint(@key)}</dd>
        <dt class="text-faint">{gettext("Stored secrets")}</dt>
        <dd>
          {secrets_words(@key.allow_secrets)}
          <span class="text-muted">{gettext("Fixed when the key was made.")}</span>
        </dd>
        <dt class="text-faint">{gettext("Arrived")}</dt>
        <dd id={"#{@dom}-arrived"}>{arrived_words(@key)}</dd>
        <dt :if={@state == :revoked} class="text-faint">{state_words(@state)}</dt>
        <dd :if={@state == :revoked}>{when_words(@key.revoked_by, @key.revoked_at)}</dd>
        <dt :if={@key.last_used_at} class="text-faint">{gettext("Last used")}</dt>
        <dd :if={@key.last_used_at}>
          {Format.datetime(@key.last_used_at)}
          <span :if={@key.last_runner_version} class="text-muted">
            {gettext("runner %{version}", version: @key.last_runner_version)}
          </span>
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
              <span aria-hidden="true">{gettext("Runner file lines")}</span>
              <span class="sr-only">
                {gettext("Runner file lines for %{label}", label: @key.label)}
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

  # The ways to give the node a key the reader may take, the kind's own first: a node is
  # one machine of its own, best enrolled with qory, which keeps the secret on it; a pool
  # is a fleet, typically a CI, whose secret goes into a secret store anyway.
  defp ways(%Node{kind: kind}, may) do
    order =
      if kind == :pool,
        do: [:generate, :new_code, :add_key],
        else: [:new_code, :generate, :add_key]

    Enum.filter(order, fn
      :new_code -> may.new_code
      _adds -> may.add_key
    end)
  end

  defp way_id(:new_code), do: "code-new-button"
  defp way_id(:generate), do: "key-generate-button"
  defp way_id(:add_key), do: "key-add-button"

  defp way_path(paths, :new_code), do: paths.new_code
  defp way_path(paths, :generate), do: paths.generate
  defp way_path(paths, :add_key), do: paths.add_key

  defp way_words(:new_code), do: gettext("New enrolment code")
  defp way_words(:generate), do: gettext("Generate a key")
  defp way_words(:add_key), do: gettext("Add a public key")

  defp variable(variables, name), do: variables |> List.keyfind!(name, 0) |> elem(1)

  defp nodes_path(paths), do: String.replace(paths.overview, ~r{/[^/]+$}, "")
end
