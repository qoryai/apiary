defmodule ApiaryWeb.PolicyLive.Target do
  @moduledoc """
  A target's view of the hive's policy (`docs/design/brief-policy.md`, pe3 to pe5): the
  effective list, one row per host in force with where it came from, the rules that lost
  hung under the rule that beat them; the hosts the harness declared; the target's own
  history, versions and export.

  `:target_id` is the target row's id. A target of another hive is not found:
  the page renders the not-found state and never another hive's rules.
  """
  use ApiaryWeb, :live_view

  import ApiaryWeb.PolicyComponents
  import ApiaryWeb.PolicyLive.Views

  alias Apiary.Policy
  alias Apiary.Runs.Filters
  alias ApiaryWeb.PolicyLive.Common
  alias Apiary.Policy.Grammar
  alias ApiaryWeb.PolicyLive.Show

  @shows ~w(hive repository overrides)

  @impl true
  def mount(%{"target_id" => id}, _session, socket) do
    case Policy.get_target(socket.assigns.current_scope, id) do
      {:ok, target} ->
        socket =
          socket
          |> Common.mount(target)
          |> assign(reload: &load/1, show: nil, ruled_host: nil, allowed: %{})
          |> assign(history: nil, open_change: nil, diff: nil, v: nil, export: nil, missing: nil)
          |> assign(credentials_open: false, summary: nil, would: nil, params: %{})

        # The page is read once, by the connected mount: the first render is its skeleton.
        socket =
          if connected?(socket),
            do: socket |> load() |> assign(:loaded, true),
            else: assign(socket, loaded: false, page_title: "Policy")

        {:ok, socket}

      {:error, _not_found} ->
        {:ok, assign(socket, holder: :not_found, loaded: true, page_title: "Policy")}
    end
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    target = socket.assigns.holder
    managed? = Policy.managed?(scope)
    own = Policy.list_rules(scope, target)
    effective = Policy.effective(scope, target)
    changes = Policy.list_changes(scope, target, 1)
    declared = Policy.declared_hosts(scope, target)

    {version, own?} =
      case Common.served_version(scope, target, managed?) do
        {configuration, own?} -> {configuration, own?}
        nil -> {nil, false}
      end

    socket
    |> assign(
      managed?: managed?,
      own: own,
      effective: effective,
      mode: Policy.get_mode(scope, target),
      locked_denies:
        for(
          %{kind: :host, source: :hive, locked: true, action: :deny, in_force: true, host: host} <-
            effective.entries,
          do: host
        ),
      # Who locked what is read only where a lock is in the list to be asked about.
      locks:
        if(Enum.any?(effective.entries, & &1.locked),
          do: Common.locks(Policy.list_changes(scope, nil, 1)),
          else: %{}
        ),
      version: version,
      baseline?: !own?,
      change_total: changes.total,
      run_total: run_total(scope, target),
      suggestions: declared.suggested,
      covered: declared.covered,
      reload_pending: false,
      now: DateTime.utc_now()
    )
    |> then(fn socket ->
      assign(socket,
        rows: Common.effective_rows(effective, socket),
        credentials: credentials(effective, socket)
      )
    end)
    |> load_record()
  end

  # How many runs the Runs tab leads to: the runs list's own count, over its default range
  # of seven days, so the number and the page agree.
  defp run_total(scope, %{system: system, path: path}) do
    filters = Filters.parse(Filters.target_params(system, path), :runs)

    case Apiary.Runs.group_facts(scope, filters, [{system, path}]) do
      %{{^system, ^path} => %{runs: runs}} -> runs
      _none -> 0
    end
  end

  defp credentials(effective, socket) do
    for %{kind: :credential} = entry <- effective.entries do
      %{
        id: entry.rule.id,
        action: to_string(entry.action),
        name: entry.name,
        argument: entry.argument,
        source: if(entry.source == :hive and entry.locked, do: :hive_locked, else: entry.source),
        in_force: entry.in_force,
        by: Common.local(socket.assigns.people[entry.rule.created_by_id]),
        at: entry.rule.inserted_at,
        can_change: entry.source == :target
      }
    end
  end

  defp load_record(socket) do
    if connected?(socket) do
      scope = socket.assigns.current_scope
      target = socket.assigns.holder

      assign_async(socket, :activity, fn ->
        case Policy.rule_activity(scope, target, Common.since()) do
          {:ok, activity} -> {:ok, %{activity: activity}}
          _ -> {:ok, %{activity: :unavailable}}
        end
      end)
    else
      assign(socket, :activity, Phoenix.LiveView.AsyncResult.loading())
    end
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{holder: :not_found}} = socket),
    do: {:noreply, socket}

  def handle_params(_params, _uri, %{assigns: %{loaded: false}} = socket), do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    socket = assign(socket, missing: nil, export: nil, params: params, now: DateTime.utc_now())
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :rules, params) do
    show = if params["show"] in @shows, do: params["show"]
    ruled_host = Common.rule_param(params["rule"])

    socket
    |> assign(show: show, ruled_host: ruled_host, page_title: title(socket))
    |> then(&if(ruled_host, do: push_event(&1, "policy:rule", %{host: ruled_host}), else: &1))
  end

  defp apply_action(socket, :history, params) do
    socket = assign(socket, :page_title, "History · " <> title(socket))
    history = Common.history(socket, Common.page_param(params["page"]))

    {open, diff} =
      case params["change"] && Common.change_diff(socket, params["change"]) do
        {:ok, diff} -> {diff.id, diff}
        _ -> {nil, nil}
      end

    assign(socket, history: history, open_change: open, diff: diff, summary: summary(socket))
  end

  defp apply_action(socket, :document, _params) do
    to =
      case socket.assigns do
        %{version: %{version: n}, baseline?: false} -> "#{socket.assigns.base}/versions/#{n}"
        %{version: %{version: n}} -> ~p"/hive/policy/versions/#{n}"
        _ -> socket.assigns.base
      end

    push_navigate(socket, to: to, replace: true)
  end

  defp apply_action(socket, action, %{"n" => n} = params) when action in [:version, :export] do
    case Common.version(socket, n, params) do
      {:ok, v} ->
        socket =
          assign(socket,
            v: v,
            page_title: "Version #{v.configuration.version} · " <> title(socket)
          )

        cond do
          action == :export and v.current? ->
            assign(socket, :export, Common.export(socket, v.configuration))

          action == :export ->
            push_patch(socket,
              to: "#{socket.assigns.base}/versions/#{v.latest}/export",
              replace: true
            )

          true ->
            socket
        end

      :error ->
        latest = if socket.assigns.baseline?, do: nil, else: socket.assigns.version
        assign(socket, v: nil, missing: %{n: n, latest: latest}, page_title: title(socket))
    end
  end

  # The versions count from 1 without a gap, so the newest one's number is how many.
  defp summary(socket) do
    own = if socket.assigns.baseline?, do: nil, else: socket.assigns.version

    since =
      case own && Policy.get_configuration(socket.assigns.current_scope, socket.assigns.holder, 1) do
        {:ok, first} -> first.rendered_at
        _ -> nil
      end

    %{versions: (own && own.version) || 0, since: since}
  end

  defp title(%{assigns: %{holder: %{system: system, path: path}}}),
    do: "#{system}/#{path} · Policy"

  ## Events

  @impl true
  def handle_event(_event, _params, %{assigns: %{holder: :not_found}} = socket),
    do: {:noreply, socket}

  def handle_event(event, params, socket) do
    case Common.handle_event(event, params, socket) do
      {:halt, socket} -> {:noreply, socket}
      :cont -> {:noreply, event(event, params, socket)}
    end
  end

  defp event("row_act", %{"id" => id, "act" => act}, socket)
       when act in ~w(disable allow_here remove restore) do
    scope = socket.assigns.current_scope
    target = socket.assigns.holder

    with {:ok, rule} <- Policy.get_rule(scope, id),
         true <- rule.kind == "host" do
      # The act is matched against the rule as it is now, not as the row showed it: a
      # hive rule that became a deny is not disabled, one that became an allow is not
      # allowed again over its paths, and a locked one is an owner's on the hive's page.
      {result, sentence, announce} =
        case {act, rule.target_id, rule.action} do
          {_act, nil, _action} when rule.locked ->
            {{:error,
              %Policy.Error{
                reason: :locked,
                message:
                  "The hive's rule for #{rule.host} is locked. An owner changes it on the hive's policy page."
              }}, nil, nil}

          {"disable", nil, "allow"} ->
            {Policy.deny(scope, target, %{host: rule.host}),
             "#{rule.host} is denied #{Common.for_holder(socket)}.",
             "#{rule.host} is disabled for this repository."}

          {"allow_here", nil, "deny"} ->
            {Policy.allow(scope, target, %{host: rule.host, paths: nil}),
             "#{rule.host} is allowed #{Common.for_holder(socket)}.",
             "#{rule.host} is allowed for this repository."}

          {act, target_id, _action}
          when act in ~w(remove restore) and target_id == target.id ->
            {Policy.remove_rule(scope, rule),
             if(act == "restore",
               do: "The hive's rule for #{rule.host} is restored #{Common.for_holder(socket)}.",
               else: "The rule #{rule.host} is removed."
             ), "Rule removed."}

          _ ->
            {{:error,
              %Policy.Error{
                reason: :conflict,
                message:
                  "The rule for #{rule.host} changed while you were deciding. The list below is current."
              }}, nil, nil}
        end

      case result do
        {:ok, written} ->
          fresh = if act in ~w(disable allow_here), do: written
          socket = Common.wrote(socket, fresh, sentence, announce)
          focus_host(socket, rule.host)

        {:error, error} ->
          Common.refused(socket, error)
      end
    else
      _ -> load(socket)
    end
  end

  defp event("target_mode_ask", %{"setting" => setting}, socket)
       when setting in ~w(follow observe enforce) do
    mode = socket.assigns.mode
    becomes = if setting == "follow", do: mode.hive, else: setting
    now = if mode.own, do: mode.own, else: "follow"

    cond do
      not socket.assigns.owner? ->
        assign(socket, :write_error, "Only an owner sets a mode.")

      setting == now ->
        socket

      becomes == mode.mode ->
        set_target_mode(socket, setting)

      becomes == "enforce" ->
        would = Common.would(socket.assigns.current_scope, socket.assigns.holder)

        assign(socket, dialog: {:target_mode, setting, "enforce"}, would: would)

      true ->
        assign(socket, dialog: {:target_mode, setting, "observe"}, would: nil)
    end
  end

  defp event(
         "target_mode_confirm",
         _params,
         %{assigns: %{dialog: {:target_mode, setting, _becomes}}} = socket
       ) do
    socket |> assign(:dialog, nil) |> set_target_mode(setting)
  end

  defp event("would_allow", %{"key" => key}, %{assigns: %{would: %{} = would}} = socket) do
    scope = socket.assigns.current_scope
    target = socket.assigns.holder

    case Enum.find(would.destinations, &(Common.would_key(&1) == key)) do
      nil ->
        socket

      destination ->
        result =
          if destination.path,
            do: Policy.allow_path(scope, target, destination.host, destination.path),
            else: Policy.allow(scope, target, %{host: destination.host})

        case result do
          {:ok, _rule} ->
            socket
            |> load()
            |> assign(:would, Common.would(scope, target, would))
            |> assign(:announce, "#{destination.host} is allowed for this repository.")

          {:error, error} ->
            assign(socket, :would, Map.put(would, :error, error.message))
        end
    end
  end

  defp event("suggest_allow", %{"host" => host, "level" => level}, socket)
       when is_binary(host) and level in ~w(repository hive) do
    case allow_suggestion(socket, host, level) do
      {:ok, socket} -> Common.focus(socket, suggestion_id(host) <> "-done")
      {:error, socket} -> socket
    end
  end

  defp event("suggest_allow_all", _params, socket) do
    hosts =
      for suggestion <- socket.assigns.suggestions,
          not Map.has_key?(socket.assigns.allowed, suggestion.host),
          do: suggestion.host

    Enum.reduce_while(hosts, socket, fn host, socket ->
      case allow_suggestion(socket, host, "repository") do
        {:ok, socket} -> {:cont, socket}
        {:error, socket} -> {:halt, socket}
      end
    end)
  end

  defp event("credentials_toggle", _params, socket) do
    open = !socket.assigns.credentials_open

    socket
    |> assign(:credentials_open, open)
    |> then(&if(open, do: Common.focus(&1, "policy-credential-name"), else: &1))
  end

  defp event("remove", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, rule} <- Policy.get_rule(scope, id),
         true <- rule.target_id == socket.assigns.holder.id,
         {:ok, rule} <- Policy.remove_rule(scope, rule) do
      socket
      |> Common.wrote(nil, "The credential #{rule.name} is removed.", "Credential removed.")
      |> Common.focus("policy-credential-name")
    else
      {:error, error} -> Common.refused(socket, error)
      _ -> load(socket)
    end
  end

  defp event("compare", %{"compare" => compare}, %{assigns: %{v: %{} = v}} = socket) do
    push_patch(socket,
      to: version_path(socket.assigns.base, v, compare: Common.page_param(compare))
    )
  end

  defp event(_event, _params, socket), do: socket

  defp set_target_mode(socket, setting) do
    scope = socket.assigns.current_scope
    before = socket.assigns.mode
    name = Common.holder_name(socket)

    case Policy.set_mode(
           scope,
           socket.assigns.holder,
           if(setting == "follow", do: :inherit, else: setting)
         ) do
      {:ok, mode} ->
        sentence =
          cond do
            setting == "follow" ->
              "#{name} follows the hive: #{mode.hive}."

            mode.mode == before.mode ->
              "#{name} #{setting}s on its own. Nothing changes today: the hive's default is #{mode.hive} too."

            true ->
              "#{name} #{setting}s on its own."
          end

        socket
        |> Common.wrote(nil, sentence, "This repository's mode is #{mode.mode}.")
        |> Common.focus("policy-repository-mode-#{setting}")

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  # The suggestions that were there when the page opened stay until the next navigation,
  # with what was done to them, though the policy now covers them.
  defp allow_suggestion(socket, host, level) do
    scope = socket.assigns.current_scope
    holder = if level == "hive", do: nil, else: socket.assigns.holder
    shown = socket.assigns.suggestions

    case Policy.allow(scope, holder, %{host: host}) do
      {:ok, rule} ->
        where = if level == "hive", do: "for the hive", else: Common.for_holder(socket)

        socket =
          socket
          |> Common.wrote(
            if(level == "hive", do: nil, else: rule),
            "#{host} is allowed #{where}.",
            "#{host} is allowed #{if level == "hive", do: "for the hive", else: "for this repository"}."
          )
          |> assign(:suggestions, shown)
          |> assign(:allowed, Map.put(socket.assigns.allowed, host, %{id: rule.id, level: level}))

        {:ok, socket}

      {:error, error} ->
        {:error, Common.refused(socket, error) |> assign(:suggestions, shown)}
    end
  end

  defp focus_host(socket, host) do
    case Enum.find(socket.assigns.rows, &(&1.host == host)) do
      %{id: id} -> Common.focus(socket, "rule-#{id}-act")
      nil -> Common.focus(socket, "policy-composer-host")
    end
  end

  ## Messages

  @impl true
  def handle_info({:policy_changed, _change}, %{assigns: %{holder: :not_found}} = socket),
    do: {:noreply, socket}

  def handle_info({:policy_changed, _change}, socket),
    do: {:noreply, Common.schedule_reload(socket)}

  def handle_info(:policy_reload, socket) do
    shown = socket.assigns.suggestions
    socket = load(socket)

    # Rows somebody acted on from this page stay in place until the next navigation.
    socket =
      if socket.assigns.allowed == %{}, do: socket, else: assign(socket, :suggestions, shown)

    # What the URL shows is read again too: a version in force a moment ago may be
    # superseded now.
    socket =
      case socket.assigns.live_action do
        :history ->
          apply_action(socket, :history, socket.assigns.params)

        action when action in [:version, :export] ->
          case Common.version(socket, socket.assigns.params["n"], socket.assigns.params) do
            {:ok, v} -> assign(socket, :v, v)
            :error -> socket
          end

        _ ->
          socket
      end

    socket =
      if socket.assigns.composer_params["host"] != "", do: Common.read(socket, %{}), else: socket

    {:noreply, socket}
  end

  ## Render

  @impl true
  def render(%{loaded: false} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:policy}
      width="full"
    >
      <.page_skeleton title={"#{@holder.system}/#{@holder.path}"} />
    </Layouts.app>
    """
  end

  def render(%{holder: :not_found} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:policy}
      width="full"
    >
      <.empty_state
        tone="neutral"
        icon="hero-magnifying-glass"
        heading="h1"
        title="This repository is not in this hive"
      >
        The link may be for another
        <.term word="hive" />, or the repository has not posted a run here.
        <:actions>
          <.button navigate={~p"/hive/policy"}>Back to policy</.button>
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
      nav={:policy}
      width="full"
    >
      <div id="policy-page" phx-hook="PolicyPage" class="grid grid-cols-[minmax(0,1fr)] gap-6">
        <div class="grid gap-3">
          <nav class="q-crumbs" aria-label="Breadcrumb">
            <.link navigate={~p"/hive/policy"}>Policy</.link>
            <.icon name="hero-chevron-right-micro" class="size-3" />
            <%= if @live_action in [:version, :export] && @v do %>
              <.link navigate={@base} class="font-mono text-xs">
                <span class="text-faint">{@holder.system}/</span>{@holder.path}
              </.link>
              <.icon name="hero-chevron-right-micro" class="size-3" />
              <span class="q-here" aria-current="page">Version {@v.configuration.version}</span>
            <% else %>
              <.link navigate={~p"/hive/policy/repositories"}>Repositories</.link>
              <.icon name="hero-chevron-right-micro" class="size-3" />
              <span class="q-here font-mono text-xs" aria-current="page">
                <span class="text-faint">{@holder.system}/</span>{@holder.path}
              </span>
            <% end %>
          </nav>

          <Show.version_head :if={@live_action in [:version, :export] && @v} v={@v} base={@base} />

          <header
            :if={!(@live_action in [:version, :export] && @v)}
            class="flex flex-wrap items-start justify-between gap-4"
          >
            <div class="min-w-0 flex-1 basis-72">
              <h1 class="break-all font-mono text-[17px]/7 font-semibold">
                <span class="font-normal text-faint">{@holder.system}/</span>{@holder.path}
              </h1>
              <p class="mt-0.5 max-w-[62ch] text-sm/5 text-muted">
                What runs of this repository may reach: the hive's rules, then this repository's own. Where the two meet on a host, the repository wins, unless the hive's rule is locked.
              </p>
            </div>
            <div :if={@version} class="q-head-side">
              <span class="inline-flex items-center gap-2">
                <.version_pill
                  id="policy-version-pill"
                  version={@version.version}
                  digest={@version.digest}
                  navigate={if @baseline?, do: ~p"/hive/policy/history", else: "#{@base}/history"}
                  copy
                />
                <small :if={@baseline?} id="policy-baseline" class="text-xs text-faint">
                  <.term
                    word="hive baseline"
                    standard="The hive's rules with no repository's own: what a repository without rules, or a run that names none, is served."
                    class="q-tip-wide tooltip-left"
                  />
                </small>
              </span>
              <.button
                id="policy-export-button"
                navigate={
                  if @baseline?,
                    do: ~p"/hive/policy/versions/#{@version.version}/export",
                    else: "#{@base}/versions/#{@version.version}/export"
                }
              >
                <.icon name="hero-arrow-up-tray-micro" class="size-4" />Export
              </.button>
            </div>
          </header>
        </div>

        <.target_tabs
          live_action={@live_action}
          base={@base}
          rules={length(@rows)}
          changes={@change_total}
          runs={@run_total}
          document={@version != nil}
          holder={@holder}
        />

        <div id="policy-announce" class="sr-only" role="status" aria-live="polite">{@announce}</div>

        <.notice :if={@write_error} kind={:error} class="max-w-[80ch]">
          <span id="policy-write-error" role="alert">{@write_error}</span>
        </.notice>

        <.rules_tab :if={@live_action == :rules} {assigns} />
        <.history_view
          :if={@live_action == :history && @history}
          history={@history}
          open={@open_change}
          diff={@diff}
          base={@base}
          scope={:target}
          summary={@summary}
          now={@now}
        />
        <.version_view :if={@live_action in [:version, :export] && @v} v={@v} base={@base} now={@now} />
        <.empty_state
          :if={@missing}
          tone="neutral"
          icon="hero-magnifying-glass"
          title={"There is no version #{String.slice(@missing.n, 0, 12)}"}
        >
          <span :if={@missing.latest}>The latest is version {@missing.latest.version}.</span>
          <span :if={!@missing.latest}>
            This repository has no versions of its own: it is served the hive baseline.
          </span>
          <:actions>
            <.button :if={@missing.latest} navigate={"#{@base}/versions/#{@missing.latest.version}"}>
              Open version {@missing.latest.version}
            </.button>
            <.button :if={!@missing.latest} navigate={@base}>Back to the repository's policy</.button>
          </:actions>
        </.empty_state>
      </div>

      <.keys_dialog />
      <.target_mode_dialog
        :if={match?({:target_mode, _, _}, @dialog)}
        setting={elem(@dialog, 1)}
        becomes={elem(@dialog, 2)}
        name={Common.holder_name(%{assigns: %{holder: @holder}})}
        hive={@mode.hive}
        would={@would}
        locked_denies={@locked_denies}
      />
      <.export_modal
        :if={@live_action == :export && @export}
        export={@export}
        close={"#{@base}/versions/#{@v.configuration.version}"}
      />
    </Layouts.app>
    """
  end

  attr :setting, :string, required: true
  attr :becomes, :string, required: true
  attr :name, :string, required: true
  attr :hive, :string, required: true
  attr :would, :any, required: true
  attr :locked_denies, :list, required: true

  defp target_mode_dialog(%{becomes: "enforce"} = assigns) do
    shown = if assigns.would, do: Enum.take(assigns.would.destinations, 8), else: []

    left = if assigns.would, do: MapSet.size(assigns.would.open), else: 0

    assigns = assign(assigns, shown: shown, left: left)

    ~H"""
    <.modal
      id="repository-mode-enforce"
      title={"Enforce #{@name}"}
      size="lg"
      on_cancel={JS.push("dialog_cancel")}
    >
      <p class="text-muted">
        From the next heartbeat, about 30 s,
        <b class="font-medium text-base-content">a connection no rule allows is denied</b>
        in this repository's runs. {whose_words(@setting, "enforce")} Other repositories do not change.
      </p>
      <div :if={@would && @would.destinations != []} id="mode-would" class="q-would">
        <div>
          <span>Let through in this repository's runs, last 7 days, with no rule matching</span>
          <span id="mode-would-n" class="tabular-nums">
            {if @left == 0, do: "none left", else: Common.plural(@left, "destination")}
          </span>
        </div>
        <ul>
          <li :for={destination <- @shown} id={"would-#{Common.would_key(destination)}"}>
            <.rule_mark action={
              if !MapSet.member?(@would.open, Common.would_key(destination)),
                do: "allow",
                else: "pending"
            } />
            <span class="q-dest">
              {destination.host}<span :if={destination.path} class="text-muted">{destination.path}</span>
            </span>
            <small>
              {Common.plural(destination.attempts, "attempt")} · {Common.plural(
                destination.runs,
                "run"
              )}
            </small>
            <%= cond do %>
              <% !MapSet.member?(@would.open, Common.would_key(destination)) -> %>
                <span class="q-done"><.icon name="hero-check-micro" class="size-3" />Allowed</span>
              <% lock = Enum.find(@locked_denies, &Grammar.covers?(&1, destination.host)) -> %>
                <span
                  class="q-locked tooltip tooltip-left q-tip-wide"
                  tabindex="0"
                  data-tip={"A locked hive rule denies #{lock}. Only an owner can change it, on the hive's policy page."}
                >
                  <.icon name="hero-lock-closed-micro" class="size-3 text-muted" />Locked deny
                </span>
              <% true -> %>
                <button
                  type="button"
                  class="btn btn-xs"
                  phx-click={JS.push("would_allow", value: %{key: Common.would_key(destination)})}
                >
                  Allow here
                </button>
            <% end %>
          </li>
        </ul>
        <p :if={length(@would.destinations) > 8} class="q-would-more">
          and {length(@would.destinations) - 8} more on the connections page
        </p>
      </div>
      <p :if={@would && @would[:error]} class="text-error-soft-content" role="alert">
        {@would[:error]}
      </p>
      <p :if={@would && @would.destinations == []} id="mode-would-none" class="text-muted">
        Every destination this repository's runs reached in the last 7 days is covered by a rule.
      </p>
      <p :if={@would && @would.destinations != []} class="text-[12.5px]/[18px] text-muted">
        Counted from this repository's recorded connections that today's rules still do not cover. Enforce will deny these. A destination no run has reached yet is not in this list.
      </p>
      <:footer>
        <.button phx-click="dialog_cancel" data-autofocus>Cancel</.button>
        <.button
          id="repository-mode-confirm"
          variant="primary"
          phx-click="target_mode_confirm"
          loading_text="Setting"
        >
          {if @setting == "follow", do: "Follow the hive", else: "Enforce this repository"}
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp target_mode_dialog(assigns) do
    ~H"""
    <.modal
      id="repository-mode-observe"
      title={"Observe #{@name}"}
      size="sm"
      on_cancel={JS.push("dialog_cancel")}
    >
      <p class="text-muted">
        From the next heartbeat, about 30 s, <b class="font-medium text-base-content">only what a deny rule names is denied in this repository's runs</b>: every other connection is let through and recorded. {whose_words(
          @setting,
          "observe"
        )}
        <span :if={@setting != "follow"}>The hive's default stays {@hive} and other repositories do not change.</span>
      </p>
      <p class="text-muted">
        The rules stay as they are, locked ones too. A deny holds in either mode<span :if={
          @locked_denies != []
        }>: <code :for={host <- @locked_denies} class="q-rule mr-1">{host}</code>
          stays denied in this repository</span>.
      </p>
      <:footer>
        <.button phx-click="dialog_cancel" data-autofocus>Cancel</.button>
        <.button
          id="repository-mode-confirm"
          variant="danger"
          phx-click="target_mode_confirm"
          loading_text="Setting"
        >
          {if @setting == "follow", do: "Follow the hive", else: "Observe this repository"}
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp effective_count(rows, effective) do
    "#{Common.plural(length(rows), "rule")} · #{Common.plural(length(effective.allow), "host")} allowed" <>
      if(effective.deny == [], do: "", else: " · #{length(effective.deny)} denied")
  end

  defp whose_words("follow", _mode),
    do: "The mode follows the hive's default from now on, and changes when it does."

  defp whose_words(_setting, mode),
    do:
      "The mode becomes this repository's own: it stays #{mode} whatever the hive's default becomes."

  attr :live_action, :atom, required: true
  attr :base, :string, required: true
  attr :rules, :integer, required: true
  attr :changes, :integer, required: true
  attr :runs, :integer, required: true
  attr :document, :boolean, required: true
  attr :holder, :map, required: true

  defp target_tabs(assigns) do
    assigns =
      assign(
        assigns,
        :target_query,
        Filters.target_params(assigns.holder.system, assigns.holder.path)
      )

    ~H"""
    <nav id="policy-tabs" class="q-tabs" aria-label="Repository policy">
      <.link patch={@base} aria-current={@live_action == :rules && "page"}>
        <.icon name="hero-shield-check-micro" class="size-4" />Effective policy
        <span :if={@rules > 0} class="q-tabs-n">{@rules}</span>
      </.link>
      <.link patch={"#{@base}/history"} aria-current={@live_action == :history && "page"}>
        <.icon name="hero-clock-micro" class="size-4" />History
        <span :if={@changes > 0} class="q-tabs-n">{@changes}</span>
      </.link>
      <.link
        :if={@document}
        patch={"#{@base}/document"}
        aria-current={@live_action in [:version, :export] && "page"}
      >
        <.icon name="hero-document-text-micro" class="size-4" />Document
      </.link>
      <.link id="policy-tab-runs" navigate={~p"/hive/runs?#{@target_query}"}>
        <.icon name="hero-play-circle-micro" class="size-4" />Runs
        <span :if={@runs > 0} class="q-tabs-n" title="In the last 7 days">{@runs}</span>
      </.link>
      <.link id="policy-tab-connections" navigate={~p"/hive/connections?#{@target_query}"}>
        <.icon name="hero-arrows-right-left-micro" class="size-4" />Connections
      </.link>
    </nav>
    """
  end

  defp rules_tab(assigns) do
    rows = assigns.rows

    shown =
      case assigns.show do
        "hive" -> Enum.filter(rows, &(&1.source in [:hive, :hive_locked]))
        "repository" -> Enum.filter(rows, &(&1.source == :target))
        "overrides" -> Enum.filter(rows, &(&1.beaten != []))
        nil -> rows
      end

    assigns =
      assigns
      |> assign(:shown, shown)
      |> assign(:counts, %{
        hive: Enum.count(rows, &(&1.source in [:hive, :hive_locked])),
        target: Enum.count(rows, &(&1.source == :target)),
        overrides: Enum.count(rows, &(&1.beaten != []))
      })
      |> assign(
        :in_force_credentials,
        Enum.filter(assigns.credentials, &(&1.in_force and &1.action == "allow"))
      )

    ~H"""
    <.target_mode
      id="policy-repository-mode"
      setting={@mode.own || "follow"}
      effective={@mode.mode}
      hive_default={@mode.hive}
      can_edit={@owner?}
      locked_denies={@locked_denies}
    />

    <.notice :if={@own == [] && is_nil(@mode.own)} kind={:info} class="max-w-[90ch]">
      <span id="policy-no-own">
        This repository has no rules of its own.
        <span :if={@version}>It is served the hive baseline, version {@version.version}.</span>
        <span :if={!@managed?}>
          Runs use each machine's own policy until the first change in this hive.
        </span>
        The first rule added here, or a mode of its own, gives it versions of its own.
      </span>
    </.notice>

    <.suggestions
      id="policy-suggestions"
      suggestions={@suggestions}
      covered={@covered}
      allowed={@allowed}
    />

    <.sect
      id="policy-effective"
      title="Effective policy"
      count={effective_count(@rows, @effective)}
    >
      <:trailing>
        <.segments id="policy-show" label="Show">
          <:segment patch={@base} pressed={@show == nil}>All</:segment>
          <:segment patch={"#{@base}?show=hive"} pressed={@show == "hive"} count={@counts.hive}>
            From the hive
          </:segment>
          <:segment
            patch={"#{@base}?show=repository"}
            pressed={@show == "repository"}
            count={@counts.target}
          >
            This repository
          </:segment>
          <:segment
            patch={"#{@base}?show=overrides"}
            pressed={@show == "overrides"}
            count={@counts.overrides}
          >
            Overrides
          </:segment>
        </.segments>
      </:trailing>
      <.rule_composer
        id="policy-composer"
        form={@composer}
        scope={:target}
        reading={@reading}
        queued={length(@queue)}
        host_placeholder="mcp.acme.example"
      />
      <.rules_table
        id="policy-rules"
        label={"Effective policy of #{@holder.system}/#{@holder.path}"}
        rows={@shown}
        scope={:target}
        activity={async_value(@activity)}
        fresh={@fresh}
        ruled_host={@ruled_host}
        empty={empty_words(@show, @rows)}
      />
      <.credential_composer
        :if={@credentials_open}
        id="policy-credential"
        form={@credential}
        reading={@credential_reading}
        class="border-t border-line"
      />
      <.credentials_table
        :if={@credentials_open}
        id="policy-credential-rows"
        label="Credentials of this repository and of the hive"
        rows={@credentials}
        scope={:target}
        activity={async_value(@activity)}
      />
      <:footer>
        <span id="policy-effective-foot">
          Mode <b class="font-medium text-base-content">{@mode.mode}</b>, {if @mode.own,
            do: "this repository's own.",
            else: "the hive's default."}
          <span :if={@in_force_credentials == []}>No credentials.</span>
          <span :if={@in_force_credentials != []}>
            Credentials:
            <span :for={{credential, index} <- Enum.with_index(@in_force_credentials, 1)}>
              <code class="q-rule">{credential.name}</code>
              <span :if={credential.argument}>
                <span class="text-faint">argument</span>
                <code class="q-rule">{credential.argument}</code>
              </span>
              <span>{credential_from(credential, index == length(@in_force_credentials))}</span>
            </span>
          </span>
          <button
            id="policy-credentials-toggle"
            type="button"
            class="q-link"
            aria-expanded={to_string(@credentials_open)}
            phx-click="credentials_toggle"
          >
            {if @credentials_open, do: "Done with credentials", else: "Edit credentials"}
          </button>
        </span>
      </:footer>
    </.sect>
    """
  end

  defp credential_from(%{source: :target}, last?),
    do: "from this repository" <> if(last?, do: ".", else: ",")

  defp credential_from(_credential, last?), do: "from the hive" <> if(last?, do: ".", else: ",")

  defp empty_words(_show, []), do: "No rule is in force for this repository yet."
  defp empty_words("hive", _rows), do: "No rules from the hive."
  defp empty_words("repository", _rows), do: "No rules of this repository's own."
  defp empty_words("overrides", _rows), do: "No overrides."
  defp empty_words(_show, _rows), do: nil

  defp async_value(%Phoenix.LiveView.AsyncResult{ok?: true, result: result}), do: result
  defp async_value(%Phoenix.LiveView.AsyncResult{loading: nil}), do: :unavailable
  defp async_value(_async), do: :loading
end
