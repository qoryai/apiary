defmodule ApiaryWeb.ActivityLive do
  @moduledoc """
  The organisation's audit trail, the Audit log section of the organisation's settings
  (`ApiaryWeb.SettingsComponents`): `/:org/settings/audit-log`, where `/:org/activity`, its
  path before, sends on (`ApiaryWeb.MovedController`). Every change a
  person, an access key or the instance made to what the organisation holds, newest
  first, a page of fifty at a time (`Apiary.Audit.list_entries/3`), for a reader who may
  `audit.read`.

  One row per entry: when (relative, the full time on hover), who (a person by the email
  address their account has now, "Former member" once the account is deleted; an access
  key by its label and key id; the instance as Qory), what, as a sentence, on what (and in
  which workspace; a workspace marked for deletion is named until it is purged), and a
  short before and after. Names are looked up when the page reads, never stored in the
  trail (`Apiary.Audit.names/2`). The words for each action are the describers'
  (`ApiaryWeb.Activity.Describer`): the edition's for its actions, the core's for the rest.

  The workspace (`workspace_id`: `workspace` is the path's word for a slug), the action
  and the page are query parameters; a value the page does not know is left out. The
  entries are read off the socket's process (`start_async`): the first render is the
  table's skeleton, a later read keeps what is on screen until the new page arrives.
  """
  use ApiaryWeb, :live_view
  on_mount {ApiaryWeb.Access, :"audit.read"}

  alias Apiary.{Access, Audit, Features, Organisations}
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.SettingsComponents

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
      nav={:audit_log}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:organisation}
        sections={@sections}
        current={:audit_log}
        measure="list"
        title={gettext("Audit log")}
      >
        <:subtitle>
          {gettext(
            "Every change made to this organisation and its workspaces: who made it, when, and what it changed."
          )}
        </:subtitle>
        <ApiaryWeb.Extension.slot name={:activity_toolbar} scope={@current_scope} />

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
            <ApiaryWeb.Extension.slot name={:activity_filters} scope={@current_scope} />
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
            <.table id="activity" label={gettext("Audit log")} rows={@rows} row_id={&"entry-#{&1.id}"}>
              <:col :let={row} label={gettext("When")}>
                <.relative_time id={"entry-#{row.id}-time"} at={row.at} />
              </:col>
              <:col :let={row} label={gettext("Who")}>
                <.actor actor={row.actor} id={"entry-#{row.id}-actor"} />
              </:col>
              <:col :let={row} label={gettext("What")} kind="title">
                <span id={"entry-#{row.id}-action"}>{row.sentence}</span>
              </:col>
              <:col :let={row} label={gettext("Subject")}>
                <span id={"entry-#{row.id}-subject"} class="flex min-w-0 items-baseline gap-2">
                  <span class="max-w-[48ch] truncate">
                    <.link :if={row.subject.href} navigate={row.subject.href} class="hover:underline">
                      <.subject_text subject={row.subject} />
                    </.link>
                    <.subject_text :if={!row.subject.href} subject={row.subject} />
                  </span>
                  <span :if={row.place} class="q-faint truncate">
                    {gettext("in %{workspace}", workspace: row.place)}
                  </span>
                </span>
              </:col>
              <:col :let={row} label={gettext("Change")} kind="faint" from="md">
                <span id={"entry-#{row.id}-change"} class="grid">
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
      </SettingsComponents.layout>
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
          <span class="truncate">{@actor.text}</span>
          <span :if={@actor.you?} class="q-faint">{gettext("you")}</span>
        <% :gone -> %>
          <span class="q-faint truncate">{@actor.text}</span>
        <% :access_key -> %>
          <.icon name="hero-key" class="size-3.5 flex-none text-faint" />
          <span :if={@actor.text} class="truncate">{@actor.text}</span>
          <span class="q-faint q-mono">{@actor.detail}</span>
        <% :instance -> %>
          <.icon name="hero-cpu-chip" class="size-3.5 flex-none text-faint" />
          <span>{@actor.text}</span>
      <% end %>
    </span>
    """
  end

  attr :subject, :map, required: true

  defp subject_text(%{subject: %{mono: true}} = assigns) do
    ~H"""
    <span class="font-mono text-[12px]">{@subject.text}</span>
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
       page_title: gettext("Audit log") <> " · " <> gettext("Organisation settings"),
       sections: SettingsComponents.sections(scope, :organisation),
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
      do: ~p"/#{scope.organisation}/settings/audit-log",
      else: ~p"/#{scope.organisation}/settings/audit-log?#{query}"
  end

  # The actions a reader can filter by: those that change something, of the features the
  # instance has, that every describer offers the reader, each by the words of its filter.
  defp action_options(scope) do
    describers = Describer.describers()

    for action <- Audit.audited_actions(),
        feature_on?(scope, Access.feature(action)),
        Enum.all?(describers, & &1.offered?(scope, action)),
        do: {Atom.to_string(action), action_label(describers, action)}
  end

  defp feature_on?(_scope, nil), do: true
  defp feature_on?(scope, feature), do: Features.on?(scope, feature)

  defp action_label(describers, action),
    do: first(describers, :label, [action]) || Atom.to_string(action)

  ## One row

  # `workspaces` are those in use, whose pages a subject links to; a workspace marked for
  # deletion is named, from `names`, and linked to nowhere. The words are the describers'
  # (`ApiaryWeb.Activity.Describer`): the edition's first, then the core's.
  defp row(entry, names, scope, workspaces) do
    describers = Describer.describers()
    action = Audit.action(entry)
    workspace = entry.workspace_id && workspaces[entry.workspace_id]
    place = entry.workspace_id && names.workspaces[entry.workspace_id]

    %{
      id: entry.id,
      at: entry.inserted_at,
      actor: actor_of(entry, names, scope),
      sentence: first(describers, :sentence, [action, entry, names]) || gettext("Made a change"),
      subject:
        first(describers, :subject, [entry, action, names, scope, workspace]) ||
          Describer.text(gettext("n/a")),
      place: if(entry.subject_kind != "workspace", do: place),
      change:
        describers
        |> first(:change, [action, entry.before || %{}, entry.after || %{}, entry.details || %{}])
        |> List.wrap()
    }
  end

  # The first answer of the describers that is not nil.
  defp first(describers, fun, args),
    do: Enum.find_value(describers, &apply(&1, fun, args))

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
end
