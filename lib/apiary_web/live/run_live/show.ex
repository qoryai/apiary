defmodule ApiaryWeb.RunLive.Show do
  @moduledoc """
  One run, read as a record, on a work surface: a header from `run.started`, `run.exited`
  and the policy applied (the title; what the run says it is about, when it says; the state
  and the run's facts, with the ⋯ menu), Details, and three tabs that are three live
  actions of this one LiveView, so that a tab is a `patch` and the header stays: Timeline,
  Terminal, Network access (`/runs/:run_id/network`, the live action `:connections`; the
  old `/connections` path sends on here).
  Details is one element, after the header and before the tabs: the right column beside
  every tab from 1280 px, Terminal too, and below that a "Details" button under the header
  that opens the same element in place (`docs/ui.md`, The run page). The old
  `/runs/:run_id/details` (the live action `:details`) lands on the Timeline with Details
  open.

  `:run_id` in the URL is the run's number (`Apiary.Runs.Run`, `number`); the node's run
  id, the run's subject, is on Details. An address with the run's `public_id`, `rn_…`, the
  id the API gives, is patched to the number's, for a run of the caller's workspace alone.
  A number the caller's workspace does not have renders the not-found state, whatever
  run that number is in another workspace, and so does an `rn_` id of another workspace's
  run and the node's run id in the URL.

  The timeline is a stream over a window of the run's items (300 on mount, 200 more at
  either end, never more than 600 in the DOM); the layout of the whole run comes from
  `Apiary.Runs.Record.timeline/2`, so rails are right at a window's edge. The page follows
  the run's topic: projections are coalesced to one read per 250 ms, a changed item is
  updated in place, and a new item is inserted only while the reader is at the live end;
  away from it the pill counts. No log byte crosses the socket: the terminal reads
  `/:org/:workspace/runs/:run_id/log`, and the LiveView only says how far the log has
  advanced.

  The run, its terminal, its timeline and its connections as Forager reported them are
  the record (`observability`). What the policy made of it is `security`'s, and an
  instance without it shows none of it: no policy in the header or on Details, no drift,
  no version, no policy applied on the timeline, no reason by rule or mode, no Allow or
  Deny. The page then neither reads the policy nor follows its topic, and a rule event
  that arrives all the same is dropped before anything is looked up.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :observability
  on_mount {ApiaryWeb.Access, :"run.read"}

  import ApiaryWeb.RunPageComponents
  import ApiaryWeb.PolicyComponents, only: [short_digest: 1]
  import ApiaryWeb.TargetComponents, only: [state_mark: 1, target_path: 2]
  import ApiaryWeb.PreparationComponents, only: [run_list: 1]

  alias Apiary.Access
  alias Apiary.Dispatches
  alias Apiary.Dispatches.{DispatchRun, MachineLogs}
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes
  alias Apiary.Policy
  alias Apiary.Policy.RequiredHosts
  alias Apiary.Runs
  alias Apiary.Runs.{Preparation, Record, Run}
  alias Apiary.Targets
  alias Apiary.Runs.Record.{Overview, Timeline}
  alias ApiaryWeb.ConnectionLive.Rules
  alias ApiaryWeb.RunLive.Concealed
  alias ApiaryWeb.MachineTypeWords
  alias ApiaryWeb.PreparationComponents
  alias ApiaryWeb.RunComponents
  alias ApiaryWeb.TranscriptComponents

  @window 300
  @page 200
  @max_dom 600
  @coalesce_ms 250
  @quiet_tick_ms 5_000
  @announce_every_ms 10_000
  @max_versions 20
  # What changes a settled preparation: a step's start or exit, as a step can run after
  # the session; a later session's start, for its Run the agent; a session's result and
  # exit, for its Finished; and the run's exit, which cancels a step left open.
  # The session's exit makes no timeline item, so `Record.extend_timeline/5` adds it to
  # the rows a flush reads.
  @preparation_events ~w(dev.qory.run.step_started dev.qory.run.step_exited dev.qory.run.exited
                           dev.qory.session.started dev.qory.runtime.result dev.qory.session.exited)
  @impl true
  def render(%{run: nil} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:runs}
      width="work"
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/runs"}>
        {gettext("Runs")}
      </:crumb>
      <:crumb :if={missing_number(@loaded_id)}>
        {gettext("Run %{run}", run: missing_number(@loaded_id))}
      </:crumb>

      <.empty_state
        tone="neutral"
        icon="hero-magnifying-glass"
        heading="h1"
        title={gettext("This run is not in this workspace")}
      >
        {gettext("The link may be for another workspace, or the run number is mistyped.")}
        <:actions>
          <.button navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/runs"}>
            {gettext("Back to runs")}
          </.button>
        </:actions>
      </.empty_state>
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
      nav={:runs}
      width="work"
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/runs"}>
        {gettext("Runs")}
      </:crumb>
      <:crumb patch={@tab != :timeline && tab_path(@current_scope, @run, :timeline)}>
        {run_title(@run)}
      </:crumb>
      <div id="run-announcer" class="sr-only" aria-live="polite" aria-atomic="true">
        {@announcement}
      </div>

      <%!-- In this order at every width: the header, the Details button, Details, the
           tabs and the tab's body. The CSS places them: from 1280 px Details is the right
           column beside every tab and the button is not shown; below it the button opens
           Details in place, above the tabs. --%>
      <div id="run-page" class="q-run">
        <header class="q-run-head">
          <h1 id="run-title" tabindex="-1">{run_title(@run)}</h1>
          <%!-- The title the run gave, under the header that names it by its number. --%>
          <p :if={shown_run_title(@run)} id="run-given-title" class="q-run-about">
            <.external_text text={shown_run_title(@run)} />
          </p>
          <.about_header
            run={@run}
            scope={@current_scope}
            work_item={@work_item}
            work_item_link={Access.can?(@current_scope, :"work_item.read", @current_scope.workspace)}
          />
          <div class="q-run-sub">
            <div class="q-run-meta-wrap">
              <p id="run-meta" class="q-run-meta">
                <%!-- A state its starter's outcome set, unlike what the exit said: the
                      sentence in the place of the state's word. --%>
                <span
                  :if={outcome_sentence(@run)}
                  id="run-state"
                  class={["q-sdot", "q-sdot-#{@run.state}"]}
                >
                  <i aria-hidden="true"></i><span id="run-outcome">{outcome_sentence(@run)}</span>
                </span>
                <.state_mark
                  :if={!outcome_sentence(@run)}
                  id="run-state"
                  state={Run.shown_state(@run)}
                  quiet={@quiet_for != nil}
                  word
                />
                <.end_reason run={@run} id="run-reason" />
                <.alive
                  :if={Run.shown_state(@run) in ~w(pending running)}
                  state={@run.state}
                  last_heartbeat_at={@run.last_heartbeat_at}
                  last_event_at={@run.last_event_at}
                  interval={beat(@run)}
                  quiet={@quiet_for != nil}
                  run={@run}
                />
                <span :if={program_exit(@run)}>{program_exit(@run)}</span>
                <.link
                  :if={target_link(@target_page) && shown_target_path(@run)}
                  id="run-target"
                  navigate={target_link(@target_page)}
                  class="q-run-target"
                >
                  <.target_name
                    path={@run.target_path}
                    system={@target_shared && @run.target_system}
                  />
                </.link>
                <span
                  :if={!target_link(@target_page) && shown_target_path(@run)}
                  id="run-target"
                >
                  <.target_name path={@run.target_path} system={@run.target_system} />
                </span>
                <span :if={@run.runtime} id="run-runtime">
                  <.external_text text={
                    join([shown_sent(@run.runtime), shown_sent(@run.runtime_version)])
                  } />
                </span>
                <.ran_on run={@run} id="run-host" class="font-mono text-[12.5px]" />
                <span :if={@run.started_at} id="run-started-at">
                  <span class="sr-only">{gettext("Started")}</span>
                  <.relative_time id="run-started" at={@run.started_at} />
                </span>
                <%!-- A run that was refused never ran, and a queued run has not started: no
                      duration to say, not even n/a. --%>
                <span :if={!Run.refused?(@run) and !Run.queued?(@run)} id="run-duration-line"><.run_duration
                  run={@run}
                  quiet={@quiet_for != nil}
                /></span>
                <.link
                  :if={@counts.denied > 0}
                  id="run-denied"
                  patch={tab_path(@current_scope, @run, :connections, %{"decision" => "denied"})}
                  class="q-run-denied"
                >
                  <.icon name="hero-no-symbol-micro" class="size-3.5" />
                  {ngettext("%{number} denied", "%{number} denied", @counts.denied,
                    number: Format.number(@counts.denied)
                  )}
                </.link>
              </p>
              <p :if={@ending} id="run-why" class="q-run-why">
                <span class="q-run-why-k">{gettext("How it ended")}</span>
                <%!-- A step's ending has no item to jump to, and wraps whole. --%>
                <span
                  :if={@ending.text}
                  class={["q-run-why-t", is_nil(@ending.seq) && "q-run-why-whole"]}
                  title={@ending.seq && @ending.text}
                >{@ending.text}</span>
                <.link
                  :if={@ending.seq}
                  id="run-why-jump"
                  patch={
                    tab_path(
                      @current_scope,
                      @run,
                      :timeline,
                      Map.put(@timeline_query, "seq", Integer.to_string(@ending.seq))
                    )
                  }
                  class="q-link"
                >
                  {gettext("Jump to it")}
                </.link>
              </p>
              <p :if={why_it_waits(@preparation)} id="run-waits" class="q-run-why">
                <span class="q-run-why-k">{gettext("Why it waits")}</span>
                <span class="q-run-why-t q-run-why-whole">
                  <.rich text={why_it_waits(@preparation)} />
                </span>
              </p>
            </div>
            <div class="q-run-actions">
              <%!-- Why Copy diagnostics failed, outside the menu that closes on the click,
                   kept until the next click (the CopyToClipboard hook writes it). --%>
              <p
                id="run-menu-status"
                role="status"
                class="max-w-[48ch] text-right text-xs text-base-content/80"
                phx-update="ignore"
              >
              </p>
              <.run_menu
                run={@run}
                diagnostics={
                  Access.can?(@current_scope, :"run.read_log", @run) &&
                    ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/runs/#{@run}/diagnostics"
                }
                log={
                  Access.can?(@current_scope, :"run.read_log", @run) &&
                    ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/runs/#{@run}/log"
                }
              />
            </div>
          </div>

          <.notice :if={@security && @in_force} kind={:warning} class="mt-3 max-w-[100ch]">
            <span id="run-behind">
              <b>{gettext("This run is behind the policy in force.")}</b>
              <.rich
                phx-no-format
                text={
                  rich_gettext(
                    "It last reported %{reported}; %{in_force} is in force (%{since}).",
                    reported: {:part, :reported},
                    in_force: {:part, :in_force},
                    since: {:part, :since}
                  )
                }
              >
                  <:part name={:reported}>{version_words(@reported_version)}<span :if={@digests.reported}> <span class="font-mono text-xs">{short_digest(@digests.reported)}</span></span></:part>
                  <:part name={:in_force}>{version_words(@in_force)} <span class="font-mono text-xs">{short_digest(@in_force.digest)}</span></:part>
                  <:part name={:since}><.relative_time id="run-behind-since" at={@in_force.rendered_at} /></:part>
                </.rich>
              {if @reported_version,
                do:
                  gettext(
                    "A run reloads at its next heartbeat; until it does, it decides by %{version}.",
                    version: version_words(@reported_version)
                  ),
                else:
                  gettext(
                    "A run reloads at its next heartbeat; until it does, it decides by what it holds."
                  )}
            </span>
            <div class="mt-1">
              <.link
                id="run-behind-diff"
                navigate={behind_path(@current_scope, @target, @reported_version, @in_force)}
                class="q-link"
              >
                {if comparable?(@reported_version, @in_force),
                  do:
                    gettext("What changed between v%{from} and v%{to} of the %{label}",
                      from: @reported_version.n,
                      to: @in_force.n,
                      label: @in_force.label
                    ),
                  else: gettext("Open %{version}", version: version_words(@in_force))}
              </.link>
            </div>
          </.notice>
        </header>

        <%!-- Below 1280 px: a disclosure, not a modal; it pushes the tabs down. Closed
             on load (open when an old Details link landed here), kept across the tabs.
             Escape closes it and keeps the focus on it. --%>
        <button
          id="run-details-toggle"
          type="button"
          class="q-run-dtoggle"
          aria-expanded={to_string(@details_open)}
          aria-controls="run-details"
          phx-click={JS.toggle_attribute({"aria-expanded", "true", "false"})}
          phx-keydown={
            JS.set_attribute({"aria-expanded", "false"}, to: "#run-details-toggle")
            |> JS.focus(to: "#run-details-toggle")
          }
          phx-key="Escape"
        >
          <span class="q-run-dtoggle-text">{gettext("Details")}</span>
          <.icon name="hero-chevron-down-micro" class="q-run-dtoggle-i size-4" />
        </button>

        <.details_rail
          scope={@current_scope}
          run={@run}
          target_page={target_link(@target_page)}
          policy={@policy}
          session_id={@session_id}
          quiet={@quiet_for != nil}
          tips={@tips}
          version={@reported_version}
          default_policy={@default_policy}
          in_force={@in_force}
          digests={@digests}
          security={@security}
          instance={@instance}
          machine_type={machine_type(@preparation)}
        />

        <%!-- A thing's tabs (`page_tabs/1`), each `run-tab-<key>`. --%>
        <.page_tabs id="run-tab" label={gettext("Run")} current={@tab}>
          <:tab
            key={:timeline}
            patch={tab_path(@current_scope, @run, :timeline, @timeline_query)}
            icon="hero-queue-list"
            count={timeline_count(@overview)}
          >
            {gettext("Timeline")}
          </:tab>
          <:tab
            :if={Access.can?(@current_scope, :"run.read_log", @run)}
            key={:terminal}
            patch={tab_path(@current_scope, @run, :terminal)}
            icon="hero-command-line"
          >
            {gettext("Terminal")}
          </:tab>
          <:tab
            key={:connections}
            patch={tab_path(@current_scope, @run, :connections)}
            icon="hero-globe-alt"
            count={connections_count(@counts)}
            tone={@counts.denied > 0 && "error"}
          >
            {gettext("Network access")}
          </:tab>
        </.page_tabs>

        <div class={["q-run-body", @tab == :terminal && "q-run-body-term"]}>
          <%= cond do %>
            <% not @loaded -> %>
              <div
                id="run-loading"
                class="grid gap-3"
                aria-busy="true"
                aria-label={gettext("Reading the record")}
              >
                <span :for={width <- ~w(w-2/3 w-1/2 w-3/5 w-2/5 w-1/2)} class={["q-skel", width]}></span>
              </div>
            <% @run.state == "pending" and @index.items == [] and @tab == :timeline and
                 PreparationComponents.shown?(@preparation, @clean_up) -> %>
              <.run_list
                preparation={@preparation}
                machine_log={@machine_log}
                alive={alive?(@run)}
                clean_up={@clean_up}
                run_state={Run.shown_state(@run)}
                wall={is_binary(@run.wall)}
              />
              <%!-- A queued run's empty Timeline under its steps: it has not pinged, so the
                    sentence that Forager pinged is left out. --%>
              <.limits
                :if={Run.queued?(@run)}
                reason={:not_started}
                variant="empty"
                sentence={false}
              />
            <% @run.state == "pending" and @index.items == [] -> %>
              <.limits
                reason={:not_started}
                variant="empty"
                registered={!!@run.registered_at}
                sentence={!Run.queued?(@run)}
              />
            <% @run.events_pruned_at && @index.items == [] && @tab == :timeline -> %>
              <.limits reason={:pruned} variant="empty" at={@run.events_pruned_at} />
            <% @tab == :timeline -> %>
              <.timeline_tab {assigns} />
            <% @tab == :terminal and Access.can?(@current_scope, :"run.read_log", @run) -> %>
              <.terminal_tab
                scope={@current_scope}
                run={@run}
                log={@log}
                stream={@streams.items}
                lines={@tab_count}
                texts={@index.texts}
                turn_ends={Enum.any?(@index.items, &(&1.kind == :turn_finished))}
                earlier={@earlier}
                later={@later}
                target={@focused && "e-#{@focused}"}
                subagents={TranscriptComponents.subagents(@index.items, @index.alive)}
              />
            <% @tab == :connections -> %>
              <.connections_tab
                scope={@current_scope}
                run={@run}
                policy={@policy}
                connections={@connections}
                counts={@counts}
                decision={@decision}
                acts={@acts}
                panel={@rule_panel}
                version={@reported_version}
                in_force={@in_force}
                security={@security}
              />
            <% true -> %>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # The ⋯ menu of the header: what the reader may take away from the run, as the run is.
  attr :run, :map, required: true

  attr :log, :any,
    required: true,
    doc: "the log's path, or false for a reader who may not read it"

  attr :diagnostics, :any,
    required: true,
    doc: "the path of the run's diagnostics document, as the reader may read it"

  defp run_menu(assigns) do
    ~H"""
    <div
      id="run-menu"
      class="dropdown dropdown-end"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id="run-menu-button"
        type="button"
        class="btn btn-sm btn-square"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("More actions")}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-ellipsis-horizontal-micro" class="size-4" />
      </button>
      <ul
        class="menu menu-sm dropdown-content right-0 top-full z-30 mt-1.5 w-56"
        role="menu"
        aria-label={gettext("More actions")}
      >
        <li role="none">
          <button
            id="run-menu-copy"
            type="button"
            role="menuitem"
            tabindex="-1"
            phx-hook="CopyToClipboard"
            data-copy={@run.public_id}
            data-copied-words={gettext("Copied")}
            data-menu-close
          >
            <.icon name="hero-link" class="size-4" /> {gettext("Copy run id")}
            <span class="sr-only" aria-live="polite"></span>
          </button>
        </li>
        <%!-- The run's diagnostics document, read when the reader clicks and copied as
             it is (`ApiaryWeb.RunDiagnosticsController`): the run, with its log, for a chat
             or an issue. Only for a reader of the run's log, which the document has. --%>
        <li :if={@diagnostics} role="none">
          <button
            id="run-menu-diagnostics"
            type="button"
            role="menuitem"
            tabindex="-1"
            phx-hook="CopyToClipboard"
            data-copy-url={@diagnostics}
            data-status="#run-menu-status"
            data-copied-words={gettext("Copied")}
            data-failed-network={
              gettext("Check your connection, then copy again. The diagnostics did not arrive.")
            }
            data-failed-gone={
              gettext(
                "Reload the page, then copy again. This run, or your access to its log, is gone."
              )
            }
            data-failed-signed-out={gettext("Sign in again, then copy again. Your session ended.")}
            data-failed-server={
              plain_text(
                rich_gettext(
                  "Copy again in a minute. If it fails again, %{contact_support} with run %{run}. Qory Apiary could not build the diagnostics.",
                  contact_support: ApiaryWeb.Support.plain(mid_sentence: true),
                  run: @run.public_id
                )
              )
            }
            data-failed-clipboard={
              gettext(
                "Allow this page to use the clipboard, then copy again. The browser did not allow the copy."
              )
            }
            data-menu-close
          >
            <.icon name="hero-clipboard-document-list" class="size-4" /> {gettext("Copy diagnostics")}
          </button>
        </li>
        <li :if={@log} role="none">
          <a
            id="run-menu-raw"
            href={@log}
            target="_blank"
            rel="noopener"
            role="menuitem"
            tabindex="-1"
          >
            <.icon name="hero-document-text" class="size-4" /> {gettext("Raw log")}
            <.icon name="hero-arrow-top-right-on-square-micro" class="ml-auto size-3.5 text-faint" />
          </a>
        </li>
        <li :if={@log} role="none">
          <a
            id="run-menu-download"
            href={@log <> "?download=1"}
            download
            role="menuitem"
            tabindex="-1"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Download log")}
          </a>
        </li>
      </ul>
    </div>
    """
  end

  ## The tabs

  defp timeline_tab(assigns) do
    ~H"""
    <div
      id="run-timeline"
      class="q-run-tl grid gap-4"
      data-live={to_string(alive?(@run))}
    >
      <div class="q-tl-bar" role="group" aria-label={gettext("Lanes")}>
        <.lane
          :for={lane <- lane_chips(@index, @lane)}
          lane={lane}
          pressed={is_nil(@lane) or @lane == lane.id}
          patch={
            tab_path(@current_scope, @run, :timeline, lane_query(@timeline_query, @lane, lane.id))
          }
        />
        <span
          :if={@index.lane_count + 1 > length(@index.lanes)}
          id="more-lanes"
          class="text-xs text-faint"
        >
          {gettext("and %{number} more",
            number: Format.number(@index.lane_count + 1 - length(@index.lanes))
          )}
        </span>
        <span
          :if={length(@index.lanes) > 1}
          class="tooltip q-tip-wide text-faint"
          tabindex="0"
          data-tip={@tips.lane}
          aria-label={gettext("lane (%{tip})", tip: @tips.lane)}
        >
          <.icon name="hero-information-circle-micro" class="size-4" />
        </span>
        <span class="flex-1"></span>
        <.shortcuts />
        <button
          type="button"
          id="toggle-connections"
          phx-click={
            JS.patch(tab_path(@current_scope, @run, :timeline, cx_query(@timeline_query, @cx)))
          }
          aria-pressed={to_string(@cx)}
          class="btn btn-ghost btn-sm q-cx-toggle"
        >
          <span class="q-toggle" data-on={@cx} aria-hidden="true"></span>
          {gettext("Connections inline")}
        </button>
      </div>

      <div :if={@unread > 0} id="unread-events">
        <.notice>
          {ngettext(
            "%{number} event has arrived and is being read.",
            "%{number} events have arrived and are being read.",
            @unread,
            number: Format.number(@unread)
          )}
        </.notice>
      </div>

      <%!-- The notes of the run: above the Timeline, which follows the **Run** list when
      the page has one, or in the agent session each is about (`run_notes/5`). --%>
      <.limits
        :for={{reason, runtime} <- run_notes(@limit, @run, @index, @preparation, @clean_up)}
        :if={!PreparationComponents.shown?(@preparation, @clean_up)}
        reason={reason}
        runtime={shown_sent(runtime)}
        registered={!!@run.registered_at}
        only_result={reason == :vm_wall and only_result?(@index)}
        terminal={Access.can?(@current_scope, :"run.read_log", @run)}
      />

      <.background_tasks
        background={concealed_tasks(@index.background, @current_scope, @run)}
        ended={!alive?(@run)}
      />

      <.run_list
        :if={PreparationComponents.shown?(@preparation, @clean_up)}
        preparation={@preparation}
        machine_log={@machine_log}
        alive={alive?(@run)}
        clean_up={@clean_up}
        run_state={Run.shown_state(@run)}
        wall={is_binary(@run.wall)}
        session_open={@focused && row_session(@preparation, focused_row(@index, @focused))}
      >
        <:session
          :let={session}
          :if={PreparationComponents.session_group?(@preparation, @clean_up)}
        >
          <.limits
            :for={{reason, runtime} <- session_notes(@limit, @run, @index, @preparation, session)}
            reason={reason}
            runtime={shown_sent(runtime)}
            only_result={reason == :vm_wall and only_result?(@index)}
            terminal={Access.can?(@current_scope, :"run.read_log", @run)}
          />
          <.timeline_list {assigns} session={session} />
        </:session>
      </.run_list>

      <.limits
        :for={{reason, runtime} <- run_notes(@limit, @run, @index, @preparation, @clean_up)}
        :if={PreparationComponents.shown?(@preparation, @clean_up)}
        reason={reason}
        runtime={shown_sent(runtime)}
        registered={!!@run.registered_at}
        only_result={reason == :vm_wall and only_result?(@index)}
        terminal={Access.can?(@current_scope, :"run.read_log", @run)}
      />

      <.timeline_list
        :if={!PreparationComponents.session_group?(@preparation, @clean_up)}
        {assigns}
      />
      <%!-- The items of a session that never ran its agent, after the list, as on a run
      whose only session's wall failed. --%>
      <.timeline_list
        :if={PreparationComponents.session_group?(@preparation, @clean_up) and unrun?(@preparation)}
        {assigns}
        session={:after_list}
      />

      <.live_end
        live={alive?(@run)}
        events={@run.event_count}
        last_sequence={projected_through(@run)}
        last_event_at={@run.last_event_at}
      />

      <.new_items
        id="new-events"
        count={@new_events}
        noun="event"
        target="#timeline"
        on_click="show_new"
      />
    </div>
    """
  end

  # The Timeline tab's count: the rows the Timeline lists with every subagent open
  # (`assign_overview/1`), the allowed connections only while Connections inline is on. It
  # is the same on every tab; none while the Timeline lists no row.
  defp timeline_count([]), do: nil
  defp timeline_count(rows), do: length(rows)

  # The run's Timeline: inside Run the agent of the **Run** list once the session started
  # (`ApiaryWeb.PreparationComponents.session_group?/2`), else after the list. In a run of
  # more than one agent session, each Run the agent has the Timeline of its session,
  # `session` (the sequence of its start): the items of the stream that belong to it
  # (`Apiary.Runs.Preparation.session_of/2`). The first session's has the id `timeline`, a
  # later one's its place: `timeline-2`. Load earlier is in the Timeline of the window's
  # first item, Load newer in that of its last, and the item `?seq=` points at is the
  # target of its Timeline alone. Each is placed by its session number (`row_session/2`),
  # so sessions that overlap in time keep their items apart. The items of a session that
  # never ran its agent (`Apiary.Runs.Preparation`'s `unrun`) are in a Timeline after the
  # list, `session` `:after_list`, with the id `timeline-after-list`.
  defp timeline_list(assigns) do
    sessions = (assigns.preparation && Map.get(assigns.preparation, :sessions)) || []
    session = assigns[:session]
    split = session != nil and (match?([_, _ | _], sessions) or unrun?(assigns.preparation))
    owner = if session == :after_list, do: nil, else: session
    owns = &(not split or row_session(assigns.preparation, &1) == owner)

    assigns =
      assign(assigns,
        list_id: timeline_id(sessions, session),
        keep: if(split, do: owns),
        owns_first: owns.(window_row(assigns, assigns.win_first)),
        owns_last: owns.(window_row(assigns, assigns.win_last)),
        owns_target: assigns.focused != nil and owns.(focused_row(assigns.index, assigns.focused))
      )

    ~H"""
    <.timeline
      id={@list_id}
      keep={@keep}
      stream={@streams.items}
      rails={@index.rails}
      started_at={@run.started_at}
      seq_path={&tab_path(@current_scope, @run, :timeline, Map.put(@timeline_query, "seq", &1))}
      target={@owns_target && "e-#{@focused}"}
      isolate={@lane}
      connections={@cx}
      terminal_path={
        Access.can?(@current_scope, :"run.read_log", @run) &&
          (&tab_path(@current_scope, @run, :terminal, %{"seq" => &1}))
      }
      earlier={if @owns_first, do: @earlier, else: 0}
      later={
        if @owns_last, do: max(@later - if(@new_events > 0, do: @new_count, else: 0), 0), else: 0
      }
      earlier_events={@earlier_events}
      later_events={max(@later_events - @new_events, 0)}
      until={if @later > 0, do: until_seq(@win_last)}
      security={@security}
      legend={@index.items != []}
    />
    """
  end

  defp shortcuts(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <button
        type="button"
        tabindex="0"
        class="btn btn-ghost btn-xs btn-square"
        aria-label={gettext("Keyboard shortcuts of the timeline")}
      >
        <.icon name="hero-question-mark-circle" class="size-4" />
      </button>
      <div tabindex="0" class="dropdown-content q-keys" role="note">
        <p class="font-medium">{gettext("With focus in the timeline")}</p>
        <dl>
          <dt><kbd>j</kbd> <kbd>k</kbd></dt>
          <dd>{gettext("next and previous item")}</dd>
          <dt><kbd>{gettext("Enter")}</kbd></dt>
          <dd>{gettext("open or close the item")}</dd>
          <dt><kbd>o</kbd></dt>
          <dd>{gettext("open every tool call")}</dd>
          <dt><kbd>x</kbd> <kbd>{gettext("Shift")}</kbd>+<kbd>x</kbd></dt>
          <dd>{gettext("next and previous denied connection")}</dd>
          <dt><kbd>g</kbd> <kbd>e</kbd></dt>
          <dd>{gettext("the live end")}</dd>
          <dt><kbd>g</kbd> <kbd>t</kbd></dt>
          <dd>{gettext("the top")}</dd>
          <dt><kbd>c</kbd></dt>
          <dd>{gettext("copy the item's link")}</dd>
        </dl>
      </div>
    </div>
    """
  end

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :run, :map, required: true
  attr :log, :map, required: true
  attr :stream, :any, required: true, doc: "the window of the Transcript's items"
  attr :lines, :integer, required: true, doc: "how many items the Transcript has"
  attr :texts, :integer, required: true, doc: "how many text items the run has"
  attr :turn_ends, :boolean, required: true, doc: "whether the run has a Turn finished"
  attr :earlier, :integer, required: true
  attr :later, :integer, required: true
  attr :target, :string, default: nil
  attr :subagents, :map, default: %{}, doc: "the run's subagents, by lane"

  # The Transcript, drawn from the run's events, and Raw, the log. Pruning removes the log
  # before the events, so a Transcript can outlive its Raw: the box then has the
  # Transcript alone, under the notice that the log was pruned.
  defp terminal_tab(assigns) do
    ~H"""
    <div>
      <.limits
        :if={@log.chunks == 0 and @lines == 0 and is_nil(@run.log_pruned_at)}
        reason={:no_log}
        variant="empty"
        live={alive?(@run)}
      />
      <.limits
        :if={@log.chunks == 0 and @lines == 0 and @run.log_pruned_at}
        reason={if @run.events_pruned_at, do: :pruned, else: :log_pruned}
        variant="empty"
        at={@run.log_pruned_at}
      />
      <.limits
        :if={@log.chunks == 0 and @lines > 0 and @run.log_pruned_at}
        reason={:log_pruned}
        at={@run.log_pruned_at}
      />
      <.terminal
        :if={@log.chunks > 0 or @lines > 0}
        raw={@log.chunks > 0}
        view="transcript"
        id="terminal"
        src={~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{@run}/log"}
        script={~p"/assets/js/terminal.js"}
        stylesheet={~p"/assets/js/terminal.css"}
        streams={@log.streams}
        live={alive?(@run)}
        bytes={@log.bytes}
        chunks={@log.chunks}
        through={@log.through}
        cols={@run.terminal_cols}
        rows={@run.terminal_rows}
      >
        <:subagents :if={@lines > 0 and map_size(@subagents) > 0}>
          <TranscriptComponents.subagents_bar
            count={map_size(@subagents)}
            running={Enum.count(@subagents, fn {_lane, sub} -> sub.state == :running end)}
          />
        </:subagents>
        <:transcript :if={@lines > 0}>
          <TranscriptComponents.transcript
            id="transcript"
            stream={@stream}
            earlier={@earlier}
            later={@later}
            raw={@log.chunks > 0}
            target={@target}
            results={@texts > 0 or @turn_ends}
          />
        </:transcript>
      </.terminal>
    </div>
    """
  end

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :run, :map, required: true
  attr :policy, :any, required: true
  attr :connections, :list, required: true
  attr :counts, :map, required: true
  attr :decision, :string, default: nil
  attr :acts, :map, default: nil
  attr :panel, :map, default: nil, doc: "the open panel of a row's Allow or Deny"
  attr :version, :any, default: nil
  attr :in_force, :any, default: nil
  attr :security, :boolean, required: true

  defp connections_tab(assigns) do
    ~H"""
    <div class="grid gap-4">
      <.limits :if={@counts.all == 0} reason={:no_egress} variant="empty" />
      <div :if={@counts.all > 0} class="q-filters" role="group" aria-label={gettext("Filters")}>
        <.segments id="decision" label={gettext("Decision")}>
          <:segment
            patch={tab_path(@scope, @run, :connections)}
            pressed={is_nil(@decision)}
            count={@counts.all}
          >
            {gettext("All")}
          </:segment>
          <:segment
            patch={tab_path(@scope, @run, :connections, %{"decision" => "allowed"})}
            pressed={@decision == "allowed"}
            count={@counts.allowed}
          >
            {gettext("Allowed")}
          </:segment>
          <:segment
            patch={tab_path(@scope, @run, :connections, %{"decision" => "denied"})}
            pressed={@decision == "denied"}
            count={@counts.denied}
          >
            {gettext("Denied")}
          </:segment>
        </.segments>
        <span class="flex-1"></span>
        <span class="q-summary">
          <span>
            <.rich text={
              rich_gettext("%{attempts} to %{destinations}",
                attempts:
                  rich_ngettext("%{number} attempt", "%{number} attempts", @counts.attempts,
                    number: {:b, Format.number(@counts.attempts)}
                  ),
                destinations:
                  rich_ngettext("%{number} destination", "%{number} destinations", @counts.all,
                    number: {:b, Format.number(@counts.all)}
                  )
              )
            } />
          </span>
          <span :if={@security && @policy}>
            {gettext("policy")} <b>{shown_sent(@policy.mode)}</b>
            <.scoped_version :if={@version} version={@version} />
            <span
              :if={!@version && @run.policy_digest}
              class="font-mono text-[12.5px]"
              title={shown_sent(@run.policy_digest)}
            >
              {String.slice(shown_sent(@run.policy_digest), 0, 12)}
            </span>
            <.drift
              :if={@in_force}
              id="connections-drift"
              reported={@version}
              in_force={@in_force}
              last_seq={@run.projected_sequence}
            />
          </span>
        </span>
      </div>
      <.connections_table
        :if={@counts.all > 0}
        id="run-connections"
        label={gettext("Network access of this run")}
        rows={@connections.rows}
        started_at={@run.started_at}
        acts={@acts}
        panel={@panel}
        security={@security}
      />
      <div
        :if={@connections.total > 0}
        id="connections-pages"
        class="flex flex-wrap items-center justify-between gap-3"
      >
        <p class="text-[12.5px] text-faint">
          {gettext("Showing %{shown} of %{total}.",
            shown: Format.number(length(@connections.rows)),
            total: Format.number(@connections.total)
          )}
        </p>
        <div :if={@connections.pages > 1} class="flex gap-2">
          <.button
            :if={@connections.page > 1}
            patch={
              tab_path(
                @scope,
                @run,
                :connections,
                connections_query(@decision, @connections.page - 1)
              )
            }
          >
            {gettext("Previous")}
          </.button>
          <.button
            :if={@connections.page < @connections.pages}
            patch={
              tab_path(
                @scope,
                @run,
                :connections,
                connections_query(@decision, @connections.page + 1)
              )
            }
          >
            {gettext("Next")}
          </.button>
        </div>
      </div>
      <p :if={@counts.all > 0} id="connections-footnote" class="max-w-[80ch] text-[12.5px] text-faint">
        {if @security,
          do:
            gettext(
              "Counted per host, port and path from the run's egress events. The reason and outcome are those of the last attempt. A rule added here changes what happens next; what the record already says stays as it was."
            ),
          else:
            gettext(
              "Counted per host, port and path from the run's egress events. The outcome is that of the last attempt."
            )}
      </p>
    </div>
    """
  end

  # The details of the run, one element: the right column beside every tab from 1280 px;
  # below that, the same element opened in place by the Details button, its sections as
  # cards, so the two never disagree and no id is rendered twice. Key and value lines
  # under small headings; the run's labels are its own identifiers, in mono.
  attr :scope, :map, required: true
  attr :run, :map, required: true
  attr :target_page, :string, default: nil, doc: "the path of the run's target's page"
  attr :policy, :any, required: true
  attr :session_id, :string, default: nil
  attr :quiet, :boolean, required: true
  attr :tips, :map, required: true
  attr :version, :any, default: nil
  attr :default_policy, :boolean, default: false
  attr :in_force, :any, default: nil
  attr :digests, :map, required: true
  attr :security, :boolean, required: true
  attr :instance, :any, default: nil, doc: "the run's instance's row, for its name"

  attr :machine_type, :map,
    default: nil,
    doc: "the machine type the claim answer had, its name and spec (`Apiary.Runs.Preparation`)"

  defp details_rail(assigns) do
    assigns =
      assign(assigns,
        labels: ordered_labels(assigns.run.labels, assigns.scope.workspace),
        key_shown: Apiary.Features.visible?(assigns.scope, :nodes),
        image_source: image_source(assigns.scope, assigns.run),
        # The terminal's size is the log's, as the Terminal tab is.
        terminal_size:
          assigns.run.terminal_cols && Access.can?(assigns.scope, :"run.read_log", assigns.run),
        # The command and its arguments are shown only to a reader of the log, as the
        # Terminal is.
        command_shown: Access.can?(assigns.scope, :"run.read_log", assigns.run),
        # The workflow of a queued run, as the runs list reads it: a run that started
        # shows what it runs instead.
        workflow: Run.queued?(assigns.run) && queued_workflow(assigns.scope, assigns.run)
      )

    ~H"""
    <aside id="run-details" class="q-run-rail" aria-label={gettext("Details")}>
      <h2 class="q-rail-title">{gettext("Details")}</h2>

      <.about_section run={@run} />

      <section class="q-rail-sec" aria-labelledby="rail-run">
        <h3 id="rail-run">{gettext("Run")}</h3>
        <dl id="run-facts" class="q-rail-kv">
          <dt>{gettext("State")}</dt>
          <dd>
            <.state_mark state={Run.shown_state(@run)} quiet={@quiet} word />
            <span :if={Run.shown_state(@run) == "pending"} class="q-rail-sub">
              {if @run.registered_at, do: gettext("Registered only"), else: gettext("Ping only")}
            </span>
            <.end_reason run={@run} id="rail-reason" class="q-rail-sub q-rail-sub-wrap" />
          </dd>
          <dt :if={exited?(@run)}>{gettext("Exit")}</dt>
          <dd :if={exited?(@run)} class="font-mono">{exit_value(@run)}</dd>
          <dt>{gettext("Started")}</dt>
          <dd><.clock at={@run.started_at} id="run-started-clock" /></dd>
          <%!-- A run that was refused never ran: it has no Duration row. --%>
          <dt :if={!Run.refused?(@run)}>{gettext("Duration")}</dt>
          <dd :if={!Run.refused?(@run)}>
            <.run_duration id="rail-duration" run={@run} quiet={@quiet} />
          </dd>
          <%!-- What the run's sessions reported they used; nothing while none did. The peak
          is of the memory of the machine type the claim answer had, when it had one. --%>
          <dt :if={@run.peak_memory_bytes}>{gettext("Peak memory")}</dt>
          <dd :if={@run.peak_memory_bytes} id="rail-peak-memory" class="tabular-nums">
            {peak_memory(@run.peak_memory_bytes, @machine_type)}
          </dd>
          <dt :if={@run.cpu_time_ms}>{gettext("CPU time")}</dt>
          <dd :if={@run.cpu_time_ms} id="rail-cpu-time" class="tabular-nums">
            {cpu_time(@run.cpu_time_ms)}
          </dd>
          <dt>{gettext("Runtime")}</dt>
          <dd>
            <.external_text text={@run.runtime} />{if !@run.runtime, do: na()}
            <span
              :if={@run.runtime_version}
              class="font-mono"
            ><.external_text text={@run.runtime_version} /></span>
          </dd>
          <dt>{gettext("Host")}</dt>
          <%!-- A pool's run shows its pool's name (`place_of/1`). --%>
          <%= case place_of(@run) do %>
            <% {:pool, name} -> %>
              <dd id="rail-host">{name}</dd>
            <% {:host, host} -> %>
              <dd id="rail-host" class="font-mono"><.external_text text={host} /></dd>
            <% nil -> %>
              <dd id="rail-host" class="font-mono">{na()}</dd>
          <% end %>
          <dt :if={@workflow}>{gettext("Workflow")}</dt>
          <dd :if={@workflow} id="rail-workflow"><.external_text text={@workflow} /></dd>
          <dt>
            <.term word={gettext("Wall")} standard={@tips.wall} class="q-tip-wide tooltip-right" />
          </dt>
          <dd>
            <%= cond do %>
              <% @run.wall -> %>
                <.external_text text={@run.wall} />
              <% @run.state == "pending" -> %>
                {na()}
              <% true -> %>
                <span class="tooltip q-tip-wide" tabindex="0" data-tip={@tips.no_wall}>
                  {gettext("None")}
                </span>
            <% end %>
          </dd>
          <%!-- The run's access key, where the reader is shown the nodes: their keys are the
          part `nodes` an edition may hide (`Apiary.Features.visible?/2`). --%>
          <dt :if={@key_shown}>{gettext("Key")}</dt>
          <dd :if={@key_shown}>
            <%= if Ecto.assoc_loaded?(@run.access_key) && @run.access_key do %>
              <span class="font-mono">{@run.access_key.label}</span>
              <span class="q-rail-sub font-mono">{@run.access_key.key_id}</span>
            <% else %>
              {na()}
            <% end %>
          </dd>
          <dt :if={@machine_type}>{gettext("Machine type")}</dt>
          <dd :if={@machine_type} id="rail-machine-type">
            <.rich text={MachineTypeWords.type_words(@machine_type)} />
          </dd>
          <dt :if={image_shown?(@image_source, @run)}>{gettext("Image")}</dt>
          <dd :if={image_shown?(@image_source, @run)} id="run-image-row">
            <%= case @image_source do %>
              <% source when source in [:configured, :given] -> %>
                <span id="run-image" class="font-mono" title={@run.configured_image}>
                  {@run.configured_image}
                </span>
                <span :if={source == :configured} id="run-image-source" class="q-rail-sub">
                  {gettext("Prebuilt for this target")}
                </span>
              <% source -> %>
                <span
                  id="run-image"
                  class="font-mono"
                  title={Apiary.ExternalText.line(@run.image)}
                >
                  <.external_text text={@run.image} />
                </span>
                <span :if={source == :pool_default} id="run-image-source" class="q-rail-sub">
                  {gettext("The pool's default image.")}
                </span>
            <% end %>
          </dd>
          <dt :if={@run.node_id}>{gettext("Machine or pool")}</dt>
          <dd :if={@run.node_id} id="run-node">
            <.node_name scope={@scope} node={Ecto.assoc_loaded?(@run.node) && @run.node} />
          </dd>
          <dt :if={@run.node_instance_id}>{gettext("Machine id")}</dt>
          <dd :if={@run.node_instance_id} id="run-instance">
            <span :if={@instance && @instance.name}>{@instance.name}</span>
            <span class={["font-mono", @instance && @instance.name && "q-rail-sub"]}>
              <.external_text text={@run.node_instance_id} />
            </span>
          </dd>
          <%!-- Policy and Policy in force, for a run whose policy event arrived. --%>
          <dt :if={@security && @policy}>{gettext("Policy")}</dt>
          <dd :if={@security && @policy} class="q-kv-policy">
            <.policy_value
              policy={@policy}
              digest={@run.policy_digest}
              tips={@tips}
              version={@version}
              reported={@digests.reported || @digests.applied}
              default_policy={@default_policy}
              in_force={@in_force}
              last_seq={@run.projected_sequence}
            />
          </dd>
        </dl>
      </section>

      <section :if={@labels != []} class="q-rail-sec" aria-labelledby="rail-labels">
        <h3 id="rail-labels">{gettext("Labels")}</h3>
        <dl id="run-labels" class="q-rail-kv q-rail-kv-mono">
          <%= for {key, value} <- @labels do %>
            <dt><.external_text text={to_string(key)} /></dt>
            <dd title={Apiary.ExternalText.line(to_string(value))}>
              <.link
                :if={path = label_path(@scope, @target_page, to_string(key))}
                navigate={path}
              >
                <.external_text text={to_string(value)} />
              </.link>
              <span :if={!label_path(@scope, @target_page, to_string(key))}>
                <.external_text text={to_string(value)} />
              </span>
            </dd>
          <% end %>
        </dl>
      </section>

      <section class="q-rail-sec" aria-labelledby="rail-command">
        <h3 id="rail-command">{gettext("Command")}</h3>
        <dl class="q-rail-kv">
          <dt>{gettext("Command")}</dt>
          <dd :if={!@command_shown} id="run-command">{na()}</dd>
          <dd :if={@command_shown} id="run-command" class="font-mono">
            <.external_text text={@run.command} />{if !@run.command, do: na()}
          </dd>
          <dt>{gettext("Arguments")}</dt>
          <%!-- A queued run has no arguments yet: n/a rather than none. --%>
          <dd :if={!@command_shown or Run.queued?(@run)} id="run-args">{na()}</dd>
          <dd :if={@command_shown and !Run.queued?(@run)} id="run-args" class="font-mono">
            <span :if={@run.args == []} class="font-sans text-faint">{gettext("none")}</span>
            <span
              :for={arg <- Enum.take(@run.args, 64)}
              class="q-arg"
            ><.external_text text={middle(Apiary.ExternalText.line(arg), 600)} /></span>
            <span :if={length(@run.args) > 64} class="font-sans text-faint">
              {gettext("and %{number} more", number: Format.number(length(@run.args) - 64))}
            </span>
          </dd>
          <dt>{gettext("Directory")}</dt>
          <dd class="font-mono"><.external_text text={@run.dir} />{if !@run.dir, do: na()}</dd>
          <dt>{gettext("Interactive")}</dt>
          <dd>{interactive_words(@run.interactive)}</dd>
          <dt :if={@terminal_size}>{gettext("Terminal")}</dt>
          <dd :if={@terminal_size} class="font-mono">
            {@run.terminal_cols}×{@run.terminal_rows}
          </dd>
          <dt>{gettext("Forager")}</dt>
          <dd class="font-mono"><.forager_version run={@run} /></dd>
        </dl>
      </section>

      <section class="q-rail-sec" aria-labelledby="rail-record">
        <h3 id="rail-record">{gettext("Record")}</h3>
        <dl class="q-rail-kv">
          <dt>{gettext("Run id")}</dt>
          <dd>
            <span id="run-id">{@run.public_id}</span>
            <.copy_button
              id="copy-run-id"
              target="#run-id"
              icon_only
              label={gettext("Copy the run id")}
            />
          </dd>
          <dt>{gettext("Run id on the machine")}</dt>
          <%!-- A run of the queue no claim registered, waiting or ended while it waited,
            has no run on a machine. --%>
          <dd :if={!on_machine?(@run)} id="run-node-run-id">{na()}</dd>
          <dd :if={on_machine?(@run)} id="run-node-run-id" class="font-mono">{@run.node_run_id}</dd>
          <dt>{gettext("Events")}</dt>
          <dd>
            <.rich text={
              rich_gettext("%{number}, projected through %{sequence}",
                number: Format.number(@run.event_count),
                sequence: {:m, "#" <> pad(projected_through(@run) || 0), "font-mono"}
              )
            } />
          </dd>
          <dt>{gettext("Last event")}</dt>
          <dd><.clock at={@run.last_event_at} id="last-event" /></dd>
          <dt>{gettext("Last heartbeat")}</dt>
          <dd>
            <.clock at={@run.last_heartbeat_at} id="last-heartbeat" />
            <span :if={@run.heartbeat_interval_seconds} class="q-rail-sub">
              {gettext("every %{seconds} s",
                seconds: Format.number(@run.heartbeat_interval_seconds)
              )}<span :if={@run.elapsed_seconds}> · {gettext("elapsed %{seconds} s",
                seconds: Format.number(@run.elapsed_seconds)
              )}</span>
            </span>
          </dd>
          <dt>{gettext("Exited")}</dt>
          <dd><.clock at={@run.exited_at} id="exited-at" /></dd>
          <dt :if={@run.lost_at}>{gettext("Lost")}</dt>
          <dd :if={@run.lost_at}><.clock at={@run.lost_at} id="lost-at" /></dd>
          <dt>{gettext("Session")}</dt>
          <dd class="font-mono">
            {shown_sent(@session_id) || gettext("n/a")}
          </dd>
        </dl>
      </section>
      <section :if={@security && @policy} class="q-rail-sec" aria-labelledby="rail-policy">
        <h3 id="rail-policy">{gettext("Policy in force")}</h3>
        <dl class="q-rail-kv">
          <dt>{gettext("Source")}</dt>
          <dd>{policy_source_words(@policy.source)}</dd>
          <dt>
            <.term word={gettext("Digest")} standard={@tips.digest} class="q-tip-wide tooltip-right" />
          </dt>
          <dd class="font-mono">
            {if @run.policy_digest,
              do: short_digest(shown_sent(@run.policy_digest)),
              else: gettext("n/a")}
            <.copy_button
              :if={@run.policy_digest}
              id="copy-digest"
              text={@run.policy_digest}
              icon_only
              label={gettext("Copy the digest")}
            />
          </dd>
          <dt>{gettext("Run configuration")}</dt>
          <dd
            class="font-mono"
            title={configuration_digest(@run)}
          >
            {short_digest(configuration_digest(@run)) || gettext("n/a")}
          </dd>
          <dt :if={@version}>{gettext("Version")}</dt>
          <dd :if={@version} id="policy-version">
            <.scoped_version version={@version} />
          </dd>
          <dt :if={@version && @digests.in_force}>{gettext("In force now")}</dt>
          <dd :if={@version && @digests.in_force} id="policy-in-force">
            <.scoped_version :if={@in_force} version={@in_force} />
            <span :if={!@in_force && @digests.in_force == @version.digest}>{gettext("the same")}</span>
            <span :if={!@in_force && @digests.in_force != @version.digest} class="font-mono">
              {short_digest(@digests.in_force)}
            </span>
          </dd>
          <dt>{gettext("Allowed hosts")}</dt>
          <dd class="font-mono">{strings(@policy.allow, @policy.allow_count) || gettext("none")}</dd>
          <dt>{gettext("Denied hosts")}</dt>
          <dd class="font-mono">{strings(@policy.deny, @policy.deny_count) || gettext("none")}</dd>
          <dt>
            <.term
              word={gettext("Reads requests to")}
              standard={@tips.terminated}
              class="q-tip-wide tooltip-right"
            />
          </dt>
          <dd class="font-mono">
            {strings(@policy.terminated, @policy.terminated_count) || gettext("none")}
          </dd>
          <dt>{gettext("Secrets")}</dt>
          <.named_hosts
            id="policy-credentials"
            named={@policy.credentials}
            count={@policy.credentials_count}
          />
          <dt>
            <.term word={gettext("Tools")} standard={@tips.tools} class="q-tip-wide tooltip-right" />
          </dt>
          <.named_hosts id="policy-tools" named={@policy.tools} count={@policy.tools_count} />
          <dt>{pgettext("plain", "Applied at")}</dt>
          <dd class="font-mono">#{pad(@policy.sequence)}</dd>
        </dl>
      </section>
    </aside>
    """
  end

  # The machine type of the claim answer, else the one a queued run was queued on.
  defp machine_type(%{machine: %{machine_type: type}}), do: type
  defp machine_type(%{queued: %{machine_type: type}}), do: type
  defp machine_type(_preparation), do: nil

  # The workflow the runs list shows for the run, nil for none.
  defp queued_workflow(scope, run) do
    case Runs.list_facts(scope, [run])[run.id] do
      %{workflow: name} when is_binary(name) -> name
      _none -> nil
    end
  end

  # Whether the rail has the Image row: for a run behind a wall, with the image Qory gave
  # it or the image it reported.
  defp image_shown?(source, %Run{wall: wall}) when source in [:configured, :given],
    do: wall != nil

  defp image_shown?(_source, %Run{wall: wall, image: image}), do: wall != nil and image != nil

  # Which image the rail's Image row shows, and the line under it. Only a run of the
  # workspace's queue, which the `factory` feature makes, is given an image: where the
  # reader is not shown the feature, every run shows the image it reported, with no line
  # under it. `:configured` is the image Qory gave the run at its attach, which it started
  # in whatever it reported, at the place a build for the run's target pushes its image
  # (`Apiary.Environments.built_for_target?/3`); `:given`, such an image elsewhere, as a
  # machine type's image was, shown with no line under it; `:pool_default`, a run of the
  # queue given none and not started in its policy's image, which starts in its pool's
  # default image; `:reported`, any other run. `policy`, the image the `security_policy`
  # set, is only on runs that attached while a run could start in its policy's image:
  # such a run shows the image it reported, with no line under it.
  defp image_source(scope, run) do
    if Apiary.Features.visible?(scope, :factory), do: image_source(run), else: :reported
  end

  defp image_source(%Run{configured_image: image} = run) when is_binary(image) do
    if Apiary.Environments.built_for_target?(image, run.organisation_id, run.target_id),
      do: :configured,
      else: :given
  end

  defp image_source(%Run{started_image_from: "policy"}), do: :reported
  defp image_source(%Run{dispatch_run_id: id}) when is_binary(id), do: :pool_default
  defp image_source(%Run{}), do: :reported

  # The Forager that reported the run, as it sent its version, and the contract it spoke;
  # n/a for a version it did not send, or one with nothing left to show
  # (`Apiary.ExternalText.present/1`).
  attr :run, :map, required: true

  defp forager_version(assigns) do
    version = Apiary.ExternalText.present(assigns.run.forager_version)
    assigns = assign(assigns, version: version, na: if(!version, do: gettext("n/a")))

    ~H"""
    <.external_text text={@version} />{@na}<span :if={@run.contract_version}> · {gettext(
      "contract %{version}",
      version: @run.contract_version
    )}</span>
    """
  end

  ## Small pieces of the header

  attr :id, :string, default: "run-duration", doc: "the ticking clock's, one per place"
  attr :run, :map, required: true
  attr :quiet, :boolean, required: true

  defp run_duration(assigns) do
    ~H"""
    <%= cond do %>
      <% is_integer(@run.duration_ms) -> %>
        <.duration ms={@run.duration_ms} />
      <% @run.state == "running" and not @quiet -> %>
        <%!-- Forager's own elapsed seconds plus this server's time since they were true. --%>
        <.duration
          id={@id}
          elapsed_seconds={elem(elapsed(@run), 0)}
          elapsed_at={elem(elapsed(@run), 1)}
          so_far
        />
      <% @run.state in ~w(running lost) and is_integer(@run.elapsed_seconds) -> %>
        <.duration at_least_seconds={@run.elapsed_seconds} />
      <% true -> %>
        <.duration />
    <% end %>
    """
  end

  # The policy cell: the mode, then the version the run last reported as a link to that
  # exact version, then its digest; the drift mark takes the digest's place while the run
  # is behind.
  attr :policy, :any, required: true
  attr :digest, :string, default: nil, doc: "Forager's own digest of its policy document"
  attr :tips, :map, required: true

  attr :version, :any,
    default: nil,
    doc: "the version the reported digest names here, when one does"

  attr :reported, :string, default: nil, doc: "the run configuration digest the run reported"

  attr :default_policy, :boolean,
    default: false,
    doc: "whether the reported digest is of the default policy a prebuild was given"

  attr :in_force, :any, default: nil, doc: "the version in force, only while the run is behind"
  attr :last_seq, :integer, default: nil

  defp policy_value(%{policy: %{source: "none"}} = assigns) do
    ~H"""
    <.term word="observe" standard={@tips.mode} class="q-tip-wide tooltip-left" />
    <small class="ml-1">{gettext("no policy")}</small>
    """
  end

  defp policy_value(assigns) do
    ~H"""
    <.term
      word={shown_sent(@policy.mode) || gettext("n/a")}
      standard={@tips.mode}
      class="q-tip-wide tooltip-left"
    />
    <%= cond do %>
      <% @version -> %>
        <.scoped_version
          version={@version}
          class="ml-1"
          title={
            gettext(
              "Version %{n} of the %{label}, sha256 %{digest}. Open the exact document.",
              n: @version.n,
              label: @version.label,
              digest: short_digest(@version.digest)
            )
          }
        />
        <small :if={!@in_force} class="ml-1 font-mono" title={@version.digest}>
          {short_digest(@version.digest)}
        </small>
      <% @reported -> %>
        <span
          id="policy-unrendered"
          tabindex="0"
          title={if @default_policy, do: @tips.default_policy, else: @tips.unrendered}
        >
          <small class="ml-1 font-mono">{short_digest(shown_sent(@reported))}</small>
          <small class="block">{gettext("Not a version made in this workspace")}</small>
        </span>
      <% @digest -> %>
        <small
          class="ml-1 font-mono"
          title={gettext("sha256 %{digest}", digest: shown_sent(@digest))}
        >
          {String.slice(shown_sent(@digest), 0, 12)}
        </small>
      <% true -> %>
    <% end %>
    <.drift :if={@in_force} reported={@version} in_force={@in_force} last_seq={@last_seq} />
    """
  end

  attr :at, :any, required: true
  attr :id, :string, required: true

  defp clock(assigns) do
    ~H"""
    <.relative_time :if={@at} id={@id} at={@at} format="clock" />
    <.na :if={!@at} />
    """
  end

  # Whether the run has a run on a machine: any run but a run of a workspace's queue that
  # no claim registered (`Run.registered?/1`).
  defp on_machine?(%Run{dispatch_run_id: nil}), do: true
  defp on_machine?(%Run{} = run), do: Run.registered?(run)

  defp na(assigns \\ %{}), do: ~H|<span class="text-faint">{gettext("n/a")}</span>|

  # The tips of the page's terms, in the domain's words.
  defp tips do
    %{
      wall: gettext("The enclosure the agent runs in. Its only route out leads to the gateway."),
      no_wall: gettext("This run had no wall. A program that ignores the proxy is not seen."),
      mode:
        gettext(
          "Enforce: a connection no rule allows is denied. Observe: it is let through and recorded. A deny rule holds in either mode."
        ),
      digest:
        gettext(
          "The sha256 of the policy this run ran under. Two runs with the same digest had the same policy."
        ),
      terminated:
        gettext(
          "A host whose requests the proxy reads, because the run holds a secret, a tool or path rules for it. Every other host is a blind tunnel."
        ),
      tools:
        gettext(
          "Programs on Forager's machine that serve hosts. The gateway hands a request to such a host to its tool when the rules let it through: a tool invocation. One a path rule refused never reaches the tool."
        ),
      lane:
        gettext(
          "One agent's events: the main session, or a subagent from its start to its finish."
        ),
      unrendered:
        gettext(
          "The run's policy digest matches no version made here: the machine used a policy file on the machine, or the run started with --local."
        ),
      default_policy:
        gettext(
          "This prebuild ran under Qory Apiary's default policy, because this workspace had no policy version when the run started."
        )
    }
  end

  ## Mount and parameters

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    security = Access.can?(scope, :"security_policy.read", scope.workspace)

    # The policy's topic is followed from mount: the sidebar's hook looks, before the first
    # handle_params, at whether the page subscribed, and stops the message at itself when
    # it did not. Subscribing any later is both a second subscription and a deaf page.
    # Without security there is no policy to follow.
    if security and connected?(socket), do: Policy.subscribe(scope)

    {:ok,
     socket
     |> assign(
       security: security,
       run: nil,
       loaded_id: nil,
       loaded: false,
       page_title: gettext("Run"),
       tips: tips(),
       target_shared: false,
       target_page: {nil, nil},
       announcement: nil,
       announced_at: nil,
       at_end: false,
       flush_scheduled: false,
       range: nil,
       full: MapSet.new(),
       opened: MapSet.new(),
       window_loaded: false,
       window_tab: nil,
       index: Timeline.new(),
       policy: nil,
       instance: nil,
       target: nil,
       digests: %{in_force: nil, reported: nil, applied: nil, drift: false},
       reported_version: nil,
       default_policy: false,
       in_force: nil,
       versions: %{},
       effective: nil,
       first_hosts: nil,
       acts: nil,
       rule_panel: nil,
       policy_flush_scheduled: false,
       session_id: nil,
       tab: :timeline,
       details_open: false,
       counts: %{all: 0, allowed: 0, denied: 0, attempts: 0},
       connections: %{rows: [], page: 1, pages: 1, total: 0},
       log: %{chunks: 0, bytes: 0, through: 0, streams: []},
       focused: nil,
       lane: nil,
       cx: true,
       decision: nil,
       timeline_query: %{},
       new_count: 0,
       new_events: 0,
       earlier: 0,
       later: 0,
       earlier_events: 0,
       later_events: 0,
       tab_count: 0,
       unread: 0,
       limit: nil,
       win_first: nil,
       win_last: nil,
       sub_choices: %{},
       timeline_choices: %{},
       opened_for: {nil, nil},
       preparation: nil,
       preparation_settled: false,
       outputs: [],
       overview: [],
       overview_cx: false,
       machine_log: :hidden,
       clean_up: nil,
       clean_up_timer: nil
     )
     |> stream_configure(:items, dom_id: & &1.id)
     |> stream(:items, [])
     |> ApiaryWeb.UserAuth.on_membership_change(&(&1 |> leave_terminal() |> conceal_timeline()))}
  end

  @impl true
  def handle_params(%{"run_id" => run_id} = params, uri, socket) do
    socket = assign_tab(socket)
    socket = if socket.assigns.loaded_id == run_id, do: socket, else: load_run(socket, run_id)
    refuse_terminal(socket)

    case socket.assigns do
      # An address with the run's `rn_` id: the same address with its number.
      %{run: %Run{} = run, loaded_id: loaded_id} when loaded_id != run_id ->
        {:noreply, push_patch(socket, to: numbered(uri, run_id, run), replace: true)}

      %{run: %Run{} = run, loaded: true} ->
        socket = apply_params(socket, Map.drop(params, ["org", "workspace", "run_id"]))
        {:noreply, assign(socket, :page_title, run_title(run, socket.assigns.tab))}

      _ ->
        {:noreply, socket}
    end
  end

  # The tab shown: the live action's, but an old link to the Details tab
  # (`/runs/:run_id/details`) lands on the Timeline with Details open; `apply_params/2`
  # then rewrites the address to the Timeline's. Details is not closed again by a patch:
  # the button keeps the state the reader left it in.
  defp assign_tab(%{assigns: %{live_action: :details}} = socket),
    do: assign(socket, tab: :timeline, details_open: true)

  defp assign_tab(socket), do: assign(socket, :tab, socket.assigns.live_action)

  # The terminal tab is `run.read_log`'s: for a reader who may not, it is a path that does
  # not exist, as the tab is not shown.
  defp refuse_terminal(%{assigns: %{live_action: :terminal, run: %Run{} = run}} = socket) do
    unless Access.can?(socket.assigns.current_scope, :"run.read_log", run),
      do: raise(ApiaryWeb.NotFound)
  end

  defp refuse_terminal(_socket), do: :ok

  # An open Terminal tab whose reader may no longer read the log, once the scope is loaded
  # again after a change of their memberships, or of what the edition hides from them,
  # leaves for the run's Timeline.
  defp leave_terminal(%{assigns: %{tab: :terminal, run: %Run{} = run}} = socket) do
    scope = socket.assigns.current_scope

    if Access.can?(scope, :"run.read_log", run),
      do: socket,
      else: push_patch(socket, to: tab_path(scope, run, :timeline), replace: true)
  end

  defp leave_terminal(socket), do: socket

  # An open Timeline whose reader may no longer read the log builds its rows again in
  # place, and the header's ending, so that no text of the session stays on the page.
  defp conceal_timeline(%{assigns: %{tab: :timeline, run: %Run{}, window_loaded: true}} = socket) do
    if read_log?(socket) do
      socket
    else
      %{win_first: first, win_last: last} = socket.assigns
      shown = Enum.filter(tab_items(socket), &(first && last && within?(pos(&1), first, last)))
      socket = assign(socket, full: MapSet.new())

      socket
      |> stream(:items, build(socket, shown))
      |> assign_ending()
    end
  end

  defp conceal_timeline(socket), do: socket

  # The run row is read for the first, static render too: it says found or not found, and
  # gives the header. Everything else waits for the socket, so that opening the page reads
  # the record once, not twice.
  defp load_run(socket, run_id) do
    scope = socket.assigns.current_scope

    case Record.fetch_run(scope, run_id) do
      {:ok, run} ->
        socket =
          socket
          |> assign(
            loaded_id: Integer.to_string(run.number),
            new_count: 0,
            new_events: 0,
            ending: nil
          )
          |> assign(
            :target_shared,
            run.target_id != nil and Targets.shared?(scope, run.target_path)
          )
          |> assign_run(run)
          |> assign_target_page(run)
          |> assign(:instance, Nodes.instance_of(scope, run))

        if connected?(socket) do
          # Subscribed before the read, so nothing projected after it is missed.
          Runs.subscribe(scope, run)
          subscribe_outputs(scope, run)
          listen_to_queue(scope, run)
          Process.send_after(self(), :quiet_tick, @quiet_tick_ms)

          security = socket.assigns.security

          socket
          |> assign(
            loaded: true,
            window_loaded: false,
            full: MapSet.new(),
            sub_choices: %{},
            timeline_choices: %{},
            opened_for: {nil, nil},
            policy: if(security, do: Record.policy(scope, run)),
            counts: Record.connection_counts(scope, run),
            session_id: Record.session_id(scope, run),
            target: if(security, do: target_of(scope, run)),
            versions: %{},
            effective: nil,
            first_hosts: nil,
            acts: nil,
            rule_panel: nil
          )
          |> put_index(Record.timeline(scope, run))
          |> assign_policy_facts()
          |> assign(preparation: nil, preparation_settled: false, machine_log: :hidden)
          |> assign_preparation()
          |> refresh_outputs()
          |> assign_ending()
        else
          socket
        end

      :error ->
        assign(socket, run: nil, loaded_id: run_id, page_title: gettext("Run not found"))
    end
  end

  defp assign_run(socket, %Run{} = run) do
    socket
    |> assign_work_item(run)
    |> assign(
      run: run,
      quiet_for: quiet_for(run),
      page_title: run_title(run, socket.assigns.tab)
    )
  end

  # The run's work item, from its run of the queue, as the runs list reads it
  # (`Apiary.Runs.work_item/2`), not from the subjects the run reports. It is read when
  # the page loads the run, and again only when the run's link to its queue changes: a
  # projection of the run's events changes neither, and reads nothing for it.
  defp assign_work_item(
         %{assigns: %{run: %Run{id: id} = old, work_item: _work_item}} = socket,
         %Run{id: id} = run
       )
       when old.dispatch_run_id == run.dispatch_run_id and old.dispatch_id == run.dispatch_id,
       do: socket

  defp assign_work_item(socket, %Run{} = run),
    do: assign(socket, :work_item, Runs.work_item(socket.assigns.current_scope, run))

  # The window's title: the run, and the tab when it is not the timeline, so a reader with
  # several tabs of one run open tells them apart.
  defp run_title(run, tab) do
    title = gettext("%{title} · Runs", title: run_title(run))

    case tab do
      :terminal -> gettext("Terminal") <> " · " <> title
      :connections -> gettext("Network access") <> " · " <> title
      _timeline -> title
    end
  end

  # Every parameter is validated against the record; what is not valid is dropped and the
  # URL is rewritten without it.
  defp apply_params(socket, params) do
    %{index: index, tab: tab} = socket.assigns
    seq = tab in [:timeline, :terminal] && sequence(params["seq"])
    # Allowed connections are inline only on the reader's word (`?cx=1`); a denied one is
    # inline always.
    cx = tab == :timeline and params["cx"] == "1"

    # The overview's rows with Connections inline as the Timeline has it after these
    # parameters: read again only when that changes.
    overview_cx = if tab == :timeline, do: cx, else: socket.assigns.overview_cx

    rows =
      if overview_cx == socket.assigns.overview_cx,
        do: socket.assigns.overview,
        else: overview_rows(index, overview_cx, socket.assigns.outputs)

    overview = {rows, overview_cx}

    # On the Timeline, a routine tool call's sequence is the Terminal's line for a reader
    # of the log, else the nearest row before it; any other sequence with no row shows the
    # row after it (`Overview.focus/3`).
    focus =
      with true <- tab == :timeline,
           item_seq when is_integer(item_seq) <- seq && index.by_seq[seq],
           %{} = item <- Enum.find(index.items, &(&1.seq == item_seq)) do
        Overview.focus(rows, item, read_log?(socket))
      else
        _ -> :as_is
      end

    case focus do
      {:terminal, _item_seq} ->
        push_patch(socket,
          to:
            tab_path(socket.assigns.current_scope, socket.assigns.run, :terminal, %{
              "seq" => Integer.to_string(seq)
            }),
          replace: true
        )

      # The address keeps a sequence of the row's item, else it moves to the row's.
      {:row, row} ->
        seq = if row.seq == index.by_seq[seq], do: seq, else: row.seq
        apply_params(socket, params, seq, row.seq, cx, overview)

      nil ->
        apply_params(socket, params, seq, nil, cx, overview)

      as_is when as_is in [:as_is, :unlisted] ->
        apply_params(socket, params, seq, seq && index.by_seq[seq], cx, overview)
    end
  end

  defp apply_params(socket, params, seq, focused, cx, {rows, overview_cx}) do
    %{index: index, run: run, tab: tab, live_action: action} = socket.assigns
    lane = tab == :timeline && Timeline.lane(index, params["lane"])

    decision =
      tab == :connections && params["decision"] in ~w(allowed denied) && params["decision"]

    page = (tab == :connections && sequence(params["page"])) || 1

    timeline_query =
      %{}
      |> put_if("lane", lane && lane.id)
      |> put_if("cx", if(cx, do: "1"))

    %{cx: old_cx, overview: old_rows} = socket.assigns

    socket =
      socket
      |> assign(
        focused: focused || nil,
        lane: (lane && lane.id) || nil,
        cx: cx,
        decision: decision || nil,
        timeline_query: keep_timeline_query(socket, tab, timeline_query),
        overview: rows,
        overview_cx: overview_cx
      )
      |> relist(old_cx, old_rows)
      |> read_tab(tab, decision || nil, page)

    canonical =
      case tab do
        :timeline ->
          put_if(timeline_query, "seq", focused && Integer.to_string(seq))

        :connections ->
          page = socket.assigns.connections.page

          %{}
          |> put_if("decision", decision || nil)
          |> put_if("page", if(page > 1, do: Integer.to_string(page)))

        :terminal ->
          put_if(%{}, "seq", focused && Integer.to_string(seq))
      end

    if canonical != params or action != tab,
      do:
        push_patch(socket,
          to: tab_path(socket.assigns.current_scope, run, tab, canonical),
          replace: true
        ),
      else: socket
  end

  # What a tab shows is read when the tab opens, and only then.
  defp read_tab(socket, :timeline, _decision, _page),
    do: socket |> open_for_params() |> ensure_window() |> assign_window_counts()

  # The Transcript is the window of the Terminal tab, as the Timeline's is of its tab.
  defp read_tab(socket, :terminal, _decision, _page) do
    %{current_scope: scope, run: run} = socket.assigns

    if Access.can?(scope, :"run.read_log", run),
      do:
        socket
        |> assign(log: Record.log_summary(scope, run))
        |> ensure_window()
        |> assign_window_counts(),
      else: assign(socket, window_loaded: false)
  end

  defp read_tab(socket, :connections, decision, page) do
    %{current_scope: scope, run: run} = socket.assigns

    socket
    |> assign(
      window_loaded: false,
      window_tab: nil,
      counts: Record.connection_counts(scope, run),
      connections: Record.connections(scope, run, decision: decision, page: page),
      # The effective policy is read when the tab opens and when the policy changes, and
      # every row's rule option is derived from it: no query per row. Without security it
      # is not read, and no row has a rule option.
      effective:
        if(socket.assigns.security,
          do: socket.assigns.effective || Policy.effective(scope, socket.assigns.target)
        ),
      first_hosts:
        if(socket.assigns.security,
          do:
            (socket.assigns.effective && socket.assigns.first_hosts) ||
              RequiredHosts.first_hosts(scope.workspace)
        )
    )
    |> assign_acts()
  end

  # Connections inline turned on or off on an open Timeline: the allowed connections
  # outside a call come into the window, or leave it, at their places
  # (`redraw_window/5`), from `old_rows`, the overview's rows before. The window keeps its
  # start, and its end, or the list's end when it reached it, so that a reader at the live
  # end keeps following the events that arrive.
  defp relist(%{assigns: %{cx: cx}} = socket, cx, _old_rows), do: socket

  defp relist(
         %{assigns: %{tab: :timeline, window_tab: :timeline, window_loaded: true}} = socket,
         _old_cx,
         old_rows
       ) do
    %{index: index, win_first: first, win_last: last} = socket.assigns

    if is_tuple(first) and is_tuple(last) do
      old = tab_items(index, :timeline, %{socket.assigns | overview: old_rows})
      new = tab_items(socket)
      at_end = old != [] and last == pos(List.last(old))
      to_last = if at_end and new != [], do: pos(List.last(new)), else: last

      {socket, _in_window, _removed} =
        redraw_window(socket, old, new, fn _ -> false end, {first, to_last})

      socket |> assign(win_last: to_last) |> fit_window(new)
    else
      socket
    end
  end

  defp relist(socket, _old_cx, _old_rows), do: socket

  # The other tabs link back to the timeline as the reader left it.
  defp keep_timeline_query(_socket, :timeline, query), do: query
  defp keep_timeline_query(socket, _tab, _query), do: socket.assigns[:timeline_query] || %{}

  defp sequence(value) when is_binary(value) and byte_size(value) <= 10 do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp sequence(_value), do: nil

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, false), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp lane_query(query, current, lane_id) do
    if current == lane_id, do: Map.delete(query, "lane"), else: Map.put(query, "lane", lane_id)
  end

  defp cx_query(query, true), do: Map.delete(query, "cx")
  defp cx_query(query, false), do: Map.put(query, "cx", "1")

  defp connections_query(decision, page) do
    %{}
    |> put_if("decision", decision)
    |> put_if("page", if(page > 1, do: Integer.to_string(page)))
  end

  defp tab_path(scope, run, tab, query \\ %{})

  defp tab_path(scope, %Run{} = run, :timeline, query),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run}?#{query}"

  defp tab_path(scope, %Run{} = run, :terminal, query),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run}/terminal?#{query}"

  defp tab_path(scope, %Run{} = run, :connections, query),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run}/network?#{query}"

  # The address `uri` with the run's number in the place of `run_id`, the `rn_` id it was
  # asked by: the same tab, the same query. The path is compared one decoded segment at a
  # time, as the router matched it.
  defp numbered(uri, run_id, %Run{} = run) do
    %URI{path: path, query: query} = URI.parse(uri)
    segments = path |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)
    ApiaryWeb.RunAddress.renumber(segments, query, run_id, run)
  end

  # A label that names the target, by the workspace's domain, links to the target's page.
  # The scope's workspace is the run's, loaded with its domain: no read per render.
  defp label_path(scope, page, key) when is_binary(page) do
    if key in Domain.target_labels(scope.workspace), do: page
  end

  defp label_path(_scope, _page, _key), do: nil

  # The number a run that is not here was asked by, when the address has a run's number;
  # nil for any other address, whose breadcrumb ends with Runs.
  defp missing_number(run_id) do
    case Run.parse_number(run_id) do
      {:ok, number} -> number
      :error -> nil
    end
  end

  # The page of the target the run names, by the target's public id: `{target_id, path}`,
  # read again only when the run names another target.
  defp assign_target_page(%{assigns: %{target_page: {id, _path}}} = socket, %Run{target_id: id}),
    do: socket

  defp assign_target_page(socket, %Run{target_id: id}) do
    scope = socket.assigns.current_scope
    target = id && Targets.get_by_id(scope, id)
    assign(socket, :target_page, {id, target && target_path(scope, target)})
  end

  defp target_link({_id, path}), do: path

  # The run's target path as a text Forager sent is shown (`shown_sent/1`): marked where
  # nothing is left of it, since it was sent; nil for a run with none.
  defp shown_target_path(run), do: shown_sent(run.target_path)

  # A text Forager sent, as the page shows it (`Apiary.ExternalText.present/1`), or marked
  # (`Apiary.ExternalText.marked/1`) where nothing is left of it, since it was sent; nil
  # where it sent none. A value that is no text is shown as it is.
  defp shown_sent(text) when is_binary(text) and text != "",
    do: Apiary.ExternalText.present(text) || Apiary.ExternalText.marked(text)

  defp shown_sent(""), do: nil
  defp shown_sent(text), do: text

  # The digest of the run configuration in force, else of the one the run reported.
  defp configuration_digest(run),
    do: shown_sent(run.run_configuration_digest || run.reported_run_configuration_digest)

  # The chips of the lane key: the first dozen, and the isolated one wherever it is.
  defp lane_chips(index, isolated) do
    if is_nil(isolated) or Enum.any?(index.lanes, &(&1.id == isolated)),
      do: index.lanes,
      else: index.lanes ++ List.wrap(Timeline.lane(index, isolated))
  end

  ## The window of the timeline

  # The stream holds a window of the tab's items (`tab_items/2`): the Timeline's, or the
  # Transcript's on the Terminal tab. It is loaded when the tab opens and when the focused
  # item is outside it; a parameter that only toggles a lane leaves it alone.
  defp ensure_window(socket) do
    %{focused: focused, window_loaded: loaded?, tab: tab} = socket.assigns

    cond do
      not loaded? or socket.assigns.window_tab != tab ->
        reset_window(socket, focused)

      focused && not in_window?(socket, shown_seq(tab_items(socket), tab, focused)) ->
        reset_window(socket, focused)

      true ->
        socket
    end
  end

  # The sequence of the row the tab shows for `seq`. On the Timeline, `apply_params/2`
  # sets `focused` to a listed row (`Overview.focus/3`); for a sequence no row has, the
  # row is the first after it, else the last one. A row with no sequence is never that
  # row. Every other tab shows the sequence as it is.
  defp shown_seq(_items, _tab, nil), do: nil

  defp shown_seq(items, :timeline, seq) do
    numbered = Enum.filter(items, &is_integer(&1.seq))

    case Enum.find(numbered, &(&1.seq >= seq)) || List.last(numbered) do
      nil -> seq
      item -> item.seq
    end
  end

  defp shown_seq(_items, _tab, seq), do: seq

  # Whether the item with this sequence is in the window. A sequence that is no item of the
  # tab is compared as `{seq, seq}`.
  defp in_window?(%{assigns: %{win_first: first, win_last: last}} = socket, seq)
       when is_tuple(first) and is_tuple(last) do
    case Enum.find(tab_items(socket), &(&1.seq == seq)) do
      nil -> within?({seq, seq}, first, last)
      item -> within?(pos(item), first, last)
    end
  end

  defp in_window?(_socket, _seq), do: false

  # An item's place in its tab, which the window's ends are: the Transcript groups a
  # subagent's lines under its start (`ApiaryWeb.TranscriptComponents.arrange/4`), so a
  # line's place there is `{head, seq}`; anywhere else it is `{seq, seq}`.
  defp pos(%{pos: pos}), do: pos
  defp pos(%{seq: seq}), do: {seq, seq}

  defp within?(pos, first, last), do: pos >= first and pos <= last

  # The sequence of the window's last item, for `data-until`: a Transcript line's
  # `{head, seq}` has it second; a row with no sequence (`Overview.list/2`) comes right
  # after the row of the sequence its place starts with.
  defp until_seq({_head, seq}) when is_integer(seq), do: seq
  defp until_seq({after_seq, {_seq, _k}}), do: after_seq
  defp until_seq(_last), do: nil

  # A light item's DOM id, which its built item has (`Timeline.build/3`): `e-` and its
  # sequence, or the `id` of a row with no sequence (`Overview.list/2`).
  defp row_id(%{id: id}) when is_binary(id), do: id
  defp row_id(%{seq: seq}), do: "e-#{seq}"

  # Whether an item comes after `last`, the window's end, or nil for a window with none.
  defp after?(_item, nil), do: true
  defp after?(item, last), do: pos(item) > last

  # The items of the index a tab shows. The Timeline lists the overview's rows of the
  # index (`overview`, `assign_overview/1`), with each subagent folded into its start, open
  # or closed as the reader chose (`timeline_choices`,
  # `ApiaryWeb.RunPageComponents.fold/3`). The Transcript shows the session, with a result
  # after the lines of another agent that came before it as a line apart
  # (`ApiaryWeb.TranscriptComponents.lines/2`), and each subagent's lines under its start,
  # open or closed as the reader chose (`sub_choices`).
  defp tab_items(index, :timeline, assigns) do
    subagents = TranscriptComponents.subagents(index.items, index.alive)
    fold(assigns.overview, subagents, assigns.timeline_choices)
  end

  defp tab_items(index, :terminal, assigns) do
    subagents = TranscriptComponents.subagents(index.items, index.alive)

    index.items
    |> TranscriptComponents.lines(index.texts, subagents: true)
    |> TranscriptComponents.arrange(subagents, assigns.sub_choices, assigns.focused)
  end

  defp tab_items(index, _tab, _assigns), do: Enum.reject(index.items, &(&1.kind == :thinking))

  defp tab_items(socket),
    do: tab_items(socket.assigns.index, socket.assigns.tab, socket.assigns)

  # The Timeline's rows of the index with every subagent open (`Overview.list/2`), each with
  # `terminal_seq`, its line in the Terminal or nil: the allowed connections only with
  # Connections inline on (`cx`), and a Pushed row for each version the run pushed
  # (`outputs`).
  defp overview_rows(index, cx, outputs) do
    line? = &TranscriptComponents.line?(&1, index.texts)

    index.items
    |> Overview.list(connections: cx, versions: outputs)
    |> Enum.map(&Map.put(&1, :terminal_seq, Overview.terminal_seq(&1, line?)))
  end

  # The overview's rows, read once for each change of the index, of the pushed versions,
  # or of Connections inline as the Timeline has it (`overview_cx`, set by
  # `apply_params/2`): the Timeline's window, the tab's count and `?seq=` read them.
  defp assign_overview(socket) do
    %{index: index, overview_cx: cx, outputs: outputs} = socket.assigns
    assign(socket, overview: overview_rows(index, cx, outputs))
  end

  defp reset_window(socket, around) do
    items = tab_items(socket)
    around = shown_seq(items, socket.assigns.tab, around)

    start =
      case around && Enum.find_index(items, &(&1.seq == around)) do
        # Around the focused item, and a whole window even when it is near the end.
        index when is_integer(index) ->
          (index - div(@window, 2)) |> min(length(items) - @window) |> max(0)

        _ ->
          0
      end

    put_window(socket, Enum.slice(items, start, @window))
  end

  defp reset_window_at_end(socket) do
    put_window(socket, Enum.take(tab_items(socket), -@window))
  end

  defp put_window(socket, light, keep_opened \\ false) do
    socket = if keep_opened, do: socket, else: assign(socket, opened: MapSet.new())

    socket
    |> stream(:items, build(socket, light), reset: true)
    |> assign(
      window_loaded: true,
      window_tab: socket.assigns.tab,
      win_first: light |> List.first() |> then(&(&1 && pos(&1))),
      win_last: light |> List.last() |> then(&(&1 && pos(&1))),
      new_count: 0,
      new_events: 0
    )
  end

  # The items of `light` as the page shows them, in the order of `light`. A row with no
  # sequence, the Main session or a Pushed row, is made by `Overview.build/2`, as
  # `Timeline.build/3` skips it; the Main session row reads its last text and result,
  # which are built for it when the window does not have them. A row keeps its
  # `terminal_seq`.
  defp build(socket, light) do
    %{current_scope: scope, run: run, full: full, opened: opened, index: index} = socket.assigns
    {numbered, rows} = Enum.split_with(light, &is_integer(&1.seq))

    needed =
      for %{kind: :main_session, seqs: seqs} <- rows, seq <- seqs, into: MapSet.new(), do: seq

    numbered_seqs = MapSet.new(numbered, & &1.seq)

    extra =
      if MapSet.size(needed) == 0,
        do: [],
        else:
          Enum.filter(
            index.items,
            &(MapSet.member?(needed, &1.seq) and not MapSet.member?(numbered_seqs, &1.seq))
          )

    built =
      scope
      |> Record.items(run, numbered ++ extra, full: MapSet.to_list(full))
      |> with_versions(socket)
      |> with_pool(run)
      |> with_dispatch_run(run)

    by_seq = Map.new(built, &{&1.seq, &1})

    light
    |> Enum.flat_map(fn
      %{seq: nil} = row ->
        [Overview.build(row, built)]

      row ->
        case by_seq[row.seq] do
          nil -> []
          item -> [Map.put(item, :terminal_seq, row[:terminal_seq])]
        end
    end)
    |> conceal(Access.can?(scope, :"run.read_log", run))
    |> Enum.map(&Map.put(&1, :open, MapSet.member?(opened, &1.seq)))
  end

  # The session's texts are the Terminal's: for a reader who may not read the log, an item
  # loses every text the run produced before it is rendered (`ApiaryWeb.RunLive.Concealed`).
  defp conceal(items, true), do: items
  defp conceal(items, false), do: Enum.map(items, &Concealed.item/1)

  defp concealed_tasks(background, scope, run) do
    if Access.can?(scope, :"run.read_log", run),
      do: background,
      else: Concealed.tasks(background)
  end

  defp read_log?(%{assigns: %{current_scope: scope, run: %Run{} = run}}),
    do: Access.can?(scope, :"run.read_log", run)

  defp read_log?(_socket), do: false

  # The run's end item reads the words of `workflow_not_in_harness` from the run of the
  # queue `Record.fetch_run/2` loaded with it (`Apiary.Harnesses.WorkflowGap.preload/1`).
  defp with_dispatch_run(items, %Run{dispatch_run: %DispatchRun{} = dispatch_run}) do
    Enum.map(items, fn
      %{kind: :run_exited} = item -> Map.put(item, :dispatch_run, dispatch_run)
      item -> item
    end)
  end

  defp with_dispatch_run(items, _run), do: items

  defp transcript_fold(socket, seq, open?) do
    with seq when is_integer(seq) <- sequence(seq),
         %{} = light <- Enum.find(tab_items(socket), &(&1.seq == seq)),
         true <- in_window?(socket, seq) do
      %{full: full, opened: opened} = socket.assigns

      socket =
        if open?,
          do: assign(socket, full: MapSet.put(full, seq), opened: MapSet.put(opened, seq)),
          else: assign(socket, opened: MapSet.delete(opened, seq))

      stream(socket, :items, build(socket, [light]))
    else
      _ -> socket
    end
  end

  # A pool's run starts on its pool: the Run started item shows the pool's name in place
  # of the host its `run.started` reported (`place_of/1`), "the Qory Pool" for the
  # instance's pool (`ApiaryWeb.NodeComponents.in_text/2`).
  defp with_pool(items, %Run{dispatch_run_id: id} = run) when is_binary(id) do
    pool = with {:pool, _name} <- place_of(run), do: ApiaryWeb.NodeComponents.in_text(run.node)

    Enum.map(items, fn
      %{kind: :run_started} = item -> Map.put(item, :host, pool)
      item -> item
    end)
  end

  defp with_pool(items, _run), do: items

  # The version each policy applied names, where this workspace rendered it. The run's own
  # are held already; any other digest costs one indexed read, and a build asks for at
  # most #{@max_versions}, whatever Forager put in its events. Without security the index
  # holds no policy applied, and nothing is asked.
  defp with_versions(items, %{assigns: %{security: false}}), do: items

  defp with_versions(items, socket) do
    %{current_scope: scope, target: target, versions: known} = socket.assigns
    target = {target, socket.assigns.target_shared}

    {items, _known} =
      Enum.map_reduce(items, known, fn
        %{kind: :policy_applied} = item, known ->
          {version, known} = lookup_version(known, scope, target, item[:digest])
          {previous, known} = lookup_version(known, scope, target, item[:previous_digest])
          {Map.merge(item, %{version: version, previous_version: previous}), known}

        item, known ->
          {item, known}
      end)

    items
  end

  defp lookup_version(known, _scope, _target, digest) when not is_binary(digest),
    do: {nil, known}

  # `target` is the run's target and whether its path is shared, which names its versions.
  defp lookup_version(known, scope, {target, shared}, digest) do
    case known do
      %{^digest => version} ->
        {version, known}

      _ when map_size(known) >= @max_versions ->
        {nil, known}

      _ ->
        version = Rules.version(scope, target, digest, shared)
        {version, Map.put(known, digest, version)}
    end
  end

  # The index the page holds. Without security the policy's items are not the page's: they
  # leave the items, and every sequence that points at one leaves `by_seq`, so neither a
  # window nor a `?seq=` can reach one. The index's own state keeps them, so the next
  # extension folds the record as it always does.
  defp put_index(%{assigns: %{security: true}} = socket, index),
    do: socket |> assign(index: index) |> assign_overview()

  defp put_index(socket, index) do
    {policy, items} = Enum.split_with(index.items, &(&1.kind == :policy_applied))
    dropped = MapSet.new(policy, & &1.seq)

    by_seq =
      if policy == [],
        do: index.by_seq,
        else: Map.reject(index.by_seq, fn {_seq, item_seq} -> item_seq in dropped end)

    socket
    |> assign(index: %{index | items: items, by_seq: by_seq})
    |> assign_overview()
  end

  # Why a run that ended badly ended so, said in its header: for a run of the queue
  # whose image was missing from the registry and whose work was queued again
  # (`Apiary.Dispatches.requeued_for_image?/1`), that, with the way to its exit; else the
  # last of its timeline's results that was no success, failed turns and failed tools,
  # read whole, with the way to that item. A run with a failed push step looks only at
  # the newest of its results and failed turns, and shows it only if that item is a
  # failure: an earlier failure that the session went on from did not end the run, and the
  # push that did is no item of the timeline. Nothing for a run that is alive or ended
  # well, or whose timeline says no more than its state. Read after the preparation, which
  # has the push steps.
  defp assign_ending(%{assigns: %{run: %Run{state: state} = run, index: index}} = socket) do
    exited = Enum.find(index.items, &(&1.kind == :run_exited))

    if exited && Dispatches.requeued_for_image?(run) do
      assign(socket,
        ending: %{
          seq: exited.seq,
          text:
            gettext(
              "Ended before it started: its environment image was missing from the registry. The work is queued again and waits for a new build of the image."
            )
        }
      )
    else
      assign_ending(socket, state, run, index)
    end
  end

  defp assign_ending(socket), do: assign(socket, ending: nil)

  # A run that ended badly ends with the failed step of its preparation
  # (`Preparation.stop_line/1`), or with the image a prebuild did not save
  # (`PreparationComponents.built_line/1`); else with the item the candidates find; else
  # with its failed push or copy (`Preparation.push_line/1`); else, for a prebuild lost
  # before its image arrived, that (`unsaved_ending/2`). A prebuild that ended in another
  # state ends with the image it did not save, as one that completed whose report failed
  # its check, or one cancelled before its image arrived. A step's ending has no `seq`.
  defp assign_ending(socket, state, run, index) do
    preparation = socket.assigns.preparation
    scope = socket.assigns.current_scope

    cond do
      state in Run.ended_badly_states() ->
        ending =
          step_ending(
            Preparation.stop_line(preparation) || PreparationComponents.built_line(preparation)
          ) ||
            item_ending(scope, run, index, preparation) ||
            step_ending(Preparation.push_line(preparation)) ||
            unsaved_ending(run, preparation)

        assign(socket, ending: ending)

      not alive?(run) ->
        ending =
          step_ending(PreparationComponents.built_line(preparation)) ||
            unsaved_ending(run, preparation)

        assign(socket, ending: ending)

      true ->
        assign(socket, ending: nil)
    end
  end

  # A prebuild lost or cancelled before its image arrived ends with that
  # (`PreparationComponents.unsaved_line/1`) only when the header has no other line on its
  # end: the starter's outcome in the place of the state, or the end reason beside it.
  defp unsaved_ending(run, preparation) do
    if is_nil(RunComponents.outcome_sentence(run)) and is_nil(RunComponents.reason_words(run)),
      do: step_ending(PreparationComponents.unsaved_line(preparation))
  end

  defp step_ending(nil), do: nil
  defp step_ending(line), do: %{seq: nil, text: line}

  # Why a queued run waits, in the header, where a person fixes it: no pool offers a
  # machine that fits its type (`ApiaryWeb.PreparationComponents.waiting_words/2`); nil
  # for any other run.
  defp why_it_waits(%{queued: %{reason: {:no_fit, _key, _pool} = reason, machine_type: type}})
       when is_map(type),
       do: PreparationComponents.waiting_words(reason, type)

  defp why_it_waits(_preparation), do: nil

  defp item_ending(scope, run, index, preparation) do
    candidates = ending_candidates(index, preparation)
    log? = Access.can?(scope, :"run.read_log", run)

    if candidates != [],
      do:
        scope
        |> Record.items(run, candidates)
        |> Enum.reverse()
        |> Enum.find_value(&ending_of(&1, log?))
  end

  defp ending_candidates(index, preparation) do
    {kinds, last} =
      if Preparation.push_failed?(preparation),
        do: {[:result, :turn_failed], 1},
        else: {[:result, :turn_failed, :tool], 12}

    index.items |> Enum.filter(&(&1.kind in kinds)) |> Enum.take(-last)
  end

  defp ending_of(%{kind: :result, outcome: outcome, text: text} = item)
       when outcome != "success" and is_binary(text) and text != "",
       do: ending(item, text)

  defp ending_of(%{kind: :turn_failed} = item) do
    case item[:error] || item[:message] do
      text when is_binary(text) and text != "" -> ending(item, text)
      _ -> nil
    end
  end

  defp ending_of(%{kind: :tool, status: :failed} = item) do
    tool = shown_sent(item.tool)

    text =
      if is_binary(item.summary) and item.summary != "",
        do: gettext("%{tool} failed: %{summary}", tool: tool, summary: shown_sent(item.summary)),
        else: gettext("%{tool} failed", tool: tool)

    ending(item, text)
  end

  defp ending_of(_item), do: nil

  # For a reader who may not read the log, the ending is chosen as for any reader and keeps
  # its item, but none of the session's text: a failed tool keeps its name, a result or a
  # failed turn only the way to it (`ApiaryWeb.RunLive.Concealed`).
  defp ending_of(item, true), do: ending_of(item)

  defp ending_of(item, false) do
    case ending_of(item) do
      nil -> nil
      _ending when item.kind == :tool -> item |> Concealed.item() |> ending_of()
      ending -> %{ending | text: nil}
    end
  end

  # The item's words are texts the runtime sent, shown as one is
  # (`Apiary.ExternalText.lines/1`), on one line. Words with nothing left to show are
  # marked (`Apiary.ExternalText.marked/1`), since the item sent them: the ending names
  # this item, never the one before it.
  defp ending(item, text) do
    line =
      case text |> Apiary.ExternalText.lines() |> one_line() do
        "" -> text |> Apiary.ExternalText.marked() |> one_line()
        line -> line
      end

    %{seq: item.seq, text: line}
  end

  defp one_line(text),
    do: text |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 400)

  # The run's session shows only its result: every session item is one. With runtime
  # events read from the output, a run behind a wall shows more than its result.
  defp only_result?(index) do
    results = Enum.count(index.items, &(&1.kind == :result))
    results > 0 and results == index.session_items
  end

  defp assign_window_counts(socket) do
    %{index: index, win_first: first, win_last: last, run: run} = socket.assigns
    items = tab_items(socket)

    {earlier, later} =
      if is_tuple(first),
        do: {Enum.count(items, &(pos(&1) < first)), Enum.count(items, &(pos(&1) > last))},
        else: {0, length(items)}

    # The words of Load earlier and Load newer count events: the rows with a sequence.
    {earlier_events, later_events} =
      if is_tuple(first),
        do:
          {Enum.count(items, &(pos(&1) < first and is_integer(&1.seq))),
           Enum.count(items, &(pos(&1) > last and is_integer(&1.seq)))},
        else: {0, Enum.count(items, &is_integer(&1.seq))}

    # `new_count` is the rows that wait at the end, the pill's events those with a sequence.
    new_count = min(socket.assigns.new_count, later)
    new_events = items |> Enum.take(-new_count) |> Enum.count(&is_integer(&1.seq))

    assign(socket,
      tab_count: length(items),
      earlier: earlier,
      later: later,
      earlier_events: earlier_events,
      later_events: later_events,
      new_count: new_count,
      new_events: new_events,
      unread: max(run.event_count - projected_count(run), 0),
      limit: limit_reason(run, index)
    )
  end

  # The window after items were added at one end: the rows on the page are the window's,
  # from `win_first` through `win_last`. The page keeps #{@max_dom}: past that, the other
  # end moves in, and only then, and the rows it passes leave the stream. The server
  # deletes them, as the browser would apply a stream's `limit` to each list separately
  # when the Timeline is one list per agent session.
  defp trim_window(socket, :after_append) do
    shown = shown_items(socket)
    {dropped, kept} = Enum.split(shown, max(length(shown) - @max_dom, 0))

    socket
    |> delete_rows(dropped)
    |> assign(win_first: kept |> List.first() |> then(&(&1 && pos(&1))))
  end

  defp trim_window(socket, :after_prepend) do
    {kept, dropped} = socket |> shown_items() |> Enum.split(@max_dom)

    socket
    |> delete_rows(dropped)
    |> assign(win_last: kept |> List.last() |> then(&(&1 && pos(&1))))
  end

  defp delete_rows(socket, rows),
    do: Enum.reduce(rows, socket, &stream_delete(&2, :items, %{id: row_id(&1)}))

  defp shown_items(%{assigns: %{win_first: first, win_last: last}} = socket),
    do: socket |> tab_items() |> Enum.filter(&within?(pos(&1), first, last))

  # Rows added after the window. More than the page keeps replace the window, so that no
  # row is inserted and deleted in one render.
  defp append(socket, light) when length(light) >= @max_dom,
    do: put_window(socket, Enum.take(light, -@max_dom), true)

  defp append(socket, light) do
    socket
    |> stream(:items, build(socket, light), at: -1)
    |> assign(
      win_last: pos(List.last(light)),
      win_first: socket.assigns.win_first || pos(hd(light))
    )
    |> trim_window(:after_append)
  end

  ## The limits of the record, chosen from it in this order

  # The last sequence projected, nil while none is: a registered run's projection starts at
  # its registration's sequence 1 (`Apiary.Runs.Run.projected_from/1`), which is no event.
  defp projected_through(%Run{} = run) do
    if run.projected_sequence > Run.projected_from(run), do: run.projected_sequence
  end

  # How many of the run's stored events are projected: its events start after the
  # sequence its projection starts from.
  defp projected_count(%Run{} = run), do: max(run.projected_sequence - Run.projected_from(run), 0)

  defp limit_reason(%Run{state: "pending"}, _index), do: :not_started

  defp limit_reason(%Run{} = run, index) do
    # A run that was refused never started: no session was there to send events, so their
    # absence says nothing about the hooks, a wall or the runtime.
    if Run.refused?(run), do: nil, else: session_limit(run, index)
  end

  defp session_limit(run, index) do
    # By this server's clock, from when it first heard of the run: never Forager's.
    settled? = not alive?(run) or older_than?(run.inserted_at, 60)

    cond do
      other_runtime?(run.runtime) ->
        :other_runtime

      is_binary(run.wall) and index.hook_events == 0 and settled? ->
        :vm_wall

      run.runtime == "claude" and is_nil(run.wall) and index.session_items == 0 and settled? ->
        :no_hooks

      true ->
        nil
    end
  end

  # Whether a runtime is one that sends no session events: they come from Claude Code's
  # hooks alone.
  defp other_runtime?(runtime), do: is_binary(runtime) and runtime != "claude"

  defp older_than?(%DateTime{} = at, seconds), do: DateTime.diff(DateTime.utc_now(), at) > seconds
  defp older_than?(_at, _seconds), do: false

  ## Events from the page

  @impl true
  def handle_event("load_earlier", _params, %{assigns: %{win_first: first}} = socket)
      when is_tuple(first) do
    light = socket |> tab_items() |> Enum.filter(&(pos(&1) < first)) |> Enum.take(-@page)

    socket =
      if light == [] do
        socket
      else
        socket
        # Prepending one by one reverses a list, so it is handed over reversed.
        |> stream(:items, socket |> build(light) |> Enum.reverse(), at: 0)
        |> assign(win_first: pos(hd(light)))
        |> trim_window(:after_prepend)
        |> announce(
          ngettext(
            "%{number} earlier event loaded.",
            "%{number} earlier events loaded.",
            length(light),
            number: Format.number(length(light))
          ),
          :now
        )
      end

    {:noreply, assign_window_counts(socket)}
  end

  def handle_event("load_later", _params, %{assigns: %{window_loaded: true}} = socket) do
    %{win_last: last} = socket.assigns
    light = socket |> tab_items() |> Enum.filter(&after?(&1, last)) |> Enum.take(@page)
    socket = if light == [], do: socket, else: append(socket, light)
    {:noreply, assign_window_counts(socket)}
  end

  def handle_event("show_new", _params, %{assigns: %{window_loaded: true}} = socket) do
    %{win_last: last} = socket.assigns
    tail = socket |> tab_items() |> Enum.filter(&after?(&1, last))
    first_new = tail |> Enum.take(-max(socket.assigns.new_count, 1)) |> List.first()

    socket =
      cond do
        tail == [] -> socket
        length(tail) <= @window -> append(socket, tail)
        true -> reset_window_at_end(socket)
      end

    {:noreply,
     socket
     |> assign(new_count: 0)
     |> assign_window_counts()
     |> push_event("timeline:end", %{focus: first_new && row_id(first_new)})}
  end

  def handle_event("live_end", %{"at_end" => at_end}, socket) when is_boolean(at_end) do
    {:noreply, assign(socket, at_end: at_end)}
  end

  # Show all reads a whole payload, which only a reader of the log may see: for any other
  # reader the event changes nothing. So does a Transcript's result that opens.
  def handle_event("show_all", %{"seq" => seq}, %{assigns: %{window_loaded: true}} = socket) do
    with true <- read_log?(socket),
         seq when is_integer(seq) <- sequence(seq),
         %{} = light <- Enum.find(tab_items(socket), &(&1.seq == seq)),
         true <- in_window?(socket, seq) do
      socket = assign(socket, full: MapSet.put(socket.assigns.full, seq))
      {:noreply, stream(socket, :items, build(socket, [light]))}
    else
      _ -> {:noreply, socket}
    end
  end

  # A result of the Transcript opens to every line, read whole as `show_all` reads an item,
  # and folds again to its first lines.
  def handle_event(
        "transcript_open",
        %{"seq" => seq},
        %{assigns: %{window_loaded: true}} = socket
      ),
      do: {:noreply, if(read_log?(socket), do: transcript_fold(socket, seq, true), else: socket)}

  def handle_event(
        "transcript_close",
        %{"seq" => seq},
        %{assigns: %{window_loaded: true}} = socket
      ),
      do: {:noreply, transcript_fold(socket, seq, false)}

  # A subagent's lines open or close, as the reader chose: the choice stays as it is while
  # lines arrive, and after the subagent's finish.
  def handle_event(
        "subagent_toggle",
        %{"seq" => seq},
        %{assigns: %{window_loaded: true}} = socket
      ) do
    with seq when is_integer(seq) <- sequence(seq),
         %{sub: %{open: open?}} <- Enum.find(tab_items(socket), &(&1.seq == seq and &1[:sub])) do
      case socket.assigns.tab do
        :timeline ->
          choices = Map.put(socket.assigns.timeline_choices, seq, not open?)
          {:noreply, socket |> refold(choices) |> assign_window_counts()}

        _terminal ->
          {:noreply, regroup(socket, Map.put(socket.assigns.sub_choices, seq, not open?))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # `x` or `Shift+x` reached a denied call of a closed subagent (`TimelineKeys`): the
  # subagent opens, as for a link to the call, and the call is inside the window for the
  # hook to move to. The key closes nothing.
  def handle_event(
        "subagent_open",
        %{"seq" => seq},
        %{assigns: %{window_loaded: true, tab: :timeline}} = socket
      ) do
    with seq when is_integer(seq) <- sequence(seq),
         %{lane: %{index: lane}} when is_integer(lane) <-
           Enum.find(socket.assigns.index.items, &(&1.seq == seq)),
         %{sub: %{open: false, seq: head}} <-
           Enum.find(tab_items(socket), &(&1[:sub] && &1.lane[:index] == lane)) do
      socket = refold(socket, Map.put(socket.assigns.timeline_choices, head, true), seq)
      {:noreply, assign_window_counts(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("subagent_open", _params, socket), do: {:noreply, socket}

  def handle_event(
        "subagents_all",
        %{"open" => open},
        %{assigns: %{window_loaded: true}} = socket
      )
      when open in ["true", "false"] do
    %{index: index} = socket.assigns

    choices =
      index.items
      |> TranscriptComponents.subagents(index.alive)
      |> Map.new(fn {_lane, sub} -> {sub.seq, open == "true"} end)

    {:noreply, regroup(socket, choices)}
  end

  # A line of the Transcript in Raw: the byte of the log at which the session's output line
  # `line` starts, in the stream Raw shows (`Apiary.Runs.Record.log_offset/5`). Nil when the
  # log has no such line.
  def handle_event("raw_line", %{"session" => session, "line" => line} = params, socket)
      when is_integer(session) and is_integer(line) do
    %{current_scope: scope, run: run} = socket.assigns
    stream = if params["stream"] in ~w(stdout stderr terminal), do: params["stream"]

    offset =
      if socket.assigns.tab == :terminal and Access.can?(scope, :"run.read_log", run),
        do: Record.log_offset(scope, run, session, line, stream)

    {:reply, %{offset: offset}, socket}
  end

  ## A row's Allow and Deny. What the browser names is looked up among the rows the page
  ## holds, which are the run's: an id of another run or another workspace finds nothing.

  # Without security there is no rule to write: a crafted event is dropped here, before
  # a row, a policy or a connection is read.
  def handle_event(event, _params, %{assigns: %{security: false}} = socket)
      when event in ~w(rule_open rule_change rule_cancel rule_submit),
      do: {:noreply, socket}

  def handle_event("rule_open", %{"id" => id, "action" => action}, socket)
      when is_binary(id) and action in ~w(allow deny) do
    %{connections: %{rows: rows}, acts: acts, tab: tab} = socket.assigns
    row = tab == :connections && Enum.find(rows, &(&1.id == id))
    act = row && acts && acts["cx-#{row.id}"]

    case {act, action} do
      {%{rule_option: :can_allow}, "allow"} ->
        {:noreply, open_panel(socket, row, act, :allow)}

      {%{rule_option: :can_deny}, "deny"} ->
        {:noreply, open_panel(socket, row, act, :deny)}

      # No rule decides the host: it can be denied outright as well as allowed.
      {%{rule_option: :can_allow, deny: true}, "deny"} ->
        {:noreply, open_panel(socket, row, act, :deny)}

      {%{rule_option: locked}, _} when locked in [:locked_deny, :locked_allow] ->
        {:noreply, open_refusal(socket, row, act)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "rule_change",
        params,
        %{assigns: %{rule_panel: %{refusal: nil} = panel}} = socket
      ) do
    level =
      case params["for"] do
        "target" when not is_nil(panel.target) -> :target
        "workspace" -> :workspace
        _ -> panel.level
      end

    {:noreply, assign(socket, rule_panel: %{panel | level: level, error: nil})}
  end

  def handle_event("rule_cancel", _params, socket), do: {:noreply, close_panel(socket)}

  # The rule is the domain's to make and to refuse: `rule_from_connection/4` and nothing
  # else, and what it refuses is said in its own sentence.
  def handle_event(
        "rule_submit",
        _params,
        %{assigns: %{rule_panel: %{refusal: nil, level: level} = panel}} = socket
      )
      when level in [:target, :workspace] do
    %{current_scope: scope, run: run} = socket.assigns

    # What the panel said was true of the policy it opened on. It is sent only while
    # that is still the policy: a stale Allow must not undo a deny made meanwhile.
    with :ok <- still(socket, panel),
         {:ok, connection} <- Record.connection(scope, run, panel.connection_id),
         {:ok, rule} <- Policy.rule_from_connection(scope, connection, panel.action, level) do
      {:noreply,
       socket
       |> close_panel()
       |> assign(effective: nil)
       |> refresh_policy()
       |> put_flash(:info, rule_toast(socket, panel, rule, level))
       |> announce(
         Rules.toast(
           rule,
           panel.action,
           panel.host,
           panel.path,
           if(level == :target, do: :this_target, else: :workspace)
         ),
         :now
       )}
    else
      :stale ->
        {:noreply, socket |> assign(effective: nil) |> refresh_policy() |> policy_moved()}

      {:error, %Policy.Error{message: message}} ->
        {:noreply, assign(socket, rule_panel: %{panel | error: message})}

      _not_found ->
        {:noreply,
         socket
         |> close_panel()
         |> put_flash(:error, gettext("This connection is no longer in this run."))}
    end
  end

  # A crafted event, or one for a page without a run: nothing to do.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp open_panel(socket, row, act, action) do
    %{run: run, target: target, current_scope: scope, effective: effective} =
      socket.assigns

    shared = socket.assigns.target_shared
    path = row.path || ""
    # The page holds the target's policy; the workspace's is read when a panel opens,
    # since what a rule for the workspace would be is decided by the paths of the
    # workspace's policy.
    baseline = if target, do: Policy.effective(scope, nil), else: effective

    assign(socket,
      rule_panel: %{
        anchor: "cx-#{row.id}-#{action}",
        connection_id: row.id,
        action: action,
        host: act.host,
        path: path,
        mode: Rules.mode(row),
        page: :run,
        level: if(target, do: :target, else: :workspace),
        target:
          target &&
            %{label: shown_target_label(target.system, target.path, shared)},
        targets: [],
        choice: nil,
        what: %{
          target: target && Rules.what(effective, act.host, path),
          workspace: Rules.what(baseline, act.host, path)
        },
        own_rule: target != nil and Rules.own_rule?(effective, act.host),
        seen: {Rules.seen(effective, act.host), Rules.seen(baseline, act.host)},
        rule_option: act.rule_option,
        workspace: scope.workspace.name,
        alive: alive?(run),
        fetched: fetched?(socket),
        interval: beat(run),
        consequence: deny_consequence(act[:entry]),
        error: nil,
        refusal: nil
      }
    )
    |> mark_expanded()
  end

  defp open_refusal(socket, row, act) do
    scope = socket.assigns.current_scope
    locked = locked_change(scope, act.entry)

    assign(socket,
      rule_panel: %{
        anchor: "cx-#{row.id}-lock",
        host: act.host,
        refusal: %{
          rule_option: act.rule_option,
          rule: act.entry.host,
          locked_by: locked && ApiaryWeb.People.email(locked.changed_by),
          locked_at: locked && locked.inserted_at,
          owner: Access.can?(scope, :"security_policy.lock", scope.workspace),
          who: ApiaryWeb.Edition.who_may_sentence(:"security_policy.lock", scope),
          rule_path: Rules.rule_path(scope, nil, act.entry.host),
          reader: scope.user.email
        }
      }
    )
    |> mark_expanded()
  end

  defp close_panel(socket), do: socket |> assign(rule_panel: nil) |> mark_expanded()

  # The slot's button says whether its panel is open.
  defp mark_expanded(%{assigns: %{acts: acts, rule_panel: panel}} = socket) when is_map(acts) do
    open = panel && row_of_anchor(panel.anchor)
    action = panel && panel[:action]

    assign(socket,
      acts:
        Map.new(acts, fn {id, act} ->
          {id, Map.merge(act, %{expanded: id == open, expanded_action: id == open && action})}
        end)
    )
  end

  defp mark_expanded(socket), do: socket

  # Who locked the rule and when, from the newest
  # page of the workspace's history; nil further back.
  defp locked_change(scope, entry) do
    scope
    |> Policy.list_changes(nil, 1)
    |> Map.get(:items, [])
    |> Enum.find(&(&1.action == "rule_locked" and &1.subject == entry.host))
  end

  defp deny_consequence(%{source: :workspace}) do
    %{
      target: gettext("Disables the workspace's allow rule here. Other targets keep it."),
      workspace: gettext("Replaces the workspace's allow rule.")
    }
  end

  defp deny_consequence(%{source: :target}) do
    %{
      target: gettext("Replaces this target's allow rule."),
      workspace: gettext("An allow rule on this target still holds here.")
    }
  end

  defp deny_consequence(_entry), do: %{}

  # Whether the policy is still the one the panel opened on, for the host it is about.
  defp still(socket, panel) do
    %{current_scope: scope, target: target, connections: %{rows: rows}} = socket.assigns
    effective = Policy.effective(scope, target)
    baseline = if target, do: Policy.effective(scope, nil), else: effective
    row = Enum.find(rows, &(&1.id == panel.connection_id))

    if (row && Rules.rule_option(row, effective, :run).rule_option == panel.rule_option) and
         {Rules.seen(effective, panel.host), Rules.seen(baseline, panel.host)} == panel.seen,
       do: :ok,
       else: :stale
  end

  defp policy_moved(socket) do
    socket
    |> close_panel()
    |> put_flash(:error, gettext("The policy changed; look at the row again."))
  end

  # A change of the policy under an open panel closes it when it touches its host.
  defp recheck_panel(%{assigns: %{rule_panel: %{refusal: nil} = panel}} = socket) do
    if still(socket, panel) == :ok, do: socket, else: policy_moved(socket)
  end

  defp recheck_panel(%{assigns: %{rule_panel: %{}}} = socket), do: close_panel(socket)
  defp recheck_panel(socket), do: socket

  defp rule_toast(socket, panel, rule, level) do
    %{current_scope: scope, target: target, target_shared: shared} = socket.assigns
    holder = if level == :target, do: target, else: nil

    where =
      cond do
        level != :target ->
          :workspace

        target ->
          {:target, shown_target_label(target.system, target.path, shared)}

        true ->
          :this_target
      end

    version =
      case Policy.list_changes(scope, holder, 1) do
        %{items: [%{version_after: n} | _]} when is_integer(n) ->
          gettext("Version %{n}.", n: n)

        _ ->
          nil
      end

    own =
      if level == :workspace and panel.own_rule,
        do: gettext("A rule on this target still decides here.")

    reach =
      if fetched?(socket) or not alive?(socket.assigns.run),
        do: gettext("Running sessions have it within a heartbeat."),
        else:
          gettext(
            "This run uses its machine's policy; sessions that take this one have it within a heartbeat."
          )

    [Rules.toast(rule, panel.action, panel.host, panel.path, where), version, own, reach]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  ## The policy facts of the header and of the rows

  defp target_of(scope, %Run{target_id: id}) when is_binary(id) do
    case Policy.get_target(scope, id) do
      {:ok, target} -> target
      _ -> nil
    end
  end

  defp target_of(_scope, _run), do: nil

  # A run that holds a configuration fetched from this server is one that reloads.
  defp fetched?(%{assigns: %{digests: digests}}),
    do: is_binary(digests.reported) or is_binary(digests.applied)

  # Drift is a comparison, read at mount, on each message of the policy's topic and when
  # the run reports another digest. No timer decides it. Without security there is no
  # policy to be behind.
  defp assign_policy_facts(%{assigns: %{security: false}} = socket), do: socket

  defp assign_policy_facts(%{assigns: %{run: %Run{} = run}} = socket) do
    %{current_scope: scope, target: target, versions: known} = socket.assigns
    digests = Rules.digests(scope, run)

    {reported, known} =
      lookup_version(
        known,
        scope,
        {target, socket.assigns.target_shared},
        digests.reported || digests.applied
      )

    behind? = alive?(run) and digests.drift

    in_force =
      if behind? do
        case Policy.current_configuration(scope, target) do
          {:ok, configuration} ->
            Rules.version_of(scope, configuration, target, socket.assigns.target_shared)

          _ ->
            nil
        end
      end

    socket =
      if in_force && is_nil(socket.assigns.in_force),
        do: announce(socket, gettext("This run is behind the policy in force."), :now),
        else: socket

    assign(socket,
      digests: digests,
      reported_version: reported,
      default_policy:
        is_nil(reported) and
          Policy.default_policy_digest?(scope, digests.reported || digests.applied),
      in_force: in_force,
      versions: known
    )
  end

  defp assign_policy_facts(socket), do: socket

  defp refresh_policy(%{assigns: %{security: true, run: %Run{}, loaded: true}} = socket) do
    %{current_scope: scope, target: target, tab: tab} = socket.assigns
    socket = assign_policy_facts(socket)

    if tab == :connections,
      do:
        socket
        |> assign(
          effective: Policy.effective(scope, target),
          first_hosts: RequiredHosts.first_hosts(scope.workspace)
        )
        |> assign_acts(),
      else: assign(socket, effective: nil, first_hosts: nil)
  end

  defp refresh_policy(socket), do: socket

  # What each row of the page may ask, and the line after the rows a rule already answers.
  # A harness fetch (channel `stack`) asks nothing: the stack proxy reads no rule of the
  # workspace or of a target, so its row has no Allow or Deny. A row of a host that every
  # run is allowed has the lock in place of Allow and Deny, as on Network access.
  defp assign_acts(%{assigns: %{effective: %Policy.Effective{} = effective}} = socket) do
    %{current_scope: scope, target: target, connections: %{rows: rows}} = socket.assigns
    first = socket.assigns.first_hosts || RequiredHosts.first_hosts(scope.workspace)

    rule_options =
      for row <- rows, Map.get(row, :channel) != "stack" do
        option = Rules.rule_option(row, effective, :run)
        {row, Rules.required_option(option, row, effective, first)}
      end

    changes = Rules.changes(scope, target, Enum.map(rule_options, &elem(&1, 1)))

    rule_options =
      for {row, rule_option} <- rule_options, do: {row, Rules.answered(rule_option, row, changes)}

    # Who locked a locked rule, for the lock's hint on the rows it decides: one read.
    locks =
      Rules.locks(
        scope,
        for(
          {_row, %{rule_option: option, entry: %{host: host}}} <- rule_options,
          option in [:locked_deny, :locked_allow],
          uniq: true,
          do: host
        )
      )

    acts =
      for {row, rule_option} <- rule_options, into: %{} do
        {"cx-#{row.id}", act(socket, row, rule_option, changes) |> locked(locks, scope)}
      end

    socket |> assign(acts: acts) |> mark_expanded()
  end

  defp assign_acts(socket), do: assign(socket, acts: nil)

  defp act(
         socket,
         row,
         %{rule_option: {:rule_added, action}, entry: entry} = rule_option,
         changes
       )
       when not is_nil(entry) do
    %{target: target, current_scope: scope, target_shared: shared} = socket.assigns
    holder = if entry.source == :target and target, do: target
    change = Rules.change_for(entry, changes)

    rule_option
    |> Map.merge(%{
      values: %{"id" => row.id},
      entry_host: entry.host,
      rule_path: Rules.rule_path(scope, holder, entry.host),
      after: %{
        action: action,
        level: if(entry.source == :target, do: :target, else: :workspace),
        changed?: match?(%{action: "rule_changed"}, change),
        version:
          change && is_integer(change.version) &&
            %{
              n: change.version,
              path: Rules.version_path(scope, holder, change.version),
              label: Rules.version_label(holder && holder.id, target, shared)
            },
        by: change && who(change, scope),
        at: (change && change.at) || (entry.rule && entry.rule.updated_at),
        state: after_state(socket),
        reloaded_at: reloaded_at(socket)
      }
    })
  end

  # A row a rule decides links to that rule, in the Network access section of its policy.
  defp act(socket, row, rule_option, _changes) do
    %{target: target, current_scope: scope} = socket.assigns
    entry = rule_option.entry

    Map.merge(rule_option, %{
      values: %{"id" => row.id},
      entry_host: entry && entry.host,
      rule_path:
        entry && entry.host &&
          Rules.rule_path(scope, if(entry.source == :target and target, do: target), entry.host),
      after: nil
    })
  end

  defp who(%{by_id: id}, %{user: %{id: id}}) when not is_nil(id), do: :you
  defp who(%{by: email}, _scope) when is_binary(email), do: email
  defp who(_change, _scope), do: nil

  # A locked rule's row: the way to the rule, and who locked it when that is known.
  defp locked(%{rule_option: option, entry: %{host: host}} = act, locks, scope)
       when option in [:locked_deny, :locked_allow],
       do: Map.merge(act, %{rule_path: Rules.rule_path(scope, nil, host), locked: locks[host]})

  defp locked(act, _locks, _scope), do: act

  # "In force in this run" is claimed from the record alone: the run reported the digest
  # that is in force. Never after a timer, and never of a run that takes no policy here.
  defp after_state(%{assigns: %{run: run, digests: digests}} = socket) do
    cond do
      not alive?(run) -> :ended
      not fetched?(socket) -> :machine
      is_binary(digests.reported) and digests.reported == digests.in_force -> :in_force
      true -> :pending
    end
  end

  # `applied` is the policy part of what the run applied (`Apiary.Policy.digests/2`).
  defp reloaded_at(%{assigns: %{digests: digests, policy: %{sequence: sequence}}})
       when is_integer(sequence) do
    if is_binary(digests.in_force) and digests.applied == digests.in_force,
      do: sequence
  end

  defp reloaded_at(_socket), do: nil

  defp comparable?(%{target_id: id}, %{target_id: id}), do: true
  defp comparable?(_reported, _in_force), do: false

  # A target's version is on the run's target's Policy tab: the only target a run's
  # versions are of.
  defp behind_path(scope, target, reported, in_force) do
    if comparable?(reported, in_force) and (is_nil(in_force.target_id) or target != nil),
      do:
        Rules.version_path(
          scope,
          in_force.target_id && target,
          in_force.n,
          %{"compare" => reported.n}
        ),
      else: in_force.path
  end

  ## The run's topic

  @impl true
  def handle_info(
        {:run_changed, %Run{id: id}},
        %{assigns: %{run: %Run{id: id} = old, loaded: true}} = socket
      )
      when old.state == "pending" and is_nil(old.registered_at) and is_nil(old.node_id),
      do: {:noreply, read_queued(socket)}

  def handle_info({:run_changed, %Run{} = run}, socket),
    do: {:noreply, socket |> follow_run(run) |> schedule_flush()}

  # While the run is queued, a change of its workspace's queue, or a key a machine enrolled
  # on a pool that serves the workspace, may change why it waits, or end it: the run and
  # its preparation are read again.
  def handle_info({Apiary.Dispatches, :changed}, %{assigns: %{run: %Run{} = run}} = socket) do
    if socket.assigns[:loaded] && Run.queued?(run),
      do: {:noreply, read_queued(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:key_enrolled, _key}, %{assigns: %{run: %Run{} = run}} = socket) do
    if socket.assigns[:loaded] && Run.queued?(run),
      do: {:noreply, read_queued(socket)},
      else: {:noreply, socket}
  end

  # At most one read per run per #{@coalesce_ms} ms, however many batches land: the ranges
  # that arrive in between are joined.
  def handle_info({:run_projected, %Run{} = run, first, last}, socket)
      when is_integer(first) and is_integer(last) do
    range =
      case socket.assigns.range do
        nil -> {first, last}
        {a, b} -> {min(a, first), max(b, last)}
      end

    {:noreply, socket |> follow_run(run) |> assign(range: range) |> schedule_flush()}
  end

  def handle_info(:flush, socket) do
    {:noreply, socket |> assign(flush_scheduled: false) |> flush()}
  end

  # The pool's starter reported about the removal of the run's machine: the preparation is
  # read again, settled or not, so Remove the machine shows the report.
  def handle_info(
        {:machine_end_changed, %Run{id: id}},
        %{assigns: %{run: %Run{id: id}}} = socket
      ),
      do: {:noreply, socket |> assign_preparation() |> refresh_outputs()}

  # A version was pushed to the run's work item: the preparation is read again, settled or
  # not, so Save the outputs shows a version the run pushed with no push step too, and the
  # Timeline its Pushed row.
  def handle_info(
        {:artifact_pushed, _work_item, _version},
        %{assigns: %{run: %Run{}, loaded: true}} = socket
      ),
      do: {:noreply, socket |> assign_preparation() |> refresh_outputs()}

  # Remove the machine waited 15 minutes after the run ended: the preparation is read
  # again, and the row shows the report that came, or that none came.
  def handle_info(:clean_up_due, %{assigns: %{run: %Run{}, loaded: true}} = socket),
    do: {:noreply, socket |> assign_preparation() |> refresh_outputs()}

  # Quiet is the server's word: recomputed on a timer and on every batch, never by the page.
  def handle_info(:quiet_tick, socket) do
    Process.send_after(self(), :quiet_tick, @quiet_tick_ms)

    case socket.assigns.run do
      %Run{} = run ->
        was = socket.assigns.quiet_for
        now = quiet_for(run)

        socket =
          if is_nil(was) and now != nil,
            do:
              announce(
                socket,
                gettext("No heartbeat for %{seconds} s.", seconds: Format.number(now)),
                :now
              ),
            else: socket

        socket = socket |> assign(quiet_for: now) |> read_machine_start()

        # The run as `read_machine_start/1` may have read it again.
        {:noreply,
         if(socket.assigns.tab == :timeline and socket.assigns.window_loaded,
           do: assign(socket, limit: limit_reason(socket.assigns.run, socket.assigns.index)),
           else: socket
         )}

      nil ->
        {:noreply, socket}
    end
  end

  # The policy's topic: coalesced like the run's, one read per #{@coalesce_ms} ms. A page
  # without security never subscribed, and has nothing of the policy to read again.
  def handle_info({:policy_changed, _what}, %{assigns: %{security: false}} = socket),
    do: {:noreply, socket}

  def handle_info({:policy_changed, _what}, socket) do
    if socket.assigns.policy_flush_scheduled do
      {:noreply, socket}
    else
      Process.send_after(self(), :policy_flush, @coalesce_ms)
      {:noreply, assign(socket, policy_flush_scheduled: true)}
    end
  end

  def handle_info(:policy_flush, socket) do
    {:noreply,
     socket |> assign(policy_flush_scheduled: false) |> refresh_policy() |> recheck_panel()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp schedule_flush(%{assigns: %{flush_scheduled: true}} = socket), do: socket

  defp schedule_flush(socket) do
    Process.send_after(self(), :flush, @coalesce_ms)
    assign(socket, flush_scheduled: true)
  end

  defp follow_run(%{assigns: %{run: %Run{id: id} = old}} = socket, %Run{id: id} = run) do
    # The broadcast carries the row; the key it was posted with and its node do not change.
    run = %{run | access_key: old.access_key, node: old.node}
    was_quiet? = socket.assigns.quiet_for != nil

    socket
    |> assign_run(run)
    |> assign_target_page(run)
    |> announce_change(old, run, was_quiet?)
    |> follow_digests(old, run)
  end

  defp follow_run(socket, _run), do: socket

  # The page of a queued run listens to its workspace's queue (`Apiary.Dispatches`) and to
  # the access keys of the pools that serve the workspace's runs and of the gateways their
  # choices lead to, as the work item page listens while no pool can take its run. A
  # topic the scope may not read is not listened to.
  defp listen_to_queue(scope, %Run{} = run) do
    if Run.queued?(run) do
      Apiary.Dispatches.subscribe(run.workspace_id)

      for pool <- Apiary.WorkspaceSetup.serving_pools(scope.workspace),
          node <- [pool, Apiary.Gateways.chosen(pool)],
          listenable?(scope, node),
          do: Apiary.AccessKeys.subscribe(scope, node)
    end

    :ok
  end

  defp listenable?(%{workspace: %{id: id}}, %{workspace_id: id}), do: true

  defp listenable?(%{organisation: %{id: id}}, %{workspace_id: nil, organisation_id: id}),
    do: true

  defp listenable?(_scope, %{workspace_id: nil, organisation_id: nil}), do: true
  defp listenable?(_scope, _node), do: false

  # A queued run read again with what its page loads beside it (`Apiary.Runs.Record`): its
  # node changes at the claim, which the broadcast row does not have. The page then shows
  # it as any run: queued, registered by a claim, or ended while it waited.
  defp read_queued(%{assigns: %{current_scope: scope, run: %Run{} = old}} = socket) do
    case Record.reload(scope, old) do
      %Run{} = run ->
        socket
        |> assign_run(run)
        |> assign_target_page(run)
        |> assign(:instance, Nodes.instance_of(scope, run))
        |> assign_preparation()
        |> refresh_outputs()
        |> schedule_flush()

      nil ->
        socket
    end
  end

  # A heartbeat changes nothing here. What the run reports, what it applied and whether it
  # is alive do: then, and only then, the facts are read again.
  defp follow_digests(socket, %Run{} = old, %Run{} = run) do
    same? =
      old.reported_run_configuration_digest == run.reported_run_configuration_digest and
        old.run_configuration_digest == run.run_configuration_digest and
        alive?(old) == alive?(run)

    cond do
      same? or not socket.assigns.loaded ->
        socket

      socket.assigns.tab == :connections ->
        socket |> assign_policy_facts() |> assign_acts()

      true ->
        assign_policy_facts(socket)
    end
  end

  defp announce_change(socket, %Run{state: state}, %Run{state: state} = run, was_quiet?) do
    if was_quiet? and is_nil(quiet_for(run)) and state == "running",
      do: announce(socket, gettext("Heartbeats resumed."), :now),
      else: socket
  end

  defp announce_change(socket, _old, %Run{} = run, _was_quiet?) do
    announce(socket, state_sentence(run), :now)
  end

  # A state its starter's outcome set, unlike what the exit said, is said as the header
  # says it (`outcome_sentence/1`).
  defp state_sentence(%Run{state: state} = run),
    do: outcome_sentence(run) || state_sentence(state, run)

  defp state_sentence("completed", %Run{duration_ms: ms}) when is_integer(ms),
    do: gettext("Run completed after %{duration}.", duration: format_duration_ms(ms))

  defp state_sentence("completed", _run), do: gettext("Run completed.")
  defp state_sentence("failed", %Run{exited_at: nil}), do: gettext("Run did not start.")

  # The program's exit is said where the header says it (`program_exit/1`).
  defp state_sentence("failed", run) do
    cond do
      is_nil(program_exit(run)) -> gettext("Run failed.")
      signal?(run) -> gettext("Run failed with %{signal}.", signal: shown_signal(run))
      true -> gettext("Run failed with exit %{code}.", code: run.exit_code)
    end
  end

  defp state_sentence("cancelled", run) do
    if words = reason_words(run),
      do: gettext("Run cancelled: %{reason}.", reason: words),
      else: gettext("Run cancelled.")
  end

  # Lost by its exit: why, in words. Lost by the liveness check: how long it was silent.
  defp state_sentence("lost", %Run{exited_at: %DateTime{}} = run) do
    if words = reason_words(run),
      do: gettext("Run lost: %{reason}.", reason: words),
      else: gettext("Run lost.")
  end

  # A run lost at the deadline its attach set for its end (`backstop_at`) was lost however
  # recently it beat: no heartbeat to count.
  defp state_sentence("lost", %Run{heartbeat_interval_seconds: interval} = run)
       when is_integer(interval) do
    if lost_past_backstop?(run),
      do: gettext("Run lost."),
      else:
        gettext("Run lost. No heartbeat for %{seconds} s.", seconds: Format.number(interval * 3))
  end

  defp state_sentence("lost", _run), do: gettext("Run lost.")
  defp state_sentence("running", _run), do: gettext("Run started.")
  defp state_sentence(_state, _run), do: nil

  defp lost_past_backstop?(%Run{lost_at: %DateTime{} = lost_at} = run),
    do: Apiary.Runs.Liveness.past_backstop?(run, lost_at)

  defp lost_past_backstop?(_run), do: false

  defp announce(socket, nil, _when), do: socket

  # A state change is said at once, and holds the floor: "n new events" waits its turn.
  defp announce(socket, text, :now),
    do: assign(socket, announcement: text, announced_at: System.monotonic_time(:millisecond))

  # "n new events" is said at most once every ten seconds.
  defp announce(socket, text, :throttled) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns.announced_at

    if is_nil(last) or now - last >= @announce_every_ms,
      do: assign(socket, announcement: text, announced_at: now),
      else: socket
  end

  # After the projections of the last quarter second. What is read is the range they
  # announced and what the open tab shows of it: never the run again, whatever its size.
  # The one exception is an event that arrived below what the page holds.
  defp flush(%{assigns: %{run: %Run{} = run, loaded: true}} = socket) do
    %{current_scope: scope, index: old, overview: old_rows, range: range, tab: tab} =
      socket.assigns

    socket = assign(socket, range: nil)

    {index, rows} =
      case range do
        nil ->
          {Timeline.alive(old, alive?(run)), []}

        {first, last} ->
          case Record.extend_timeline(scope, run, old, first, last) do
            {:ok, index, rows} -> {index, rows}
            :stale -> {Record.timeline(scope, run), :stale}
          end
      end

    socket = socket |> put_index(index) |> refresh_preparation(rows) |> assign_ending()
    security = socket.assigns.security

    case rows do
      :stale ->
        socket
        |> assign(
          policy: if(security, do: Record.policy(scope, run)),
          session_id: Record.session_id(scope, run),
          window_loaded: false
        )
        |> read_tab(tab, socket.assigns.decision, socket.assigns.connections.page)

      rows ->
        types = MapSet.new(rows, & &1.type)
        egress? = "dev.qory.run.egress" in types

        socket
        |> then(
          &if(security and "dev.qory.run.policy_applied" in types,
            do: &1 |> assign(policy: Record.policy(scope, run)) |> announce_reload() |> reline(),
            else: &1
          )
        )
        |> then(
          &if(egress?, do: assign(&1, counts: Record.connection_counts(scope, run)), else: &1)
        )
        # Details is beside every tab: its Record's Session is read again once the session
        # started, whatever the tab. Only `session_id` is assigned, so the Timeline's window
        # stays as it is.
        |> then(
          &if("dev.qory.runtime.started" in types,
            do: assign(&1, session_id: Record.session_id(scope, run)),
            else: &1
          )
        )
        |> flush_tab(tab, %{index: old, overview: old_rows}, types, range)
    end
    |> refresh_outputs()
  end

  defp flush(socket), do: assign(socket, range: nil)

  ## The **Run** list

  # The run's preparation (`Apiary.Runs.Preparation`), read again at each flush until it
  # is settled (`ApiaryWeb.PreparationComponents.settled?/2`) or the timeline has a
  # session's item, so a live session's flushes read it only for an event of
  # `@preparation_events`; and its machine log for an instance admin, read until it has
  # arrived.
  defp assign_preparation(%{assigns: %{run: %Run{} = run, current_scope: scope}} = socket) do
    was = layout(socket.assigns)
    preparation = Preparation.read(scope, run)

    socket
    |> assign(
      preparation: preparation,
      preparation_settled:
        PreparationComponents.settled?(preparation, alive?(run)) or
          socket.assigns.index.session_items > 0,
      machine_log: machine_log(scope, preparation, socket.assigns.machine_log)
    )
    |> assign_clean_up()
    |> resend_window(was)
  end

  # The versions the run pushed, which the Timeline lists as Pushed rows, from the
  # preparation. They are taken apart from `assign_preparation/1`, after the window
  # follows the index (`flush/1`), so that the window follows one change at a time: a
  # new version's row is inserted at its place, as an item that arrived is.
  defp refresh_outputs(%{assigns: %{preparation: preparation, outputs: outputs}} = socket) do
    versions = (preparation && Map.get(preparation, :outputs)) || []

    case socket.assigns do
      _assigns when versions == outputs ->
        socket

      %{tab: :timeline, window_tab: :timeline, window_loaded: true} ->
        old = tab_items(socket)
        socket = socket |> assign(outputs: versions) |> assign_overview()

        socket
        |> follow_items(old, tab_items(socket), fn _item -> false end)
        |> assign_window_counts()

      _assigns ->
        socket |> assign(outputs: versions) |> assign_overview()
    end
  end

  # The artifacts topic of the run's work item (`Apiary.Artifacts`), so that a version the
  # run pushes reaches Save the outputs with no step or exit event; none for a run with no
  # work item, or for a reader who may not read it.
  defp subscribe_outputs(scope, run) do
    case Preparation.work_item(scope, run) do
      nil -> :ok
      work_item -> Apiary.Artifacts.subscribe(scope, work_item)
    end
  end

  # The agent session of a row of the Timeline, light (`tab_items/2`) or built (`build/2`),
  # as `Apiary.Runs.Preparation.session_of/2` places it: by its session number, its
  # sequence, or, for a Pushed row, its time. The sequence of the session's start; nil
  # before one starts.
  defp row_session(%{sessions: sessions} = preparation, row) do
    Preparation.session_of(sessions, Map.get(preparation, :unrun, []), %{
      sequence: row[:sequence] || row[:seq],
      session: row[:session],
      time: row[:time] || row[:at]
    })
  end

  defp row_session(_preparation, _row), do: nil

  # Whether the preparation has a session that never ran its agent.
  defp unrun?(%{unrun: [_ | _]}), do: true
  defp unrun?(_preparation), do: false

  # The light item `?seq=` points at (`focused`), for its session number.
  defp focused_row(index, seq),
    do: Enum.find(index.items, &(&1.seq == seq)) || %{seq: seq}

  # The Timeline's row at a place of the window (`pos/1`), for its session number. A place
  # that is no row's is taken as the sequence it starts with.
  defp window_row(%{overview: rows}, place) when is_tuple(place),
    do: Enum.find(rows, &(pos(&1) == place)) || %{seq: window_sequence(place)}

  defp window_row(_assigns, _place), do: %{}

  # Whether the Timeline is one list per agent session, with one after the list for the
  # items of a session that never ran its agent (`timeline_list/1`): the browser then
  # places each item of the stream in the list of its session.
  defp split?(%{preparation: %{sessions: [_, _ | _]}} = assigns), do: grouped?(assigns)
  defp split?(%{preparation: %{unrun: [_ | _]}} = assigns), do: grouped?(assigns)
  defp split?(_assigns), do: false

  # Each item of `items`, in order, with its index in the list the browser shows it in:
  # among the items of its session when the Timeline is split (`split?/1`), else among all.
  defp list_places(items, assigns) do
    if split?(assigns) do
      {placed, _counts} =
        Enum.map_reduce(items, %{}, fn item, counts ->
          session = row_session(assigns.preparation, item)
          at = Map.get(counts, session, 0)
          {{item, at}, Map.put(counts, session, at + 1)}
        end)

      placed
    else
      Enum.with_index(items)
    end
  end

  # The id of the Timeline of `session`, the sequence of a session's start: `timeline` for
  # the first session's, or for the one Timeline of a run with one session or none; else
  # `timeline-` and the session's place; `timeline-after-list` for `:after_list`.
  defp timeline_id([_, _ | _] = sessions, session) when is_integer(session) do
    case Enum.find_index(sessions, &(&1.sequence == session)) do
      index when is_integer(index) and index > 0 -> "timeline-#{index + 1}"
      _first -> "timeline"
    end
  end

  defp timeline_id(_sessions, :after_list), do: "timeline-after-list"
  defp timeline_id(_sessions, _session), do: "timeline"

  # The sequence a place of the window (`pos/1`) starts with, nil for no window.
  defp window_sequence({seq, _rest}), do: seq
  defp window_sequence(_pos), do: nil

  # Whether the Timeline is drawn inside Run the agent of the **Run** list
  # (`ApiaryWeb.PreparationComponents.session_group?/2`).
  defp grouped?(%{preparation: preparation, clean_up: clean_up}),
    do: PreparationComponents.session_group?(preparation, clean_up)

  defp grouped?(_assigns), do: false

  # Once the session started, or once the list appears around a session that started, the
  # Timeline is drawn inside Run the agent, so the stream's container is a new element
  # and has none of the items sent before: the window is sent again as it is, with the
  # count of new items kept. So is it once a session's wall fails after its start: the
  # items of that session sent before move to the Timeline after the list. `was` is the
  # `layout/1` before. A later agent session's start needs no such resend: its Timeline
  # is new, but the items sent before belong to the sessions before it, and the flush
  # inserts the items after it once the preparation has the session (`flush/1`).
  defp resend_window(%{assigns: %{tab: :timeline, window_loaded: true}} = socket, was) do
    %{win_first: first, win_last: last} = socket.assigns

    if was != layout(socket.assigns) and is_tuple(first) do
      %{new_count: count, new_events: events} = socket.assigns
      light = socket |> tab_items() |> Enum.filter(&within?(pos(&1), first, last))
      socket |> put_window(light, true) |> assign(new_count: count, new_events: events)
    else
      socket
    end
  end

  defp resend_window(socket, _was), do: socket

  # Whether the Timeline is drawn inside Run the agent (`grouped?/1`), and the starts of
  # the sessions that never ran their agent, whose items are after the list.
  defp layout(assigns) do
    unrun = (assigns[:preparation] && Map.get(assigns.preparation, :unrun)) || []
    {grouped?(assigns), Enum.map(unrun, & &1.sequence)}
  end

  # Remove the machine as it is now (`ApiaryWeb.PreparationComponents.clean_up/3`), and,
  # while it waits for a report, one timer for the moment it no longer does, which reads
  # the preparation again. The timer before is cancelled.
  defp assign_clean_up(%{assigns: %{preparation: preparation, run: run}} = socket) do
    now = DateTime.utc_now()
    if ref = socket.assigns.clean_up_timer, do: Process.cancel_timer(ref)

    timer =
      case PreparationComponents.clean_up_due(preparation, run, now) do
        nil ->
          nil

        due_at ->
          Process.send_after(self(), :clean_up_due, DateTime.diff(due_at, now, :millisecond) + 1)
      end

    assign(socket,
      clean_up: PreparationComponents.clean_up(preparation, run, now),
      clean_up_timer: timer
    )
  end

  # The notes of the run outside its agent sessions, `{reason, runtime}` each, shown above
  # the Timeline: after the **Run** list when the page has one, never above it. Where the
  # Timeline is inside the sessions (`PreparationComponents.session_group?/2`), each note
  # is in the session it is about (`session_notes/4`), and none is here. The run's runtime
  # is its last session's (`Apiary.Runs.Fold`), so its note (`limit_reason/2`) is about that
  # session; a run whose sessions ran Claude Code and another runtime has a second note,
  # for the others (`mixed_limit/4`).
  defp run_notes(limit, run, index, preparation, clean_up) do
    if PreparationComponents.session_group?(preparation, clean_up) do
      []
    else
      reason = shown_limit(limit, preparation)

      Enum.reject(
        [reason && {reason, run.runtime}, mixed_limit(limit, run, index, preparation)],
        &is_nil/1
      )
    end
  end

  # A run that stopped before an agent session ran has no note, as at a wall that failed:
  # its failed step and How it ended state what happened. A wall's note is for a run whose
  # agent session started.
  defp shown_limit(_limit, %{stopped: %{}, session_started_at: nil}), do: nil
  defp shown_limit(:vm_wall, %{session_started_at: nil}), do: nil
  defp shown_limit(limit, _preparation), do: limit

  # The second note of a run whose sessions ran Claude Code and another runtime, nil for
  # any other run: for a run whose last session ran another runtime, the note of the wall
  # or the hooks of its Claude Code sessions; else the note of the other runtime.
  defp mixed_limit(:other_runtime, run, index, %{sessions: sessions} = preparation) do
    with true <- Enum.any?(sessions, &(&1.runtime == "claude")),
         reason when reason != nil <- shown_limit(claude_limit(run, index, "claude"), preparation) do
      {reason, nil}
    else
      _none -> nil
    end
  end

  defp mixed_limit(limit, _run, _index, %{sessions: sessions} = preparation)
       when limit != :not_started do
    with %{runtime: runtime} <- Enum.find(sessions, &other_runtime?(&1.runtime)),
         :other_runtime <- shown_limit(:other_runtime, preparation) do
      {:other_runtime, runtime}
    else
      _none -> nil
    end
  end

  defp mixed_limit(_limit, _run, _index, _preparation), do: nil

  # The note in the agent session that started at `sequence`, above its Timeline: for a
  # runtime that sends no session events, the note on that runtime; for Claude Code, the
  # note of the wall or the hooks (`claude_limit/3`), which every Claude Code session of
  # the run shows, as the wall and the hook count are the run's. A run of Claude Code alone
  # has that note as `limit`, read again when it settles (`limit_reason/2`).
  defp session_notes(limit, run, index, %{sessions: sessions}, sequence) do
    case Enum.find(sessions, &(&1.sequence == sequence)) do
      %{runtime: runtime} ->
        cond do
          other_runtime?(runtime) -> [{:other_runtime, runtime}]
          limit in [:vm_wall, :no_hooks] -> [{limit, nil}]
          reason = limit == :other_runtime && claude_limit(run, index, runtime) -> [{reason, nil}]
          true -> []
        end

      nil ->
        []
    end
  end

  defp session_notes(_limit, _run, _index, _preparation, _sequence), do: []

  # The note of a run's Claude Code sessions, as `session_limit/2` reads it for a run of
  # Claude Code alone.
  defp claude_limit(run, index, runtime) do
    settled? = not alive?(run) or older_than?(run.inserted_at, 60)

    cond do
      is_binary(run.wall) and index.hook_events == 0 and settled? ->
        :vm_wall

      runtime == "claude" and is_nil(run.wall) and index.session_items == 0 and settled? ->
        :no_hooks

      true ->
        nil
    end
  end

  # A `:stale` read returns no rows to look at, so the preparation is read.
  defp refresh_preparation(%{assigns: %{preparation_settled: true}} = socket, rows)
       when is_list(rows) do
    if Enum.any?(rows, &(&1.type in @preparation_events)),
      do: assign_preparation(socket),
      else: socket
  end

  defp refresh_preparation(socket, _rows), do: assign_preparation(socket)

  # The starter's `dispatched` and the redemption of the run's code are broadcast on the
  # run's topic once they commit. As that broadcast runs after the commit and may fail,
  # the Timeline tab, which shows the preparation, also reads them at each quiet tick
  # while the machine is starting. A step's start reaches the page as an event, through
  # `flush/1`.
  defp read_machine_start(
         %{
           assigns: %{
             tab: :timeline,
             preparation_settled: false,
             preparation: %{machine: %{started: started}}
           }
         } = socket
       )
       when started.state == "running" do
    case Record.reload(socket.assigns.current_scope, socket.assigns.run) do
      %Run{} = run -> socket |> follow_run(run) |> assign_preparation() |> refresh_outputs()
      nil -> socket
    end
  end

  defp read_machine_start(socket), do: socket

  defp machine_log(_scope, _preparation, {:ok, _text, _truncated} = read), do: read
  defp machine_log(_scope, %{machine: nil}, _read), do: :hidden

  defp machine_log(scope, %{machine: %{dispatch_id: dispatch_id} = machine}, _read) do
    if ApiaryWeb.Access.instance_can?(scope, :"instance.read") do
      case Dispatches.machine_log(scope, dispatch_id) do
        {:ok, %{text: text, truncated: truncated}} -> {:ok, text, truncated}
        {:error, :unreadable} -> :unreadable
        {:error, _none} -> no_machine_log(machine)
      end
    else
      :hidden
    end
  end

  # No machine log is recorded: none has arrived, or one did and the machine logs'
  # retention deleted it. A prune deletes under the setting in force when it runs, which
  # can be lower than today's, so a log can be gone once the setting's least days have
  # passed since the claim. The line shows today's setting.
  defp no_machine_log(%{requested_at: requested_at}) do
    least = MachineLogs.retention_min_days()

    if DateTime.compare(DateTime.add(requested_at, least, :day), DateTime.utc_now()) == :lt,
      do: {:deleted, MachineLogs.retention_days()},
      else: :none
  end

  # A reload arrived: the lines after the rows say at which sequence the run reloaded,
  # and they were made when the run's row changed, before this event was read.
  defp reline(%{assigns: %{tab: :connections, effective: %Policy.Effective{}}} = socket),
    do: assign_acts(socket)

  defp reline(socket), do: socket

  defp announce_reload(%{assigns: %{index: index, policy: %{sequence: sequence}}} = socket) do
    reload? =
      Enum.any?(
        index.items,
        &(&1.kind == :policy_applied and &1.seq == sequence and &1[:previous_seq])
      )

    version = socket.assigns.versions[socket.assigns.run.run_configuration_digest]

    cond do
      not reload? ->
        socket

      version ->
        announce(
          socket,
          gettext("The run reloaded its policy: version %{n}.", n: version.n),
          :now
        )

      true ->
        announce(socket, gettext("The run reloaded its policy."), :now)
    end
  end

  defp announce_reload(socket), do: socket

  defp flush_tab(%{assigns: %{window_loaded: true}} = socket, :timeline, old, _types, _range),
    do: socket |> follow_timeline(old) |> assign_window_counts()

  # The log is read by difference: what followed the last chunk the page knows of. The
  # hook is told how far it has come, and fetches the bytes itself. Only for a reader who
  # may read the log, as the tab is: `refuse_terminal/1` keeps anyone else off it already.
  defp flush_tab(socket, :terminal, old, _types, range) do
    socket =
      if socket.assigns.window_loaded,
        do: socket |> follow_timeline(old) |> assign_window_counts(),
        else: socket

    %{current_scope: scope, run: run, log: log} = socket.assigns
    log? = range != nil and Access.can?(scope, :"run.read_log", run)
    more = if log?, do: Record.log_summary(scope, run, log.through), else: %{chunks: 0}

    if more.chunks > 0 do
      log = Record.add_log_summary(log, more)
      socket |> assign(log: log) |> push_event("log_advanced", %{through: log.through})
    else
      socket
    end
  end

  defp flush_tab(socket, :connections, _old, types, _range) do
    if "dev.qory.run.egress" in types,
      do:
        read_tab(socket, :connections, socket.assigns.decision, socket.assigns.connections.page),
      else: socket
  end

  defp flush_tab(socket, _tab, _old, _types, _range), do: socket

  # New and changed items of the tab, after the index was extended from `old`, the index
  # and the overview's rows before. The Transcript is followed while its window ends at
  # the record's end; the Timeline while the reader is at its live end too, else a pill
  # counts what arrived.
  defp follow_timeline(socket, %{index: old_index, overview: old_rows}) do
    %{index: index, tab: tab} = socket.assigns
    # A result is drawn again when the Transcript's choice of texts changes: it shows its
    # text only in a run with neither texts nor turn ends.
    fallback_changed = tab == :terminal and fallback(old_index) != fallback(index)
    again? = &(fallback_changed and &1.kind == :result)

    follow_items(
      socket,
      tab_items(old_index, tab, %{socket.assigns | overview: old_rows}),
      tab_items(index, tab, socket.assigns),
      again?
    )
  end

  # The tab's items were `old` and are `new`; `again?` picks the items drawn again even
  # when they did not change.
  defp follow_items(socket, old, new, again?) do
    %{win_first: first, win_last: last, tab: tab} = socket.assigns
    old_last = old |> List.last() |> then(&(&1 && pos(&1)))
    at_end = tab == :terminal or (socket.assigns.at_end and socket.assigns.new_count == 0)

    if is_nil(first) do
      # Nothing was on the page yet: the window starts with what arrived.
      reset_window(socket, socket.assigns.focused)
    else
      appended = Enum.filter(new, &after?(&1, old_last))
      follow? = appended != [] and last == old_last and at_end

      # A window that follows the live end keeps #{@max_dom} rows with the rows that
      # arrived: its start moves in here, so the rows it passes leave the stream before any
      # row is drawn again, and none is both drawn again and deleted.
      bounds =
        if follow? do
          kept = new |> Enum.filter(&(pos(&1) >= first)) |> Enum.take(-@max_dom)
          {pos(hd(kept)), last}
        end

      # An item the tab no longer shows leaves the window: on the Terminal tab, a turn's end
      # once a text of the run arrived, which has the turn's message; on either tab, the
      # items of a subagent that finished, which close.
      {socket, in_window, removed} = redraw_window(socket, old, new, again?, bounds)

      cond do
        # Every line of the window left (a subagent's, closed, or more rows arrived than
        # the page keeps): the window is drawn again at the end.
        in_window == [] and removed != [] ->
          put_window(socket, Enum.take(new, -@window), true)

        appended == [] ->
          fit_window(socket, new)

        follow? ->
          socket |> assign(win_first: elem(bounds, 0)) |> append(appended)

        # The pill counts the events among the rows that wait, and a Main session or
        # Pushed row is none.
        true ->
          events = Enum.count(appended, &is_integer(&1.seq))

          socket
          |> fit_window(new)
          |> assign(new_count: socket.assigns.new_count + length(appended))
          |> then(fn socket ->
            if events == 0,
              do: socket,
              else:
                announce(
                  socket,
                  ngettext("%{number} new event.", "%{number} new events.", events,
                    number: Format.number(events)
                  ),
                  :throttled
                )
          end)
      end
    end
  end

  # The window drawn again from the tab's items before (`old`) and after (`new`) a change,
  # with its ends at `bounds`, or where they were for nil: the items that were inside it
  # and that the tab no longer shows leave it, the items that changed, or that `again?`
  # picks, are drawn again, and the items that came into it are inserted at their places.
  # Returns the socket, the items now inside the window and the sequences that left it.
  defp redraw_window(socket, old, new, again?, bounds) do
    %{win_first: first, win_last: last} = socket.assigns
    {to_first, to_last} = bounds || {first, last}

    old_in_window =
      for item <- old, within?(pos(item), first, last), into: %{}, do: {row_id(item), item}

    in_window = Enum.filter(new, &within?(pos(&1), to_first, to_last))

    changed =
      for item <- in_window,
          id = row_id(item),
          is_map_key(old_in_window, id),
          old_in_window[id] != item or again?.(item),
          do: item

    shown = MapSet.new(in_window, &row_id/1)
    removed = for {id, _item} <- old_in_window, id not in shown, do: id

    socket = Enum.reduce(removed, socket, &stream_delete(&2, :items, %{id: &1}))
    socket = if changed == [], do: socket, else: stream(socket, :items, build(socket, changed))
    {insert_inside(socket, in_window, old_in_window), in_window, removed}
  end

  # The Timeline after the reader opened or closed subagents (`choices`): the items of a
  # subagent that opened are inserted at their places in time, among the other agents'
  # items, and those of one that closed leave; the rows whose rails changed are drawn
  # again. The window keeps its start, and its end, or the tab's end when it reached it;
  # it has a whole window at least, while items follow that the pill does not count, and
  # at most what the page keeps. When that leaves out the row shown for `keep`
  # (`shown_seq/3`), the window is drawn around that row instead: a stream's reset keeps
  # the inserts made before it in the same render, so the two cannot follow each other.
  defp refold(socket, choices, keep \\ nil)

  defp refold(%{assigns: %{win_first: first, win_last: last}} = socket, choices, keep)
       when is_tuple(first) and is_tuple(last) do
    old = tab_items(socket)
    at_end = last == old |> List.last() |> then(&(&1 && pos(&1)))
    socket = assign(socket, timeline_choices: choices)
    new = tab_items(socket)
    from = Enum.drop_while(new, &(pos(&1) < first))
    inside = if at_end, do: from, else: Enum.take_while(from, &(pos(&1) <= last))

    # The new events the pill counts wait for it: the window fills up to them.
    waiting =
      if socket.assigns.new_count > 0,
        do: old |> Enum.take(-socket.assigns.new_count) |> hd() |> pos()

    fill = if waiting, do: Enum.take_while(from, &(pos(&1) < waiting)), else: from

    light =
      if length(inside) < @window,
        do: Enum.take(fill, @window),
        else: Enum.take(inside, @max_dom)

    case light do
      [] ->
        put_window(socket, Enum.take(new, -@window), true)

      _light ->
        bounds = {pos(hd(light)), pos(List.last(light))}
        shown = shown_seq(new, :timeline, keep)
        kept = shown && Enum.find(new, &(&1.seq == shown))

        if kept && not within?(pos(kept), elem(bounds, 0), elem(bounds, 1)) do
          reset_window(socket, keep)
        else
          {socket, _in_window, _removed} =
            redraw_window(socket, old, new, fn _item -> false end, bounds)

          assign(socket, win_first: elem(bounds, 0), win_last: elem(bounds, 1))
        end
    end
  end

  defp refold(socket, choices, _keep), do: assign(socket, timeline_choices: choices)

  # A `?seq=` that points at an item of a closed subagent, or a `?lane=` that keeps a closed
  # subagent's lane, opens that subagent on the Timeline. Only a new `?seq=` or `?lane=`
  # does (`opened_for`, what the last address had): a subagent the reader closed stays
  # closed while another parameter changes.
  defp open_for_params(socket) do
    %{index: index, focused: focused, lane: lane, timeline_choices: choices} = socket.assigns
    {was_focused, was_lane} = socket.assigns.opened_for
    socket = assign(socket, opened_for: {focused, lane})

    # The heads of the closed subagents, by their lane's index.
    closed =
      for %{sub: %{open: false, seq: seq}} = item <- tab_items(index, :timeline, socket.assigns),
          into: %{},
          do: {item.lane.index, seq}

    focused_lane =
      focused != was_focused && focused &&
        Enum.find_value(index.items, &(&1.seq == focused && &1.lane[:index]))

    lane_index = lane != was_lane && lane && (Timeline.lane(index, lane) || %{})[:index]

    opened =
      for {i, except} <- [{focused_lane, focused}, {lane_index, nil}],
          head = closed[i],
          head != nil and head != except,
          into: choices,
          do: {head, true}

    cond do
      opened == choices -> socket
      socket.assigns.window_tab == :timeline -> refold(socket, opened, focused)
      true -> assign(socket, timeline_choices: opened)
    end
  end

  # The lines that arrived inside the window, each at its place: a subagent's line under
  # its start, before the lines that came after the start. They are inserted in order, so
  # each one's index is its place in the list that shows it: the window, or, with one list
  # per agent session, the window's items of its session (`list_places/2`). Past what the
  # page keeps, the window is drawn again at its end.
  defp insert_inside(socket, in_window, old_in_window) do
    inside =
      in_window
      |> list_places(socket.assigns)
      |> Enum.reject(fn {item, _at} -> is_map_key(old_in_window, row_id(item)) end)

    cond do
      inside == [] ->
        socket

      length(in_window) > @max_dom ->
        put_window(socket, Enum.take(in_window, -@max_dom), true)

      true ->
        built = socket |> build(Enum.map(inside, &elem(&1, 0))) |> Map.new(&{&1.id, &1})

        Enum.reduce(inside, socket, fn {item, at}, socket ->
          case built[row_id(item)] do
            nil -> socket
            full -> stream_insert(socket, :items, full, at: at)
          end
        end)
    end
  end

  # The window's ends, moved to the first and last items still inside them: lines that
  # left (a subagent's, closed) can have been one.
  defp fit_window(%{assigns: %{win_first: first, win_last: last}} = socket, items)
       when is_tuple(first) and is_tuple(last) do
    case Enum.filter(items, &within?(pos(&1), first, last)) do
      [] -> socket
      inside -> assign(socket, win_first: pos(hd(inside)), win_last: pos(List.last(inside)))
    end
  end

  defp fit_window(socket, _items), do: socket

  # The Transcript after the reader opened or closed subagents' lines: the window from the
  # start of the group its first line is in, which can have closed, through its last line
  # and the lines of a group whose start is in it, or through the end when the window was
  # at the end; a whole window at least, filled from before that start when too few lines
  # follow it. Results the reader opened stay open.
  defp regroup(socket, choices) do
    %{win_first: first, win_last: last} = socket.assigns
    old = tab_items(socket)
    at_end = is_nil(last) or last == old |> List.last() |> then(&(&1 && pos(&1)))
    socket = assign(socket, sub_choices: choices)
    new = tab_items(socket)

    rest =
      if is_tuple(first),
        do: Enum.drop_while(new, &(pos(&1) < {elem(first, 0), elem(first, 0)})),
        else: new

    inside =
      if at_end,
        do: rest,
        else:
          Enum.take_while(rest, fn item ->
            pos(item) <= last or (item[:group] != nil and {item.group, item.group} <= last)
          end)

    light =
      cond do
        length(inside) >= @window -> Enum.take(inside, @max_dom)
        length(rest) >= @window -> Enum.take(rest, @window)
        true -> Enum.take(new, -@window)
      end

    socket
    |> put_window(light, true)
    |> assign_window_counts()
  end

  # Whether the Transcript shows turn ends and result texts in place of texts: none in a run
  # recorded before Forager sent them (`ApiaryWeb.TranscriptComponents.transcript?/2`).
  defp fallback(index),
    do: {index.texts == 0, Enum.any?(index.items, &(&1.kind == :turn_finished))}

  ## Words

  defp alive?(%Run{state: state}), do: state in Run.alive_states()
  # A run whose exit was recorded, whatever its state: one that ended Lost by its exit too.
  # A run that Qory Apiary marked lost after its keep-alive stopped, and one that did not
  # start, have no exit.
  defp exited?(%Run{exited_at: exited_at}), do: exited_at != nil

  # CPU time as a duration, to the second, a half second rounded up: "12 s",
  # "41 m 10 s", "5 h 00 m" (`ApiaryWeb.RunComponents.format_seconds/1`).
  defp cpu_time(ms), do: ApiaryWeb.RunComponents.format_seconds(div(ms + 500, 1000))

  # The peak alone, "9.8 GiB", or, with the machine type's memory, both in GiB to a tenth:
  # "9.8 of 16 GiB".
  defp peak_memory(bytes, %{spec: %{"memory_mib" => mib}}) when is_integer(mib),
    do: gettext("%{peak} of %{memory} GiB", peak: gib(bytes), memory: gib(mib * 1_048_576))

  defp peak_memory(bytes, _machine_type), do: ApiaryWeb.ArtifactComponents.size(bytes)

  # Bytes in GiB to a tenth, a half rounded up: "9.8", "16".
  defp gib(bytes) do
    tenths = div(bytes * 10 + 536_870_912, 1_073_741_824)

    if rem(tenths, 10) == 0,
      do: Format.number(div(tenths, 10)),
      else: Format.number(tenths / 10, digits: 1)
  end

  # The program's exit as recorded, whatever the run's state. `-1` with no signal is the
  # gateway's placeholder for an exit it wrote: the program's exit code was not
  # recorded. A signal is shown as a text Forager sent is, and one with nothing left to
  # show is none (`shown_signal/1`).
  defp exit_value(%Run{} = run) do
    if signal = shown_signal(run), do: signal, else: exit_code_value(run)
  end

  defp exit_code_value(%Run{exit_code: -1}), do: gettext("not recorded")

  defp exit_code_value(%Run{exit_code: code}) when is_integer(code),
    do: Integer.to_string(code)

  defp exit_code_value(_run), do: gettext("n/a")

  # The program's exit after a failed run's state, when the program exited
  # non-zero by itself and no reason words stand: "exit 1", "SIGKILL". Nil otherwise.
  # A run whose outcome's sentence says the exit says it there.
  defp program_exit(%Run{} = run) do
    if run.state == "failed" and is_nil(reason_words(run)) and
         is_nil(outcome_sentence(run)) do
      cond do
        signal?(run) -> shown_signal(run)
        is_integer(run.exit_code) and run.exit_code not in [0, -1] -> exit_words(run.exit_code)
        true -> nil
      end
    end
  end

  defp exit_words(code), do: gettext("exit %{code}", code: code)

  defp signal?(%Run{} = run), do: shown_signal(run) != nil

  defp connections_count(%{denied: denied}) when denied > 0,
    do: ngettext("%{number} denied", "%{number} denied", denied, number: Format.number(denied))

  defp connections_count(%{all: all}) when all > 0, do: Format.number(all)
  defp connections_count(_counts), do: nil

  defp interactive_words(true), do: gettext("Yes, on a pseudo-terminal")
  defp interactive_words(false), do: gettext("No, on pipes")
  defp interactive_words(_unknown), do: gettext("n/a")

  defp join(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  # The strings the record kept of a list, and how many the list had.
  defp strings([], _count), do: nil

  defp strings(shown, count) when is_list(shown) do
    more = (count || 0) - length(shown)
    list = Enum.map_join(shown, ", ", &shown_sent/1)

    if more > 0,
      do: gettext("%{list} and %{number} more", list: list, number: Format.number(more)),
      else: list
  end

  defp strings(_other, _count), do: nil

  # Credentials or tools by name, each with the argument the policy passed to it, when it
  # passed one, and the hosts it is for. The event lists each use of a credential, all with
  # the same name and argument: they show as one, with the hosts of every use. Never a
  # credential's value: the event contains none. Past the entries read, "and N more"
  # counts the entries not shown, grouped the same way.
  attr :id, :string, required: true
  attr :named, :list, required: true, doc: ~s(`%{"name", "argument", "hosts"}` each)
  attr :count, :integer, default: 0, doc: "the entries of the event, grouped"

  defp named_hosts(assigns) do
    named = group_named(assigns.named)
    assigns = assign(assigns, named: named, more: (assigns.count || 0) - length(named))

    ~H"""
    <dd id={@id} class="font-mono">
      <span :if={@named == []}>{gettext("none")}</span>
      <span :for={{item, i} <- Enum.with_index(@named)} id={"#{@id}-#{i}"}>{if i > 0, do: ", "}{item.name}<span :if={
        item.argument
      }>{" "}<code class="q-rule">{item.argument}</code></span><span :if={item.hosts}>{" "}({item.hosts})</span></span>
      <span :if={@more > 0}>
        {ngettext("and %{number} more", "and %{number} more", @more, number: Format.number(@more))}
      </span>
    </dd>
    """
  end

  # In the order of the first use, with the hosts of every use in order, each once, joined;
  # nil for none.
  defp group_named(named) when is_list(named) do
    by = &{&1["name"], &1["argument"]}
    grouped = Enum.group_by(named, by, &List.wrap(&1["hosts"]))

    for {name, argument} = key <- named |> Enum.map(by) |> Enum.uniq() do
      hosts = grouped[key] |> Enum.concat() |> Enum.uniq()

      %{
        name: shown_sent(name),
        argument: shown_sent(argument),
        hosts: if(hosts != [], do: Enum.map_join(hosts, ", ", &shown_sent/1))
      }
    end
  end

  defp group_named(_other), do: []
end
