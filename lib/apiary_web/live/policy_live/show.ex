defmodule ApiaryWeb.PolicyLive.Show do
  @moduledoc """
  The hive's security policy (`docs/design/brief-policy.md`, pe1, pe2, pe4, pe5): the mode
  with its two confirms, the host rules with the composer that reads a rule back before it
  is saved, the credentials, the targets and their policy, the history with diffs,
  one version with its document, and the export.

  One LiveView, five live actions, so a tab is a patch. Filters, the opened change, the
  compared version and the export modal are in the URL. The page calls `Apiary.Policy`
  and nothing under it, except the contract's grammar for the reading line. It follows
  `policy:<hive>` and reads again at most once per 250 ms.

  A hive nobody has changed yet is not served a policy by Qory: its machines use their
  own until the first change here, and the page says so.
  """
  use ApiaryWeb, :live_view

  import ApiaryWeb.PolicyComponents
  import ApiaryWeb.PolicyLive.Views

  alias Apiary.Policy
  alias Apiary.Policy.Grammar
  alias ApiaryWeb.PolicyLive.Common

  @shows ~w(allow deny locked)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> Common.mount(nil)
      |> assign(reload: &load/1, show: nil, ruled_host: nil, targets: nil)
      |> assign(history: nil, open_change: nil, diff: nil, v: nil, export: nil, missing: nil)
      |> assign(would: nil, composer_open: false, own_only: false, params: %{})
      |> assign(target_list: [], summary: nil)
      |> assign(:target_details, Phoenix.LiveView.AsyncResult.loading())
      |> assign(:target_suggestions, Phoenix.LiveView.AsyncResult.loading())

    # The page is read once, by the connected mount: the first render is its skeleton.
    socket =
      if connected?(socket),
        do: socket |> load() |> assign(:loaded, true),
        else: assign(socket, loaded: false, page_title: gettext("Policy"))

    {:ok, socket}
  end

  # Everything the rules tab and the page head show, read again after a write and on a
  # change from elsewhere.
  defp load(socket) do
    scope = socket.assigns.current_scope
    managed? = Policy.managed?(scope)
    own = Policy.list_rules(scope, nil)
    changes = Policy.list_changes(scope, nil, 1)
    locks = Common.locks(changes)
    targets = Policy.list_targets(scope)

    version =
      case Common.served_version(scope, nil, managed?) do
        {configuration, _own?} -> configuration
        nil -> nil
      end

    socket
    |> assign(
      managed?: managed?,
      mode: Policy.get_mode(scope),
      own: own,
      effective: Policy.effective(scope, nil),
      locks: locks,
      version: version,
      change_total: changes.total,
      target_list: targets,
      target_total: length(targets),
      following: Enum.count(targets, &is_nil(&1.own_mode)),
      own_modes: for(%{own_mode: mode} <- targets, mode != nil, do: mode),
      reload_pending: false,
      now: DateTime.utc_now()
    )
    |> then(fn socket ->
      assign(socket,
        rows: Common.hive_rows(own, socket, locks),
        credentials: Common.credential_rows(own, socket)
      )
    end)
    |> load_record()
  end

  # What the recorded connections say: the mode card's fact and the Last 7 days column.
  # Bounded reads that may answer :unavailable; then the fact and the column are left out.
  defp load_record(socket) do
    if connected?(socket) do
      scope = socket.assigns.current_scope
      mode = socket.assigns.mode

      socket
      |> assign_async(:activity, fn ->
        {:ok, %{activity: unwrap(Policy.rule_activity(scope, nil, Common.since()))}}
      end)
      |> assign_async(:fact, fn -> {:ok, %{fact: fact(scope, mode)}} end)
    else
      socket
      |> assign(:activity, Phoenix.LiveView.AsyncResult.loading())
      |> assign(:fact, Phoenix.LiveView.AsyncResult.loading())
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(_unavailable), do: :unavailable

  defp fact(scope, "enforce") do
    case Policy.denied_summary(scope, Common.since()) do
      {:ok, %{denied: 0}} ->
        :none

      {:ok, %{denied: denied, destinations: destinations}} ->
        %{denied: denied, destinations: destinations}

      _ ->
        nil
    end
  end

  defp fact(scope, _observe) do
    case Policy.uncovered(scope, Common.since()) do
      {:ok, []} ->
        :none

      {:ok, destinations} ->
        %{
          uncovered: destinations |> Enum.map(& &1.attempts) |> Enum.sum(),
          destinations: length(destinations)
        }

      _ ->
        nil
    end
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{loaded: false}} = socket), do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    socket = assign(socket, missing: nil, export: nil, params: params, now: DateTime.utc_now())
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :rules, params) do
    show = if params["show"] in @shows, do: params["show"]
    ruled_host = Common.rule_param(params["rule"])

    socket
    |> assign(show: show, ruled_host: ruled_host, page_title: gettext("Policy"))
    |> then(&if(ruled_host, do: push_event(&1, "policy:rule", %{host: ruled_host}), else: &1))
    |> then(&if(params["confirm"] == "enforce", do: confirm_enforce(&1), else: &1))
  end

  defp apply_action(socket, :targets, params) do
    socket
    |> assign(page_title: gettext("Targets · Policy"), own_only: params["mode"] == "own")
    |> load_targets(:all)
  end

  defp apply_action(socket, :history, params) do
    socket = assign(socket, :page_title, gettext("History · Policy"))
    history = Common.history(socket, Common.page_param(params["page"]))

    {open, diff} =
      case params["change"] && Common.change_diff(socket, params["change"]) do
        {:ok, diff} -> {diff.id, diff}
        _ -> {nil, nil}
      end

    assign(socket, history: history, open_change: open, diff: diff, summary: summary(socket))
  end

  defp apply_action(socket, :document, _params) do
    case socket.assigns.version do
      %{version: n} -> push_navigate(socket, to: ~p"/hive/policy/versions/#{n}", replace: true)
      _ -> push_navigate(socket, to: ~p"/hive/policy", replace: true)
    end
  end

  defp apply_action(socket, action, %{"n" => n} = params) when action in [:version, :export] do
    case Common.version(socket, n, params) do
      {:ok, v} ->
        socket =
          assign(socket,
            v: v,
            page_title: gettext("Version %{version} · Policy", version: v.configuration.version)
          )

        cond do
          action == :export and v.current? ->
            assign(socket, :export, Common.export(socket, v.configuration))

          action == :export ->
            push_patch(socket, to: ~p"/hive/policy/versions/#{v.latest}/export", replace: true)

          true ->
            socket
        end

      :error ->
        assign(socket,
          v: nil,
          missing: %{n: n, latest: socket.assigns.version},
          page_title: gettext("Policy")
        )
    end
  end

  # The versions count from 1 without a gap, so the newest one's number is how many.
  defp summary(socket) do
    since =
      case socket.assigns.version &&
             Policy.get_configuration(socket.assigns.current_scope, nil, 1) do
        {:ok, first} -> first.rendered_at
        _ -> nil
      end

    %{versions: (socket.assigns.version && socket.assigns.version.version) || 0, since: since}
  end

  # The targets tab. The list is the one read `load/1` made. What costs a read per
  # target is read off the render, in two tasks, for the first fifty (the ones with
  # rules or a mode of their own first): the overrides and the version served, and the
  # suggestions, which read events. A change that names one target re-reads that
  # target alone.
  @detailed 50
  defp load_targets(socket, :all) do
    scope = socket.assigns.current_scope
    managed? = socket.assigns.managed?
    detailed = detailed(socket.assigns.target_list)

    socket
    |> assign_async(:target_details, fn ->
      {:ok, %{target_details: details(scope, detailed, managed?)}}
    end)
    |> assign_async(:target_suggestions, fn ->
      {:ok,
       %{
         target_suggestions:
           Map.new(
             detailed,
             &{&1.target.id, length(Policy.suggestions(scope, &1.target))}
           )
       }}
    end)
  end

  defp load_targets(socket, %MapSet{} = ids) do
    %{target_details: details, target_suggestions: suggestions} = socket.assigns

    if details.ok? and suggestions.ok? do
      scope = socket.assigns.current_scope
      rows = Enum.filter(detailed(socket.assigns.target_list), &(&1.target.id in ids))

      socket
      |> assign(
        :target_details,
        Phoenix.LiveView.AsyncResult.ok(
          details,
          Map.merge(details.result, details(scope, rows, socket.assigns.managed?))
        )
      )
      |> assign(
        :target_suggestions,
        Phoenix.LiveView.AsyncResult.ok(
          suggestions,
          Enum.reduce(rows, suggestions.result, fn row, map ->
            Map.put(map, row.target.id, length(Policy.suggestions(scope, row.target)))
          end)
        )
      )
    else
      load_targets(socket, :all)
    end
  end

  defp detailed(list) do
    list |> Enum.sort_by(&(&1.rule_count == 0 and is_nil(&1.own_mode))) |> Enum.take(@detailed)
  end

  # Two reads for all of them, the versions and the last changes, and the effective
  # policy of each target that has rules, for its overrides.
  defp details(scope, rows, managed?) do
    targets = Enum.map(rows, & &1.target)
    versions = if managed?, do: Policy.newest_versions(scope, [nil | targets]), else: %{}
    changes = Policy.last_changes(scope, targets)

    Map.new(rows, fn %{target: target, rule_count: count} ->
      overrides =
        if count > 0 do
          Enum.count(
            Policy.effective(scope, target).entries,
            &(&1.source == :target and &1.in_force and &1.overrides != [])
          )
        else
          0
        end

      {target.id,
       %{
         overrides: overrides,
         version: versions[target.id] || versions[nil],
         changed: changes[target.id] && changes[target.id].inserted_at
       }}
    end)
  end

  defp target_rows(list, details, suggestions) do
    details = if details.ok?, do: details.result
    suggestions = if suggestions.ok?, do: suggestions.result

    list
    |> Enum.map(fn %{target: target} = row ->
      detail = details && details[target.id]

      %{
        id: target.id,
        system: target.system,
        path: target.path,
        own: row.rule_count,
        mode: row.mode,
        own_mode: row.own_mode,
        detail: if(details, do: detail || :none, else: :loading),
        suggestions: if(suggestions, do: Map.get(suggestions, target.id, :none), else: :loading),
        changed: detail && detail.changed
      }
    end)
    |> Enum.sort_by(fn row ->
      {-if(is_integer(row.suggestions), do: row.suggestions, else: 0),
       -((row.changed && DateTime.to_unix(row.changed)) || 0), row.system, row.path}
    end)
  end

  ## Events

  # `?confirm=enforce` (the overview's one-click nudge, brief-overview ol 3) lands with the
  # enforce confirm open, as if Enforce had been chosen, and only for an owner of a hive
  # that observes; the parameter is dropped from the address at once, so a reload or a
  # shared link does not ask again. Any other value of `confirm` is ignored.
  defp confirm_enforce(socket) do
    # The address is cleaned once the page is up: a patch from the connected mount's own
    # `handle_params` would be part of the join.
    send(self(), :drop_confirm)

    if socket.assigns.owner? and socket.assigns.mode != "enforce",
      do: event("mode_ask", %{"mode" => "enforce"}, socket),
      else: socket
  end

  @impl true
  def handle_event(event, params, socket) do
    case Common.handle_event(event, params, socket) do
      {:halt, socket} -> {:noreply, socket}
      :cont -> {:noreply, event(event, params, socket)}
    end
  end

  defp event("composer_open", _params, socket) do
    socket |> assign(:composer_open, true) |> Common.focus("policy-composer-host")
  end

  defp event("mode_ask", %{"mode" => mode}, socket) when mode in ~w(observe enforce) do
    cond do
      not socket.assigns.owner? ->
        assign(socket, :write_error, gettext("Only an owner sets a mode."))

      mode == socket.assigns.mode ->
        socket

      mode == "enforce" ->
        assign(socket,
          dialog: {:mode, "enforce"},
          would: Common.would(socket.assigns.current_scope, nil)
        )

      true ->
        assign(socket, dialog: {:mode, "observe"}, would: nil)
    end
  end

  defp event("mode_confirm", _params, %{assigns: %{dialog: {:mode, mode}}} = socket) do
    case Policy.set_mode(socket.assigns.current_scope, mode) do
      {:ok, mode} ->
        socket
        |> assign(:dialog, nil)
        |> then(fn socket ->
          following = socket.assigns.following
          default = default_sentence(mode)

          Common.wrote(
            socket,
            nil,
            default <>
              " " <>
              ngettext(
                "%{count} target follows it.",
                "%{count} targets follow it.",
                following
              ),
            default
          )
        end)
        |> Common.focus("policy-mode-#{mode}")

      {:error, error} ->
        socket |> assign(:dialog, nil) |> Common.refused(error)
    end
  end

  defp event("would_allow", %{"key" => key}, %{assigns: %{would: %{} = would}} = socket) do
    scope = socket.assigns.current_scope

    case Enum.find(would.destinations, &(would_key(&1) == key)) do
      nil ->
        socket

      destination ->
        result =
          if destination.path,
            do: Policy.allow_path(scope, nil, destination.host, destination.path),
            else: Policy.allow(scope, nil, %{host: destination.host})

        case result do
          {:ok, _rule} ->
            socket
            |> load()
            |> assign(:would, Common.would(scope, nil, would))
            |> assign(
              :announce,
              gettext("%{host} is allowed for the hive.", host: destination.host)
            )

          {:error, error} ->
            assign(socket, :would, Map.put(would, :error, error.message))
        end
    end
  end

  defp event("lock_toggle", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with true <- socket.assigns.owner?,
         {:ok, rule} <- Policy.get_rule(scope, id),
         true <- is_nil(rule.target_id) do
      held = if rule.locked, do: [], else: held_by_lock(scope, rule)

      if held == [] do
        set_lock(socket, rule, !rule.locked)
      else
        assign(socket, :dialog, {:lock, rule, held})
      end
    else
      false ->
        assign(
          socket,
          :write_error,
          gettext("Only an owner can lock, unlock or change a locked rule.")
        )

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  # A confirm acts on the rule as it is now, not as it was when the dialog opened: one
  # that is gone, or is not what the dialog named any more, is refused and the list re-read.
  defp event("lock_confirm", _params, %{assigns: %{dialog: {:lock, rule, _held}}} = socket) do
    socket = assign(socket, :dialog, nil)

    case fresh(socket, rule) do
      {:ok, %{locked: false} = rule} -> set_lock(socket, rule, true)
      {:ok, _locked_already} -> load(socket)
      {:error, error} -> Common.refused(socket, error)
    end
  end

  defp event("edit_paths", %{"id" => id}, socket) do
    case Policy.get_rule(socket.assigns.current_scope, id) do
      {:ok, %{kind: "host", target_id: nil} = rule} ->
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

  # The other action for the same host: the domain replaces the rule, as the composer's
  # "Replace with deny" does, and the toast names the version it made.
  defp event("change_action", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Policy.get_rule(scope, id) do
      {:ok, %{kind: "host", target_id: nil, action: "allow"} = rule} ->
        changed(socket, Policy.deny(scope, nil, %{host: rule.host}), rule.host, "deny")

      {:ok, %{kind: "host", target_id: nil, action: "deny"} = rule} ->
        changed(socket, Policy.allow(scope, nil, %{host: rule.host}), rule.host, "allow")

      _ ->
        load(socket)
    end
  end

  defp event("remove", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Policy.get_rule(scope, id) do
      {:ok, %{target_id: nil, kind: "host"} = rule} ->
        overriders = overriders(scope, rule)

        if overriders != [] or rule.locked,
          do: assign(socket, :dialog, {:remove, rule, overriders}),
          else: remove(socket, rule)

      {:ok, %{target_id: nil} = rule} ->
        remove(socket, rule)

      _ ->
        load(socket)
    end
  end

  defp event("remove_confirm", _params, %{assigns: %{dialog: {:remove, rule, _}}} = socket) do
    socket = assign(socket, :dialog, nil)

    case fresh(socket, rule) do
      {:ok, rule} -> remove(socket, rule)
      {:error, error} -> Common.refused(socket, error)
    end
  end

  defp event("compare", %{"compare" => compare}, %{assigns: %{v: %{} = v}} = socket) do
    push_patch(socket,
      to: version_path(socket.assigns.base, v, compare: Common.page_param(compare))
    )
  end

  defp event(_event, _params, socket), do: socket

  defp fresh(socket, %{id: id, action: action, host: host}) do
    case Policy.get_rule(socket.assigns.current_scope, id) do
      {:ok, %{action: ^action, host: ^host, target_id: nil} = rule} ->
        {:ok, rule}

      {:ok, _changed} ->
        {:error,
         %Policy.Error{
           reason: :conflict,
           message:
             gettext(
               "The rule for %{host} changed while you were deciding. The list below is current.",
               host: host
             )
         }}

      {:error, _gone} ->
        {:error,
         %Policy.Error{
           reason: :not_found,
           message:
             gettext(
               "The rule for %{host} was removed while you were deciding. The list below is current.",
               host: host
             )
         }}
    end
  end

  defp set_lock(socket, rule, locked) do
    scope = socket.assigns.current_scope
    result = if locked, do: Policy.lock(scope, rule), else: Policy.unlock(scope, rule)

    case result do
      {:ok, rule} ->
        sentence =
          if locked,
            do: gettext("%{rule} is locked. No target can override it.", rule: subject(rule)),
            else:
              gettext("%{rule} is unlocked. A target can override it again.", rule: subject(rule))

        announce = if locked, do: gettext("Rule locked."), else: gettext("Rule unlocked.")

        socket
        |> Common.wrote(nil, sentence, announce)
        |> Common.focus("rule-#{rule.id}-lock")

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  # The page is the hive's: the rule is the hive's, never a target's.
  defp changed(socket, {:ok, rule}, host, action) do
    sentence =
      if action == "deny",
        do: gettext("%{host} is denied for the hive.", host: host),
        else: gettext("%{host} is allowed for the hive.", host: host)

    Common.wrote(socket, rule, sentence, gettext("Rule changed."))
  end

  defp changed(socket, {:error, error}, _host, _action), do: Common.refused(socket, error)

  defp remove(socket, rule) do
    rows = socket.assigns.rows
    index = Enum.find_index(rows, &(&1.id == rule.id))
    next = index && (Enum.at(rows, index + 1) || (index > 0 && Enum.at(rows, index - 1)))

    case Policy.remove_rule(socket.assigns.current_scope, rule) do
      {:ok, rule} ->
        words =
          if rule.kind == "credential",
            do: gettext("The credential %{name} is removed.", name: rule.name),
            else: gettext("The rule %{host} is removed.", host: rule.host)

        socket
        |> Common.wrote(nil, words, gettext("Rule removed."))
        |> Common.focus(if(next, do: "rule-#{next.id}-menu-button", else: "policy-composer-host"))

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  defp subject(%{kind: "credential", name: name}), do: name
  defp subject(%{host: host}), do: host

  defp default_sentence("enforce"), do: gettext("The hive's default is enforce.")
  defp default_sentence(_observe), do: gettext("The hive's default is observe.")

  # The targets' own rules a lock of this rule would put out of force: a rule on the
  # same host, or an allow below a locked `*.` deny. Read for the targets that have
  # rules of their own, at most fifty of them.
  defp held_by_lock(scope, rule) do
    for {target, own} <- target_rules(scope),
        other <- own,
        other.kind == "host",
        other.host == rule.host or
          (rule.action == "deny" and other.action == "allow" and
             Grammar.covers?(rule.host, other.host)),
        do: %{target: target, rule: other}
  end

  defp overriders(scope, rule) do
    for {target, own} <- target_rules(scope),
        other <- own,
        other.kind == "host" and other.host == rule.host,
        do: %{target: target, rule: other}
  end

  defp target_rules(scope) do
    for %{target: target, rule_count: count} <- Policy.list_targets(scope),
        count > 0 do
      target
    end
    |> Enum.take(50)
    |> Enum.map(&{&1, Policy.list_rules(scope, &1)})
  end

  ## Messages

  @impl true
  def handle_info({:policy_changed, change}, socket),
    do: {:noreply, Common.schedule_reload(socket, change)}

  # `?confirm=enforce` did its work in `handle_params`; the address says the page alone.
  def handle_info(:drop_confirm, socket), do: {:noreply, push_patch(socket, to: ~p"/hive/policy")}

  def handle_info(:policy_reload, socket) do
    touched = socket.assigns.touched
    socket = socket |> load() |> assign(:touched, MapSet.new())

    # What the URL shows is read again too: a version that was in force a moment ago may
    # be superseded now, a history may have a change more.
    socket =
      case socket.assigns.live_action do
        :targets -> load_targets(socket, touched)
        action when action in [:history, :version, :export] -> reapply(socket, action)
        _ -> socket
      end

    socket =
      if socket.assigns.composer_params["host"] != "", do: Common.read(socket, %{}), else: socket

    {:noreply, socket}
  end

  defp reapply(socket, :history), do: apply_action(socket, :history, socket.assigns.params)

  defp reapply(socket, action) do
    case Common.version(socket, socket.assigns.params["n"], socket.assigns.params) do
      {:ok, v} ->
        export = if action == :export and v.current?, do: Common.export(socket, v.configuration)
        assign(socket, v: v, export: export || socket.assigns.export)

      :error ->
        socket
    end
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
      <.page_skeleton title={gettext("Policy")} />
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
        <div :if={@live_action in [:version, :export] && @v} class="grid gap-3">
          <nav class="q-crumbs" aria-label={gettext("Breadcrumb")}>
            <.link navigate={~p"/hive/policy"}>{gettext("Policy")}</.link>
            <.icon name="hero-chevron-right-micro" class="size-3" />
            <span class="q-here" aria-current="page">
              {gettext("Version %{version}", version: @v.configuration.version)}
            </span>
          </nav>
          <.version_head v={@v} base={@base} />
        </div>

        <.header :if={!(@live_action in [:version, :export] && @v)}>
          {gettext("Policy")}
          <:subtitle>
            {gettext("What the runs of this hive may reach through the runner's proxy.")}
            {gettext(
              "What no rule names is denied under enforce, and let through and recorded under observe; a deny rule holds in either mode."
            )}
          </:subtitle>
          <:actions>
            <div :if={@managed? && @version} class="q-head-side">
              <.version_pill
                id="policy-version-pill"
                version={@version.version}
                digest={@version.digest}
                navigate={~p"/hive/policy/history"}
                copy
              />
              <.button
                id="policy-export-button"
                navigate={~p"/hive/policy/versions/#{@version.version}/export"}
              >
                <.icon name="hero-arrow-up-tray-micro" class="size-4" />{gettext("Export")}
              </.button>
            </div>
            <div :if={!(@managed? && @version)} class="q-head-side">
              <.version_pill id="policy-version-pill" />
              <.tooltip
                tip={gettext("Nothing to export yet: the first change here renders version 1.")}
                placement="left"
                class="q-tip-wide"
              >
                <.button id="policy-export-button" disabled aria-disabled="true">
                  <.icon name="hero-arrow-up-tray-micro" class="size-4" />{gettext("Export")}
                </.button>
              </.tooltip>
            </div>
          </:actions>
        </.header>

        <.policy_tabs
          live_action={@live_action}
          rules={length(@own)}
          targets={@target_total}
          changes={@change_total}
          document={@managed? && @version != nil}
        />

        <div id="policy-announce" class="sr-only" role="status" aria-live="polite">{@announce}</div>

        <.notice :if={@write_error} kind={:error} class="max-w-[80ch]">
          <span id="policy-write-error" role="alert">{@write_error}</span>
        </.notice>

        <.rules_tab :if={@live_action == :rules} {assigns} />
        <.targets_tab
          :if={@live_action == :targets}
          rows={target_rows(@target_list, @target_details, @target_suggestions)}
          own_only={@own_only}
        />
        <.history_view
          :if={@live_action == :history && @history}
          history={@history}
          open={@open_change}
          diff={@diff}
          base={@base}
          scope={:hive}
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
          <span :if={!@missing.latest}>{gettext("This hive has no version yet.")}</span>
          <:actions>
            <.button
              :if={@missing.latest}
              navigate={~p"/hive/policy/versions/#{@missing.latest.version}"}
            >
              {gettext("Open version %{version}", version: @missing.latest.version)}
            </.button>
            <.button :if={!@missing.latest} navigate={~p"/hive/policy"}>
              {gettext("Back to policy")}
            </.button>
          </:actions>
        </.empty_state>
      </div>

      <.keys_dialog />
      <.export_modal
        :if={@live_action == :export && @export}
        export={@export}
        close={~p"/hive/policy/versions/#{@v.configuration.version}"}
      />
      <.mode_dialog
        :if={match?({:mode, _}, @dialog)}
        mode={elem(@dialog, 1)}
        would={@would}
        alive={if @own_modes == [], do: (@nav_counts && @nav_counts[:alive]) || 0, else: 0}
        started={@managed?}
        following={@following}
        own={length(@own_modes)}
      />
      <.lock_dialog
        :if={match?({:lock, _, _}, @dialog)}
        rule={elem(@dialog, 1)}
        held={elem(@dialog, 2)}
      />
      <.remove_dialog
        :if={match?({:remove, _, _}, @dialog)}
        rule={elem(@dialog, 1)}
        overriders={elem(@dialog, 2)}
      />
    </Layouts.app>
    """
  end

  attr :v, :map, required: true
  attr :base, :string, required: true

  def version_head(assigns) do
    ~H"""
    <header class="flex flex-wrap items-start justify-between gap-4">
      <div class="q-run-title">
        <h1 class="text-xl/7 font-semibold tracking-[-0.017em]">
          {gettext("Version %{version}", version: @v.configuration.version)}
        </h1>
        <.badge :if={@v.current?} color="success">
          <.icon name="hero-check-micro" class="size-3" />{gettext("In force")}
        </.badge>
        <.badge :if={!@v.current?}>{gettext("Superseded")}</.badge>
        <span :if={@v.superseded_by} id="version-superseded" class="text-[13px] text-muted">
          <%= for part <- superseded_words(@v) do %>
            <.version_link
              :if={part == :version}
              version={@v.superseded_by.version}
              navigate={"#{@base}/versions/#{@v.superseded_by.version}"}
            />{if part != :version, do: part}
          <% end %>
        </span>
      </div>
      <div class="q-head-side">
        <.button id="version-export" patch={"#{@base}/versions/#{@v.latest}/export"}>
          <.icon name="hero-arrow-up-tray-micro" class="size-4" />{if @v.current?,
            do: gettext("Export"),
            else: gettext("Export the version in force")}
        </.button>
      </div>
    </header>
    """
  end

  # "by v3 after 2 h", with the version a link: the sentence split at its bindings.
  defp superseded_words(v) do
    rich_gettext("by %{version} after %{time}",
      version: :version,
      time:
        format_seconds(
          max(DateTime.diff(v.superseded_by.rendered_at, v.configuration.rendered_at), 0)
        )
    )
  end

  attr :live_action, :atom, required: true
  attr :rules, :integer, required: true
  attr :targets, :integer, required: true
  attr :changes, :integer, required: true
  attr :document, :boolean, required: true

  defp policy_tabs(assigns) do
    ~H"""
    <.tabs id="policy-tabs" label={gettext("Policy")}>
      <:tab
        patch={~p"/hive/policy"}
        icon="hero-shield-check-micro"
        current={@live_action == :rules}
        count={@rules > 0 && @rules}
      >
        {gettext("Rules")}
      </:tab>
      <:tab
        patch={~p"/hive/policy/targets"}
        icon="hero-book-open-micro"
        current={@live_action == :targets}
        count={@targets > 0 && @targets}
      >
        {gettext("Targets")}
      </:tab>
      <:tab
        patch={~p"/hive/policy/history"}
        icon="hero-clock-micro"
        current={@live_action == :history}
        count={@changes > 0 && @changes}
      >
        {gettext("History")}
      </:tab>
      <:tab
        :if={@document}
        patch={~p"/hive/policy/document"}
        icon="hero-document-text-micro"
        current={@live_action in [:version, :export, :document]}
      >
        {gettext("Document")}
      </:tab>
    </.tabs>
    """
  end

  defp rules_tab(assigns) do
    hosts = assigns.rows

    shown =
      case assigns.show do
        "allow" -> Enum.filter(hosts, &(&1.action == "allow"))
        "deny" -> Enum.filter(hosts, &(&1.action == "deny"))
        "locked" -> Enum.filter(hosts, & &1.locked)
        nil -> hosts
      end

    assigns =
      assigns
      |> assign(:shown, shown)
      |> assign(:empty?, assigns.own == [] and not assigns.composer_open)
      |> assign(:counts, %{
        allow: Enum.count(hosts, &(&1.action == "allow")),
        deny: Enum.count(hosts, &(&1.action == "deny")),
        locked: Enum.count(hosts, & &1.locked)
      })

    ~H"""
    <.mode_switch
      mode={@mode}
      can_edit={@owner?}
      served={@managed?}
      following={@following}
      own={@own_modes}
      fact={with :unavailable <- async_value(@fact, :loading), do: nil}
    />

    <div :if={@empty?} id="policy-empty" class="grid gap-4">
      <.empty_state
        icon="hero-shield-check"
        title={if @managed?, do: gettext("No rules yet"), else: gettext("Qory serves no policy yet")}
      >
        <span :if={!@managed?} id="policy-unmanaged">
          {gettext(
            "Until the first change here, every machine of this hive runs under its own policy, the one in its runner file. The first rule you add, or a mode you set, renders version 1, and machines take their policy from Qory from then on. You can also let a run reach out first and allow its hosts from the Connections page, one row at a time."
          )}
        </span>
        <span :if={@managed?}>
          {if @mode == "observe",
            do: gettext("With no rules, runs reach everything and every connection is recorded."),
            else: gettext("With no rules, a run under enforce reaches nothing.")}
          {gettext(
            "Add the hosts your runs need here, or let a run reach out first and allow its hosts from the Connections page, one row at a time."
          )}
        </span>
        <:actions>
          <.button id="policy-first-rule" variant="primary" phx-click="composer_open">
            <.icon name="hero-plus-micro" class="size-4" />{gettext("Add a host rule")}
          </.button>
          <.button navigate={~p"/hive/connections"}>{gettext("Go to connections")}</.button>
        </:actions>
      </.empty_state>
      <p
        :if={!@managed?}
        id="policy-first-version"
        class="max-w-[80ch] text-[12.5px]/[18px] text-faint"
      >
        {gettext(
          "Version 1 is rendered by the first change, never by a machine asking. Until it exists, a machine that asks is told there is no policy here and keeps its own."
        )}
      </p>
      <p
        :if={@managed? && @version}
        id="policy-first-version"
        class="max-w-[80ch] text-[12.5px]/[18px] text-faint"
      >
        {gettext(
          "Version %{version} is what machines are served now: the mode, with nothing allowed. A rule added here renders the next one.",
          version: @version.version
        )}
      </p>
    </div>

    <.sect :if={!@empty?} id="policy-hosts" title={gettext("Host rules")} count={length(@rows)}>
      <:trailing>
        <.segments id="policy-show" label={gettext("Show")}>
          <:segment patch={~p"/hive/policy"} pressed={@show == nil}>{gettext("All")}</:segment>
          <:segment
            patch={~p"/hive/policy?show=allow"}
            pressed={@show == "allow"}
            count={@counts.allow}
          >
            {gettext("Allow")}
          </:segment>
          <:segment patch={~p"/hive/policy?show=deny"} pressed={@show == "deny"} count={@counts.deny}>
            {gettext("Deny")}
          </:segment>
          <:segment
            patch={~p"/hive/policy?show=locked"}
            pressed={@show == "locked"}
            count={@counts.locked}
          >
            {gettext("Locked")}
          </:segment>
        </.segments>
      </:trailing>
      <.rule_composer
        id="policy-composer"
        form={@composer}
        scope={:hive}
        reading={@reading}
        queued={length(@queue)}
      />
      <.rules_table
        id="policy-rules"
        label={gettext("Host rules of the hive")}
        rows={@shown}
        scope={:hive}
        can_lock={@owner?}
        activity={async_value(@activity, :loading)}
        fresh={@fresh}
        ruled_host={@ruled_host}
        empty={empty_words(@show, @rows)}
      />
      <:footer>
        {gettext(
          "Locked rules come first, then deny, then allow, each by host read from the right, so a suffix sits beside the hosts below it. A deny is written to the document's deny list, which a runner decides first and in either mode, and takes the allowed hosts it covers out of its allow list."
        )}
      </:footer>
    </.sect>

    <.sect
      :if={!@empty?}
      id="policy-credentials"
      title={gettext("Credentials")}
      count={length(@credentials)}
    >
      <:description>
        {gettext(
          "Credentials a run may use, by name. The policy names one; it never holds one. Each machine defines its credentials in its runner file, and a name a machine does not define is no run."
        )}
      </:description>
      <.credential_composer id="policy-credential" form={@credential} reading={@credential_reading} />
      <.credentials_table
        id="policy-credential-rows"
        label={gettext("Credentials of the hive")}
        rows={@credentials}
        scope={:hive}
        activity={async_value(@activity, :loading)}
      />
    </.sect>
    """
  end

  defp empty_words(_show, []), do: gettext("No host rules yet. Add the first above.")
  defp empty_words("locked", _rows), do: gettext("No locked rules.")
  defp empty_words("deny", _rows), do: gettext("No deny rules.")
  defp empty_words("allow", _rows), do: gettext("No allow rules.")
  defp empty_words(_show, _rows), do: nil

  defp async_value(%Phoenix.LiveView.AsyncResult{ok?: true, result: result}, _loading), do: result
  defp async_value(%Phoenix.LiveView.AsyncResult{loading: nil}, _loading), do: :unavailable
  defp async_value(_async, loading), do: loading

  attr :rows, :any, required: true
  attr :own_only, :boolean, default: false

  defp targets_tab(%{rows: []} = assigns) do
    ~H"""
    <.empty_state tone="neutral" icon="hero-book-open" title={gettext("No targets yet")}>
      {gettext("A target appears here once a run names it with its system and target labels.")}
    </.empty_state>
    """
  end

  defp targets_tab(assigns) do
    assigns =
      assign(
        assigns,
        :shown,
        if(assigns.own_only, do: Enum.filter(assigns.rows, & &1.own_mode), else: assigns.rows)
      )

    ~H"""
    <div id="policy-targets" class="grid grid-cols-[minmax(0,1fr)] gap-6">
      <div id="targets-summary" class="q-summary">
        <span>
          <.rich text={
            rich_ngettext(
              "%{number} target has posted runs",
              "%{number} targets have posted runs",
              length(@rows),
              number: {:b, to_string(length(@rows))}
            )
          } />
        </span>
        <span>
          <.rich text={
            rich_ngettext(
              "%{number} with rules of their own",
              "%{number} with rules of their own",
              Enum.count(@rows, &(&1.own > 0)),
              number: {:b, to_string(Enum.count(@rows, &(&1.own > 0)))}
            )
          } />
        </span>
        <span>
          <.rich text={
            rich_ngettext(
              "%{number} sets its own mode",
              "%{number} set their own mode",
              Enum.count(@rows, & &1.own_mode),
              number: {:b, to_string(Enum.count(@rows, & &1.own_mode))}
            )
          } />
        </span>
        <span>
          <.rich text={
            rich_ngettext(
              "%{number} with suggestions",
              "%{number} with suggestions",
              Enum.count(@rows, &suggested?/1),
              number: {:b, to_string(Enum.count(@rows, &suggested?/1))}
            )
          } />
        </span>
        <span :if={@own_only} id="targets-own-only">
          {gettext("Showing those that set their own mode.")}
          <.link patch={~p"/hive/policy/targets"} class="q-link">{gettext("Show all")}</.link>
        </span>
      </div>
      <div
        class="overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs"
        tabindex="0"
        role="region"
        aria-label={gettext("Targets and their policy")}
      >
        <table class="table q-targets" role="table">
          <thead>
            <tr role="row">
              <th role="columnheader">{gettext("Target")}</th>
              <th role="columnheader">{gettext("Mode")}</th>
              <th role="columnheader">{gettext("Policy")}</th>
              <th role="columnheader" class="q-num">{gettext("Own rules")}</th>
              <th role="columnheader" class="q-num">{gettext("Overrides")}</th>
              <th role="columnheader" class="q-num">{gettext("Suggestions")}</th>
              <th role="columnheader">{gettext("Version")}</th>
              <th role="columnheader">{gettext("Last change")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@shown == []} role="row">
              <td role="cell" colspan="8" class="!whitespace-normal text-[13px] text-faint">
                {gettext("No target sets its own mode. Every one follows the hive's default.")}
              </td>
            </tr>
            <tr :for={row <- @shown} id={"target-#{row.id}"} role="row" class="q-target-row">
              <td role="cell" class="q-c-target">
                <.link
                  navigate={~p"/hive/policy/targets/#{row.id}"}
                  class="q-target-name q-rowlink"
                >
                  <span class="q-target-system">{row.system}/</span><span class="q-target-path">{row.path}</span>
                </.link>
              </td>
              <td role="cell" class="q-c-mode">
                <span class="mr-1.5 text-[13px] font-medium">{row.mode}</span>
                <.source_chip
                  :if={row.own_mode}
                  source={:target}
                  label={gettext("Its own")}
                  class="q-src-bare"
                />
                <.source_chip
                  :if={!row.own_mode}
                  source={:hive}
                  label={gettext("Hive default")}
                  class="q-src-bare"
                />
              </td>
              <td role="cell">
                <.source_chip :if={row.own > 0} source={:target} label={gettext("Own rules")} />
                <.source_chip
                  :if={row.own == 0 && row.own_mode}
                  source={:target}
                  label={gettext("Own mode")}
                />
                <.source_chip
                  :if={row.own == 0 && !row.own_mode}
                  source={:hive}
                  label={gettext("Hive baseline")}
                />
              </td>
              <td role="cell" class={["q-num q-opt", row.own == 0 && "q-zero"]}>{row.own}</td>
              <td role="cell" class="q-num q-opt">
                <.cell value={row.detail} none={gettext("n/a")}>
                  <span class={row.detail.overrides == 0 && "q-zero"}>{row.detail.overrides}</span>
                </.cell>
              </td>
              <td role="cell" class="q-num">
                <.cell value={row.suggestions} none={gettext("n/a")}>
                  <span :if={row.suggestions > 0} class="q-newdot">
                    {gettext("%{count} to review", count: row.suggestions)}
                  </span>
                  <span :if={row.suggestions == 0} class="q-zero">
                    <span class="sr-only">{gettext("none")}</span><span aria-hidden="true">–</span>
                  </span>
                </.cell>
              </td>
              <td role="cell" class="q-opt font-mono text-[12.5px]">
                <.cell value={row.detail} none={gettext("n/a")}>
                  <.version_pill
                    :if={row.detail.version}
                    size="sm"
                    version={row.detail.version.version}
                    digest={row.detail.version.digest}
                    scope={
                      if is_nil(row.detail.version.target_id),
                        do: gettext("hive baseline"),
                        else: "#{row.system}/#{row.path}"
                    }
                    navigate={
                      if is_nil(row.detail.version.target_id),
                        do: ~p"/hive/policy/versions/#{row.detail.version.version}",
                        else:
                          ~p"/hive/policy/targets/#{row.id}/versions/#{row.detail.version.version}"
                    }
                  />
                  <span :if={!row.detail.version} class="text-faint font-sans text-[13px]">
                    {gettext("no version yet")}
                  </span>
                </.cell>
              </td>
              <td role="cell" class="q-opt text-muted tabular-nums">
                <.relative_time :if={row.changed} at={row.changed} />
                <span :if={!row.changed} class="text-faint">{gettext("n/a")}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="max-w-[80ch] text-[12.5px]/[18px] text-faint">
        {gettext(
          "A target appears here once a run names it. A target with neither rules nor a mode of its own is served the hive baseline, and so is a run that names no target."
        )}
      </p>
    </div>
    """
  end

  # A cell read off the render: a skeleton while it loads, "n/a" for a target past the
  # first fifty, never a number nobody counted.
  attr :value, :any, required: true
  attr :none, :string, required: true
  slot :inner_block, required: true

  defp cell(%{value: :loading} = assigns) do
    ~H|<span class="skeleton q-skel inline-block w-10 align-middle" aria-hidden="true"></span>|
  end

  defp cell(%{value: :none} = assigns) do
    ~H|<span class="q-zero font-sans" title={gettext("Open the target to see it")}>{@none}</span>|
  end

  defp cell(assigns), do: ~H"{render_slot(@inner_block)}"

  defp suggested?(row), do: is_integer(row.suggestions) and row.suggestions > 0

  ## Dialogs

  attr :mode, :string, required: true
  attr :would, :any, required: true
  attr :alive, :integer, required: true
  attr :started, :boolean, required: true
  attr :following, :integer, required: true
  attr :own, :integer, required: true

  defp mode_dialog(%{mode: "enforce"} = assigns) do
    shown = if assigns.would, do: Enum.take(assigns.would.destinations, 8), else: []

    left = if assigns.would, do: MapSet.size(assigns.would.open), else: 0

    assigns = assign(assigns, shown: shown, left: left)

    ~H"""
    <.modal
      id="mode-enforce"
      title={gettext("Set the hive's default to enforce")}
      size="lg"
      on_cancel={JS.push("dialog_cancel")}
    >
      <p class="text-muted">
        <%= for part <- effect_words("enforce", @following, @alive) do %>
          <b :if={part == :effect} class="font-medium text-base-content">
            {effect_phrase("enforce")}
          </b>{if part !=
                                                                                                                             :effect,
                                                                                                                           do:
                                                                                                                             part}
        <% end %>
        {own_words(@own)}
        {gettext("You can switch back at any time.")}
        <span :if={!@started}>
          {gettext(
            "This is the hive's first change: it renders version 1, and machines take their policy from Qory from then on."
          )}
        </span>
      </p>
      <div :if={@would && @would.destinations != []} id="mode-would" class="q-would">
        <div>
          <span>
            {gettext("Let through in the last 7 days with no rule matching, in those targets")}
          </span>
          <span id="mode-would-n" class="tabular-nums">
            {if @left == 0,
              do: gettext("none left"),
              else: ngettext("%{count} destination", "%{count} destinations", @left)}
          </span>
        </div>
        <ul>
          <li :for={destination <- @shown} id={"would-#{would_key(destination)}"}>
            <.rule_mark action={
              if !MapSet.member?(@would.open, would_key(destination)), do: "allow", else: "pending"
            } />
            <span class="q-dest">
              {destination.host}<span :if={destination.path} class="text-muted">{destination.path}</span>
            </span>
            <small>
              {ngettext("%{count} attempt", "%{count} attempts", destination.attempts)} · {ngettext(
                "%{count} run",
                "%{count} runs",
                destination.runs
              )}
            </small>
            <button
              :if={MapSet.member?(@would.open, would_key(destination))}
              type="button"
              class="btn btn-xs"
              phx-click={JS.push("would_allow", value: %{key: would_key(destination)})}
            >
              {gettext("Allow for the hive")}
            </button>
            <span :if={!MapSet.member?(@would.open, would_key(destination))} class="q-done">
              <.icon name="hero-check-micro" class="size-3" />{gettext("Allowed")}
            </span>
          </li>
        </ul>
        <p :if={length(@would.destinations) > 8} class="q-would-more">
          <%= for part <- more_words(length(@would.destinations) - 8) do %>
            <.link :if={part == :link} navigate={~p"/hive/connections?since=7d"} class="q-link">
              {gettext("connections page")}
            </.link>{if part !=
                                                                                                                                                               :link,
                                                                                                                                                             do:
                                                                                                                                                               part}
          <% end %>
        </p>
      </div>
      <p :if={@would && @would[:error]} class="text-error-soft-content" role="alert">
        {@would[:error]}
      </p>
      <p :if={@would && @would.destinations == []} id="mode-would-none" class="text-muted">
        {gettext("Every destination your runs reached in the last 7 days is covered by a rule.")}
      </p>
      <p :if={@would && @would.destinations != []} class="text-[12.5px]/[18px] text-muted">
        {gettext(
          "Counted from recorded connections that today's rules still do not cover. Enforce will deny these. A destination no run has reached yet is not in this list."
        )}
      </p>
      <:footer>
        <.button phx-click="dialog_cancel" data-autofocus>{gettext("Cancel")}</.button>
        <.button
          id="mode-confirm"
          variant="primary"
          phx-click="mode_confirm"
          loading_text={gettext("Setting")}
        >
          {gettext("Set the default to enforce")}
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp mode_dialog(assigns) do
    ~H"""
    <.modal
      id="mode-observe"
      title={gettext("Set the hive's default to observe")}
      size="sm"
      on_cancel={JS.push("dialog_cancel")}
    >
      <p class="text-muted">
        <%= for part <- effect_words("observe", @following, @alive) do %>
          <b :if={part == :effect} class="font-medium text-base-content">
            {effect_phrase("observe")}
          </b>{if part !=
                                                                                                                             :effect,
                                                                                                                           do:
                                                                                                                             part}
        <% end %>
        {gettext(
          "A target that sets its own mode does not change. The rules stay as they are, locked ones too: a deny holds in either mode."
        )}
      </p>
      <:footer>
        <.button phx-click="dialog_cancel" data-autofocus>{gettext("Cancel")}</.button>
        <.button
          id="mode-confirm"
          variant="danger"
          phx-click="mode_confirm"
          loading_text={gettext("Setting")}
        >
          {gettext("Set the default to observe")}
        </.button>
      </:footer>
    </.modal>
    """
  end

  # The first sentence of a mode's confirm: what the mode denies, in whose runs. Each
  # case is a whole sentence; the effect is a bold phrase of its own, `:effect` here.
  defp effect_words(mode, following, alive) do
    effect = :effect
    runs = ngettext("%{count} run", "%{count} runs", alive)

    case {mode, following, alive} do
      {"enforce", 0, 0} ->
        rich_gettext(
          "From the next heartbeat, about 30 s, %{effect} in the runs that name no target.",
          effect: effect
        )

      {"enforce", 0, _alive} ->
        rich_gettext(
          "From the next heartbeat, about 30 s, %{effect} in the runs that name no target, and among the %{runs} alive now.",
          effect: effect,
          runs: runs
        )

      {"enforce", _following, 0} ->
        rich_ngettext(
          "From the next heartbeat, about 30 s, %{effect} in the %{count} target that follows the hive's default.",
          "From the next heartbeat, about 30 s, %{effect} in the %{count} targets that follow the hive's default.",
          following,
          effect: effect
        )

      {"enforce", _following, _alive} ->
        rich_ngettext(
          "From the next heartbeat, about 30 s, %{effect} in the %{count} target that follows the hive's default, and among the %{runs} alive now.",
          "From the next heartbeat, about 30 s, %{effect} in the %{count} targets that follow the hive's default, and among the %{runs} alive now.",
          following,
          effect: effect,
          runs: runs
        )

      {_observe, 0, 0} ->
        rich_gettext(
          "From the next heartbeat, about 30 s, %{effect} in the runs that name no target: every other connection is let through and recorded.",
          effect: effect
        )

      {_observe, 0, _alive} ->
        rich_gettext(
          "From the next heartbeat, about 30 s, %{effect} in the runs that name no target, and among the %{runs} alive now: every other connection is let through and recorded.",
          effect: effect,
          runs: runs
        )

      {_observe, _following, 0} ->
        rich_ngettext(
          "From the next heartbeat, about 30 s, %{effect} in the %{count} target that follows the hive's default: every other connection is let through and recorded.",
          "From the next heartbeat, about 30 s, %{effect} in the %{count} targets that follow the hive's default: every other connection is let through and recorded.",
          following,
          effect: effect
        )

      {_observe, _following, _alive} ->
        rich_ngettext(
          "From the next heartbeat, about 30 s, %{effect} in the %{count} target that follows the hive's default, and among the %{runs} alive now: every other connection is let through and recorded.",
          "From the next heartbeat, about 30 s, %{effect} in the %{count} targets that follow the hive's default, and among the %{runs} alive now: every other connection is let through and recorded.",
          following,
          effect: effect,
          runs: runs
        )
    end
  end

  defp effect_phrase("enforce"), do: gettext("a connection no rule allows is denied")
  defp effect_phrase(_observe), do: gettext("only what a deny rule names is denied")

  defp own_words(0), do: ""

  defp own_words(n),
    do:
      ngettext(
        "%{count} target sets its own mode and does not change.",
        "%{count} targets set their own mode and do not change.",
        n
      )

  # "and 4 more on the connections page", with the page a link.
  defp more_words(more),
    do: rich_gettext("and %{more} more on the %{link}", more: to_string(more), link: :link)

  @doc false
  def would_key(destination), do: Common.would_key(destination)

  attr :rule, :map, required: true
  attr :held, :list, required: true

  defp lock_dialog(assigns) do
    ~H"""
    <.modal
      id="lock-confirm"
      title={lock_title(@rule)}
      size="sm"
      on_cancel={JS.push("dialog_cancel")}
    >
      <p class="text-muted">
        {gettext("A locked rule holds against every target.")}
        <b class="font-medium text-base-content">{ngettext(
            "%{count} target rule stops being in force",
            "%{count} target rules stop being in force",
            length(@held)
          )}</b>:
      </p>
      <div class="q-would">
        <ul>
          <li :for={held <- @held} class="!grid-cols-[18px_minmax(0,1fr)_auto]">
            <.rule_mark action={held.rule.action} />
            <span class="q-dest">{held.rule.host}</span>
            <small class="font-mono">{held.target.system}/{held.target.path}</small>
          </li>
        </ul>
      </div>
      <p class="text-muted">
        {gettext("The target's rule is kept and shown as held. Only an owner can unlock.")}
      </p>
      <:footer>
        <.button phx-click="dialog_cancel" data-autofocus>{gettext("Cancel")}</.button>
        <.button id="lock-confirm-button" variant="primary" phx-click="lock_confirm">
          {gettext("Lock the rule")}
        </.button>
      </:footer>
    </.modal>
    """
  end

  attr :rule, :map, required: true
  attr :overriders, :list, required: true

  defp remove_dialog(assigns) do
    ~H"""
    <.modal
      id="remove-confirm"
      title={remove_title(@rule)}
      size="sm"
      on_cancel={JS.push("dialog_cancel")}
    >
      <p class="text-muted">
        <span :if={@rule.locked}>
          {gettext(
            "This rule is locked: it holds against every target, and removing it lets their own rules decide again."
          )}
        </span>
        <span :if={@overriders != []}>
          {ngettext(
            "%{count} target has a rule of its own on this host; it then has nothing to override and is kept.",
            "%{count} targets have a rule of their own on this host; it then has nothing to override and is kept.",
            length(@overriders)
          )}
        </span>
        {gettext("This takes effect within a heartbeat.")}
      </p>
      <:footer>
        <.button phx-click="dialog_cancel" data-autofocus>{gettext("Cancel")}</.button>
        <.button id="remove-confirm-button" variant="danger" phx-click="remove_confirm">
          {gettext("Remove the rule")}
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp lock_title(%{action: "deny", host: host}),
    do: gettext("Lock the deny rule %{host}", host: host)

  defp lock_title(%{host: host}), do: gettext("Lock the allow rule %{host}", host: host)

  defp remove_title(%{action: "deny", host: host}),
    do: gettext("Remove the deny rule %{host}", host: host)

  defp remove_title(%{host: host}), do: gettext("Remove the allow rule %{host}", host: host)
end
