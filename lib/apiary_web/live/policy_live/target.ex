defmodule ApiaryWeb.PolicyLive.Target do
  @moduledoc """
  A target's view of the workspace's policy, the Policy tab of the target's page
  (`ApiaryWeb.TargetLive.Show`, `…/-/policy`): the effective list, one row per host in
  force with where it came from, the rules that lost hung under the rule that beat them;
  the hosts the harness declared; the target's own history (`…/-/policy/history`),
  versions (`…/-/policy/versions/:n`, with `/export`) and document.

  Not a page of its own: the target's page mounts it with the target it found in its own
  workspace (`mount/2`), puts the tab's action in `:action` (`:rules`, `:history`,
  `:document`, `:version`, `:export`) and hands it the page's parameters, events and
  messages while the tab is open (`handle_params/2`, `handle_event/3`, `handle_info/2`);
  it renders the tab's content (`content/1`) under the page's header and tabs. The old
  paths, `/policy/targets/:target_id/…`, send on to the tab (`ApiaryWeb.MovedController`).
  """
  use ApiaryWeb, :html
  use ApiaryWeb.Async

  import ApiaryWeb.PolicyComponents
  import ApiaryWeb.PolicyLive.Views

  alias Apiary.Policy
  alias Apiary.Policy.Grammar
  alias Apiary.Runs.Filters
  alias ApiaryWeb.PolicyLive.{Common, RuleList, Show}

  @doc """
  mount/3 is the tab's assigns for `target`, a target of the scope's workspace, and the
  subscription to the policy's changes. `shared` is whether the target's path is shared
  by another target of the workspace, as its page's address says; read once when nil.
  The tab names and addresses the target by it. The tab is read once, by the connected
  mount: the first render is its skeleton.
  """
  def mount(socket, target, shared \\ nil) do
    socket =
      socket
      |> Common.mount(target, if(is_boolean(shared), do: [shared: shared], else: []))
      |> assign(reload: &load/1, list_query: %RuleList{}, ruled_host: nil, allowed: %{})
      |> assign(history: nil, open_change: nil, diff: nil, v: nil, export: nil, missing: nil)
      |> assign(composer_open: false, summary: nil, would: nil, params: %{}, shown: nil)

    if connected?(socket),
      do: socket |> load() |> assign(loaded: true, network: network_path(socket, target)),
      else: assign(socket, loaded: false)
  end

  # What the target's runs reached: Network access narrowed to the target, its system in
  # the address only where another system has the same path.
  defp network_path(socket, target) do
    scope = socket.assigns.current_scope
    params = Filters.target_params(target.system, target.path, socket.assigns.holder_shared)
    ~p"/#{scope.organisation}/#{scope.workspace}/network?#{params}"
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
      # The denies that hold in the target whatever its own rules: the level above's and
      # the workspace's locked.
      locked_denies:
        for(
          %{
            kind: :host,
            source: source,
            locked: locked,
            action: :deny,
            in_force: true,
            host: host
          } <-
            effective.entries,
          source == :organisation or (source == :workspace and locked),
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
      mode_set: mode_set(changes.items),
      suggestions: declared.suggested,
      covered: declared.covered,
      reload_pending: false,
      now: DateTime.utc_now()
    )
    |> then(fn socket ->
      assign(socket,
        rows: Common.target_rules(effective, socket)
      )
    end)
    |> load_record()
  end

  # Who set the target's own mode, and when: the newest change of its mode on the first
  # page of its history, nil when it is further back or the target follows.
  defp mode_set(changes) do
    case Enum.find(changes, &(&1.action == "mode_changed")) do
      %{after: %{"mode" => mode}} = change when mode in ~w(observe enforce) ->
        %{
          by: ApiaryWeb.People.short(ApiaryWeb.People.email(change.changed_by)),
          at: change.inserted_at
        }

      _ ->
        nil
    end
  end

  defp load_record(socket) do
    if connected?(socket) do
      scope = socket.assigns.current_scope
      target = socket.assigns.holder

      assign_async(socket, :activity, fn ->
        case Policy.rule_activity(scope, target, Common.use_since()) do
          {:ok, activity} -> {:ok, %{activity: activity}}
          _ -> {:ok, %{activity: :unavailable}}
        end
      end)
    else
      assign(socket, :activity, Phoenix.LiveView.AsyncResult.loading())
    end
  end

  @doc """
  handle_params/2 applies the tab's action (`:action`) with the page's parameters: the
  rule the URL points at, the history's page and opened change, the version shown.
  """
  def handle_params(_params, %{assigns: %{loaded: false}} = socket), do: {:noreply, socket}

  def handle_params(params, socket) do
    socket = assign(socket, missing: nil, export: nil, params: params, now: DateTime.utc_now())

    # The mode's choices stay open on every view, the card being above them, and close
    # where the card is not drawn: a version and its export.
    socket =
      if socket.assigns.action in [:version, :export],
        do: assign(socket, mode_pick: nil, would: nil),
        else: socket

    action = socket.assigns.action

    {:noreply,
     socket
     |> apply_action(action, params)
     |> Common.heading_focus(socket.assigns.shown, action)
     |> assign(:shown, action)}
  end

  # The list's query is the URL's (`RuleList`), written back without what it does not
  # know; `?rule=` lands on the page of the list that holds the rule.
  defp apply_action(socket, :rules, params) do
    if RuleList.canonical?(params) do
      ruled_host = Common.rule_param(params["rule"])

      query =
        RuleList.landing(
          RuleList.parse(params),
          socket.assigns.rows,
          Common.async_value(socket.assigns.activity),
          ruled_host
        )

      socket
      |> assign(list_query: query, ruled_host: ruled_host, page_title: title(socket))
      |> then(&if(ruled_host, do: push_event(&1, "policy:rule", %{host: ruled_host}), else: &1))
    else
      push_patch(socket,
        to: Common.list_path(socket, RuleList.parse(params), Map.take(params, ~w(rule))),
        replace: true
      )
    end
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
            assign(socket,
              export: Common.export(socket, v.configuration),
              page_title:
                gettext("Export · Version %{version} · %{title}",
                  version: v.configuration.version,
                  title: title(socket)
                )
            )

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

  defp title(socket), do: gettext("%{target} · Policy", target: Common.holder_name(socket))

  ## Events

  # The rows' menu is the tab's own here: its own rules are weighed against the
  # workspace's, and a rule of another holder is a link, never an event.
  @own_events ~w(edit_paths change_action remove)
  @settings ~w(follow observe enforce)

  @doc "handle_event/3 is the tab's answer to an event of its content."
  def handle_event(event, params, socket) when event in @own_events,
    do: {:noreply, event(event, params, socket)}

  def handle_event(event, params, socket) do
    case Common.handle_event(event, params, socket) do
      {:halt, socket} -> {:noreply, socket}
      :cont -> {:noreply, event(event, params, socket)}
    end
  end

  # The mode's choices: opened by Change mode, a pick only selects, and one button saves
  # the pick; Cancel and Escape close them. Each asks again whether the reader may set a
  # mode and whether the level above fixes it. `mode_pick` alone says the choices are open,
  # and what is picked.
  defp event("mode_open", params, socket) do
    cond do
      socket.assigns.mode.floor ->
        socket

      not Common.may?(socket, :"security_policy.set_mode") ->
        assign(socket, :write_error, gettext("Only an owner or an admin sets a mode."))

      true ->
        pick =
          case params do
            %{"mode" => setting} when setting in @settings -> setting
            _ -> setting(socket.assigns.mode)
          end

        socket |> pick_mode(pick) |> Common.focus("policy-mode-opt-#{pick}")
    end
  end

  defp event("mode_pick", %{"mode" => setting}, socket) when setting in @settings do
    cond do
      socket.assigns.mode.floor or is_nil(socket.assigns.mode_pick) ->
        socket

      not Common.may?(socket, :"security_policy.set_mode") ->
        assign(socket, :write_error, gettext("Only an owner or an admin sets a mode."))

      true ->
        pick_mode(socket, setting)
    end
  end

  defp event("mode_set", _params, socket) do
    pick = socket.assigns.mode_pick

    cond do
      socket.assigns.mode.floor ->
        socket

      not Common.may?(socket, :"security_policy.set_mode") ->
        assign(socket, :write_error, gettext("Only an owner or an admin sets a mode."))

      is_nil(pick) ->
        socket

      pick == setting(socket.assigns.mode) ->
        close_mode(socket)

      true ->
        socket |> assign(mode_pick: nil, would: nil) |> set_target_mode(pick)
    end
  end

  defp event("mode_cancel", _params, socket), do: close_mode(socket)

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
            would = Common.would(scope, target, would)
            socket = load(socket)
            locked = socket.assigns.locked_denies

            socket
            |> assign(:would, would)
            |> assign(
              :announce,
              gettext("%{host} is allowed for this target.", host: destination.host)
            )
            |> Common.focus_next_allow(
              would,
              key,
              "policy-mode-set",
              &(not Enum.any?(locked, fn lock -> Grammar.covers?(lock, &1.host) end))
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

  # The target's own rule, from its menu: its paths into the composer, the other action,
  # or its removal (which gives back the workspace's rule it overrode, `restore`).
  defp event("edit_paths", %{"id" => id}, socket) do
    target_id = socket.assigns.holder.id

    case Policy.get_rule(socket.assigns.current_scope, id) do
      {:ok, %{kind: "host", target_id: ^target_id, action: "allow"} = rule} ->
        socket
        |> assign(:composer_open, true)
        |> Common.read(%{
          "action" => "allow",
          "host" => rule.host,
          "paths" => Enum.join(rule.paths || [], " "),
          "every" => "false"
        })
        |> Common.set_fields()
        |> Common.focus("policy-composer-paths")

      _ ->
        socket
    end
  end

  defp event("change_action", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    target = socket.assigns.holder
    target_id = target.id

    case Policy.get_rule(scope, id) do
      {:ok, %{kind: "host", target_id: ^target_id, action: action} = rule} ->
        {result, sentence} =
          if action == "allow",
            do:
              {Policy.deny(scope, target, %{host: rule.host}),
               gettext("%{host} is denied for %{target}.", host: rule.host, target: name(socket))},
            else:
              {Policy.allow(scope, target, %{host: rule.host}),
               gettext("%{host} is allowed for %{target}.", host: rule.host, target: name(socket))}

        case result do
          {:ok, written} ->
            socket
            |> Common.wrote(written, sentence, gettext("Rule changed."))
            |> focus_host(rule.host)

          {:error, error} ->
            Common.refused(socket, error)
        end

      _ ->
        load(socket)
    end
  end

  defp event("remove", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Policy.get_rule(scope, id) do
      {:ok, rule} -> remove_host(socket, rule)
      {:error, error} -> Common.refused(socket, error)
    end
  end

  defp event("compare", %{"compare" => compare}, %{assigns: %{v: %{} = v}} = socket) do
    push_patch(socket,
      to: version_path(socket.assigns.base, v, compare: Common.page_param(compare))
    )
  end

  defp event(_event, _params, socket), do: socket

  # The target's setting: following the workspace, or its own mode.
  defp setting(mode), do: mode.own || "follow"

  # The mode a setting puts in force.
  defp becomes("follow", mode), do: mode.workspace
  defp becomes(setting, _mode), do: setting

  # A pick of the mode's choices: what enforce would deny in the target's runs is read
  # when the pick puts enforce in force where it is not, and kept while that holds.
  defp pick_mode(socket, setting) do
    mode = socket.assigns.mode

    would =
      if becomes(setting, mode) == "enforce" and mode.mode != "enforce",
        do:
          socket.assigns.would ||
            Common.would(socket.assigns.current_scope, socket.assigns.holder),
        else: nil

    assign(socket, mode_pick: setting, would: would)
  end

  # The choices close, nothing saved; the focus goes back to Change mode.
  defp close_mode(socket) do
    socket |> assign(mode_pick: nil, would: nil) |> Common.focus("policy-mode-change")
  end

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
        |> Common.focus("policy-mode-change")

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
                 target: name(socket)
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

  # Removing the target's own host rule gives the workspace's rule back where the target's
  # overrode it (the row's act is `restore`), and the toast says so. A rule written
  # elsewhere is changed where it lives: the event changes nothing here.
  defp remove_host(socket, rule) do
    scope = socket.assigns.current_scope
    target = socket.assigns.holder

    with true <- rule.target_id == target.id,
         {:ok, _} <- Policy.remove_rule(scope, rule) do
      restores? = Enum.any?(socket.assigns.rows, &(&1.id == rule.id and &1.act == :restore))

      sentence =
        if restores?,
          do:
            gettext("The workspace's rule for %{host} is restored for %{target}.",
              host: rule.host,
              target: name(socket)
            ),
          else: gettext("The rule %{host} is removed.", host: rule.host)

      socket
      |> Common.wrote(nil, sentence, gettext("Rule removed."))
      |> focus_host(rule.host)
    else
      {:error, error} -> Common.refused(socket, error)
      _ -> load(socket)
    end
  end

  # The target in words, as it is addressed (`Common.holder_name/1`).
  defp name(socket), do: Common.holder_name(socket)

  # After an act on a row, focus stays on the row: its menu, when it is on the page.
  defp focus_host(socket, host) do
    case Enum.find(Common.listing(socket.assigns).rows, &(&1.host == host)) do
      %{id: id} -> Common.focus(socket, "rule-#{id}-menu-button")
      nil -> Common.focus(socket, "policy-rules-add")
    end
  end

  ## Messages

  @doc "handle_info/2 follows the policy: a change reloads the tab, coalesced."
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
      case socket.assigns.action do
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

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Render

  @doc """
  content/1 is the tab's content, under the target's page's header and tabs: what the
  policy of the target is, with the version in force and its export; the tab's own
  views (the effective policy, its history, its document); the view of the action; and
  the export page. Its skeleton until the connected mount has read it.
  """
  def content(%{loaded: false} = assigns) do
    ~H"""
    <div id="policy-page" class="grid gap-3" aria-busy="true">
      <span class="skeleton q-skel w-96 max-w-full"></span>
      <span class="skeleton q-skel w-64"></span>
      <span class="skeleton q-skel mt-4 h-40 w-full"></span>
    </div>
    """
  end

  def content(assigns) do
    assigns = assign(assigns, :target_name, Common.holder_name(%{assigns: assigns}))

    ~H"""
    <div id="policy-page" phx-hook="PolicyPage" class="q-policy grid grid-cols-[minmax(0,1fr)] gap-6">
      <Show.version_head
        :if={@action == :version && @v}
        v={@v}
        base={@base}
        heading="h2"
      />

      <.mode_card
        :if={!(@action in [:version, :export] && @v)}
        level={:target}
        scope={@current_scope}
        mode={@mode.mode}
        setting={setting(@mode)}
        workspace_default={@mode.workspace}
        workspace={@current_scope.workspace.name}
        target={@target_name}
        set={@mode_set}
        can_edit={Common.may?(@current_scope, :"security_policy.set_mode")}
        floor={@mode.floor && %{name: @effective.above.name}}
        pick={@mode_pick}
      >
        <:effect>
          <.target_mode_effect
            :if={@mode_pick}
            setting={@mode_pick}
            becomes={becomes(@mode_pick, @mode)}
            now={@mode.mode}
            name={@target_name}
            workspace={@current_scope.workspace.name}
            default={@mode.workspace}
          />
        </:effect>
        <.target_mode_more
          :if={@mode_pick}
          becomes={becomes(@mode_pick, @mode)}
          now={@mode.mode}
          would={@would}
          locked_denies={@locked_denies}
        />
      </.mode_card>

      <div
        :if={!(@action == :export && @v)}
        class="flex flex-wrap items-center justify-between gap-3"
      >
        <.target_tabs
          action={@action}
          base={@base}
          rules={length(@rows)}
          changes={@change_total}
          document={@version != nil}
        />
        <div :if={@version && !(@action in [:version, :export] && @v)} class="q-head-side">
          <span class="inline-flex items-center gap-2">
            <.version_pill
              id="policy-version-pill"
              version={@version.version}
              digest={@version.digest}
              navigate={
                if @baseline?,
                  do: ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy/history",
                  else: "#{@base}/history"
              }
              copy
            />
            <small :if={@baseline?} id="policy-baseline" class="text-xs text-faint">
              <.term
                word={gettext("workspace's policy")}
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
            <.icon name="hero-arrow-up-tray" class="size-4" />{gettext("Export")}
          </.button>
        </div>
      </div>

      <div id="policy-announce" class="sr-only" role="status" aria-live="polite">{@announce}</div>
      <.keys_panel />

      <.notice :if={@write_error} kind={:error} class="max-w-[80ch]">
        <span id="policy-write-error" role="alert">{@write_error}</span>
      </.notice>

      <.rules_tab :if={@action == :rules} {assigns} />
      <.history_view
        :if={@action == :history && @history}
        history={@history}
        open={@open_change}
        diff={@diff}
        base={@base}
        scope={:target}
        summary={@summary}
        now={@now}
      />
      <.version_view :if={@action == :version && @v} v={@v} base={@base} now={@now} />
      <.export_page
        :if={@action == :export && @v && @export}
        export={@export}
        policy={@base}
        version={@v.configuration.version}
        done={"#{@base}/versions/#{@v.configuration.version}"}
        heading="h2"
      />
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
          {gettext("This target has no versions of its own: it is served %{workspace}'s policy.",
            workspace: @current_scope.workspace.name
          )}
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
    """
  end

  attr :setting, :string, required: true, doc: "the setting picked"
  attr :becomes, :string, required: true, doc: "the mode the pick puts in force"
  attr :now, :string, required: true, doc: "the mode in force now"
  attr :name, :string, required: true
  attr :workspace, :string, required: true, doc: "the workspace's name"
  attr :default, :string, required: true, doc: "the workspace's default"

  # What the picked setting does, the question's sentence (`PolicyComponents.mode_card/1`):
  # from when, and what is denied; or, where the mode in force stays the same, that nothing
  # changes today and what changes from now on.
  defp target_mode_effect(%{becomes: same, now: same} = assigns) do
    ~H"""
    {if @default == "enforce",
      do: gettext("Nothing changes today: %{workspace} enforces too.", workspace: @workspace),
      else: gettext("Nothing changes today: %{workspace} observes too.", workspace: @workspace)}
    {if @setting == "follow",
      do: whose_words("follow", @becomes),
      else:
        gettext("From now on %{target} stays on %{mode} whatever %{workspace}'s mode becomes.",
          target: @name,
          mode: @becomes,
          workspace: @workspace
        )}
    """
  end

  defp target_mode_effect(%{becomes: "enforce"} = assigns) do
    ~H"""
    <.rich text={mode_lead("enforce")} />
    {whose_words(@setting, "enforce")} {gettext("Other targets do not change.")}
    """
  end

  defp target_mode_effect(assigns) do
    ~H"""
    <.rich text={mode_lead("observe")} />
    {whose_words(@setting, "observe")}
    <span :if={@setting != "follow"}>
      {gettext("The workspace's default stays %{mode} and other targets do not change.",
        mode: @default
      )}
    </span>
    """
  end

  attr :becomes, :string, required: true, doc: "the mode the pick puts in force"
  attr :now, :string, required: true, doc: "the mode in force now"
  attr :would, :any, required: true
  attr :locked_denies, :list, required: true

  # What follows the question's sentence: for enforce, what this target's runs were let
  # through in the last 14 days with no rule, each with its Allow here; for observe, the
  # denies that still hold. Nothing where the mode in force stays the same.
  defp target_mode_more(%{becomes: same, now: same} = assigns), do: ~H""

  defp target_mode_more(%{becomes: "enforce"} = assigns) do
    shown = if assigns.would, do: Common.would_shown(assigns.would), else: []
    left = if assigns.would, do: MapSet.size(assigns.would.open), else: 0
    assigns = assign(assigns, shown: shown, left: left)

    ~H"""
    <div :if={@would && @would.destinations != []} id="mode-would" class="q-would">
      <div>
        <span>
          {gettext("Let through in this target's runs, last 14 days, with no rule matching")}
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
              <span class="q-done"><.icon name="hero-check-micro" class="size-3" />{gettext("Allowed")}</span>
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
                id={"would-#{Common.would_key(destination)}-allow"}
                type="button"
                class="btn btn-xs"
                phx-click={JS.push("would_allow", value: %{key: Common.would_key(destination)})}
              >
                {gettext("Allow here")}<span class="sr-only">: {Common.would_name(destination)}</span>
              </button>
          <% end %>
        </li>
      </ul>
      <p :if={length(@would.destinations) > 8} class="q-would-more">
        {ngettext(
          "and %{number} more on the Network access page",
          "and %{number} more on the Network access page",
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
        "Every destination this target's runs reached in the last 14 days is covered by a rule."
      )}
    </p>
    <p :if={@would && @would.destinations != []} class="text-[12.5px]/[18px] text-muted">
      {gettext(
        "Counted from this target's recorded connections that today's rules still do not cover."
      )}
      {gettext("Enforce will deny these.")}
      {gettext("A destination no run has reached yet is not in this list.")}
    </p>
    """
  end

  defp target_mode_more(assigns) do
    ~H"""
    <p class="text-muted">
      {gettext("The rules stay as they are, locked ones too.")}
      <span :if={@locked_denies == []}>{gettext("A deny holds in either mode.")}</span>
      <.rich :if={@locked_denies != []} text={locked_denies_words(@locked_denies)} />
    </p>
    """
  end

  defp whose_words("follow", _mode),
    do: gettext("The mode follows the workspace's default from now on, and changes when it does.")

  defp whose_words(_setting, mode),
    do:
      gettext(
        "The mode becomes this target's own: it stays %{mode} whatever the workspace's default becomes.",
        mode: mode
      )

  # The tab's own views, under the page's tabs: views, not a second bar of tabs.
  attr :action, :atom, required: true
  attr :base, :string, required: true
  attr :rules, :integer, required: true
  attr :changes, :integer, required: true
  attr :document, :boolean, required: true

  defp target_tabs(assigns) do
    ~H"""
    <nav id="policy-tabs" class="q-views" aria-label={gettext("Target policy")}>
      <.link patch={@base} aria-current={@action == :rules && "page"}>
        {gettext("Effective policy")}
        <span :if={@rules > 0} class="q-views-n">{@rules}</span>
      </.link>
      <.link patch={"#{@base}/history"} aria-current={@action == :history && "page"}>
        {gettext("History")}
        <span :if={@changes > 0} class="q-views-n">{@changes}</span>
      </.link>
      <.link
        :if={@document}
        patch={"#{@base}/document"}
        aria-current={@action in [:version, :export] && "page"}
      >
        {gettext("Document")}
      </.link>
    </nav>
    """
  end

  defp rules_tab(assigns) do
    scope = assigns.current_scope
    edit? = Common.may?(scope, :"security_policy.edit")
    activity = Common.async_value(assigns.activity)

    assigns =
      assign(assigns,
        edit?: edit?,
        activity_now: activity,
        listing: Common.listing(assigns),
        workspace: scope.workspace.name,
        target_name: Common.holder_name(%{assigns: assigns})
      )

    ~H"""
    <p :if={@own == [] && is_nil(@mode.own)} class="q-modeline-p max-w-[90ch]">
      <span id="policy-no-own">
        {gettext("This target has no rules of its own.")}
        <span :if={@version}>
          {gettext("It is served %{workspace}'s policy, version %{version}.",
            workspace: @current_scope.workspace.name,
            version: @version.version
          )}
        </span>
        <span :if={!@managed?}>
          {gettext("Runs use each machine's own policy until the first change in this workspace.")}
        </span>
        {gettext(
          "The first rule added here, or a mode of its own, gives it a policy of its own, numbered from version 1."
        )}
      </span>
    </p>

    <.suggestions
      id="policy-suggestions"
      suggestions={@suggestions}
      covered={@covered}
      allowed={@allowed}
      above={@effective.above && @effective.above.name}
    />

    <section id="policy-hosts" class="q-psec" aria-labelledby="policy-hosts-h">
      <div class="q-psec-h">
        <h2 id="policy-hosts-h">{gettext("Network access")}</h2>
        <span class="grow"></span>
        <.link
          id="policy-hosts-network"
          navigate={@network}
          class="q-sect-link"
        >
          {gettext("See what its runs reached")}<.icon
            name="hero-arrow-right-micro"
            class="size-3.5"
          />
        </.link>
      </div>
      <.rule_list
        id="policy-rules"
        label={gettext("Network access rules in force for %{target}", target: @target_name)}
        listing={@listing}
        query={@list_query}
        path={&Common.list_path(@base, &1)}
        sections={RuleList.sections(@rows, @activity_now)}
        default_sort={gettext("Its own first")}
        activity={@activity_now}
        source
        can_add={@edit?}
        adding={@composer_open}
        fresh={@fresh}
        ruled_host={@ruled_host}
        empty={gettext("No rule is in force for this target yet.")}
      >
        <:composer>
          <.rule_composer
            :if={@composer_open && @edit?}
            id="policy-composer"
            class="q-composer-line"
            form={@composer}
            scope={:target}
            reading={@reading}
            queued={length(@queue)}
            host_placeholder="mcp.acme.example"
          />
        </:composer>
      </.rule_list>
      <p id="policy-hosts-note" class="q-psec-note">
        {if @effective.above,
          do:
            gettext(
              "Its own rules come first; %{name}'s and %{workspace}'s follow and are changed where they live. %{name}'s rules hold in every workspace and target, in either mode.",
              name: @effective.above.name,
              workspace: @workspace
            ),
          else:
            gettext(
              "Its own rules come first and are changed here; %{workspace}'s follow and are changed on %{workspace}'s policy page. %{workspace}'s locked rules hold in every target, in either mode.",
              workspace: @workspace
            )}
      </p>
    </section>
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
end
