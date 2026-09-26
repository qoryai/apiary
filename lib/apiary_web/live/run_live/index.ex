defmodule ApiaryWeb.RunLive.Index do
  @moduledoc """
  The runs of the workspace (`docs/design/brief-runs.md`, re1): one row per run with its
  state, what it worked on, where and for how long, and its denials; grouped by target, by
  task or not at all; filtered by state, target, task, runtime, host, time range and
  denials. Every filter, the grouping and the page are query parameters, read through
  `Apiary.Runs.Filters`: a value it does not know is dropped and the URL rewritten.

  Live through the workspace's topic. A run on the page changes in place, by its DOM id;
  changes are collected and applied at most every 250 ms, and the rows are a keyed
  comprehension, so only the rows that changed are sent. A new
  run that the filters return is never inserted under the reader: the summary line gains
  "1 new run", said politely to a screen reader, which asks again when the reader follows it. Whether a running run has gone quiet is
  decided here, on a 5 s timer and on every change, never in the browser.

  The page is loaded off the socket's process (`start_async`): the first render is the
  table's skeleton, later ones keep what is on screen until the new page arrives.

  The runs are the record (`observability`). A target's group links to its policy only
  where the instance has `security`; without it the group has no such link (decision 0070).
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :observability
  on_mount {ApiaryWeb.Access, :"run.read"}

  alias Apiary.Access

  alias Apiary.AccessKeys
  alias Apiary.Runs
  alias Apiary.Runs.Filters

  @quiet_tick 5_000
  @summary_window 1_000
  # Closed's tooltip in the State menu: what the state means and where it is counted.
  @closed_menu_tip [
    gettext_noop("Stopped by the workspace: a member closed it after it went quiet."),
    gettext_noop("Counted with the runs that ended badly.")
  ]
  @flush_window 250

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:runs}
      width="full"
    >
      <.header>
        {gettext("Runs")}
        <:subtitle>
          {gettext("Every run the machines of this workspace have posted, as their events tell it.")}
        </:subtitle>
      </.header>

      <.notice :if={@load_error} kind={:error} class="max-w-[80ch]">
        <span id="runs-error">
          {gettext(
            "The runs could not be loaded. Reload the page; if it keeps happening, the server log has the reason."
          )}
        </span>
      </.notice>

      <div
        :if={!@load_error && !first_run?(@summary, @filters)}
        class="grid grid-cols-[minmax(0,1fr)] gap-6"
      >
        <.filter_bar
          id="runs-filters"
          clear={Filters.any?(@filters) && page_path(@current_scope, Filters.clear(@filters))}
        >
          <.filter
            name="state"
            label={gettext("State")}
            multiple
            value={@filters.states}
            value_label={family_words(@filters.states)}
            options={state_options(@facets)}
            groups={state_groups()}
            tips={state_tips()}
            remove={page_path(@current_scope, Filters.put(@filters, states: []))}
          />
          <.filter
            name="target"
            total={facet_total(@facets, :target)}
            query={@narrow["target"]}
            label={gettext("Target")}
            value={Filters.target_value(@filters.target)}
            options={
              with_chosen(
                facet_options(@facets, :target),
                Filters.target_value(@filters.target),
                target_label(@filters.target)
              )
            }
            remove={page_path(@current_scope, Filters.put(@filters, target: nil))}
          />
          <.filter
            name="task"
            total={facet_total(@facets, :task)}
            query={@narrow["task"]}
            label={gettext("Task")}
            value={task_param(@filters.task)}
            options={
              with_chosen(
                facet_options(@facets, :task),
                task_param(@filters.task),
                task_label(@filters.task)
              )
            }
            remove={page_path(@current_scope, Filters.put(@filters, task: nil))}
          />
          <.filter
            name="runtime"
            total={facet_total(@facets, :runtime)}
            query={@narrow["runtime"]}
            label={gettext("Runtime")}
            value={@filters.runtime}
            options={
              with_chosen(facet_options(@facets, :runtime), @filters.runtime, @filters.runtime)
            }
            remove={page_path(@current_scope, Filters.put(@filters, runtime: nil))}
          />
          <.filter
            name="host"
            total={facet_total(@facets, :host)}
            query={@narrow["host"]}
            label={gettext("Host")}
            value={@filters.host}
            options={with_chosen(facet_options(@facets, :host), @filters.host, @filters.host)}
            remove={page_path(@current_scope, Filters.put(@filters, host: nil))}
          />
          <.filter
            name="since"
            label={gettext("Started")}
            value={range_value(@filters)}
            value_label={Filters.range_label(@filters)}
            options={for {label, value} <- Filters.ranges(), do: {label, value, nil}}
            dates={
              %{
                from: @filters.from && Date.to_iso8601(@filters.from),
                to: @filters.to && Date.to_iso8601(@filters.to)
              }
            }
            remove={
              page_path(@current_scope, Filters.put(@filters, since: "all", from: nil, to: nil))
            }
          />
          <.filter_toggle
            name="denials"
            label={gettext("Has denials")}
            icon="hero-no-symbol-micro"
            pressed={@filters.denials}
            patch={page_path(@current_scope, Filters.put(@filters, denials: !@filters.denials))}
          />
          <:trailing>
            <.segments id="runs-group" label={gettext("Group by")}>
              <:segment
                :for={
                  {label, value} <- [
                    {gettext("Target"), "target"},
                    {gettext("Task"), "task"},
                    {gettext("None"), "none"}
                  ]
                }
                patch={page_path(@current_scope, Filters.put(@filters, group: value))}
                pressed={@filters.group == value}
              >
                {label}
              </:segment>
            </.segments>
          </:trailing>
        </.filter_bar>

        <div id="runs-summary" class="q-summary">
          <span :if={@summary}><.rich text={summary_runs(@summary, @filters.group)} /></span>
          <span :if={@summary && @summary.alive > 0}>
            <.rich text={
              rich_ngettext("%{number} alive", "%{number} alive", @summary.alive,
                number: {:b, Format.number(@summary.alive)}
              )
            } />
          </span>
          <span :if={@summary && @summary.ended_well > 0}>
            <.rich text={
              rich_ngettext("%{number} ended well", "%{number} ended well", @summary.ended_well,
                number: {:b, Format.number(@summary.ended_well)}
              )
            } />
          </span>
          <span :if={@summary && @summary.ended_badly > 0}>
            <.rich text={
              rich_ngettext("%{number} ended badly", "%{number} ended badly", @summary.ended_badly,
                number: {:b, Format.number(@summary.ended_badly)}
              )
            } />
          </span>
          <span :if={@summary && @summary.with_denials > 0}>
            <.rich text={
              rich_ngettext("%{number} with denials", "%{number} with denials", @summary.with_denials,
                number: {:b, Format.number(@summary.with_denials)}
              )
            } />
          </span>
          <span :if={!@summary} class="skeleton q-skel w-56"></span>
          <%!-- Never followed for the reader: a screen reader's cursor leaves focus on the
          body, which looks like "nothing focused". The link is shown and said politely. --%>
          <span id="runs-new-status" role="status" aria-live="polite">
            <.link :if={MapSet.size(@new_ids) > 0} id="runs-new" phx-click="show_new" href="#">
              {ngettext("%{number} new run", "%{number} new runs", MapSet.size(@new_ids),
                number: Format.number(MapSet.size(@new_ids))
              )}
            </.link>
          </span>
          <span class="text-faint">{gettext("Updated as batches land")}</span>
        </div>

        <.runs_table
          :if={@listing == nil || @listing.runs != []}
          id="runs"
          scope={@current_scope}
          groups={@groups}
          group_by={@filters.group}
          facts={@facts}
          quiet_ids={@quiet_ids}
          loading={@listing == nil}
          connections_path={&connections_path(@current_scope, &1)}
          security={@security}
        />

        <.empty_state
          :if={@listing && @listing.runs == [] && @summary}
          icon="hero-funnel"
          tone="neutral"
          title={empty_title(@filters)}
        >
          <span id="runs-hidden">
            {hidden_sentence(@summary.workspace_runs)}
          </span>
          <:actions>
            <.button
              :if={Filters.any?(@filters)}
              id="runs-clear"
              patch={page_path(@current_scope, Filters.clear(@filters))}
            >
              {gettext("Clear filters")}
            </.button>
            <.button
              :if={!Filters.any?(@filters)}
              id="runs-all-time"
              patch={page_path(@current_scope, Filters.put(@filters, since: "all"))}
            >
              {gettext("Show every run")}
            </.button>
          </:actions>
        </.empty_state>

        <div
          :if={@listing && @listing.runs != []}
          class="flex flex-wrap items-center justify-between gap-3"
        >
          <p id="runs-footer" class="max-w-[80ch] text-[12.5px] text-faint">
            {ngettext(
              "Showing %{shown} of %{total}.",
              "Showing %{shown} of %{total}.",
              @listing.total,
              shown: Format.number(length(@listing.runs)),
              total: Format.number(@listing.total)
            )}
            <.rich text={
              rich_gettext(
                "A run's state comes from its events alone: a run that stops posting is %{lost}, never assumed finished.",
                lost: {:b, gettext("lost"), "font-medium"}
              )
            } />
          </p>
          <div :if={@listing.pages > 1} class="flex items-center gap-2">
            <.button
              id="runs-previous"
              patch={page_path(@current_scope, %{@filters | page: @listing.page - 1})}
              disabled={@listing.page <= 1}
            >
              {gettext("Previous")}
            </.button>
            <.button
              id="runs-next"
              patch={page_path(@current_scope, %{@filters | page: @listing.page + 1})}
              disabled={@listing.page >= @listing.pages}
            >
              {gettext("Next")}
            </.button>
          </div>
        </div>
      </div>

      <.notice :if={@dropped != []} kind={:warning} class="max-w-[80ch]">
        <span id="runs-dropped">{dropped_sentence(@dropped)}</span>
      </.notice>

      <div :if={!@load_error && first_run?(@summary, @filters)} class="grid gap-4">
        <.empty_state :if={!@has_keys} icon="hero-play-circle" title={gettext("No runs yet")}>
          {gettext(
            "A run appears here when a machine with an access key of this workspace starts one."
          )}
          {gettext(
            "Create a key, paste its server block into the runner file on the machine, and start a run."
          )}
          <:actions>
            <.button
              id="runs-create-key"
              variant="primary"
              navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys/new"}
            >
              {gettext("Create an access key")}
            </.button>
          </:actions>
        </.empty_state>
        <.empty_state :if={@has_keys} icon="hero-play-circle" title={gettext("No runs yet")}>
          {gettext("No machine has posted a run to this workspace yet.")}
          {gettext("The server block to paste into the runner file is on the access keys page.")}
          <:actions>
            <.button
              id="runs-go-to-keys"
              navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/keys"}
            >
              {gettext("Go to access keys")}
            </.button>
          </:actions>
        </.empty_state>
        <.listening :if={@has_keys}>{gettext("Listening for the first run.")}</.listening>
      </div>
    </Layouts.app>
    """
  end

  ## The table (rd8)

  attr :id, :string, required: true
  attr :groups, :list, required: true
  attr :group_by, :string, required: true
  attr :facts, :map, required: true
  attr :quiet_ids, :any, required: true
  attr :loading, :boolean, default: false

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :connections_path, :any, required: true
  attr :security, :boolean, required: true

  defp runs_table(assigns) do
    assigns = assign(assigns, :columns, if(assigns.group_by == "none", do: 8, else: 7))

    ~H"""
    <div
      class="overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs"
      tabindex="0"
      role="region"
      aria-label={table_name(@group_by)}
      aria-busy={to_string(@loading)}
    >
      <table id={@id} class="table q-runs" phx-hook="RunGroups" role="table">
        <thead role="rowgroup">
          <tr role="row">
            <th scope="col" role="columnheader">{gettext("State")}</th>
            <th scope="col" role="columnheader">
              {if @group_by == "task", do: gettext("Target"), else: gettext("Run")}
            </th>
            <th :if={@group_by == "none"} scope="col" role="columnheader">{gettext("Target")}</th>
            <th scope="col" role="columnheader">{gettext("Runtime")}</th>
            <th scope="col" role="columnheader">{gettext("Host")}</th>
            <th scope="col" role="columnheader">{gettext("Started")}</th>
            <th scope="col" role="columnheader" class="q-num">{gettext("Duration")}</th>
            <th scope="col" role="columnheader" class="q-num">{gettext("Denials")}</th>
          </tr>
        </thead>
        <tbody :if={@loading} id={"#{@id}-loading"} role="rowgroup">
          <tr :for={n <- 1..8} role="row" class="q-skel-row" aria-hidden="true">
            <td><span class="skeleton q-skel w-16"></span></td>
            <td>
              <span class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-40", else: "w-28")]}></span>
            </td>
            <td :if={@group_by == "none"}><span class="skeleton q-skel w-32"></span></td>
            <td><span class="skeleton q-skel w-24"></span></td>
            <td><span class="skeleton q-skel w-16"></span></td>
            <td><span class="skeleton q-skel w-24"></span></td>
            <td><span class="skeleton q-skel ml-auto w-14"></span></td>
            <td><span class="skeleton q-skel ml-auto w-5"></span></td>
          </tr>
        </tbody>
        <tbody
          :for={group <- @groups}
          role="rowgroup"
          id={"#{@id}-group-#{group_id(group)}"}
          data-group={group.kind != :none && group_storage_key(@group_by, group)}
          phx-mounted={JS.ignore_attributes(["data-collapsed"])}
        >
          <tr :if={group.kind != :none} class="q-group" role="row">
            <td colspan={@columns} role="cell">
              <.group_header
                scope={@scope}
                group={group}
                facts={@facts[group.key]}
                connections_path={@connections_path}
                security={@security}
              />
            </td>
          </tr>
          <.run_row
            :for={run <- group.runs}
            :key={run.id}
            scope={@scope}
            run={run}
            group_by={@group_by}
            quiet={MapSet.member?(@quiet_ids, run.id)}
          />
        </tbody>
      </table>
    </div>
    """
  end

  attr :group, :map, required: true
  attr :facts, :any, default: nil

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :connections_path, :any, required: true
  attr :security, :boolean, required: true

  defp group_header(assigns) do
    facts = assigns.facts || %{runs: length(assigns.group.runs), alive: 0, denials: 0}
    assigns = assign(assigns, facts: facts, words: group_aria(assigns.group, facts))

    ~H"""
    <div class="q-group-in">
      <button
        type="button"
        data-group-toggle
        aria-expanded="true"
        aria-label={@words}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-chevron-right-micro" class="q-chev size-4" />
        <%= case @group.kind do %>
          <% :target -> %>
            <span class="q-system">{@group.system}</span>
            <span class="q-path">{@group.path}</span>
          <% :unassigned -> %>
            <span class="q-path q-plain">{gettext("Unassigned")}</span>
            <span class="q-system q-plain">{gettext("no system or target label")}</span>
          <% :task -> %>
            <span class="q-path q-plain">{@group.title}</span>
          <% :no_task -> %>
            <span class="q-path q-plain">{gettext("No task")}</span>
            <span class="q-system q-plain">{gettext("no task label")}</span>
        <% end %>
      </button>
      <span class="q-g-meta">
        <span>{group_runs(@facts)}</span>
        <span :if={@facts.alive > 0} class="q-opt">{alive_words(@facts.alive)}</span>
        <span :if={@facts.denials > 0} class="q-opt">{denial_words(@facts.denials)}</span>
        <.link
          :if={@group.kind == :target}
          navigate={@connections_path.(@group.key)}
          class="q-opt"
          aria-label={
            gettext("Connections of %{system} %{path}", system: @group.system, path: @group.path)
          }
        >
          {gettext("Connections")}
        </.link>
        <.link
          :if={@security && @group.kind == :target && group_target_id(@group)}
          navigate={
            ApiaryWeb.ConnectionLive.Rules.target_policy_path(@scope, group_target_id(@group))
          }
          class="q-g-policy"
          aria-label={
            gettext("Policy of %{system} %{path}", system: @group.system, path: @group.path)
          }
        >
          {gettext("Policy")}
        </.link>
      </span>
    </div>
    """
  end

  # The target's row id, from any of the group's runs: they share it.
  defp group_target_id(%{runs: [%{target_id: id} | _]}) when is_binary(id), do: id
  defp group_target_id(_group), do: nil

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :run, :map, required: true
  attr :group_by, :string, required: true
  attr :quiet, :boolean, default: false

  defp run_row(assigns) do
    assigns = assign(assigns, :pending?, assigns.run.state == "pending")

    ~H"""
    <tr id={"run-#{@run.run_id}"} class="q-row" role="row">
      <td class="q-c-state" role="cell">
        <.run_state
          state={@run.state}
          exit_code={@run.exit_code}
          signal={@run.signal}
          quiet_for={if @quiet, do: quiet_for(@run) || 0}
          quiet_since={heard_at(@run)}
          interval={beat(@run)}
          closed_at={@run.closed_at}
        />
      </td>
      <td class="q-c-run" role="cell">
        <div class="q-run-cell">
          <.link
            navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{@run.run_id}"}
            class="q-rowlink truncate"
          >
            <.run_lead run={@run} group_by={@group_by} />
          </.link>
          <span>
            {short_id(@run.run_id)}{if !@pending? && is_nil(@run.task),
              do: " · " <> gettext("no task label")}
          </span>
        </div>
      </td>
      <td :if={@group_by == "none"} class="q-c-target font-mono text-[12.5px]" role="cell">
        <span :if={@run.target_system && @run.target_path}>
          <span class="text-faint">{@run.target_system}/</span>{@run.target_path}
        </span>
        <span :if={!(@run.target_system && @run.target_path)} class="font-sans text-faint">
          {gettext("n/a")}
        </span>
      </td>
      <td class="q-c-rt q-meta" role="cell">
        <span :if={@run.runtime}>{@run.runtime} {@run.runtime_version}</span>
        <span :if={!@run.runtime} class="text-faint">{gettext("n/a")}</span>
      </td>
      <td class="q-c-host q-meta" role="cell">
        <span :if={@run.host} class="font-mono text-[12.5px]">{@run.host}</span>
        <span :if={!@run.host} class="text-faint">{gettext("n/a")}</span>
      </td>
      <td class="q-c-when q-meta" role="cell">
        <.relative_time at={@run.started_at || @run.inserted_at} />
      </td>
      <td class="q-c-dur q-num q-meta" role="cell">
        <.run_duration run={@run} quiet={@quiet} />
      </td>
      <td class="q-c-den q-num" role="cell">
        <span :if={@run.denied_count == 0} class="q-zero">0</span>
        <span :if={@run.denied_count > 0} class="q-denials">
          <.icon name="hero-no-symbol-micro" class="size-3" />{Format.number(@run.denied_count)}
          <span class="sr-only">{gettext("denied")}</span>
        </span>
      </td>
    </tr>
    """
  end

  attr :run, :map, required: true
  attr :group_by, :string, required: true

  # The first line of the run cell: the task; grouped by task, the target; without
  # either, the command as it was typed; for a run that has only pinged, that fact.
  defp run_lead(%{run: %{state: "pending", started_at: nil}} = assigns) do
    ~H"""
    <b class="!font-normal text-faint">{gettext("Ping only")}</b>
    """
  end

  defp run_lead(%{group_by: "task", run: %{target_system: system, target_path: path}} = assigns)
       when is_binary(system) and is_binary(path) do
    ~H"""
    <b class="font-mono text-[12.5px]"><span class="font-normal text-faint">{@run.target_system}/</span>{@run.target_path}</b>
    """
  end

  defp run_lead(%{run: %{task: task}, group_by: group_by} = assigns)
       when is_binary(task) and group_by != "task" do
    ~H"""
    <b>{@run.task}</b>
    """
  end

  defp run_lead(assigns) do
    ~H"""
    <b class="font-mono text-[12.5px] !font-normal" title={command_line(@run)}>
      {middle_or_end(command_line(@run))}
    </b>
    """
  end

  attr :run, :map, required: true
  attr :quiet, :boolean, required: true

  defp run_duration(%{run: %{state: state}} = assigns)
       when state in ~w(succeeded failed timed_out) do
    ~H"""
    <.duration ms={@run.duration_ms} />
    """
  end

  defp run_duration(%{run: %{state: "running"}, quiet: false} = assigns) do
    {seconds, at} = elapsed(assigns.run)
    assigns = assign(assigns, seconds: seconds, at: at)

    ~H"""
    <.duration elapsed_seconds={@seconds} elapsed_at={@at} />
    """
  end

  defp run_duration(%{run: %{state: "pending"}} = assigns) do
    ~H"""
    <.duration />
    """
  end

  defp run_duration(assigns) do
    ~H"""
    <.duration at_least_seconds={@run.elapsed_seconds} />
    """
  end

  ## Lifecycle

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Runs.subscribe(scope)
      Process.send_after(self(), :quiet_tick, @quiet_tick)
    end

    {:ok,
     assign(socket,
       page_title: gettext("Runs"),
       filters: %Filters{},
       listing: nil,
       groups: [],
       facts: %{},
       facets: %{},
       summary: nil,
       new_ids: MapSet.new(),
       quiet_ids: MapSet.new(),
       loaded_at: DateTime.utc_now(),
       load_error: false,
       summary_window: :closed,
       dropped: [],
       narrow: %{},
       has_keys: AccessKeys.list_access_keys(scope) != [],
       security: Access.can?(scope, :"security_policy.read", scope.workspace)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Filters.parse(params, :runs)

    # The path's organisation and workspace are not filters.
    if Filters.to_params(filters) == Map.drop(params, ["org", "workspace"]) do
      {:noreply, socket |> keep_dropped() |> assign(:filters, filters) |> load()}
    else
      # A value the page does not know was dropped: the address bar says what is shown,
      # and the page says that the link was not read in full.
      {:noreply,
       socket
       |> assign(:dropped, filters.dropped)
       |> put_private(:rewrote, true)
       |> push_patch(
         to: page_path(socket.assigns.current_scope, %{filters | dropped: []}),
         replace: true
       )}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     push_patch(socket,
       to: page_path(socket.assigns.current_scope, Filters.change(socket.assigns.filters, params))
     )}
  end

  # What the reader types in a menu narrows that menu's options on the server: the menu
  # holds the fifty most frequent values, never all of them.
  def handle_event("narrow", %{"_filter" => name, "q" => q}, socket)
      when name in ~w(target task runtime host) and is_binary(q) do
    %{current_scope: scope, filters: filters} = socket.assigns
    narrow = Map.put(socket.assigns.narrow, name, String.slice(q, 0, 256))

    {:noreply,
     socket
     |> assign(:narrow, narrow)
     |> start_async(:facets, fn ->
       ApiaryWeb.Lingo.with_locale(scope, fn ->
         %{
           filters: filters,
           narrow: narrow,
           facets: Runs.run_facets(scope, filters, narrow: narrow)
         }
       end)
     end)}
  end

  def handle_event("narrow", _params, socket), do: {:noreply, socket}

  def handle_event("show_new", _params, socket) do
    filters = socket.assigns.filters

    if filters.page == 1,
      do: {:noreply, load(socket)},
      else:
        {:noreply,
         push_patch(socket, to: page_path(socket.assigns.current_scope, %{filters | page: 1}))}
  end

  @impl true
  def handle_async(:load, {:ok, %{filters: filters} = loaded}, socket) do
    if filters == socket.assigns.filters do
      {:noreply,
       socket
       |> assign(
         listing: loaded.listing,
         groups: Runs.group_runs(loaded.listing.runs, filters.group),
         facts: loaded.facts,
         facets: loaded.facets,
         summary: loaded.summary,
         loaded_at: loaded.at,
         new_ids: MapSet.new(),
         load_error: false
       )
       |> assign_quiet()}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:load, {:exit, _reason}, socket) do
    {:noreply, assign(socket, load_error: true)}
  end

  def handle_async(:facets, {:ok, %{filters: filters, narrow: narrow, facets: facets}}, socket) do
    if filters == socket.assigns.filters and narrow == socket.assigns.narrow,
      do: {:noreply, assign(socket, :facets, facets)},
      else: {:noreply, socket}
  end

  def handle_async(:facets, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:summary, {:ok, %{filters: filters} = loaded}, socket) do
    if filters == socket.assigns.filters,
      do: {:noreply, assign(socket, summary: loaded.summary, facts: loaded.facts)},
      else: {:noreply, socket}
  end

  def handle_async(:summary, {:exit, _reason}, socket), do: {:noreply, socket}

  # Changes are collected and applied at most once every @flush_window: at once for the
  # first, then together when the window ends. A busy workspace costs this page one render
  # and at most one query a window, however many batches land; nothing is read again for a
  # row, the message carries the run.
  @impl true
  def handle_info({:run_changed, run}, socket) do
    changed = Map.put(socket.private[:changed] || %{}, run.id, run)
    socket = put_private(socket, :changed, changed)

    case socket.private[:flush_window] do
      :open ->
        {:noreply, socket}

      _closed ->
        Process.send_after(self(), :flush_runs, @flush_window)
        {:noreply, socket |> put_private(:flush_window, :open) |> flush()}
    end
  end

  def handle_info(:flush_runs, socket) do
    if map_size(socket.private[:changed] || %{}) > 0 do
      Process.send_after(self(), :flush_runs, @flush_window)
      {:noreply, flush(socket)}
    else
      {:noreply, put_private(socket, :flush_window, :closed)}
    end
  end

  def handle_info(:quiet_tick, socket) do
    Process.send_after(self(), :quiet_tick, @quiet_tick)
    {:noreply, assign_quiet(socket)}
  end

  def handle_info(:summary_window_over, socket) do
    case socket.assigns.summary_window do
      :dirty -> {:noreply, socket |> assign(:summary_window, :closed) |> touch_summary()}
      _open -> {:noreply, assign(socket, :summary_window, :closed)}
    end
  end

  defp flush(%{assigns: %{listing: nil}} = socket), do: put_private(socket, :changed, %{})

  defp flush(socket) do
    %{listing: listing, filters: filters, current_scope: scope, new_ids: new_ids} =
      socket.assigns

    changed = socket.private[:changed] || %{}
    socket = put_private(socket, :changed, %{})
    on_page = MapSet.new(listing.runs, & &1.id)

    # Only a run that did not exist when the page was read can be new to it; an old run
    # of another page changing costs nothing. One query for all of them.
    candidates =
      for {id, run} <- changed,
          not MapSet.member?(on_page, id),
          not MapSet.member?(new_ids, id),
          DateTime.compare(run.inserted_at, socket.assigns.loaded_at) == :gt,
          do: id

    new = if candidates == [], do: [], else: Runs.matching_ids(scope, filters, candidates)

    socket =
      if Enum.any?(changed, fn {id, _run} -> MapSet.member?(on_page, id) end) do
        runs = Enum.map(listing.runs, &Map.get(changed, &1.id, &1))

        socket
        |> assign(listing: %{listing | runs: runs}, groups: Runs.group_runs(runs, filters.group))
        |> assign_quiet()
      else
        socket
      end

    socket = if new == [], do: socket, else: assign(socket, :new_ids, Enum.into(new, new_ids))

    if map_size(changed) > 0, do: touch_summary(socket), else: socket
  end

  # The summary and the groups' facts are counted again at once on the first change, then
  # at most once a second while changes keep coming.
  defp touch_summary(%{assigns: %{summary_window: :closed}} = socket) do
    %{current_scope: scope, filters: filters, groups: groups} = socket.assigns
    keys = Enum.map(groups, & &1.key)
    Process.send_after(self(), :summary_window_over, @summary_window)

    socket
    |> assign(:summary_window, :open)
    |> start_async(:summary, fn ->
      ApiaryWeb.Lingo.with_locale(scope, fn ->
        %{
          filters: filters,
          summary: Runs.summarise_runs(scope, filters),
          facts: Runs.group_facts(scope, filters, keys)
        }
      end)
    end)
  end

  defp touch_summary(socket), do: assign(socket, :summary_window, :dirty)

  defp load(socket) do
    %{current_scope: scope, filters: filters} = socket.assigns

    if connected?(socket) do
      narrow = socket.assigns.narrow

      # The task does not inherit the process's locale: what `Apiary.Runs` names in it
      # (a group without a task, a facet's option) is named in the workspace's domain all
      # the same.
      start_async(socket, :load, fn ->
        ApiaryWeb.Lingo.with_locale(scope, fn ->
          now = DateTime.utc_now()
          listing = Runs.page_runs(scope, filters, now)
          keys = listing.runs |> Enum.map(&Runs.group_key(&1, filters.group)) |> Enum.uniq()

          %{
            filters: filters,
            at: now,
            listing: listing,
            summary: Runs.summarise_runs(scope, filters, now),
            facts: Runs.group_facts(scope, filters, keys, now),
            facets: Runs.run_facets(scope, filters, now: now, narrow: narrow)
          }
        end)
      end)
    else
      socket
    end
  end

  # Assigned only when the set changes: the seconds tick in the browser.
  defp assign_quiet(%{assigns: %{listing: nil}} = socket), do: socket

  defp assign_quiet(socket) do
    now = DateTime.utc_now()

    quiet =
      for run <- socket.assigns.listing.runs, quiet_for(run, now), into: MapSet.new(), do: run.id

    if quiet == socket.assigns.quiet_ids, do: socket, else: assign(socket, :quiet_ids, quiet)
  end

  ## Words and paths

  # The notice of a rewritten link stays for the view the rewrite led to, and goes with the
  # reader's next change.
  defp keep_dropped(socket) do
    if socket.private[:rewrote],
      do: put_private(socket, :rewrote, false),
      else: assign(socket, :dropped, [])
  end

  defp dropped_sentence(names) do
    pngettext(
      "plain",
      "The link's %{names} filter could not be read, so it is not applied.",
      "The link's %{names} filters could not be read, so they are not applied.",
      length(names),
      names: Enum.join(names, ", ")
    )
  end

  defp page_path(scope, %Filters{} = filters),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/runs?#{Filters.to_params(filters)}"

  defp connections_path(scope, {system, path}) do
    ~p"/#{scope.organisation}/#{scope.workspace}/connections?#{Filters.target_params(system, path)}"
  end

  # No run in the workspace at all, and nothing narrowing the view: the first-run states.
  defp first_run?(%{workspace_runs: 0}, filters), do: not Filters.any?(filters)
  defp first_run?(_summary, _filters), do: false

  defp hidden_sentence(n) do
    ngettext("%{number} run is hidden by them.", "%{number} runs are hidden by them.", n,
      number: Format.number(n)
    )
  end

  defp table_name("target"), do: gettext("Runs, grouped by target")
  defp table_name("task"), do: gettext("Runs, grouped by task")
  defp table_name(_none), do: gettext("Runs, not grouped")

  # The summary's first item: the runs, and what they are in when the page is grouped by
  # it, the numbers in bold.
  defp summary_runs(summary, group) do
    runs = rich_run_words(summary.runs)

    cond do
      group != "task" && summary.targets > 0 ->
        rich_gettext("%{runs} in %{targets}",
          runs: runs,
          targets:
            rich_ngettext("%{number} target", "%{number} targets", summary.targets,
              number: {:b, Format.number(summary.targets)}
            )
        )

      group == "task" && summary.tasks > 0 ->
        rich_gettext("%{runs} in %{tasks}",
          runs: runs,
          tasks:
            rich_ngettext("%{number} task", "%{number} tasks", summary.tasks,
              number: {:b, Format.number(summary.tasks)}
            )
        )

      true ->
        runs
    end
  end

  defp rich_run_words(n),
    do: rich_ngettext("%{number} run", "%{number} runs", n, number: {:b, Format.number(n)})

  # A group's runs, and its targets when it has more than one.
  defp group_runs(%{targets: targets} = facts) when is_integer(targets) and targets > 1,
    do:
      gettext("%{runs} in %{targets}",
        runs: run_words(facts.runs),
        targets: target_words(targets)
      )

  defp group_runs(facts), do: run_words(facts.runs)

  defp run_words(n),
    do: ngettext("%{number} run", "%{number} runs", n, number: Format.number(n))

  defp target_words(n),
    do: ngettext("%{number} target", "%{number} targets", n, number: Format.number(n))

  defp alive_words(n),
    do: ngettext("%{number} alive", "%{number} alive", n, number: Format.number(n))

  defp denial_words(n),
    do: ngettext("%{number} denial", "%{number} denials", n, number: Format.number(n))

  defp group_aria(group, facts) do
    name =
      case group.kind do
        :target -> "#{group.system} #{group.path}"
        _other -> group.title
      end

    [
      name,
      run_words(facts.runs),
      facts.alive > 0 && alive_words(facts.alive),
      facts.denials > 0 && denial_words(facts.denials)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  # Never an index: the group's own key, as a token no two labels can be made to share.
  defp group_id(%{key: key}), do: dom_token(key)

  defp group_storage_key(group_by, %{key: key}) do
    "#{group_by}:#{dom_token(key)}"
  end

  # Every state, in its family's order, with its count under the other filters; a state no
  # run has shows without a count, so the menu keeps its shape from one view to the next.
  defp state_options(facets) do
    counts =
      for {state, _value, count} <- facet_options(facets, :state), into: %{}, do: {state, count}

    for family <- Filters.families(),
        state <- family.states,
        do: {state_label(state), state, counts[state]}
  end

  # The menu's headings: the family's checkbox reads its label and is named for a screen
  # reader as the sentence of the brief ("Every alive state").
  defp state_groups do
    for family <- Filters.families() do
      %{
        key: family.key,
        label: family.label,
        name: family_checkbox_name(family.key),
        states: family.states
      }
    end
  end

  defp family_checkbox_name("alive"), do: gettext("Every alive state")
  defp family_checkbox_name("ended_well"), do: gettext("Every state that ended well")
  defp family_checkbox_name("ended_badly"), do: gettext("Every state that ended badly")

  defp state_tips do
    tip = Enum.map_join(@closed_menu_tip, " ", &Gettext.gettext(ApiaryWeb.Gettext, &1))
    %{"closed" => tip}
  end

  # The chosen states as family words when they are whole families ("ended badly", "alive,
  # ended badly"); nil otherwise, and the chip reads the states as it does for any filter.
  defp family_words(states) do
    case Filters.families_of(states) do
      nil -> nil
      keys -> Enum.map_join(keys, ", ", &family_word/1)
    end
  end

  defp family_word("alive"), do: gettext("alive")
  defp family_word("ended_well"), do: gettext("ended well")
  defp family_word("ended_badly"), do: gettext("ended badly")

  # The funnel empty state's title: the family in the sentence when the states are exactly
  # one family ("No runs ended badly in the last 7 days."), the plain title otherwise.
  defp empty_title(%Filters{states: states} = filters) do
    case Filters.families_of(states) do
      [key] -> empty_family_title(key, Filters.range_phrase(filters))
      _other -> gettext("No runs match these filters")
    end
  end

  defp empty_family_title("alive", nil), do: gettext("No runs alive.")
  defp empty_family_title("ended_well", nil), do: gettext("No runs ended well.")
  defp empty_family_title("ended_badly", nil), do: gettext("No runs ended badly.")

  defp empty_family_title("alive", range),
    do: gettext("No runs alive %{range}.", range: range)

  defp empty_family_title("ended_well", range),
    do: gettext("No runs ended well %{range}.", range: range)

  defp empty_family_title("ended_badly", range),
    do: gettext("No runs ended badly %{range}.", range: range)

  defp facet_options(facets, name), do: (facets[name] || %{options: []}).options
  defp facet_total(facets, name), do: facets[name] && facets[name].total

  # A chosen value that the data no longer offers still shows in its menu, so it can be read.
  defp with_chosen(options, nil, _label), do: options || []

  defp with_chosen(options, value, label) do
    options = options || []

    if Enum.any?(options, fn {_label, v, _count} -> v == value end),
      do: options,
      else: [{label, value, 0} | options]
  end

  defp task_param(:none), do: "none"
  defp task_param(task), do: task

  defp task_label(:none), do: gettext("No task")
  defp task_label(task), do: task

  defp target_label(:none), do: gettext("Unassigned")
  defp target_label({system, path}), do: "#{system}/#{path}"
  defp target_label(nil), do: nil

  defp range_value(%Filters{from: nil, to: nil, since: "all"}), do: nil
  defp range_value(%Filters{from: nil, to: nil, since: since}), do: since
  defp range_value(%Filters{}), do: "dates"

  defp command_line(%{command: nil}), do: gettext("n/a")
  defp command_line(%{command: command, args: args}), do: Enum.join([command | args || []], " ")

  defp middle_or_end(line) do
    if String.length(line) > 48, do: String.slice(line, 0, 47) <> "…", else: line
  end
end
