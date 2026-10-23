defmodule ApiaryWeb.TargetLive.Show do
  @moduledoc """
  One target's page, in the target's words.

  **Its address** is the target's public id, `/:org/:workspace/targets/tg_…`
  (`ApiaryWeb.TargetComponents.target_path/3`), never its system or its path, which are
  Forager's labels. Overview is the bare address, and Policy (`…/tg_…/policy`, with more
  paths after it) is there where the reader may read the security policy. An id of no
  target of the workspace, and a tab the reader may not read, are not found.

  **The lists live once, at the workspace** (the narrowing ruling): the page has no Runs or
  Network access tab. Its Overview leads to the runs list and to Network access narrowed to
  the target, by its id (`?target=tg_…`, `Apiary.Runs.Filters.target_params/1`).

  The header names the target in its notation, its path, `acme/shop`, and its system
  before it only where the path is shared, `git.example/acme/shop` (the title and the
  breadcrumb do too; its full `system/path` is the name's tooltip), with the reader's
  pin, one muted line (how many runs since it was first seen, its last run, and its
  policy mode only where it overrides the workspace's) and a link to it in its system when the system
  is a host name. The breadcrumb ends with the section, a link to the targets' list, and
  the target, and the sidebar marks its pin.

  - **Overview**: its last runs and the destinations its runs were denied in fourteen
    days, one line each, each card with its link to the narrowed list; beside them, as
    plain text, what it is, the same path in other systems, its runs a day, its machines
    and runtimes.
  - **Policy**: the target's view of the policy (`ApiaryWeb.PolicyLive.Target`).

  A tab is a separate mount: the tabs are navigations, and the Policy tab gets the page's
  parameters, events and messages while it is open. Overview follows the workspace's
  topic: a run of the target on the page changes in place; a new one is counted, never
  inserted under the reader, and comes in when asked.
  """

  # With the `factory` feature, which the documentation leaves out, Overview ends with
  # three more parts. Where the target's collection is assigned to the workspace, and it
  # and its adapter have items, the Backlog card: one switch, whether its tickets come
  # into the workspace's Backlog, named with its source's word for them, which owners and
  # admins turn at once (Apiary.Adapters.Collections.set_backlog/3) and anyone else reads,
  # disabled, with who may change it. After it, where the reader may read the workspace's
  # work items, the Environment card (Apiary.Environments.section/2): for each node pool
  # of the workspace, the image a run of the target on the pool starts in, as
  # Apiary.Environments.image_for/2 gives it, in mono, its digest cut to twelve characters
  # and the whole reference its title, when it was built and from which commit, or that
  # runs wait until the target's environment image is built, or that runs use the pool's
  # default image and why, or, where the policy in force for the target sets an image,
  # that runs use the image set in the policy; whether a build runs
  # or waits; and the last build's failure, never the reason a starter gave. Where no pool
  # serves the workspace, or the target names no environment, one line says so instead.
  # Its Rebuild queues a build for each pool (Apiary.Environments.rebuild/2), for whoever
  # may ask for one (`target.rebuild_environment`), where the target names an environment
  # and a pool serves the workspace; a reader who may not sees no button. After it, under
  # the same condition, where the workspace's domain has a label for a run's paths
  # (`Apiary.Lingo.Domain.paths_label/1`), what its runs also read
  # (`Apiary.Targets.further_repositories/1`), one path a line, with Change, for those who
  # may change it (`target.set_further_repositories`), which leads to its form page
  # (`ApiaryWeb.TargetLive.FurtherRepositories`).

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :observability
  on_mount {ApiaryWeb.Access, :"run.read"}

  import ApiaryWeb.TargetComponents

  alias Apiary.{Access, Environments, Runs, Targets}
  alias Apiary.Adapters.Collections
  alias Apiary.Lingo.Domain
  alias Apiary.Runs.{Filters, Target}
  alias ApiaryWeb.{PolicyLive, SourceComponents}

  @recent 5
  @window_days 14

  @impl true
  def mount(%{"target_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope
    security = Access.can?(scope, :"security_policy.read", scope.workspace)

    case {Targets.get_by_public_id(scope, public_id), tab(socket.assigns.live_action, security)} do
      {%Target{} = target, {:ok, tab}} -> {:ok, mount_target(socket, target, tab, security)}
      _not_found -> raise Ecto.NoResultsError, queryable: Target
    end
  end

  # The target's name carries its system only where another target of the workspace has
  # its path (`TargetComponents.with_system?/3`, given the page's `shared`).
  defp mount_target(socket, target, tab, security) do
    scope = socket.assigns.current_scope

    socket
    |> assign(
      target: target,
      shared: Targets.shared?(scope, target.path),
      tab: elem(tab, 0),
      security: security,
      pinned: Targets.pinned?(scope, target),
      facts: nil,
      runs: nil,
      new_runs: 0
    )
    |> load_backlog()
    |> load_environment()
    |> load_further()
    |> load_summary()
    |> mount_tab(tab)
  end

  # The tab the route's action names. The Policy tab's actions are its paths
  # (`ApiaryWeb.PolicyLive.Target`), there only where the reader may read the policy.
  @policy_actions [:rules, :history, :document, :version, :export, :new_rule, :edit_rule]

  defp tab(:overview, _security), do: {:ok, {:overview}}
  defp tab(action, true) when action in @policy_actions, do: {:ok, {:policy, action}}
  defp tab(_action, _security), do: :error

  defp mount_tab(socket, {:overview}) do
    if connected?(socket), do: Runs.subscribe(socket.assigns.current_scope)

    socket
    |> assign(:page_title, name(socket.assigns.target, socket.assigns.shared))
    |> load_overview()
  end

  # The tab names the target as the page does, and writes its links (`base`) by its id.
  defp mount_tab(socket, {:policy, action}) do
    %{target: target, shared: shared} = socket.assigns

    socket
    |> PolicyLive.Target.mount(target, shared)
    |> assign(
      action: action,
      page_title: gettext("Policy · %{target}", target: name(target, shared))
    )
  end

  @impl true
  def handle_params(%{"target_id" => public_id} = params, uri, socket) do
    %{target: target, tab: current} = socket.assigns

    case {public_id == target.public_id, tab(socket.assigns.live_action, socket.assigns.security)} do
      {true, {:ok, {:policy, action}}} when current == :policy ->
        PolicyLive.Target.handle_params(
          Map.delete(params, "target_id"),
          assign(socket, :action, action)
        )

      {true, {:ok, {:overview}}} when current == :overview ->
        {:noreply, socket}

      # Another target or another tab, reached by a patch: a mount of its own.
      _other ->
        {:noreply, push_navigate(socket, to: URI.parse(uri).path, replace: true)}
    end
  end

  @impl true
  def handle_event("target_pin", _params, %{assigns: %{target: _}} = socket) do
    %{current_scope: scope, target: target, pinned: pinned} = socket.assigns

    case if(pinned, do: Targets.unpin(scope, target), else: Targets.pin(scope, target)) do
      :ok ->
        pins = Targets.list_pins(scope)

        {:noreply,
         socket
         |> assign(:pinned, !pinned)
         |> assign(:nav_counts, Map.put(socket.assigns.nav_counts || %{}, :pins, pins))}

      {:error, _refused} ->
        {:noreply, socket}
    end
  end

  # The Backlog card's switch: turned the other way from what the page shows, with a
  # toast that says what is so now. A refusal says who may change it; a target whose
  # collection went meanwhile loses its card.
  def handle_event("set_backlog", _params, %{assigns: %{tab: :overview}} = socket) do
    %{current_scope: scope, target: target, shared: shared, backlog: backlog} = socket.assigns
    on = !(backlog && backlog.on)

    case Collections.set_backlog(scope, target, on) do
      {:ok, _count} ->
        {:noreply,
         socket
         |> assign(:backlog, %{on: on, item_noun: backlog && backlog.item_noun})
         |> put_flash(:info, backlog_words(on, name(target, shared), backlog))}

      {:error, :not_found} ->
        {:noreply, load_backlog(socket)}

      {:error, _refused} ->
        {:noreply,
         socket
         |> load_backlog()
         |> put_flash(:error, only_admins_change(scope))}
    end
  end

  # Rebuild: a build queued for each pool whose build of the target does not wait
  # unclaimed, with a toast that says whether one was queued or every pool's waits
  # already. A refusal, or a target that names no environment any more, reads the card
  # again and says nothing.
  def handle_event("rebuild_environment", _params, %{assigns: %{tab: :overview}} = socket) do
    %{current_scope: scope, target: target, shared: shared} = socket.assigns

    case Environments.rebuild(scope, target) do
      {:ok, 0} ->
        {:noreply,
         socket
         |> load_environment()
         |> put_flash(
           :info,
           gettext("A build of %{target} is already waiting.", target: name(target, shared))
         )}

      {:ok, _queued} ->
        {:noreply,
         socket
         |> load_environment()
         |> put_flash(
           :info,
           gettext("A build of %{target} is queued.", target: name(target, shared))
         )}

      {:error, _refused} ->
        {:noreply, load_environment(socket)}
    end
  end

  def handle_event("show_new_runs", _params, %{assigns: %{tab: :overview}} = socket),
    do: {:noreply, socket |> assign(:new_runs, 0) |> load_summary() |> load_overview()}

  def handle_event(event, params, %{assigns: %{tab: :policy}} = socket),
    do: PolicyLive.Target.handle_event(event, params, socket)

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(message, %{assigns: %{tab: :policy}} = socket),
    do: PolicyLive.Target.handle_info(message, socket)

  # A run of the target: one the page shows changes in place; a new one is counted.
  def handle_info(
        {:run_changed, %{target_id: id} = run},
        %{assigns: %{target: %{id: id}}} = socket
      ) do
    case socket.assigns.runs do
      runs when is_list(runs) ->
        # The broadcast carries the row; the run's node, read with the list, does not change.
        if Enum.any?(runs, &(&1.id == run.id)) do
          runs = Enum.map(runs, &if(&1.id == run.id, do: Map.put(run, :node, &1.node), else: &1))
          {:noreply, assign(socket, :runs, runs)}
        else
          {:noreply, update(socket, :new_runs, &(&1 + 1))}
        end

      _loading ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:target_runs, {:ok, runs}, socket),
    do: {:noreply, assign(socket, :runs, runs)}

  def handle_async(:target_runs, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :runs, [])}

  def handle_async(:target_summary, {:ok, summary}, socket),
    do: {:noreply, assign(socket, :facts, summary)}

  def handle_async(:target_summary, {:exit, _reason}, socket), do: {:noreply, socket}

  ## Reads

  # Whether the target's tickets come into the Backlog, where its collection is assigned
  # to the workspace and the reader may read its work items, and whether the reader may
  # turn it.
  defp load_backlog(socket) do
    %{current_scope: scope, target: target} = socket.assigns

    assign(socket,
      backlog: Collections.backlog_switch(scope, target),
      may_set_backlog: Access.can?(scope, :"collection.set_backlog", scope.organisation)
    )
  end

  # What the target's environment is for each node pool of the workspace, where the reader
  # may read its work items, and whether the reader may ask for a build of it: where it
  # names an environment, which only a collection assigned to the workspace does, and a
  # pool serves the workspace.
  defp load_environment(socket) do
    %{current_scope: scope, target: target} = socket.assigns
    environment = Environments.section(scope, target)

    assign(socket,
      environment: environment,
      may_rebuild: may_rebuild?(scope, target, environment)
    )
  end

  defp may_rebuild?(scope, target, %{named: true, pools: [_ | _]}),
    do: Access.can?(scope, :"target.rebuild_environment", target)

  defp may_rebuild?(_scope, _target, _environment), do: false

  # What the target's runs also read, where the reader is shown the work items and the
  # workspace's domain has a label for a run's paths (`Apiary.Lingo.Domain.paths_label/1`),
  # and whether the reader may change it.
  defp load_further(socket) do
    %{current_scope: scope, target: target} = socket.assigns

    assign(socket,
      further:
        if(
          Access.can?(scope, :"work_item.read", scope.workspace) and
            Domain.paths_label(scope.workspace) != nil,
          do: Targets.further_repositories(target)
        ),
      may_set_further: Access.can?(scope, :"target.set_further_repositories", target)
    )
  end

  # `backlog` is the card's, with what the target's sources call their items.
  defp backlog_words(true, target, backlog),
    do:
      gettext("The %{items} of %{target} now come into the Backlog.",
        items: backlog_items(backlog),
        target: target
      )

  defp backlog_words(false, target, backlog),
    do:
      gettext("The %{items} of %{target} no longer come into the Backlog.",
        items: backlog_items(backlog),
        target: target
      )

  defp backlog_items(backlog), do: SourceComponents.items(backlog && backlog.item_noun)

  # Who may turn the switch, in the edition's words where it has some.
  defp only_admins_change(scope),
    do:
      ApiaryWeb.Access.who_may(
        scope,
        :"collection.set_backlog",
        gettext("Only owners and admins change this.")
      )

  defp load_summary(socket) do
    if connected?(socket) do
      %{current_scope: scope, target: target} = socket.assigns
      start_async(socket, :target_summary, fn -> Targets.summary(scope, target) end)
    else
      socket
    end
  end

  defp load_overview(socket) do
    if connected?(socket) do
      %{current_scope: scope, target: target} = socket.assigns
      since = DateTime.add(DateTime.utc_now(), -@window_days * 86_400, :second)

      socket
      |> start_async(:target_runs, fn -> Targets.recent_runs(scope, target, @recent) end)
      |> assign_async(:about, fn ->
        {:ok,
         %{
           about: %{
             denied: Targets.denied_destinations(scope, target, since),
             machines: Targets.machines(scope, target),
             runtimes: Targets.runtimes(scope, target),
             elsewhere: Targets.elsewhere(scope, target)
           }
         }}
      end)
    else
      assign(socket, :about, Phoenix.LiveView.AsyncResult.loading())
    end
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:targets}
      target={@target.id}
      width="list"
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/targets"}>
        {gettext("Targets")}
      </:crumb>
      <:crumb navigate={@tab != :overview && target_path(@current_scope, @target)}>
        <.target_name
          path={@target.path}
          system={@target.system}
          shared={@shared}
        />
      </:crumb>
      <%!-- A version of the target's policy and its export, as the workspace's own. --%>
      <:crumb
        :if={@tab == :policy && @action in [:version, :export] && @v}
        navigate={@action == :export && "#{@base}/versions/#{@v.configuration.version}"}
      >
        {gettext("Version %{version}", version: @v.configuration.version)}
      </:crumb>
      <:crumb :if={@tab == :policy && @action == :export && @v}>{gettext("Export")}</:crumb>
      <%!-- The rule form, a page of the Policy tab: back to the tab's list as it was left. --%>
      <:crumb :if={rule_form?(assigns)} patch={PolicyLive.Common.cancel_path(assigns)}>
        {gettext("Policy")}
      </:crumb>
      <:crumb :if={rule_form?(assigns)}>
        {if @action == :new_rule, do: gettext("New rule"), else: gettext("Edit rule")}
      </:crumb>

      <.target_header
        :if={!rule_form?(assigns)}
        target={@target}
        shared={@shared}
        pinned={@pinned}
        facts={@facts}
        security={@security}
      />

      <.page_tabs
        :if={!rule_form?(assigns)}
        id="target-tabs"
        label={gettext("Target")}
        current={@tab}
      >
        <:tab
          key={:overview}
          navigate={target_path(@current_scope, @target)}
          icon="hero-book-open"
        >
          {gettext("Overview")}
        </:tab>
        <:tab
          :if={@security}
          key={:policy}
          navigate={target_path(@current_scope, @target, ["policy"])}
          icon="hero-shield-check"
        >
          {gettext("Policy")}
        </:tab>
      </.page_tabs>

      <.overview
        :if={@tab == :overview}
        target={@target}
        shared={@shared}
        runs={@runs}
        about={@about}
        facts={@facts}
        new_runs={@new_runs}
        scope={@current_scope}
        backlog={@backlog}
        may_set_backlog={@may_set_backlog}
        environment={@environment}
        may_rebuild={@may_rebuild}
        further={@further}
        may_set_further={@may_set_further}
      />

      <PolicyLive.Target.content :if={@tab == :policy} {assigns} />
    </Layouts.app>
    """
  end

  # The header: the target in its notation, the reader's pin, one muted line and the
  # way to it in its system.
  attr :target, :map, required: true
  attr :shared, :boolean, required: true
  attr :pinned, :boolean, required: true
  attr :facts, :any, required: true
  attr :security, :boolean, required: true

  defp target_header(assigns) do
    assigns = assign(assigns, :external, external(assigns.target))

    ~H"""
    <header id="target-header" class="q-tgt-head">
      <div class="min-w-0 flex-1">
        <h1 class="q-tgt-h1 outline-none" tabindex="-1">
          <.icon name="hero-folder" class="size-5 flex-none text-muted" />
          <.target_name
            path={@target.path}
            system={@target.system}
            shared={@shared}
            class="min-w-0 truncate"
          />
        </h1>
        <p id="target-meta" class="q-tgt-meta">
          <span :if={!@facts} class="skeleton q-skel w-72"></span>
          <span :if={@facts && @facts.runs > 0}>
            {ngettext(
              "%{number} run since %{date}",
              "%{number} runs since %{date}",
              @facts.runs,
              number: Format.number(@facts.runs),
              date: Format.date(@target.first_seen_at)
            )}
          </span>
          <span :if={@facts && @facts.runs == 0}>
            {gettext("First seen %{date}, no run in the record",
              date: Format.date(@target.first_seen_at)
            )}
          </span>
          <span :if={@facts && @facts.last} class="q-tgt-meta-sep" aria-hidden="true">·</span>
          <span :if={@facts && @facts.last}>
            <.rich text={rich_gettext("last run %{time}", time: {:part, :time})}>
              <:part name={:time}><.relative_time at={@facts.last.at} /></:part>
            </.rich>
          </span>
          <span
            :if={@facts && @security && @target.egress_mode}
            class="q-tgt-meta-sep"
            aria-hidden="true"
          >
            ·
          </span>
          <span :if={@facts && @security && @target.egress_mode} id="target-mode">
            {own_mode_words(@target.egress_mode)}
          </span>
        </p>
      </div>
      <div class="q-tgt-actions">
        <.pin_button id="target-pin" target={@target} shared={@shared} pinned={@pinned} label />
        <.button :if={@external} id="target-external" href={@external}>
          {gettext("Open on %{system}", system: @target.system)}
          <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" />
        </.button>
      </div>
    </header>
    """
  end

  attr :target, :map, required: true
  attr :shared, :boolean, required: true
  attr :runs, :any, required: true
  attr :about, :any, required: true
  attr :facts, :any, required: true
  attr :new_runs, :integer, required: true
  attr :scope, :any, required: true
  attr :backlog, :map, default: nil
  attr :may_set_backlog, :boolean, default: false
  attr :environment, :map, default: nil
  attr :may_rebuild, :boolean, default: false
  attr :further, :list, default: nil
  attr :may_set_further, :boolean, default: false

  defp overview(assigns) do
    assigns =
      assign(assigns,
        denied: about_value(assigns.about, :denied),
        elsewhere: about_value(assigns.about, :elsewhere) || [],
        machines: about_value(assigns.about, :machines) || [],
        runtimes: about_value(assigns.about, :runtimes) || []
      )

    ~H"""
    <div id="target-overview" class="q-tgt-ov">
      <div class="q-tgt-ov-main">
        <section class="q-tgt-card" aria-labelledby="target-last-runs-h">
          <div class="q-tgt-card-h">
            <h2 id="target-last-runs-h">{gettext("Last runs")}</h2>
            <.new_runs count={@new_runs} />
            <span class="grow"></span>
            <.link
              :if={@facts && @facts.runs > 0}
              id="target-all-runs"
              navigate={list_path(@scope, :runs, @target)}
              class="q-tgt-more"
            >
              {ngettext("All %{number} run", "All %{number} runs", @facts.runs,
                number: Format.number(@facts.runs)
              )}<.icon name="hero-arrow-right-micro" class="size-3.5" />
            </.link>
          </div>
          <.card_skeleton :if={@runs == nil} rows={3} />
          <p :if={@runs == []} class="q-tgt-card-empty">
            {gettext("No run of this target is in the record.")}
          </p>
          <.run_rows
            :if={@runs not in [nil, []]}
            id="target-last-runs"
            label={gettext("The last runs")}
            runs={@runs}
            scope={@scope}
            class="q-tgt-inset"
          />
        </section>

        <section class="q-tgt-card" aria-labelledby="target-denied-h">
          <div class="q-tgt-card-h">
            <h2 id="target-denied-h">{gettext("Denied, 14 days")}</h2>
            <span :if={@denied && @denied.attempts > 0} class="q-tgt-card-n">
              {denied_words(@denied)}
            </span>
            <span class="grow"></span>
            <.link
              id="target-denied-connections"
              navigate={list_path(@scope, :network, @target, decision: "denied")}
              class="q-tgt-more"
            >
              {gettext("Network access")}<.icon name="hero-arrow-right-micro" class="size-3.5" />
            </.link>
          </div>
          <.card_skeleton :if={@about.loading} rows={2} />
          <p :if={@denied && @denied.rows == []} class="q-tgt-card-empty">
            {gettext("No run of this target was denied anything in the last 14 days.")}
          </p>
          <ul :if={@denied && @denied.rows != []} id="target-denied" class="q-tgt-dn">
            <li
              :for={row <- @denied.rows}
              id={"target-denied-#{:erlang.phash2({row.host, row.port, row.path})}"}
              title={"#{sent(row.host)}:#{row.port}#{sent(row.path)}"}
            >
              <.icon name="hero-no-symbol-micro" class="size-3.5 text-faint" />
              <span class="q-tgt-dn-dest"><bdi>{sent(row.host)}</bdi><span class="text-faint">:{row.port}</span><span
                :if={row.path not in [nil, ""]}
                class="text-muted"
              ><bdi>{sent(row.path)}</bdi></span></span>
              <span>{attempts_words(row)}</span>
              <span class="q-tgt-dn-t">
                <.rich text={rich_gettext("last %{time}", time: {:part, :time})}>
                  <:part name={:time}><.relative_time at={row.last_at} /></:part>
                </.rich>
              </span>
            </li>
          </ul>
        </section>

        <section
          :if={@backlog}
          id="target-backlog"
          class="q-tgt-card"
          aria-labelledby="target-backlog-h"
        >
          <div class="q-tgt-card-h">
            <h2 id="target-backlog-h">{gettext("Backlog")}</h2>
          </div>
          <div class="q-tgt-card-b">
            <.switch
              id="target-backlog-switch"
              label={gettext("Take its %{items} into the Backlog", items: backlog_items(@backlog))}
              checked={@backlog.on}
              disabled={!@may_set_backlog}
              phx-click={@may_set_backlog && "set_backlog"}
            >
              {gettext(
                "If its %{items} only track bugs, turn this off. Work items already taken in stay.",
                items: backlog_items(@backlog)
              )}
            </.switch>
            <p :if={!@may_set_backlog} id="target-backlog-read-only" class="q-tgt-card-ro">
              {only_admins_change(@scope)}
            </p>
          </div>
        </section>

        <section
          :if={@environment}
          id="target-environment"
          class="q-tgt-card"
          aria-labelledby="target-environment-h"
        >
          <div class="q-tgt-card-h">
            <h2 id="target-environment-h">{gettext("Environment")}</h2>
            <span class="grow"></span>
            <.button
              :if={@may_rebuild}
              id="target-environment-rebuild"
              size="xs"
              phx-click="rebuild_environment"
              loading_text={gettext("Asking")}
            >
              {gettext("Rebuild")}
            </.button>
          </div>
          <p
            :if={@environment.state == :no_pool}
            id="target-environment-no-pool"
            class="q-tgt-card-empty"
          >
            {gettext("No pool serves the workspace of this target.")}
          </p>
          <p
            :if={@environment.state == :no_environment}
            id="target-environment-none"
            class="q-tgt-card-empty"
          >
            {gettext("This target has no environment set, so runs use each pool's default image.")}
          </p>
          <ul :if={@environment.state == :pools} id="target-environment-pools" class="q-tgt-env">
            <li :for={pool <- @environment.pools} id={"target-environment-pool-#{pool.id}"}>
              <h3 class="q-tgt-env-pool">{pool.name}</h3>
              <p class="q-tgt-env-line">
                <.environment_image id={"target-environment-pool-#{pool.id}"} pool={pool} />
                <span :if={pool.running} id={"target-environment-pool-#{pool.id}-running"}>
                  {gettext("A build is running.")}
                </span>
                <span :if={pool.waiting} id={"target-environment-pool-#{pool.id}-waiting"}>
                  {gettext("A build is waiting.")}
                </span>
              </p>
              <p
                :if={pool.serves == :image && pool.commit}
                id={"target-environment-pool-#{pool.id}-commit"}
                class="q-tgt-env-line"
              >
                <.rich text={
                  rich_gettext("from %{commit}", commit: {:m, {:bdi, short_commit(pool.commit)}})
                } />
              </p>
              <p
                :if={pool.failure}
                id={"target-environment-pool-#{pool.id}-failure"}
                class="q-tgt-env-line q-hot"
              >
                {failure_words(pool.failure)}
              </p>
            </li>
          </ul>
        </section>

        <section
          :if={@further}
          id="target-further-repositories"
          class="q-tgt-card"
          aria-labelledby="target-further-repositories-h"
        >
          <div class="q-tgt-card-h">
            <h2 id="target-further-repositories-h">{gettext("Targets its runs also read")}</h2>
            <span :if={@further != []} class="q-tgt-card-n">
              {Format.number(length(@further))}
            </span>
            <span class="grow"></span>
            <.link
              :if={@may_set_further}
              id="target-further-repositories-change"
              navigate={target_path(@scope, @target, ["also-read"])}
              class="q-tgt-more"
            >
              {gettext("Change")}<.icon name="hero-arrow-right-micro" class="size-3.5" />
            </.link>
          </div>
          <p :if={@further == []} id="target-further-repositories-empty" class="q-tgt-card-empty">
            {gettext("Its runs read no other target.")}
          </p>
          <ul :if={@further != []} id="target-further-repositories-rows" class="q-tgt-also">
            <li
              :for={{path, n} <- Enum.with_index(@further, 1)}
              id={"target-further-repositories-row-#{n}"}
              title={path}
            >
              {path}
            </li>
          </ul>
        </section>
      </div>

      <aside id="target-about" class="q-tgt-about" aria-label={gettext("About this target")}>
        <section>
          <h3>{gettext("About")}</h3>
          <dl class="q-tgt-kv">
            <dt>{gettext("System")}</dt>
            <dd class="font-mono"><.external_text text={@target.system} /></dd>
            <dt>{gettext("Path")}</dt>
            <dd class="break-all font-mono"><.external_text text={@target.path} /></dd>
            <dt>{gettext("First seen")}</dt>
            <dd>
              {Format.date(@target.first_seen_at)}
              <span :if={@facts && @facts.first} class="text-faint">
                ·
                <.rich text={rich_gettext("run %{id}", id: {:part, :id})}>
                  <:part name={:id}>
                    <.link
                      navigate={
                        ~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{@facts.first.public_id}"
                      }
                      class="font-mono text-xs hover:underline"
                    >{short_id(@facts.first.public_id)}</.link>
                  </:part>
                </.rich>
              </span>
            </dd>
          </dl>
        </section>

        <section :if={@elsewhere != []}>
          <h3>{gettext("The same path elsewhere")}</h3>
          <ul class="q-tgt-pl">
            <li :for={{other, runs} <- @elsewhere}>
              <.link navigate={target_path(@scope, other)} class="q-tgt-pl-name">
                <.target_name path={other.path} system={other.system} />
              </.link>
              <span class="q-tgt-pl-c">
                {ngettext("%{number} run", "%{number} runs", runs, number: Format.number(runs))}
              </span>
            </li>
          </ul>
        </section>

        <section class="q-tgt-bigspark">
          <h3>{gettext("Runs, 14 days")}</h3>
          <span :if={!@facts} class="skeleton q-skel h-10 w-full"></span>
          <.sparkline :if={@facts} values={@facts.days} />
          <p :if={@facts}>{window_words(@facts.window)}</p>
        </section>

        <section :if={@machines != []}>
          <h3>{gettext("Machines")}</h3>
          <ul class="q-tgt-pl">
            <li :for={{host, runs} <- @machines}>
              <span class="q-tgt-pl-name font-mono"><.external_text text={host} /></span>
              <span class="q-tgt-pl-c">{Format.number(runs)}</span>
            </li>
          </ul>
        </section>

        <section :if={@runtimes != []}>
          <h3>{gettext("Runtimes")}</h3>
          <ul class="q-tgt-pl">
            <li :for={{runtime, runs} <- @runtimes}>
              <span class="q-tgt-pl-name font-mono"><.external_text text={runtime} /></span>
              <span class="q-tgt-pl-c">{Format.number(runs)}</span>
            </li>
          </ul>
        </section>
      </aside>
    </div>
    """
  end

  # What runs of a pool start in: the image the pool's build of the target's
  # `environment_ref` made, with when it was built, or that they wait for that build, or
  # the pool's default image, and why.
  attr :id, :string, required: true
  attr :pool, :map, required: true

  defp environment_image(%{pool: %{serves: :image}} = assigns) do
    ~H"""
    <span id={"#{@id}-image"} class="q-tgt-env-image" title={@pool.image}>
      {short_image(@pool.image)}
    </span>
    <span id={"#{@id}-built"}>
      <.rich text={rich_gettext("built %{time}", time: {:part, :time})}>
        <:part name={:time}>
          <time datetime={DateTime.to_iso8601(@pool.built_at)}>{built_time(@pool.built_at)}</time>
        </:part>
      </.rich>
    </span>
    """
  end

  defp environment_image(%{pool: %{serves: :default}} = assigns) do
    ~H"""
    <span id={"#{@id}-default"}>{gettext("The pool's default image.")}</span>
    """
  end

  defp environment_image(%{pool: %{serves: :held}} = assigns) do
    ~H"""
    <span id={"#{@id}-held"}>
      {gettext("Runs wait until this target's environment image is built.")}
    </span>
    """
  end

  defp environment_image(%{pool: %{serves: :policy}} = assigns) do
    ~H"""
    <span id={"#{@id}-policy"}>{gettext("Runs use the image set in this workspace's policy.")}</span>
    """
  end

  defp environment_image(%{pool: %{serves: :retired}} = assigns) do
    ~H"""
    <span id={"#{@id}-retired"}>
      {gettext("Runs use the pool's default image: this target no longer has an environment set.")}
    </span>
    """
  end

  # The runs that landed since the list was read: counted, and in when asked.
  attr :count, :integer, required: true

  defp new_runs(assigns) do
    ~H"""
    <button
      :if={@count > 0}
      id="target-new-runs"
      type="button"
      class="q-tgt-new"
      phx-click="show_new_runs"
    >
      <.icon name="hero-arrow-path-micro" class="size-3.5" />
      {ngettext("%{number} new run", "%{number} new runs", @count, number: Format.number(@count))}
    </button>
    """
  end

  attr :rows, :integer, required: true

  defp card_skeleton(assigns) do
    ~H"""
    <div class="grid gap-3 px-4 py-3" aria-busy="true">
      <span
        :for={n <- 1..@rows}
        class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-64", else: "w-80")]}
      ></span>
    </div>
    """
  end

  ## Words and paths

  # The Policy tab's New rule or Edit rule page: a form alone, without the target's header
  # and tabs.
  defp rule_form?(%{tab: :policy, action: action, loaded: true})
       when action in [:new_rule, :edit_rule],
       do: true

  defp rule_form?(_assigns), do: false

  # The workspace's runs list or Network access narrowed to the target, by its id, then the
  # list's parameters.
  defp list_path(scope, list, target, params \\ []) do
    %{organisation: organisation, workspace: workspace} = scope
    target_params = Filters.target_params([target.public_id])
    narrowed_path(organisation, workspace, list, target_params, params)
  end

  # A list's path with the target's parameter first, then the list's, in their order.
  defp narrowed_path(organisation, workspace, list, target_params, params) do
    path =
      case list do
        :runs -> ~p"/#{organisation}/#{workspace}/runs"
        :network -> ~p"/#{organisation}/#{workspace}/network"
      end

    path <> "?" <> URI.encode_query(Enum.sort(target_params) ++ params)
  end

  # The target in words, in its notation: its system only where its path is shared.
  defp name(target, shared), do: target_label(target.system, target.path, shared)

  # A text Forager sent, a denied destination's host or path, as the page shows it where
  # markup cannot go or around a cut (`Apiary.ExternalText.sent/1`).
  defp sent(text), do: Apiary.ExternalText.sent(text)

  # The target in its system, when the system is a host name: https, the path's segments
  # escaped.
  defp external(%{system: system, path: path}) do
    if Regex.match?(
         ~r/^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+(:\d{1,5})?$/i,
         system
       ) do
      segments =
        path
        |> String.split("/")
        |> Enum.map(&URI.encode(&1, fn c -> URI.char_unreserved?(c) end))

      "https://#{system}/" <> Enum.join(segments, "/")
    end
  end

  # An image pinned by its digest, its digest cut to the twelve characters every page
  # shows of one; a reference without a digest as it is.
  defp short_image(reference) do
    case String.split(reference, "@sha256:", parts: 2) do
      [name, hex] when byte_size(hex) > 12 ->
        name <> "@sha256:" <> String.slice(hex, 0, 12) <> "…"

      _whole ->
        reference
    end
  end

  # The commit a build was made from, as a pool reported it, cleaned as a page shows a text
  # a node sent (`Apiary.ExternalText.sent/1`), then cut to its first seven characters.
  # The cut counts graphemes, so a control character shown as U+FFFD is one of the seven,
  # and a character is never cut apart from what joins it.
  defp short_commit(commit), do: commit |> Apiary.ExternalText.sent() |> String.slice(0, 7)

  # When a build was made, its year only where it is not the current one.
  defp built_time(at) do
    if Format.local(at).year == Format.local(DateTime.utc_now()).year,
      do: Format.datetime(at, year: false),
      else: Format.datetime(at)
  end

  # The last build's failure, by its cause; the reason a starter gave is never shown.
  defp failure_words(:released), do: gettext("The last build was given back.")
  defp failure_words(:lost), do: gettext("The last build was lost before it finished.")
  defp failure_words(:failed), do: gettext("The last build failed.")

  # The time a build has before it is lost, as it is now: the record keeps no time with
  # its failure.
  defp failure_words(:timed_out),
    do:
      gettext("The last build failed: it ran past %{duration}.",
        duration:
          ApiaryWeb.OverviewComponents.duration_words(
            Apiary.Dispatches.backstop_seconds(Apiary.Dispatches.DispatchRun.prebuild())
          )
      )

  defp own_mode_words("observe"), do: gettext("overrides the mode: observe")
  defp own_mode_words("enforce"), do: gettext("overrides the mode: enforce")

  defp about_value(%{ok?: true, result: about}, key), do: Map.get(about, key)
  defp about_value(_about, _key), do: nil

  defp denied_words(%{attempts: attempts, destinations: destinations}) do
    gettext("%{attempts} to %{destinations}",
      attempts:
        ngettext("%{number} attempt", "%{number} attempts", attempts,
          number: Format.number(attempts)
        ),
      destinations:
        ngettext("%{number} destination", "%{number} destinations", destinations,
          number: Format.number(destinations)
        )
    )
  end

  defp attempts_words(%{attempts: attempts, runs: runs}) do
    gettext("%{attempts} in %{runs}",
      attempts:
        ngettext("%{number} attempt", "%{number} attempts", attempts,
          number: Format.number(attempts)
        ),
      runs: ngettext("%{number} run", "%{number} runs", runs, number: Format.number(runs))
    )
  end

  defp window_words(%{runs: 0}), do: gettext("No run in the last 14 days.")

  defp window_words(%{runs: runs, ended_well: well, ended_badly: badly, denied: denied}) do
    [
      ngettext("%{number} run", "%{number} runs", runs, number: Format.number(runs)),
      well + badly > 0 &&
        gettext("%{percent}% ended well", percent: round(well * 100 / (well + badly))),
      denied > 0 &&
        ngettext("%{number} denied attempt", "%{number} denied attempts", denied,
          number: Format.number(denied)
        )
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end
end
