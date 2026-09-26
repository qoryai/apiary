defmodule ApiaryWeb.ActivityLive do
  @moduledoc """
  The organisation's audit trail, an organisation's page: `/:org/activity`. Every change a
  person, an access key or the instance made to what the organisation holds, newest
  first, a page of fifty at a time (`Apiary.Audit.list_entries/3`), for a reader who may
  `audit.read`.

  One row per entry: when (relative, the full time on hover), who (a person by the email
  address their account has now, "Former member" once it is gone; an access key by its
  label and key id; the instance as Qory), what, as a sentence, on what (and in which
  workspace), and a short before and after. Names are looked up when the page reads, never
  stored in the trail (`Apiary.Audit.names/2`).

  The workspace (`workspace_id`: `workspace` is the path's word for a slug), the action
  and the page are query parameters; a value the page does not know is left out. The
  entries are read off the socket's process (`start_async`): the first render is the
  table's skeleton, a later read keeps what is on screen until the new page arrives.
  """
  use ApiaryWeb, :live_view
  on_mount {ApiaryWeb.Access, :"audit.read"}

  alias Apiary.{Access, Audit, Features, Organisations}

  # A page past the last is said to be empty; one this far is not read at all.
  @page_max 10_000

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:activity}
      width="wide"
    >
      <.header>
        {gettext("Activity")}
        <:subtitle>
          {gettext(
            "Every change made to this organisation and its workspaces: who made it, when, and what it changed."
          )}
        </:subtitle>
      </.header>

      <div class="grid grid-cols-[minmax(0,1fr)] gap-4">
        <.filter_bar
          id="activity-filters"
          clear={
            filtered?(@filters) &&
              page_path(@current_scope, %{@filters | workspace_id: nil, action: nil, page: 1})
          }
        >
          <.filter
            id="filter-workspace"
            name="workspace_id"
            label={gettext("Workspace")}
            value={@filters.workspace_id}
            options={for w <- @workspaces, do: {w.name, w.id, nil}}
            remove={page_path(@current_scope, %{@filters | workspace_id: nil, page: 1})}
          />
          <.filter
            name="action"
            label={gettext("Action")}
            value={@filters.action}
            options={for {value, label} <- action_options(@current_scope), do: {label, value, nil}}
            remove={page_path(@current_scope, %{@filters | action: nil, page: 1})}
          />
        </.filter_bar>

        <.notice :if={@load_error} kind={:error} class="max-w-[80ch]">
          <span id="activity-error">
            {gettext(
              "The activity could not be loaded. Reload the page; if it keeps happening, the server log has the reason."
            )}
          </span>
        </.notice>

        <div
          :if={is_nil(@rows) && !@load_error}
          id="activity-loading"
          class="overflow-hidden rounded-box border border-line bg-base-100 shadow-xs"
          aria-busy="true"
        >
          <span class="sr-only">{gettext("Loading the activity")}</span>
          <div
            :for={n <- 1..8}
            class="flex items-center gap-6 border-b border-line px-4 py-3.5 last:border-b-0"
          >
            <span class="skeleton q-skel w-16"></span>
            <span class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-40", else: "w-28")]}></span>
            <span class="skeleton q-skel w-32"></span>
            <span class="skeleton q-skel w-24 max-md:hidden"></span>
          </div>
        </div>

        <div :if={@rows == [] && @filters.page > 1} id="activity-past-end">
          <.empty_state
            icon="hero-clipboard-document-list"
            tone="neutral"
            title={gettext("No entries on this page")}
          >
            {gettext("The activity has fewer pages than that.")}
            <:actions>
              <.button
                id="activity-first-page"
                patch={page_path(@current_scope, %{@filters | page: 1})}
              >
                {gettext("Go to the first page")}
              </.button>
            </:actions>
          </.empty_state>
        </div>

        <div :if={@rows == [] && @filters.page == 1} id="activity-empty">
          <.empty_state
            icon="hero-clipboard-document-list"
            tone="neutral"
            title={
              if filtered?(@filters),
                do: gettext("No activity matches these filters"),
                else: gettext("No activity yet")
            }
          >
            {if filtered?(@filters),
              do: gettext("Clear the filters to see every change."),
              else:
                gettext("Changes to the organisation, its workspaces, members and keys show here.")}
          </.empty_state>
        </div>

        <div :if={@rows not in [nil, []]} aria-busy={to_string(@loading)}>
          <.table id="activity" label={gettext("Activity")} rows={@rows} row_id={&"entry-#{&1.id}"}>
            <:col :let={row} label={gettext("When")} class="whitespace-nowrap">
              <.relative_time id={"entry-#{row.id}-time"} at={row.at} class="text-muted" />
            </:col>
            <:col :let={row} label={gettext("Who")}>
              <.actor actor={row.actor} id={"entry-#{row.id}-actor"} />
            </:col>
            <:col :let={row} label={gettext("What")}>
              <span id={"entry-#{row.id}-action"}>{row.sentence}</span>
            </:col>
            <:col :let={row} label={gettext("Subject")}>
              <div id={"entry-#{row.id}-subject"} class="grid min-w-0">
                <span class="truncate">
                  <.link :if={row.subject.href} navigate={row.subject.href} class="link">
                    <.subject_text subject={row.subject} />
                  </.link>
                  <.subject_text :if={!row.subject.href} subject={row.subject} />
                </span>
                <span :if={row.place} class="truncate text-[12.5px]/[18px] text-faint">
                  {gettext("in %{workspace}", workspace: row.place)}
                </span>
              </div>
            </:col>
            <:col :let={row} label={gettext("Change")}>
              <span id={"entry-#{row.id}-change"} class="grid text-muted">
                <span :for={line <- row.change}><.rich text={line} /></span>
              </span>
            </:col>
          </.table>
        </div>

        <nav
          :if={@rows not in [nil, []] && (@filters.page > 1 || @more?)}
          id="activity-pages"
          class="flex items-center justify-end gap-2"
          aria-label={gettext("Pages")}
        >
          <.button
            :if={@filters.page > 1}
            id="activity-newer"
            size="sm"
            patch={page_path(@current_scope, %{@filters | page: @filters.page - 1})}
          >
            <.icon name="hero-chevron-left-micro" class="size-4" /> {gettext("Newer")}
          </.button>
          <.button
            :if={@more?}
            id="activity-older"
            size="sm"
            patch={page_path(@current_scope, %{@filters | page: @filters.page + 1})}
          >
            {gettext("Older")} <.icon name="hero-chevron-right-micro" class="size-4" />
          </.button>
        </nav>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :actor, :map, required: true

  defp actor(assigns) do
    ~H"""
    <span id={@id} class="inline-flex min-w-0 items-center gap-2">
      <%= case @actor.kind do %>
        <% :person -> %>
          <span class="truncate font-medium">{@actor.text}</span>
          <.badge :if={@actor.you?}>{gettext("You")}</.badge>
        <% :gone -> %>
          <span class="truncate text-muted">{@actor.text}</span>
        <% :access_key -> %>
          <.icon name="hero-key-micro" class="size-4 flex-none text-faint" />
          <span :if={@actor.text} class="truncate font-medium">{@actor.text}</span>
          <.mono bare>{@actor.detail}</.mono>
        <% :instance -> %>
          <.icon name="hero-cpu-chip-micro" class="size-4 flex-none text-faint" />
          <span class="font-medium">{@actor.text}</span>
      <% end %>
    </span>
    """
  end

  attr :subject, :map, required: true

  defp subject_text(%{subject: %{mono: true}} = assigns) do
    ~H"""
    <span class="font-mono text-[12.5px]">{@subject.text}</span>
    """
  end

  defp subject_text(assigns) do
    ~H"""
    <span>{@subject.text}</span>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       page_title: gettext("Activity"),
       workspaces: Organisations.list_workspaces(scope),
       filters: %{workspace_id: nil, action: nil, page: 1},
       rows: nil,
       more?: false,
       loading: false,
       load_error: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:filters, parse(params, socket.assigns)) |> load()}
  end

  @impl true
  def handle_event("filter", %{"_filter" => name} = params, socket)
      when name in ~w(workspace_id action) do
    value = if params[name] in [nil, ""], do: nil, else: params[name]
    key = if name == "workspace_id", do: :workspace_id, else: :action
    filters = socket.assigns.filters |> Map.put(key, value) |> Map.put(:page, 1)

    {:noreply,
     push_patch(socket,
       to: page_path(socket.assigns.current_scope, parse(to_params(filters), socket.assigns))
     )}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  # The menus hold every value there is: there is nothing to narrow on the server.
  def handle_event("narrow", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:load, {:ok, {filters, {:ok, page, names}}}, socket) do
    if filters == socket.assigns.filters do
      scope = socket.assigns.current_scope
      workspaces = Map.new(socket.assigns.workspaces, &{&1.id, &1})

      {:noreply,
       assign(socket,
         rows: Enum.map(page.entries, &row(&1, names, scope, workspaces)),
         more?: page.more?,
         loading: false,
         load_error: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:load, _result, socket) do
    {:noreply, assign(socket, loading: false, load_error: true)}
  end

  defp load(socket) do
    %{current_scope: scope, filters: filters} = socket.assigns

    if connected?(socket) do
      socket
      |> assign(:loading, true)
      |> start_async(:load, fn ->
        answer =
          with {:ok, page} <-
                 Audit.list_entries(
                   scope,
                   %{workspace_id: filters.workspace_id, action: filters.action},
                   filters.page
                 ) do
            {:ok, page, Audit.names(scope, page.entries)}
          end

        {filters, answer}
      end)
    else
      socket
    end
  end

  ## Filters

  defp parse(params, %{workspaces: workspaces, current_scope: scope}) do
    workspace = Enum.find(workspaces, &(&1.id == params["workspace_id"]))
    action = if List.keymember?(action_options(scope), params["action"], 0), do: params["action"]

    page =
      case Integer.parse(to_string(params["page"] || "")) do
        {n, ""} when n > 1 -> min(n, @page_max)
        _ -> 1
      end

    %{workspace_id: workspace && workspace.id, action: action, page: page}
  end

  defp to_params(filters) do
    %{
      "workspace_id" => filters.workspace_id,
      "action" => filters.action,
      "page" => to_string(filters.page)
    }
  end

  defp filtered?(filters), do: not is_nil(filters.workspace_id) or not is_nil(filters.action)

  defp page_path(scope, filters) do
    query =
      for {key, value} <- [
            workspace_id: filters.workspace_id,
            action: filters.action,
            page: filters.page > 1 && filters.page
          ],
          value,
          do: {key, value}

    if query == [],
      do: ~p"/#{scope.organisation}/activity",
      else: ~p"/#{scope.organisation}/activity?#{query}"
  end

  # The actions a reader can filter by: those that change something, of the features the
  # instance has, each by the words of its filter.
  defp action_options(scope) do
    for action <- Audit.audited_actions(),
        feature_on?(scope, Access.feature(action)),
        do: {Atom.to_string(action), action_label(action)}
  end

  defp feature_on?(_scope, nil), do: true
  defp feature_on?(scope, feature), do: Features.on?(scope, feature)

  defp action_label(:"organisation.create"), do: gettext("Organisation created")
  defp action_label(:"organisation.rename"), do: gettext("Organisation renamed")
  defp action_label(:"member.invite"), do: gettext("Member invited")
  defp action_label(:"member.change_level"), do: gettext("Member's level changed")
  defp action_label(:"member.remove"), do: gettext("Member removed")
  defp action_label(:"invitation.revoke"), do: gettext("Invitation revoked")
  defp action_label(:"invitation.accept"), do: gettext("Invitation accepted")
  defp action_label(:"audit.prune"), do: gettext("Activity pruned")
  defp action_label(:"workspace.rename"), do: gettext("Workspace renamed")
  defp action_label(:"access_key.create"), do: gettext("Access key created")
  defp action_label(:"access_key.rotate"), do: gettext("Access key rotated")
  defp action_label(:"access_key.revoke"), do: gettext("Access key revoked")
  defp action_label(:"run.close"), do: gettext("Run closed")
  defp action_label(:"retention.edit"), do: gettext("Retention changed")
  defp action_label(:"security_policy.edit"), do: gettext("Policy rules changed")
  defp action_label(:"security_policy.lock"), do: gettext("Policy rule locked or unlocked")
  defp action_label(:"security_policy.set_mode"), do: gettext("Policy mode changed")
  defp action_label(action), do: Atom.to_string(action)

  ## One row

  defp row(entry, names, scope, workspaces) do
    action = Audit.action(entry)
    details = entry.details || %{}
    workspace = entry.workspace_id && workspaces[entry.workspace_id]

    %{
      id: entry.id,
      at: entry.inserted_at,
      actor: actor_of(entry, names, scope),
      sentence: sentence(action, details),
      subject: subject(entry, action, names, scope, workspace),
      place: if(workspace && entry.subject_kind != "workspace", do: workspace.name),
      change: action |> change(entry.before || %{}, entry.after || %{}, details) |> List.wrap()
    }
  end

  defp actor_of(%{actor_kind: :person, actor_id: id}, names, scope) do
    case names.users[id] do
      nil -> %{kind: :gone, text: gettext("Former member")}
      email -> %{kind: :person, text: email, you?: scope.user && scope.user.id == id}
    end
  end

  defp actor_of(%{actor_kind: :access_key, actor_id: id}, names, _scope) do
    case names.access_keys[id] do
      %{label: label, key_id: key_id} -> %{kind: :access_key, text: label, detail: key_id}
      nil -> %{kind: :gone, text: gettext("An access key")}
    end
  end

  defp actor_of(%{actor_kind: :instance}, _names, _scope),
    do: %{kind: :instance, text: gettext("Qory")}

  # What was done, one whole sentence an action, and one a kind of change where an action
  # takes several.
  defp sentence(:"organisation.create", _details),
    do: gettext("Signed up and created the organisation")

  defp sentence(:"organisation.rename", _details), do: gettext("Renamed the organisation")
  defp sentence(:"member.invite", _details), do: gettext("Invited a member")
  defp sentence(:"member.change_level", _details), do: gettext("Changed a member's level")
  defp sentence(:"member.remove", _details), do: gettext("Removed a member")

  defp sentence(:"invitation.revoke", %{"reason" => "expired"}),
    do: gettext("Removed an expired invitation, sending a new one")

  defp sentence(:"invitation.revoke", %{"reason" => "undelivered"}),
    do: gettext("Withdrew an invitation that could not be delivered")

  defp sentence(:"invitation.revoke", _details), do: gettext("Revoked an invitation")
  defp sentence(:"invitation.accept", _details), do: gettext("Accepted an invitation")

  defp sentence(:"audit.prune", _details),
    do: gettext("Deleted the activity older than the instance keeps")

  defp sentence(:"workspace.rename", _details), do: gettext("Renamed the workspace")
  defp sentence(:"access_key.create", _details), do: gettext("Created an access key")

  defp sentence(:"access_key.rotate", %{"change" => "previous_retired"}),
    do: gettext("Retired an access key's previous secret")

  defp sentence(:"access_key.rotate", _details), do: gettext("Rotated an access key")
  defp sentence(:"access_key.revoke", _details), do: gettext("Revoked an access key")
  defp sentence(:"run.close", _details), do: gettext("Closed a run")
  defp sentence(:"retention.edit", _details), do: gettext("Changed how long runs are kept")
  defp sentence(_policy, %{"change" => "rule_added"}), do: gettext("Added a policy rule")
  defp sentence(_policy, %{"change" => "rule_changed"}), do: gettext("Changed a policy rule")
  defp sentence(_policy, %{"change" => "rule_removed"}), do: gettext("Removed a policy rule")
  defp sentence(_policy, %{"change" => "rule_locked"}), do: gettext("Locked a policy rule")
  defp sentence(_policy, %{"change" => "rule_unlocked"}), do: gettext("Unlocked a policy rule")
  defp sentence(_policy, %{"change" => "mode_changed"}), do: gettext("Changed the policy's mode")

  defp sentence(_policy, %{"change" => "rerendered"}),
    do: gettext("Rendered the run configurations again")

  defp sentence(:"security_policy.edit", _details), do: gettext("Changed the policy")
  defp sentence(_action, _details), do: gettext("Made a change")

  # What was acted on, as it is called now.
  defp subject(entry, action, names, scope, workspace) do
    id = entry.subject_id

    case entry.subject_kind do
      "organisation" ->
        text(scope.organisation.name)

      "workspace"
      when action in [
             :"security_policy.edit",
             :"security_policy.lock",
             :"security_policy.set_mode"
           ] ->
        text(
          gettext("Baseline of %{workspace}",
            workspace: (workspace && workspace.name) || gettext("n/a")
          )
        )

      "workspace" ->
        text((workspace && workspace.name) || gettext("n/a"))

      "membership" ->
        case names.users[(entry.details || %{})["user_id"]] do
          nil -> text(gettext("Former member"))
          email -> text(email)
        end

      "invitation" ->
        text(gettext("An invitation"))

      "access_key" ->
        case names.access_keys[id] do
          %{label: label} when is_binary(label) and label != "" -> text(label)
          %{key_id: key_id} -> %{text: key_id, mono: true, href: nil}
          nil -> text(gettext("An access key"))
        end

      "run" ->
        case names.runs[id] do
          nil ->
            text(gettext("A run"))

          run_id ->
            href =
              workspace && Features.on?(scope, :observability) &&
                ~p"/#{scope.organisation}/#{workspace}/runs/#{run_id}"

            %{text: String.slice(run_id, 0, 8), mono: true, href: href || nil}
        end

      "target" ->
        case names.targets[id] do
          nil -> text(gettext("A target"))
          target -> %{text: target, mono: true, href: nil}
        end

      "rule" ->
        text(gettext("A policy rule"))

      _other ->
        text(gettext("n/a"))
    end
  end

  defp text(text), do: %{text: text, mono: false, href: nil}

  # The change in a few words: what was, and what is.
  defp change(action, before, after_, _details)
       when action in [:"organisation.rename", :"workspace.rename"],
       do: from_to(before["name"], after_["name"])

  defp change(:"member.change_level", before, after_, _details),
    do: from_to(level(before["level"]), level(after_["level"]))

  defp change(action, _before, %{"level" => level}, _details)
       when action in [:"member.invite", :"invitation.accept"],
       do: as_level(level)

  defp change(action, %{"level" => level}, _after, _details)
       when action in [:"member.remove", :"invitation.revoke"],
       do: as_level(level)

  defp change(:"access_key.create", _before, %{"key_id" => key_id}, _details),
    do: [{:m, key_id}]

  defp change(:"run.close", before, after_, _details),
    do: from_to(state(before["state"]), state(after_["state"]))

  defp change(:"retention.edit", before, after_, _details) do
    parts =
      for {field, label} <- [
            {"events_retention_days", gettext("Events")},
            {"log_retention_days", gettext("Log output")}
          ],
          Map.has_key?(after_, field) or Map.has_key?(before, field) do
        rich_gettext("%{what}: %{from} → %{to}",
          what: label,
          from: days(before[field]),
          to: days(after_[field])
        )
      end

    parts
  end

  defp change(:"audit.prune", _before, _after, %{"removed" => removed} = details) do
    rich_ngettext(
      "%{number} entry older than %{days}",
      "%{number} entries older than %{days}",
      removed,
      number: Format.number(removed),
      days: days(details["retention_days"])
    )
  end

  defp change(_policy, before, after_, %{"change" => "mode_changed"} = details),
    do: Enum.reject([from_to(before["mode"], after_["mode"]), version(details)], &is_nil/1)

  defp change(_policy, _before, _after, %{"change" => _change, "subject" => subject} = details)
       when is_binary(subject),
       do: Enum.reject([[{:m, subject}], version(details)], &is_nil/1)

  defp change(_policy, _before, _after, %{"change" => _change} = details), do: version(details)

  defp change(_action, _before, _after, _details), do: nil

  # The version of the run configuration the change left in force.
  defp version(%{"version" => version}) when is_integer(version),
    do: gettext("Now v%{version}", version: version)

  defp version(_details), do: nil

  defp from_to(from, to) when is_binary(from) and is_binary(to),
    do: rich_gettext("%{from} → %{to}", from: from, to: to)

  defp from_to(_from, _to), do: nil

  defp as_level("owner"), do: gettext("As an owner")
  defp as_level("member"), do: gettext("As a member")
  defp as_level(_level), do: nil

  defp level("owner"), do: gettext("Owner")
  defp level("member"), do: gettext("Member")
  defp level(other), do: other

  defp state(nil), do: nil
  defp state(state), do: state_label(state)

  defp days(nil), do: gettext("Forever")

  defp days(n) when is_integer(n),
    do: ngettext("%{number} day", "%{number} days", n, number: Format.number(n))

  defp days(_other), do: gettext("n/a")
end
