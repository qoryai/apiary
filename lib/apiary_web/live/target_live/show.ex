defmodule ApiaryWeb.TargetLive.Show do
  @moduledoc """
  One target's page, GitHub's repository page in the target's words:
  `/:org/:workspace/targets/:system/*path`, the path the glob, its tabs after a `-`
  segment (`ApiaryWeb.TargetComponents.target_path/4`). Overview is the bare path, then,
  where the reader may read the security policy, Security policy (`…/-/policy`, with its
  own paths after it): approving and denying the target's hosts is daily work, so it is a
  tab of the operational page, not of a Settings. The target's records are not tabs of
  their own: its runs and its network access are the sidebar's Runs and Network access,
  filtered to it (`target:`), which its Overview leads to. A Settings tab, the last, set
  apart at the right end, joins once the target has settings of its own to hold. A target
  is looked up by its system and path in the scope's workspace; one the workspace does not
  have, and a tab the page does not know, is not found.

  The header names the target in full, `system/path`, with the reader's pin, one muted
  line (how many runs since it was first seen, its last run, and its policy mode only
  where it sets its own) and a link to it in its system when the system is a host name.
  The breadcrumb's third segment is the target; the sidebar marks Targets the current
  entry, and the target's pin, where it is pinned, as the place within it.

  - **Overview**: its last runs and the destinations its runs were denied in fourteen
    days, one line each, the few with "See all" to the many on Runs and Network access,
    filtered to the target; beside them, as plain text, what it is, the same path in other
    systems, its runs a day, its machines and runtimes.
  - **Security policy**: the target's view of the policy (`ApiaryWeb.PolicyLive.Target`).

  A tab is its own mount: the tabs are navigations, and the tab another page's module
  answers gets the page's parameters, events and messages while it is open. Overview
  follows the workspace's topic: a run of the target on the page changes in place; a new
  one is counted, never inserted under the reader, and comes in when asked.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :observability
  on_mount {ApiaryWeb.Access, :"run.read"}

  import ApiaryWeb.TargetComponents

  alias Apiary.{Access, Features, Runs, Targets}
  alias Apiary.Runs.Filters
  alias ApiaryWeb.PolicyLive

  @recent 5
  @window_days 14

  @impl true
  def mount(%{"system" => system, "path" => glob}, _session, socket) do
    {path, rest} = parse_glob(glob)
    mount_target(socket, system, path, rest)
  end

  defp mount_target(socket, system, path, rest) do
    scope = socket.assigns.current_scope

    security =
      Features.on?(scope, :security) and
        Access.can?(scope, :"security_policy.read", scope.workspace)

    with %{} = target <- Targets.get(scope, system, path),
         {:ok, tab} <- tab(rest, security) do
      {:ok,
       socket
       |> assign(
         target: target,
         tab: elem(tab, 0),
         security: security,
         pinned: Targets.pinned?(scope, target),
         facts: nil,
         runs: nil,
         new_runs: 0
       )
       |> load_summary()
       |> mount_tab(tab)}
    else
      _not_found -> raise Ecto.NoResultsError, queryable: Apiary.Runs.Target
    end
  end

  # The tab the segments after `-` name, with what it needs of them.
  defp tab([], _security), do: {:ok, {:overview}}
  defp tab(["policy" | rest], true), do: policy_action(rest)
  defp tab(_rest, _security), do: :error

  defp policy_action([]), do: {:ok, {:policy, :rules, %{}}}
  defp policy_action(["history"]), do: {:ok, {:policy, :history, %{}}}
  defp policy_action(["document"]), do: {:ok, {:policy, :document, %{}}}
  defp policy_action(["versions", n]), do: {:ok, {:policy, :version, %{"n" => n}}}
  defp policy_action(["versions", n, "export"]), do: {:ok, {:policy, :export, %{"n" => n}}}
  defp policy_action(_rest), do: :error

  defp mount_tab(socket, {:overview}) do
    subscribe(socket)

    socket
    |> assign(:page_title, name(socket.assigns.target))
    |> load_overview()
  end

  defp mount_tab(socket, {:policy, action, _params}) do
    target = socket.assigns.target

    socket
    |> PolicyLive.Target.mount(target)
    |> assign(
      action: action,
      page_title: gettext("Security policy · %{target}", target: name(target))
    )
  end

  defp subscribe(socket) do
    if connected?(socket), do: Runs.subscribe(socket.assigns.current_scope)
  end

  @impl true
  def handle_params(%{"system" => system, "path" => glob}, uri, socket) do
    %{target: target, tab: current} = socket.assigns
    {path, rest} = parse_glob(glob)
    same? = system == target.system and path == target.path

    case {same?, tab(rest, socket.assigns.security)} do
      {true, {:ok, {:policy, action, params}}} when current == :policy ->
        PolicyLive.Target.handle_params(
          Map.merge(query(uri), params),
          assign(socket, :action, action)
        )

      {true, {:ok, tab}} when elem(tab, 0) == current ->
        {:noreply, socket}

      # Another target or another tab, reached by a patch: a mount of its own.
      _other ->
        {:noreply, push_navigate(socket, to: URI.parse(uri).path, replace: true)}
    end
  end

  defp query(uri), do: URI.decode_query(URI.parse(uri).query || "")

  @impl true
  def handle_event("target_pin", _params, socket) do
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
      <:crumb navigate={@tab != :overview && page_path(@current_scope, @target, [])}>
        <.target_name path={@target.path} system={@target.system} />
      </:crumb>

      <.target_header
        target={@target}
        pinned={@pinned}
        facts={@facts}
        security={@security}
      />

      <.tabs id="target-tabs" label={gettext("Target")}>
        <:tab
          id="target-tab-overview"
          navigate={page_path(@current_scope, @target, [])}
          current={@tab == :overview}
          icon="hero-book-open"
        >
          {gettext("Overview")}
        </:tab>
        <:tab
          :if={@security}
          id="target-tab-policy"
          navigate={page_path(@current_scope, @target, ["policy"])}
          current={@tab == :policy}
          icon="hero-shield-check"
        >
          {gettext("Security policy")}
        </:tab>
      </.tabs>

      <.overview
        :if={@tab == :overview}
        target={@target}
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

  # The header: the target in full, the reader's pin, one muted line and the way to it in
  # its system.
  attr :target, :map, required: true
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
          <.target_name path={@target.path} system={@target.system} class="min-w-0 truncate" />
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
        <.pin_button id="target-pin" target={@target} pinned={@pinned} label />
        <.button :if={@external} id="target-external" href={@external}>
          {gettext("Open on %{system}", system: @target.system)}
          <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" />
        </.button>
      </div>
    </header>
    """
  end

  attr :target, :map, required: true
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
              navigate={
                ~p"/#{@scope.organisation}/#{@scope.workspace}/runs?#{Filters.target_params(@target.system, @target.path)}"
              }
              class="q-tgt-more"
              title={
                ngettext("Its %{number} run, on Runs", "All its %{number} runs, on Runs", @facts.runs,
                  number: Format.number(@facts.runs)
                )
              }
            >
              {gettext("See all")}<.icon name="hero-arrow-right-micro" class="size-3.5" />
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
              navigate={
                ~p"/#{@scope.organisation}/#{@scope.workspace}/network?#{Map.put(Filters.target_params(@target.system, @target.path), "decision", "denied")}"
              }
              class="q-tgt-more"
              title={gettext("What it was denied, on Network access")}
            >
              {gettext("See all")}<.icon name="hero-arrow-right-micro" class="size-3.5" />
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
              <.icon name="hero-no-symbol-micro" class="size-4 text-error" />
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
              <.link navigate={page_path(@scope, other, [])} class="q-tgt-pl-name">
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

  defp page_path(scope, target, rest), do: target_path(scope, target.system, target.path, rest)

  defp name(target), do: "#{target.system}/#{target.path}"

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
