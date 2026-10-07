defmodule ApiaryWeb.NodeLive.AccessKey do
  @moduledoc """
  A node's Access key tab, `/:org/:workspace/nodes/:node_id/access-key`: the node's access
  keys and its outstanding enrolment codes, over `Apiary.AccessKeys` as it is. Its header
  and tabs are the node's page's (`ApiaryWeb.NodeComponents`).

  **What is true today.** Qory can't check a node's key yet, so the node receives no runs:
  machines send their runs with a workspace access key, and no enrolment is built, so
  nothing takes a code. The tab says so once, plainly, above everything else, with the
  way to the workspace's access keys (Workspace settings › Access keys), and none of its
  lines says a node posts, enrols or connects with what it holds. The add and code pages
  say it too.

  - **Keys**, those in use first, then the revoked and the rejected, newest first: each its
    label, key id and state, its fingerprint, its stored-secrets flag, how and when it
    arrived, who approved, revoked or rejected it and when, and its use where the record
    holds any. A key whose row does not match its integrity code says so, and offers no
    approval. Owners and admins approve or reject a key that awaits approval and revoke
    an approved one, each confirmed in place, at a path of its own
    (`…/access-key/keys/:key_id/approve`, `reject`, `revoke`), a key named by its key id.
  - **Add a public key** (`…/access-key/add`), a page of its own: a label, the
    stored-secrets flag and the public key, whose fingerprint shows as soon as it reads as
    one; the key is approved as it is added (`Apiary.AccessKeys.add_access_key/3`).
  - **Enrolment codes**: the node's outstanding codes, who made each and when, when it
    expires, and the settings of the key it would bring; owners and admins revoke one in
    place (`…/access-key/codes/:code_id/revoke`, the code's row id, never the code). The
    page reads the codes again the moment the first of them expires, so an expired code
    leaves the list, and its confirmation, at once.
  - **New enrolment code** (`…/access-key/new-code`), a page of its own: the stored-secrets
    flag and a label hint. Once made, the page is the code, shown once and given the
    focus, with its expiry ("Expired" once past) and Done back to the tab.

  Leaving a form or a confirmation gives the focus back to the button that opened it, or,
  where the act took that button away, to the key's heading or to New enrolment code.

  **A code is shown once.** It lives in the page's process alone, wrapped in a function so
  no inspection of the process's state prints it, until the reader leaves the page by any
  way: every path starts without it, no path, flash or title carries it, and nothing logs
  it. A page opened again starts without it.

  Everyone in the workspace reads the tab (`node.read`); owners and admins act
  (`access_key.add`, `access_key.create_code`, `access_key.approve`, `access_key.reject`,
  `access_key.revoke`, `access_key.cancel_code`). A member sees no button and the line that
  says who manages the keys; an act's path refuses them. Every act is asked of
  `Apiary.Access` again by the context function, with the membership as the database has
  it, and an event that comes without its page or its confirmation open acts on nothing.
  """
  use ApiaryWeb, :live_view
  on_mount {ApiaryWeb.Access, :"node.read"}

  alias Apiary.{Access, AccessKeys, Nodes, Repo, Runs}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Contract.Ed25519
  alias Apiary.Nodes.Node
  alias ApiaryWeb.{NodeComponents, People, SettingsComponents, UserAuth}

  # The page's acts, and the action of `Apiary.Access` each one asks.
  @acts [
    add_key: :"access_key.add",
    new_code: :"access_key.create_code",
    approve: :"access_key.approve",
    reject: :"access_key.reject",
    revoke: :"access_key.revoke",
    revoke_code: :"access_key.cancel_code"
  ]

  # The events that change something, and the act each is.
  @write_events %{
    "add_key" => :add_key,
    "create_code" => :new_code,
    "approve" => :approve,
    "reject" => :reject,
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

  # The node's keys and outstanding codes, with who made, approved and revoked each, and
  # what the record holds of their use.
  defp load(socket) do
    %{current_scope: scope, node: node} = socket.assigns

    keys =
      scope
      |> AccessKeys.list_for_node(node)
      |> Repo.preload([:created_by, :approved_by, :revoked_by])

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
  defp opener(%{shown: :new_code}), do: :new_code

  defp opener(%{shown: act, key: %AccessKey{key_id: key_id}})
       when act in [:approve, :reject, :revoke],
       do: {:key, key_id, act}

  defp opener(%{shown: :revoke_code, code: %EnrolmentCode{id: id}}), do: {:code, id}
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
  defp focus_id(%{may: may}, :new_code), do: if(may.new_code, do: "code-new-button")

  defp focus_id(assigns, {:key, key_id, act}) do
    case Enum.find(assigns.keys, &(&1.key_id == key_id)) do
      nil ->
        nil

      key ->
        if act in key_acts(key, assigns.may, assigns.intact[key.id]),
          do: "key-#{key_id}-#{act}",
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

  defp apply_action(socket, :new_code, _params) do
    if socket.assigns.may.new_code,
      do: assign_form(socket, fresh(code_changeset(%{})), :code),
      else: refused(socket, gettext("Only owners and admins make enrolment codes."))
  end

  defp apply_action(socket, act, %{"key_id" => key_id})
       when act in [:approve, :reject, :revoke] do
    key = Enum.find(socket.assigns.keys, &(&1.key_id == key_id))

    cond do
      not socket.assigns.may[act] ->
        refused(socket, gettext("Only owners and admins manage a node's keys."))

      is_nil(key) ->
        to_tab(socket, :error, gettext("This node has no such key."))

      act in [:approve, :reject] and AccessKey.status(key) != :pending ->
        to_tab(socket, :error, gettext("%{label} no longer awaits approval.", label: key.label))

      act == :approve and not socket.assigns.intact[key.id] ->
        to_tab(socket, :error, integrity_words(key))

      act == :revoke and AccessKey.status(key) != :active ->
        to_tab(socket, :error, gettext("%{label} is not an approved key.", label: key.label))

      true ->
        assign(socket, :key, key)
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
      {:ok, key} ->
        {:noreply,
         to_tab(socket, :info, gettext("%{label} is added, and approved.", label: key.label))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign_form(changeset, :key) |> assign(:preview, preview(params))}

      {:error, :key_limit} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "%{name} holds two keys already. Revoke or reject one before you add another.",
             name: node.name
           )
         )}

      {:error, :not_found} ->
        {:noreply, not_found(socket)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, gettext("Only owners and admins add a node's keys."))}
    end
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
        # The code, in a function: shown by this page once, and printed by nothing else.
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
        "approve",
        _params,
        %{assigns: %{live_action: :approve, key: %AccessKey{} = key, may: %{approve: true}}} =
          socket
      ) do
    case AccessKeys.approve(socket.assigns.current_scope, key) do
      {:ok, key} ->
        {:noreply, to_tab(socket, :info, gettext("%{label} is approved.", label: key.label))}

      {:error, :key_limit} ->
        {:noreply,
         to_tab(
           socket,
           :error,
           gettext(
             "%{name} holds two approved keys already. Revoke one before you approve another.",
             name: socket.assigns.node.name
           )
         )}

      {:error, :not_pending} ->
        {:noreply,
         to_tab(socket, :error, gettext("%{label} no longer awaits approval.", label: key.label))}

      {:error, :integrity} ->
        {:noreply, to_tab(socket, :error, integrity_words(key))}

      {:error, :not_found} ->
        {:noreply, not_found(socket)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, gettext("Only owners and admins manage a node's keys."))}

      {:error, _not_saved} ->
        {:noreply, to_tab(socket, :error, gettext("Nothing was changed. Try again."))}
    end
  end

  def handle_event(
        "reject",
        _params,
        %{assigns: %{live_action: :reject, key: %AccessKey{} = key, may: %{reject: true}}} =
          socket
      ) do
    case AccessKeys.reject(socket.assigns.current_scope, key) do
      {:ok, key} ->
        {:noreply, to_tab(socket, :info, gettext("%{label} is rejected.", label: key.label))}

      {:error, :not_pending} ->
        {:noreply,
         to_tab(socket, :error, gettext("%{label} no longer awaits approval.", label: key.label))}

      {:error, :not_found} ->
        {:noreply, not_found(socket)}

      {:error, :forbidden} ->
        {:noreply, refused(socket, gettext("Only owners and admins manage a node's keys."))}

      {:error, _not_saved} ->
        {:noreply, to_tab(socket, :error, gettext("Nothing was changed. Try again."))}
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

      {:error, :pending} ->
        {:noreply,
         to_tab(
           socket,
           :error,
           gettext("%{label} awaits approval: reject it instead.", label: key.label)
         )}

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
  def handle_event(event, _params, socket) when event in ~w(validate_key validate_code),
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
        %{live_action: :new_code, form: %{}} -> gettext("New enrolment code")
        _tab -> gettext("Access key")
      end

    assign(socket, :page_title, title <> " · " <> assigns.node.name)
  end

  defp integrity_words(key),
    do:
      gettext(
        "%{label} can't be approved: its record was changed outside the application.",
        label: key.label
      )

  defp outstanding_no_more, do: gettext("This enrolment code is no longer outstanding.")

  # The acts a key's card offers the reader: approving or rejecting one that awaits
  # approval, approving it only while its record is intact; revoking an approved one.
  defp key_acts(%AccessKey{} = key, may, intact) do
    case state(key) do
      :pending ->
        for {act, true} <- [approve: may.approve and intact, reject: may.reject], do: act

      :approved ->
        if may.revoke, do: [:revoke], else: []

      _revoked_or_rejected ->
        []
    end
  end

  defp state(%AccessKey{} = key) do
    case AccessKey.status(key) do
      :pending -> :pending
      :revoked -> if key.approved_at, do: :revoked, else: :rejected
      _approved -> :approved
    end
  end

  defp state_words(:pending), do: gettext("Awaiting approval")
  defp state_words(:approved), do: gettext("Approved")
  defp state_words(:revoked), do: gettext("Revoked")
  defp state_words(:rejected), do: gettext("Rejected")

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

  defp arrived_words(%AccessKey{} = key),
    do:
      gettext("Pasted by %{person}, %{date}",
        person: People.email(key.created_by) || gettext("Former member"),
        date: Format.datetime(key.received_at || key.inserted_at)
      )

  defp limits_words do
    %{approved: approved, pending: pending} = AccessKeys.key_limits()

    gettext(
      "A node holds at most %{approved} approved keys, and %{pending} more awaiting approval.",
      approved: Format.number(approved),
      pending: Format.number(pending)
    )
  end

  defp not_yet_text,
    do:
      rich_gettext(
        "Qory can't check these keys yet, so this node receives no runs. Until it can, machines send their runs with a workspace access key, from %{link}.",
        link: {:part, :link}
      )

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
          <NodeComponents.not_yet scope={@current_scope} text={not_yet_text()} />

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
          {gettext("A key for %{name}. A key you add here is approved as you add it.",
            name: @node.name
          )}
        </:description>
        <NodeComponents.not_yet scope={@current_scope} text={not_yet_text()} class="mb-4" />
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
            hint={gettext("An Ed25519 public key: its 32 bytes in base64url, without padding.")}
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
        <NodeComponents.not_yet scope={@current_scope} text={not_yet_text()} class="mb-4" />
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

  # The tab.
  def render(assigns) do
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
        <NodeComponents.not_yet scope={@current_scope} text={not_yet_text()} />

        <SettingsComponents.part id="node-keys" title={gettext("Keys")} level={:h2}>
          <p class="text-[13px]/5 text-muted">{limits_words()}</p>
          <p :if={!@manages} id="node-keys-members" class="text-[13px]/5 text-muted">
            {gettext("Only owners and admins manage a node's keys.")}
          </p>
          <div :if={@may.add_key or @may.new_code} class="flex flex-wrap gap-2">
            <.button
              :if={@may.add_key}
              id="key-add-button"
              patch={@paths.add_key}
              phx-hook="FocusOn"
            >
              <.icon name="hero-plus-micro" class="size-4" />{gettext("Add a public key")}
            </.button>
            <.button
              :if={@may.new_code}
              id="code-new-button"
              patch={@paths.new_code}
              phx-hook="FocusOn"
            >
              <.icon name="hero-plus-micro" class="size-4" />{gettext("New enrolment code")}
            </.button>
          </div>

          <p :if={@keys == []} id="node-keys-none" class="text-[13px]/5 text-muted">
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
    %{key: key, may: may, intact: intact} = assigns

    assigns =
      assign(assigns,
        state: state(key),
        dom: "key-#{key.key_id}",
        acts: key_acts(key, may, intact)
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
        <.state_word id={"#{@dom}-state"} hot={@state == :pending}>
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
            "This key's record doesn't match its integrity code: it was changed outside the application. It can't be approved."
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
        <dt :if={@key.approved_at} class="text-faint">{gettext("Approved")}</dt>
        <dd :if={@key.approved_at}>{when_words(@key.approved_by, @key.approved_at)}</dd>
        <dt :if={@state in [:revoked, :rejected]} class="text-faint">{state_words(@state)}</dt>
        <dd :if={@state in [:revoked, :rejected]}>{when_words(@key.revoked_by, @key.revoked_at)}</dd>
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
        <% :approve -> %>
          <.inline_confirm
            id={"#{@dom}-confirm"}
            question={gettext("Approve %{label}?", label: @key.label)}
            cancel={@paths.access_key}
          >
            {gettext(
              "Approve it only if its fingerprint, %{fingerprint}, is the one on the machine that holds the key.",
              fingerprint: AccessKey.fingerprint(@key)
            )}
            <:action>
              <.button
                id={"#{@dom}-confirm-button"}
                variant="primary"
                size="xs"
                phx-click="approve"
                loading_text={gettext("Approving")}
              >
                {gettext("Yes, approve")}
              </.button>
            </:action>
          </.inline_confirm>
        <% :reject -> %>
          <.inline_confirm
            id={"#{@dom}-confirm"}
            question={gettext("Reject %{label}?", label: @key.label)}
            cancel={@paths.access_key}
          >
            {gettext("Its public key can never be used again. This cannot be undone.")}
            <:action>
              <.button
                id={"#{@dom}-confirm-button"}
                variant="danger"
                size="xs"
                phx-click="reject"
                loading_text={gettext("Rejecting")}
              >
                {gettext("Yes, reject")}
              </.button>
            </:action>
          </.inline_confirm>
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
          <p :if={:approve in @acts} id={"#{@dom}-guidance"} class="text-muted">
            {gettext(
              "Approve it only if its fingerprint is the one on the machine that holds the key."
            )}
          </p>
          <p :if={@acts != []} class="flex flex-wrap gap-3">
            <.button
              :if={:approve in @acts}
              id={"#{@dom}-approve"}
              variant="link"
              patch={key_path(@paths, @key, "approve")}
              phx-hook="FocusOn"
            >
              {gettext("Approve…")}
            </.button>
            <.button
              :if={:reject in @acts}
              id={"#{@dom}-reject"}
              variant="link"
              patch={key_path(@paths, @key, "reject")}
              phx-hook="FocusOn"
            >
              {gettext("Reject…")}
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

  defp nodes_path(paths), do: String.replace(paths.overview, ~r{/[^/]+$}, "")
end
