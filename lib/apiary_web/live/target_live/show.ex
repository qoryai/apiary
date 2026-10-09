defmodule ApiaryWeb.TargetLive.Show do
  @moduledoc """
  One target's page, GitHub's repository page in the target's words.

  **Its address** is the target's path alone, `/:org/:workspace/targets/acme/shop`, and the
  path after its system, `…/targets/gitlab.com/acme/shop`, only where two targets of the
  workspace share the path (question 9, answer A; `ApiaryWeb.TargetComponents.target_path/5`).
  Its tabs follow a `-` segment: Overview is the bare address, and Policy (`…/-/policy`,
  with its own paths after it) is there where the reader may read the security policy.
  The address is read in this order:

    * the path and its system, where the path is shared: the target;
    * the path alone, of one target of the workspace: that target;
    * the path and its system, where the path is not shared: an old address, sent on to
      the path alone with its tab and its query;
    * the path alone, shared by two targets or more, or an address that reads both as one
      target's system and path and as another's path alone: a page that names each, with
      a link to it by an address that names it alone, since this one does not say which;
      an old tab's address that reads as two targets comes there too, with its tab;
    * anything else, and a tab the page does not know: not found.

  A `-` first in the address is the system `-`, not the tab's separator.

  **The lists live once, at the workspace** (the narrowing ruling): the page has no Runs or
  Network access tab. Its Overview leads to the runs list and to Network access narrowed to
  the target (`?target=acme/shop`, the system only where the path is shared,
  `Apiary.Runs.Filters.target_params/3`), and the old tabs' addresses, `…/-/runs`,
  `…/-/network` and `…/-/connections`, are sent on to those lists with their query.

  The header names the target as it is addressed, its path, `acme/shop`, and its system
  before it only where the path is shared, `gitlab.com/acme/shop` (the title and the
  breadcrumb do too; its full `system/path` is the name's tooltip), with the reader's
  pin, one muted line (how many runs since it was first seen, its last run, and its
  policy mode only where it sets its own) and a link to it in its system when the system
  is a host name. The breadcrumb ends with the section, a link to the targets' list, and
  the target, and the sidebar marks its pin.

  - **Overview**: its last runs and the destinations its runs were denied in fourteen
    days, one line each, each card with its link to the narrowed list; beside them, as
    plain text, what it is, the same path in other systems, its runs a day, its machines
    and runtimes.
  - **Policy**: the target's view of the policy (`ApiaryWeb.PolicyLive.Target`).

  A tab is its own mount: the tabs are navigations, and the Policy tab gets the page's
  parameters, events and messages while it is open. Overview follows the workspace's
  topic: a run of the target on the page changes in place; a new one is counted, never
  inserted under the reader, and comes in when asked.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :observability
  on_mount {ApiaryWeb.Access, :"run.read"}

  import Ecto.Query, only: [from: 2]
  import ApiaryWeb.TargetComponents

  alias Apiary.{Access, Features, Repo, Runs, Targets}
  alias Apiary.Runs.{Filters, Target}
  alias ApiaryWeb.PolicyLive

  @recent 5
  @window_days 14

  @impl true
  def mount(%{"glob" => glob}, _session, socket) do
    scope = socket.assigns.current_scope
    {segments, rest} = split_glob(glob)

    security =
      Features.on?(scope, :security) and
        Access.can?(scope, :"security_policy.read", scope.workspace)

    case {resolve(scope, segments), tab(rest, security)} do
      # The old tabs: nothing is read; `handle_params/3` sends them on with their query.
      {{:ok, target, shared, _form}, {:ok, {:moved, list}}} ->
        {:ok,
         assign(
           socket,
           :tab,
           {:moved, list, Filters.target_params(target.system, target.path, shared)}
         )}

      # A shared path given alone: the lists narrowed to the path, on every system.
      {{:choose, _targets, path}, {:ok, {:moved, list}}} ->
        {:ok, assign(socket, :tab, {:moved, list, Filters.target_params(nil, path)})}

      # An old address, with the system of a path no other target has: the path alone.
      {{:ok, target, _shared, :old}, {:ok, _tab}} ->
        {:ok, assign(socket, :tab, {:moved, target_path(scope, nil, target.path, rest)})}

      {{:ok, target, shared, :current}, {:ok, tab}} ->
        {:ok, mount_target(socket, target, shared, tab, security)}

      # An old tab of an address that reads as two targets goes there too, with the tab:
      # the lists narrowed to the path alone would be one of them only.
      {{reading, targets, path}, {:ok, _tab}} when reading in [:choose, :ambiguous] ->
        {:ok,
         assign(socket,
           tab: :choose,
           reading: reading,
           choices: choices(scope, targets),
           chosen_path: path,
           rest: rest,
           query: nil,
           page_title: path
         )}

      _not_found ->
        raise Ecto.NoResultsError, queryable: Target
    end
  end

  defp mount_target(socket, target, shared, tab, security) do
    scope = socket.assigns.current_scope

    socket
    |> assign(
      target: target,
      shared: shared,
      tab: elem(tab, 0),
      security: security,
      pinned: Targets.pinned?(scope, target),
      facts: nil,
      runs: nil,
      new_runs: 0
    )
    |> load_summary()
    |> mount_tab(tab)
  end

  # The glob's segments before the first `-`, and the tab's after it. A `-` first is the
  # address's own, the system `-` (`target_path/5` writes it so): no address starts with
  # its tab.
  defp split_glob(["-" | glob]) do
    {segments, rest} = Enum.split_while(glob, &(&1 != "-"))
    {["-" | segments], Enum.drop(rest, 1)}
  end

  defp split_glob(glob) do
    {segments, rest} = Enum.split_while(glob, &(&1 != "-"))
    {segments, Enum.drop(rest, 1)}
  end

  # The target an address names (the moduledoc's order): `{:ok, target, shared, form}`,
  # `form` `:current` for the address the page writes and `:old` for one it sends on;
  # `{:choose, targets, path}` for a path alone that two targets or more share;
  # `{:ambiguous, targets, path}` for an address that reads as two targets; `:error`. A
  # system and a path are a runner's labels, so an address can read both ways: a path
  # alone, and a system with its path. Where both readings name a target, the address
  # does not say which, and the page names each.
  defp resolve(_scope, []), do: :error

  defp resolve(scope, segments) do
    path = Enum.join(segments, "/")

    with_system =
      case segments do
        [system, _ | _] -> get(scope, system, Enum.join(tl(segments), "/"))
        _one -> nil
      end

    by_path = if Target.label(path), do: with_path(scope, path), else: []

    cond do
      with_system && by_path != [] ->
        {:ambiguous, Enum.uniq_by([with_system | by_path], & &1.id), path}

      # The system stays in the address, and so in the name, where the path alone would
      # not name this target.
      with_system && with_system?(scope, with_system) ->
        {:ok, with_system, true, :current}

      match?([_], by_path) ->
        {:ok, hd(by_path), false, :current}

      with_system ->
        {:ok, with_system, false, :old}

      by_path != [] ->
        {:choose, by_path, path}

      true ->
        :error
    end
  end

  # A target by its system and path, labels as a runner may send them: anything else, such
  # as bytes that are not UTF-8, names none.
  defp get(scope, system, path) do
    if Target.label(system) && Target.label(path), do: Targets.get(scope, system, path)
  end

  # Whether the target's address must carry its system, and so its name
  # (`TargetComponents.with_system?/3`, given the page's `shared`): its path is shared by
  # another target, or its path alone, as an address, reads as another target's system
  # and path.
  defp with_system?(scope, target),
    do: Targets.shared?(scope, target.path) or read_with_system?(scope, target)

  defp read_with_system?(scope, %Target{path: path}) do
    case String.split(path, "/", parts: 2) do
      [system, rest] -> get(scope, system, rest) != nil
      _one -> false
    end
  end

  # The workspace's targets with this path, one for each system: a read of the page's own.
  defp with_path(%{organisation: organisation, workspace: workspace}, path) do
    Repo.all(
      from t in Target,
        where:
          t.organisation_id == ^organisation.id and t.workspace_id == ^workspace.id and
            t.path == ^path,
        order_by: [asc: t.system]
    )
  end

  # Each target a chooser names, and whether its link writes its system: the path alone
  # where that names the target alone, else the system and the path, which does unless
  # another target's path starts with the system and a third shares the path.
  defp choices(scope, targets) do
    for %Target{id: id} = target <- targets do
      alone? =
        match?({:ok, %Target{id: ^id}, _, :current}, resolve(scope, path_segments(target.path)))

      {target, not alone?}
    end
  end

  # The tab the segments after `-` name, with what it needs of them. Runs and Network
  # access are the workspace's lists now: their old tabs are sent on.
  defp tab([], _security), do: {:ok, {:overview}}
  defp tab(["runs"], _security), do: {:ok, {:moved, :runs}}

  defp tab([moved], _security) when moved in ["network", "connections"],
    do: {:ok, {:moved, :network}}

  defp tab(["policy" | rest], true), do: policy_action(rest)
  defp tab(_rest, _security), do: :error

  defp policy_action([]), do: {:ok, {:policy, :rules, %{}}}
  defp policy_action(["history"]), do: {:ok, {:policy, :history, %{}}}
  defp policy_action(["document"]), do: {:ok, {:policy, :document, %{}}}
  defp policy_action(["versions", n]), do: {:ok, {:policy, :version, %{"n" => n}}}
  defp policy_action(["versions", n, "export"]), do: {:ok, {:policy, :export, %{"n" => n}}}
  defp policy_action(_rest), do: :error

  defp mount_tab(socket, {:overview}) do
    if connected?(socket), do: Runs.subscribe(socket.assigns.current_scope)

    socket
    |> assign(:page_title, name(socket.assigns.target, socket.assigns.shared))
    |> load_overview()
  end

  # The tab names the target, and writes its links (`base`), as the page's address does.
  defp mount_tab(socket, {:policy, action, _params}) do
    %{target: target, shared: shared} = socket.assigns

    socket
    |> PolicyLive.Target.mount(target, shared)
    |> assign(
      action: action,
      page_title: gettext("Policy · %{target}", target: name(target, shared))
    )
  end

  @impl true
  # An old tab: the workspace's list narrowed to the target, with the old address's query.
  def handle_params(_params, uri, %{assigns: %{tab: {:moved, list, target_params}}} = socket) do
    %{organisation: organisation, workspace: workspace} = socket.assigns.current_scope

    rest = Enum.reject(query(uri), fn {key, _value} -> key in ["system", "target"] end)

    {:noreply,
     redirect(socket, to: narrowed_path(organisation, workspace, list, target_params, rest))}
  end

  # An old address: the path alone, with its tab and its query.
  def handle_params(_params, uri, %{assigns: %{tab: {:moved, to}}} = socket) do
    query = URI.parse(uri).query
    {:noreply, redirect(socket, to: if(query in [nil, ""], do: to, else: to <> "?" <> query))}
  end

  # The address's query goes with each choice.
  def handle_params(_params, uri, %{assigns: %{tab: :choose}} = socket),
    do: {:noreply, assign(socket, :query, URI.parse(uri).query)}

  def handle_params(%{"glob" => glob}, uri, socket) do
    %{target: target, tab: current} = socket.assigns
    {segments, rest} = split_glob(glob)

    # Both of the target's addresses name it here, so a link that could not tell the path
    # is shared keeps the page.
    same? = segments in [path_segments(target.path), [target.system | path_segments(target.path)]]

    case {same?, tab(rest, socket.assigns.security)} do
      {true, {:ok, {:policy, action, params}}} when current == :policy ->
        PolicyLive.Target.handle_params(
          Map.merge(Map.new(query(uri)), params),
          assign(socket, :action, action)
        )

      {true, {:ok, {:overview}}} when current == :overview ->
        {:noreply, socket}

      # Another target or another tab, reached by a patch: a mount of its own.
      _other ->
        {:noreply, push_navigate(socket, to: URI.parse(uri).path, replace: true)}
    end
  end

  # The address's query, in its order.
  defp query(uri), do: URI.query_decoder(URI.parse(uri).query || "") |> Enum.to_list()

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
        if Enum.any?(runs, &(&1.id == run.id)) do
          {:noreply,
           assign(socket, :runs, Enum.map(runs, &if(&1.id == run.id, do: run, else: &1)))}
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
  # A path alone that two targets or more share, or an address that reads as two targets:
  # the address does not say which, so the page names each, with a link to it at the same
  # tab that names it alone.
  def render(%{tab: :choose} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:targets}
      width="read"
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/targets"}>
        {gettext("Targets")}
      </:crumb>
      <:crumb>{@chosen_path}</:crumb>

      <.page_header id="target-choose" title={@chosen_path}>
        <:description>
          {if @reading == :ambiguous,
            do: gettext("This address can mean more than one target. Choose one:"),
            else: gettext("This path is in more than one system. Choose one:")}
        </:description>
      </.page_header>

      <ul id="target-choices" class="q-tgt-pl">
        <li :for={{target, system?} <- @choices} id={"target-choice-#{target.id}"}>
          <.link
            navigate={
              target_path(@current_scope, target.system, target.path, @rest, system?) <>
                if(@query in [nil, ""], do: "", else: "?" <> @query)
            }
            class="q-tgt-pl-name"
          >
            <.target_name path={target.path} system={target.system} />
          </.link>
        </li>
      </ul>
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
      nav={:targets}
      target={@target.id}
      width="list"
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/targets"}>
        {gettext("Targets")}
      </:crumb>
      <:crumb navigate={@tab != :overview && page_path(@current_scope, @target, @shared, [])}>
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

      <.target_header
        target={@target}
        shared={@shared}
        pinned={@pinned}
        facts={@facts}
        security={@security}
      />

      <.page_tabs id="target-tabs" label={gettext("Target")} current={@tab}>
        <:tab
          key={:overview}
          navigate={page_path(@current_scope, @target, @shared, [])}
          icon="hero-book-open"
        >
          {gettext("Overview")}
        </:tab>
        <:tab
          :if={@security}
          key={:policy}
          navigate={page_path(@current_scope, @target, @shared, ["policy"])}
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
      />

      <PolicyLive.Target.content :if={@tab == :policy} {assigns} />
    </Layouts.app>
    """
  end

  # The header: the target as it is addressed, the reader's pin, one muted line and the
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
              navigate={list_path(@scope, :runs, @target, @shared)}
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
              navigate={list_path(@scope, :network, @target, @shared, decision: "denied")}
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
              title={"#{row.host}:#{row.port}#{row.path}"}
            >
              <.icon name="hero-no-symbol-micro" class="size-3.5 text-faint" />
              <span class="q-tgt-dn-dest">{row.host}<span class="text-faint">:{row.port}</span><span
                :if={row.path not in [nil, ""]}
                class="text-muted"
              >{row.path}</span></span>
              <span>{attempts_words(row)}</span>
              <span class="q-tgt-dn-t">
                <.rich text={rich_gettext("last %{time}", time: {:part, :time})}>
                  <:part name={:time}><.relative_time at={row.last_at} /></:part>
                </.rich>
              </span>
            </li>
          </ul>
        </section>
      </div>

      <aside id="target-about" class="q-tgt-about" aria-label={gettext("About this target")}>
        <section>
          <h3>{gettext("About")}</h3>
          <dl class="q-tgt-kv">
            <dt>{gettext("System")}</dt>
            <dd class="font-mono">{@target.system}</dd>
            <dt>{gettext("Path")}</dt>
            <dd class="break-all font-mono">{@target.path}</dd>
            <dt>{gettext("First seen")}</dt>
            <dd>
              {Format.date(@target.first_seen_at)}
              <span :if={@facts && @facts.first} class="text-faint">
                ·
                <.rich text={rich_gettext("run %{id}", id: {:part, :id})}>
                  <:part name={:id}>
                    <.link
                      navigate={
                        ~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{@facts.first.run_id}"
                      }
                      class="font-mono text-xs hover:underline"
                    >{short_id(@facts.first.run_id)}</.link>
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
              <.link navigate={page_path(@scope, other, true, [])} class="q-tgt-pl-name">
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
              <span class="q-tgt-pl-name font-mono">{host}</span>
              <span class="q-tgt-pl-c">{Format.number(runs)}</span>
            </li>
          </ul>
        </section>

        <section :if={@runtimes != []}>
          <h3>{gettext("Runtimes")}</h3>
          <ul class="q-tgt-pl">
            <li :for={{runtime, runs} <- @runtimes}>
              <span class="q-tgt-pl-name font-mono">{runtime}</span>
              <span class="q-tgt-pl-c">{Format.number(runs)}</span>
            </li>
          </ul>
        </section>
      </aside>
    </div>
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

  defp page_path(scope, target, shared, rest),
    do: target_path(scope, target.system, target.path, rest, shared)

  # The workspace's runs list or Network access narrowed to the target: its path, and its
  # system only where the path is shared, then the list's own parameters.
  defp list_path(scope, list, target, shared, params \\ []) do
    %{organisation: organisation, workspace: workspace} = scope
    target_params = Filters.target_params(target.system, target.path, shared)
    narrowed_path(organisation, workspace, list, target_params, params)
  end

  # A list's path with the target's parameters first (`system`, then `target`), then the
  # list's own, in their order.
  defp narrowed_path(organisation, workspace, list, target_params, params) do
    path =
      case list do
        :runs -> ~p"/#{organisation}/#{workspace}/runs"
        :network -> ~p"/#{organisation}/#{workspace}/network"
      end

    path <> "?" <> URI.encode_query(Enum.sort(target_params) ++ params)
  end

  # The target in words, as it is addressed: its system only where its address has it.
  defp name(target, shared), do: target_label(target.system, target.path, shared)

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

  defp own_mode_words("observe"), do: gettext("observes on its own")
  defp own_mode_words("enforce"), do: gettext("enforces on its own")

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
