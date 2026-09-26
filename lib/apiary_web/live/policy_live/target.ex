defmodule ApiaryWeb.PolicyLive.Target do
  @moduledoc """
  A target's view of the workspace's policy: the effective list, one row per host in force
  with where it came from, the rules that lost hung under the rule that beat them; the
  hosts the harness declared; the target's own history, versions and export.

  `:target_id` is the target row's id. A target of another workspace is not found:
  the page renders the not-found state and never another workspace's rules.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :security
  on_mount {ApiaryWeb.Access, :"security_policy.read"}

  import ApiaryWeb.PolicyComponents
  import ApiaryWeb.PolicyLive.Views

  alias Apiary.Policy
  alias Apiary.Runs.Filters
  alias ApiaryWeb.PolicyLive.Common
  alias Apiary.Policy.Grammar
  alias ApiaryWeb.PolicyLive.Show

  @shows ~w(workspace target overrides)

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
            else: assign(socket, loaded: false, page_title: gettext("Policy"))

        {:ok, socket}

      {:error, _not_found} ->
        {:ok, assign(socket, holder: :not_found, loaded: true, page_title: gettext("Policy"))}
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
          %{
            kind: :host,
            source: :workspace,
            locked: true,
            action: :deny,
            in_force: true,
            host: host
          } <-
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
        source:
          if(entry.source == :workspace and entry.locked,
            do: :workspace_locked,
            else: entry.source
          ),
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
    socket = assign(socket, :page_title, gettext("History · %{title}", title: title(socket)))
    history = Common.history(socket, Common.page_param(params["page"]))

    {open, diff} =
      case params["change"] && Common.change_diff(socket, params["change"]) do
        {:ok, diff} -> {diff.id, diff}
        _ -> {nil, nil}
      end

    assign(socket, history: history, open_change: open, diff: diff, summary: summary(socket))
  end

  defp apply_action(socket, :document, _params) do
    scope = socket.assigns.current_scope

    to =
      case socket.assigns do
        %{version: %{version: n}, baseline?: false} ->
          "#{socket.assigns.base}/versions/#{n}"

        %{version: %{version: n}} ->
          ~p"/#{scope.organisation}/#{scope.workspace}/policy/versions/#{n}"

        _ ->
          socket.assigns.base
      end

    push_navigate(socket, to: to, replace: true)
  end

  defp apply_action(socket, action, %{"n" => n} = params) when action in [:version, :export] do
    case Common.version(socket, n, params) do
      {:ok, v} ->
        socket =
          assign(socket,
            v: v,
            page_title:
              gettext("Version %{version} · %{title}",
                version: v.configuration.version,
                title: title(socket)
              )
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
    do: gettext("%{target} · Policy", target: "#{system}/#{path}")

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
      # workspace rule that became a deny is not disabled, one that became an allow is not
      # allowed again over its paths, and a locked one is an owner's on the workspace's
      # page.
      {result, sentence, announce} =
        case {act, rule.target_id, rule.action} do
          {_act, nil, _action} when rule.locked ->
            {{:error,
              %Policy.Error{
                reason: :locked,
                message:
                  gettext(
                    "The workspace's rule for %{host} is locked. An owner changes it on the workspace's policy page.",
                    host: rule.host
                  )
              }}, nil, nil}

          {"disable", nil, "allow"} ->
            {Policy.deny(scope, target, %{host: rule.host}),
             gettext("%{host} is denied for %{target}.", host: rule.host, target: name(target)),
             gettext("%{host} is disabled for this target.", host: rule.host)}

          {"allow_here", nil, "deny"} ->
            {Policy.allow(scope, target, %{host: rule.host, paths: nil}),
             gettext("%{host} is allowed for %{target}.", host: rule.host, target: name(target)),
             gettext("%{host} is allowed for this target.", host: rule.host)}

          {act, target_id, _action}
          when act in ~w(remove restore) and target_id == target.id ->
            {Policy.remove_rule(scope, rule),
             if(act == "restore",
               do:
                 gettext("The workspace's rule for %{host} is restored for %{target}.",
                   host: rule.host,
                   target: name(target)
                 ),
               else: gettext("The rule %{host} is removed.", host: rule.host)
             ), gettext("Rule removed.")}

          _ ->
            {{:error,
              %Policy.Error{
                reason: :conflict,
                message:
                  gettext(
                    "The rule for %{host} changed while you were deciding. The list below is current.",
                    host: rule.host
                  )
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
    becomes = if setting == "follow", do: mode.workspace, else: setting
    now = if mode.own, do: mode.own, else: "follow"

    cond do
      not Common.may?(socket, :"security_policy.set_mode") ->
        assign(socket, :write_error, gettext("Only an owner sets a mode."))

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
            |> assign(
              :announce,
              gettext("%{host} is allowed for this target.", host: destination.host)
            )

          {:error, error} ->
            assign(socket, :would, Map.put(would, :error, error.message))
        end
    end
  end

  defp event("suggest_allow", %{"host" => host, "level" => level}, socket)
       when is_binary(host) and level in ~w(target workspace) do
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
      case allow_suggestion(socket, host, "target") do
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
      |> Common.wrote(
        nil,
        gettext("The credential %{name} is removed.", name: rule.name),
        gettext("Credential removed.")
      )
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
              gettext("%{target} follows the workspace: %{mode}.",
                target: name,
                mode: mode.workspace
              )

            mode.mode == before.mode and setting == "observe" ->
              gettext(
                "%{target} observes on its own. Nothing changes today: the workspace's default is %{mode} too.",
                target: name,
                mode: mode.workspace
              )

            mode.mode == before.mode ->
              gettext(
                "%{target} enforces on its own. Nothing changes today: the workspace's default is %{mode} too.",
                target: name,
                mode: mode.workspace
              )

            setting == "observe" ->
              gettext("%{target} observes on its own.", target: name)

            true ->
              gettext("%{target} enforces on its own.", target: name)
          end

        socket
        |> Common.wrote(nil, sentence, gettext("This target's mode is %{mode}.", mode: mode.mode))
        |> Common.focus("policy-target-mode-#{setting}")

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  # The suggestions that were there when the page opened stay until the next navigation,
  # with what was done to them, though the policy now covers them.
  defp allow_suggestion(socket, host, level) do
    scope = socket.assigns.current_scope
    holder = if level == "workspace", do: nil, else: socket.assigns.holder
    shown = socket.assigns.suggestions

    case Policy.allow(scope, holder, %{host: host}) do
      {:ok, rule} ->
        {sentence, announce} =
          if level == "workspace",
            do:
              {gettext("%{host} is allowed for the workspace.", host: host),
               gettext("%{host} is allowed for the workspace.", host: host)},
            else:
              {gettext("%{host} is allowed for %{target}.",
                 host: host,
                 target: name(socket.assigns.holder)
               ), gettext("%{host} is allowed for this target.", host: host)}

        socket =
          socket
          |> Common.wrote(if(level == "workspace", do: nil, else: rule), sentence, announce)
          |> assign(:suggestions, shown)
          |> assign(:allowed, Map.put(socket.assigns.allowed, host, %{id: rule.id, level: level}))

        {:ok, socket}

      {:error, error} ->
        {:error, Common.refused(socket, error) |> assign(:suggestions, shown)}
    end
  end

  defp name(%{system: system, path: path}), do: "#{system}/#{path}"

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
        title={gettext("This target is not in this workspace")}
      >
        {gettext("The link may be for another workspace, or the target has not posted a run here.")}
        <:actions>
          <.button navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy"}>{gettext(
            "Back to policy"
          )}</.button>
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
          <nav class="q-crumbs" aria-label={gettext("Breadcrumb")}>
            <.link navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy"}>{gettext(
              "Policy"
            )}</.link>
            <.icon name="hero-chevron-right-micro" class="size-3" />
            <%= if @live_action in [:version, :export] && @v do %>
              <.link navigate={@base} class="font-mono text-xs">
                <span class="text-faint">{@holder.system}/</span>{@holder.path}
              </.link>
              <.icon name="hero-chevron-right-micro" class="size-3" />
              <span class="q-here" aria-current="page">
                {gettext("Version %{version}", version: @v.configuration.version)}
              </span>
            <% else %>
              <.link navigate={
                ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy/targets"
              }>{gettext("Targets")}</.link>
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
                {gettext(
                  "What runs of this target may reach: the workspace's rules, then this target's own."
                )}
                {gettext(
                  "Where the two meet on a host, the target wins, unless the workspace's rule is locked."
                )}
              </p>
            </div>
            <div :if={@version} class="q-head-side">
              <span class="inline-flex items-center gap-2">
                <.version_pill
                  id="policy-version-pill"
                  version={@version.version}
                  digest={@version.digest}
                  navigate={
                    if @baseline?,
                      do:
                        ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy/history",
                      else: "#{@base}/history"
                  }
                  copy
                />
                <small :if={@baseline?} id="policy-baseline" class="text-xs text-faint">
                  <.term
                    word={gettext("workspace baseline")}
                    standard={baseline_tip()}
                    class="q-tip-wide tooltip-left"
                  />
                </small>
              </span>
              <.button
                id="policy-export-button"
                navigate={
                  if @baseline?,
                    do:
                      ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy/versions/#{@version.version}/export",
                    else: "#{@base}/versions/#{@version.version}/export"
                }
              >
                <.icon name="hero-arrow-up-tray-micro" class="size-4" />{gettext("Export")}
              </.button>
            </div>
          </header>
        </div>

        <.target_tabs
          scope={@current_scope}
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
          title={gettext("There is no version %{version}", version: String.slice(@missing.n, 0, 12))}
        >
          <span :if={@missing.latest}>
            {gettext("The latest is version %{version}.", version: @missing.latest.version)}
          </span>
          <span :if={!@missing.latest}>
            {gettext("This target has no versions of its own: it is served the workspace baseline.")}
          </span>
          <:actions>
            <.button :if={@missing.latest} navigate={"#{@base}/versions/#{@missing.latest.version}"}>
              {gettext("Open version %{version}", version: @missing.latest.version)}
            </.button>
            <.button :if={!@missing.latest} navigate={@base}>
              {gettext("Back to the target's policy")}
            </.button>
          </:actions>
        </.empty_state>
      </div>

      <.keys_dialog />
      <.target_mode_dialog
        :if={match?({:target_mode, _, _}, @dialog)}
        setting={elem(@dialog, 1)}
        becomes={elem(@dialog, 2)}
        name={Common.holder_name(%{assigns: %{holder: @holder}})}
        workspace={@mode.workspace}
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
  attr :workspace, :string, required: true
  attr :would, :any, required: true
  attr :locked_denies, :list, required: true

  defp target_mode_dialog(%{becomes: "enforce"} = assigns) do
    shown = if assigns.would, do: Enum.take(assigns.would.destinations, 8), else: []

    left = if assigns.would, do: MapSet.size(assigns.would.open), else: 0

    assigns = assign(assigns, shown: shown, left: left)

    ~H"""
    <.modal
      id="target-mode-enforce"
      title={gettext("Enforce %{target}", target: @name)}
      size="lg"
      on_cancel={JS.push("dialog_cancel")}
    >
      <p class="text-muted">
        <.rich text={mode_lead("enforce")} />
        {whose_words(@setting, "enforce")} {gettext("Other targets do not change.")}
      </p>
      <div :if={@would && @would.destinations != []} id="mode-would" class="q-would">
        <div>
          <span>
            {gettext("Let through in this target's runs, last 7 days, with no rule matching")}
          </span>
          <span id="mode-would-n" class="tabular-nums">
            {if @left == 0,
              do: gettext("none left"),
              else:
                ngettext("%{number} destination", "%{number} destinations", @left,
                  number: Format.number(@left)
                )}
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
              {ngettext("%{number} attempt", "%{number} attempts", destination.attempts,
                number: Format.number(destination.attempts)
              )} · {ngettext(
                "%{number} run",
                "%{number} runs",
                destination.runs,
                number: Format.number(destination.runs)
              )}
            </small>
            <%= cond do %>
              <% !MapSet.member?(@would.open, Common.would_key(destination)) -> %>
                <span class="q-done"><.icon name="hero-check-micro" class="size-3" />{gettext(
                  "Allowed"
                )}</span>
              <% lock = Enum.find(@locked_denies, &Grammar.covers?(&1, destination.host)) -> %>
                <span
                  class="q-locked tooltip tooltip-left q-tip-wide"
                  tabindex="0"
                  data-tip={locked_tip(lock)}
                >
                  <.icon name="hero-lock-closed-micro" class="size-3 text-muted" />{gettext(
                    "Locked deny"
                  )}
                </span>
              <% true -> %>
                <button
                  type="button"
                  class="btn btn-xs"
                  phx-click={JS.push("would_allow", value: %{key: Common.would_key(destination)})}
                >
                  {gettext("Allow here")}
                </button>
            <% end %>
          </li>
        </ul>
        <p :if={length(@would.destinations) > 8} class="q-would-more">
          {ngettext(
            "and %{number} more on the connections page",
            "and %{number} more on the connections page",
            length(@would.destinations) - 8,
            number: Format.number(length(@would.destinations) - 8)
          )}
        </p>
      </div>
      <p :if={@would && @would[:error]} class="text-error-soft-content" role="alert">
        {@would[:error]}
      </p>
      <p :if={@would && @would.destinations == []} id="mode-would-none" class="text-muted">
        {gettext(
          "Every destination this target's runs reached in the last 7 days is covered by a rule."
        )}
      </p>
      <p :if={@would && @would.destinations != []} class="text-[12.5px]/[18px] text-muted">
        {gettext(
          "Counted from this target's recorded connections that today's rules still do not cover."
        )}
        {gettext("Enforce will deny these.")}
        {gettext("A destination no run has reached yet is not in this list.")}
      </p>
      <:footer>
        <.button phx-click="dialog_cancel" data-autofocus>{gettext("Cancel")}</.button>
        <.button
          id="target-mode-confirm"
          variant="primary"
          phx-click="target_mode_confirm"
          loading_text={gettext("Setting")}
        >
          {if @setting == "follow",
            do: gettext("Follow the workspace"),
            else: gettext("Enforce this target")}
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp target_mode_dialog(assigns) do
    ~H"""
    <.modal
      id="target-mode-observe"
      title={gettext("Observe %{target}", target: @name)}
      size="sm"
      on_cancel={JS.push("dialog_cancel")}
    >
      <p class="text-muted">
        <.rich text={mode_lead("observe")} />
        {whose_words(@setting, "observe")}
        <span :if={@setting != "follow"}>
          {gettext("The workspace's default stays %{mode} and other targets do not change.",
            mode: @workspace
          )}
        </span>
      </p>
      <p class="text-muted">
        {gettext("The rules stay as they are, locked ones too.")}
        <span :if={@locked_denies == []}>{gettext("A deny holds in either mode.")}</span>
        <.rich :if={@locked_denies != []} text={locked_denies_words(@locked_denies)} />
      </p>
      <:footer>
        <.button phx-click="dialog_cancel" data-autofocus>{gettext("Cancel")}</.button>
        <.button
          id="target-mode-confirm"
          variant="danger"
          phx-click="target_mode_confirm"
          loading_text={gettext("Setting")}
        >
          {if @setting == "follow",
            do: gettext("Follow the workspace"),
            else: gettext("Observe this target")}
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp effective_count(rows, effective) do
    [
      ngettext("%{number} rule", "%{number} rules", length(rows),
        number: Format.number(length(rows))
      ),
      ngettext("%{number} host allowed", "%{number} hosts allowed", length(effective.allow),
        number: Format.number(length(effective.allow))
      ),
      effective.deny != [] &&
        ngettext("%{number} denied", "%{number} denied", length(effective.deny),
          number: Format.number(length(effective.deny))
        )
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp whose_words("follow", _mode),
    do: gettext("The mode follows the workspace's default from now on, and changes when it does.")

  defp whose_words(_setting, mode),
    do:
      gettext(
        "The mode becomes this target's own: it stays %{mode} whatever the workspace's default becomes.",
        mode: mode
      )

  attr :live_action, :atom, required: true
  attr :base, :string, required: true
  attr :rules, :integer, required: true
  attr :changes, :integer, required: true
  attr :runs, :integer, required: true
  attr :document, :boolean, required: true
  attr :holder, :map, required: true

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  defp target_tabs(assigns) do
    assigns =
      assign(
        assigns,
        :target_query,
        Filters.target_params(assigns.holder.system, assigns.holder.path)
      )

    ~H"""
    <nav id="policy-tabs" class="q-tabs" aria-label={gettext("Target policy")}>
      <.link patch={@base} aria-current={@live_action == :rules && "page"}>
        <.icon name="hero-shield-check-micro" class="size-4" />{gettext("Effective policy")}
        <span :if={@rules > 0} class="q-tabs-n">{@rules}</span>
      </.link>
      <.link patch={"#{@base}/history"} aria-current={@live_action == :history && "page"}>
        <.icon name="hero-clock-micro" class="size-4" />{gettext("History")}
        <span :if={@changes > 0} class="q-tabs-n">{@changes}</span>
      </.link>
      <.link
        :if={@document}
        patch={"#{@base}/document"}
        aria-current={@live_action in [:version, :export] && "page"}
      >
        <.icon name="hero-document-text-micro" class="size-4" />{gettext("Document")}
      </.link>
      <.link
        id="policy-tab-runs"
        navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs?#{@target_query}"}
      >
        <.icon name="hero-play-circle-micro" class="size-4" />{gettext("Runs")}
        <span :if={@runs > 0} class="q-tabs-n" title={gettext("In the last 7 days")}>{@runs}</span>
      </.link>
      <.link
        id="policy-tab-connections"
        navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/connections?#{@target_query}"}
      >
        <.icon name="hero-arrows-right-left-micro" class="size-4" />{gettext("Connections")}
      </.link>
    </nav>
    """
  end

  defp rules_tab(assigns) do
    rows = assigns.rows

    shown =
      case assigns.show do
        "workspace" -> Enum.filter(rows, &(&1.source in [:workspace, :workspace_locked]))
        "target" -> Enum.filter(rows, &(&1.source == :target))
        "overrides" -> Enum.filter(rows, &(&1.beaten != []))
        nil -> rows
      end

    assigns =
      assigns
      |> assign(:shown, shown)
      |> assign(:counts, %{
        workspace: Enum.count(rows, &(&1.source in [:workspace, :workspace_locked])),
        target: Enum.count(rows, &(&1.source == :target)),
        overrides: Enum.count(rows, &(&1.beaten != []))
      })
      |> assign(
        :in_force_credentials,
        Enum.filter(assigns.credentials, &(&1.in_force and &1.action == "allow"))
      )

    ~H"""
    <.target_mode
      id="policy-target-mode"
      setting={@mode.own || "follow"}
      effective={@mode.mode}
      workspace_default={@mode.workspace}
      can_edit={Common.may?(@current_scope, :"security_policy.set_mode")}
      locked_denies={@locked_denies}
    />

    <.notice :if={@own == [] && is_nil(@mode.own)} kind={:info} class="max-w-[90ch]">
      <span id="policy-no-own">
        {gettext("This target has no rules of its own.")}
        <span :if={@version}>
          {gettext("It is served the workspace baseline, version %{version}.",
            version: @version.version
          )}
        </span>
        <span :if={!@managed?}>
          {gettext("Runs use each machine's own policy until the first change in this workspace.")}
        </span>
        {gettext("The first rule added here, or a mode of its own, gives it versions of its own.")}
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
      title={gettext("Effective policy")}
      count={effective_count(@rows, @effective)}
    >
      <:trailing>
        <.segments id="policy-show" label={gettext("Show")}>
          <:segment patch={@base} pressed={@show == nil}>{gettext("All")}</:segment>
          <:segment
            patch={"#{@base}?show=workspace"}
            pressed={@show == "workspace"}
            count={@counts.workspace}
          >
            {gettext("From the workspace")}
          </:segment>
          <:segment
            patch={"#{@base}?show=target"}
            pressed={@show == "target"}
            count={@counts.target}
          >
            {gettext("This target")}
          </:segment>
          <:segment
            patch={"#{@base}?show=overrides"}
            pressed={@show == "overrides"}
            count={@counts.overrides}
          >
            {gettext("Overrides")}
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
        label={gettext("Effective policy of %{target}", target: "#{@holder.system}/#{@holder.path}")}
        rows={@shown}
        scope={:target}
        current_scope={@current_scope}
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
        label={gettext("Credentials of this target and of the workspace")}
        rows={@credentials}
        scope={:target}
        activity={async_value(@activity)}
      />
      <:footer>
        <span id="policy-effective-foot">
          <.rich text={mode_words(@mode)} />
          <span :if={@in_force_credentials == []}>{gettext("No credentials.")}</span>
          <span :if={@in_force_credentials != []}>
            <.rich text={credentials_words(@in_force_credentials)} />
          </span>
          <button
            id="policy-credentials-toggle"
            type="button"
            class="q-link"
            aria-expanded={to_string(@credentials_open)}
            phx-click="credentials_toggle"
          >
            {if @credentials_open,
              do: gettext("Done with credentials"),
              else: gettext("Edit credentials")}
          </button>
        </span>
      </:footer>
    </.sect>
    """
  end

  # The lead of a mode's confirm: from when, and what is denied.
  defp mode_lead("enforce"),
    do:
      rich_gettext("From the next heartbeat, about 30 s, %{denied} in this target's runs.",
        denied:
          {:b, gettext("a connection no rule allows is denied"), "font-medium text-base-content"}
      )

  defp mode_lead("observe"),
    do:
      rich_gettext(
        "From the next heartbeat, about 30 s, %{denied}: every other connection is let through and recorded.",
        denied:
          {:b, gettext("only what a deny rule names is denied in this target's runs"),
           "font-medium text-base-content"}
      )

  defp locked_tip(host),
    do:
      gettext(
        "A locked workspace rule denies %{host}. Only an owner can change it, on the workspace's policy page.",
        host: host
      )

  defp baseline_tip,
    do:
      gettext(
        "The workspace's rules with no target's own: what a target without rules, or a run that names none, is served."
      )

  defp locked_denies_words(hosts),
    do:
      rich_ngettext(
        "A deny holds in either mode: %{hosts} stays denied in this target.",
        "A deny holds in either mode: %{hosts} stay denied in this target.",
        length(hosts),
        hosts: Enum.intersperse(Enum.map(hosts, &{:code, &1}), " ")
      )

  defp mode_words(%{own: nil, mode: mode}),
    do:
      rich_gettext("Mode %{mode}, the workspace's default.",
        mode: {:b, mode, "font-medium text-base-content"}
      )

  defp mode_words(%{mode: mode}),
    do:
      rich_gettext("Mode %{mode}, this target's own.",
        mode: {:b, mode, "font-medium text-base-content"}
      )

  defp credentials_words(credentials),
    do:
      rich_gettext("Credentials: %{credentials}.",
        credentials: Enum.intersperse(Enum.map(credentials, &credential_words/1), ", ")
      )

  # One credential in force, as a phrase of the footer's list.
  defp credential_words(%{source: :target, argument: nil} = credential),
    do: rich_gettext("%{name} from this target", name: {:code, credential.name})

  defp credential_words(%{source: :target} = credential),
    do:
      rich_gettext("%{name} argument %{argument} from this target",
        name: {:code, credential.name},
        argument: {:code, credential.argument}
      )

  defp credential_words(%{argument: nil} = credential),
    do: rich_gettext("%{name} from the workspace", name: {:code, credential.name})

  defp credential_words(credential),
    do:
      rich_gettext("%{name} argument %{argument} from the workspace",
        name: {:code, credential.name},
        argument: {:code, credential.argument}
      )

  defp empty_words(_show, []), do: gettext("No rule is in force for this target yet.")
  defp empty_words("workspace", _rows), do: gettext("No rules from the workspace.")
  defp empty_words("target", _rows), do: gettext("No rules of this target's own.")
  defp empty_words("overrides", _rows), do: gettext("No overrides.")
  defp empty_words(_show, _rows), do: nil

  defp async_value(%Phoenix.LiveView.AsyncResult{ok?: true, result: result}), do: result
  defp async_value(%Phoenix.LiveView.AsyncResult{loading: nil}), do: :unavailable
  defp async_value(_async), do: :loading
end
