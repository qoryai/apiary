defmodule ApiaryWeb.PolicyLive.Show do
  @moduledoc """
  The workspace's security policy: the mode card above the tabs, whose choices open in
  place and are saved by one button, Network access (the
  hosts and paths allowed and denied, with the composer that reads a rule back before it
  is saved, and a link to the Network access page, what the runs reached), the targets
  and their policy, the history with diffs, the document in force (the Document tab, which
  shows the new version in place after a change), one version with its document, and the
  export. The Network access page's rule links (`?rule=`) lead to the rule in that
  section.

  One LiveView, six live actions, so a tab is a patch. A version and its export name
  themselves in the frame's breadcrumb, after Policy, and have no mode card: they state
  their own mode. Filters, the opened change, the compared version and the export page
  are in the URL. The page calls `Apiary.Policy` and nothing under it, except the
  contract's grammar for the reading line. It follows `policy:<workspace>` and reads
  again at most once per 250 ms.

  A workspace nobody has changed yet is not served a policy by Qory: its machines use
  their own until the first change here, and the page says so.

  Where the edition keeps a level above the workspace's policy (`Apiary.Policy.Above`,
  the `above` of the effective policy), the page says so under its title, lists the
  level's rules first with their source and a lock glyph, read here and changed where
  the level is, and shows the mode fixed when the level requires enforce.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :security
  on_mount {ApiaryWeb.Access, :"security_policy.read"}

  import ApiaryWeb.PolicyComponents
  import ApiaryWeb.PolicyLive.Views

  alias Apiary.Policy
  alias Apiary.Policy.Grammar
  alias ApiaryWeb.PolicyLive.{Common, RuleList}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> Common.mount(nil)
      |> assign(reload: &load/1, list_query: %RuleList{}, ruled_host: nil, targets: nil)
      |> assign(history: nil, open_change: nil, diff: nil, v: nil, export: nil, missing: nil)
      |> assign(would: nil, composer_open: false, own_only: false, params: %{})
      |> assign(target_list: [], summary: nil, shown: nil)
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

    effective = Policy.effective(scope, nil)

    socket
    |> assign(
      managed?: managed?,
      mode: Policy.get_mode(scope),
      own: own,
      effective: effective,
      above_link: effective.above && ApiaryWeb.Edition.above_policy_link(scope),
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
        rows: Common.above_rows(effective, socket) ++ Common.workspace_rules(own, socket, locks)
      )
    end)
    |> load_record()
    |> follow_document()
  end

  # The Document tab shows the version in force: after a change, read again with the page,
  # it shows the new one in place.
  defp follow_document(%{assigns: %{loaded: true, live_action: :document}} = socket),
    do: document(socket)

  defp follow_document(socket), do: socket

  defp document(socket) do
    with %{version: n} <- socket.assigns.version,
         {:ok, v} <- Common.version(socket, n, socket.assigns.params) do
      assign(socket,
        v: Map.put(v, :path, "#{socket.assigns.base}/document"),
        page_title: gettext("Version %{version} · Policy", version: n)
      )
    else
      _ -> socket
    end
  end

  # What the level above the workspace fixes: the mode, when it requires enforce.
  defp required_mode(%{above: %{floor: true, name: name}}), do: %{name: name}
  defp required_mode(_effective), do: nil

  # What the recorded connections say: the mode's fact and the rules' use, both over 14
  # days. Bounded reads that may answer :unavailable; then the fact and the column
  # are left out.
  defp load_record(socket) do
    if connected?(socket) do
      scope = socket.assigns.current_scope
      mode = socket.assigns.mode

      socket
      |> assign_async(:activity, fn ->
        {:ok, %{activity: unwrap(Policy.rule_activity(scope, nil, Common.use_since()))}}
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

    # A rule row's confirm is in place on the rules tab: another tab leaves it. The mode's
    # choices stay open on every tab, the card being above them, and close where the card
    # is not drawn: a version and its export.
    socket =
      if socket.assigns.live_action != :rules and socket.assigns.dialog != nil,
        do: assign(socket, :dialog, nil),
        else: socket

    socket =
      if socket.assigns.live_action in [:version, :export],
        do: assign(socket, mode_pick: nil, would: nil),
        else: socket

    action = socket.assigns.live_action

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
      |> assign(list_query: query, ruled_host: ruled_host, page_title: gettext("Policy"))
      |> then(&if(ruled_host, do: push_event(&1, "policy:rule", %{host: ruled_host}), else: &1))
      |> then(&if(params["confirm"] == "enforce", do: confirm_enforce(&1), else: &1))
    else
      push_patch(socket,
        to: Common.list_path(socket, RuleList.parse(params), Map.take(params, ~w(rule confirm))),
        replace: true
      )
    end
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

  # The document in force, under the card and the tabs; with none yet, the page.
  defp apply_action(socket, :document, _params) do
    scope = socket.assigns.current_scope

    case socket.assigns.version do
      %{version: _} ->
        socket |> assign(:v, nil) |> document()

      _ ->
        push_navigate(socket,
          to: ~p"/#{scope.organisation}/#{scope.workspace}/policy",
          replace: true
        )
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
            assign(socket,
              export: Common.export(socket, v.configuration),
              page_title:
                gettext("Export · Version %{version} · Policy", version: v.configuration.version)
            )

          action == :export ->
            scope = socket.assigns.current_scope

            push_patch(socket,
              to:
                ~p"/#{scope.organisation}/#{scope.workspace}/policy/versions/#{v.latest}/export",
              replace: true
            )

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

  # `?confirm=enforce` (the overview's one-click nudge) lands with the mode's choices
  # open and Enforce picked, its question asked, and only for an owner of a workspace that
  # observes; nothing is saved until its button is pressed. The parameter is dropped from
  # the address at once, so a reload or a shared link does not ask again. Any other value
  # of `confirm` is ignored.
  defp confirm_enforce(socket) do
    # The address is cleaned once the page is up: a patch from the connected mount's own
    # `handle_params` would be part of the join.
    send(self(), :drop_confirm)

    if Common.may?(socket, :"security_policy.set_mode") and socket.assigns.mode != "enforce",
      do: event("mode_open", %{"mode" => "enforce"}, socket),
      else: socket
  end

  # The rows' menu is the page's own here: the workspace's rules come with a lock and a
  # confirm, and a rule of the level above is a link, never an event.
  @own_events ~w(edit_paths change_action remove)

  @impl true
  def handle_event(event, params, socket) when event in @own_events,
    do: {:noreply, event(event, params, socket)}

  def handle_event(event, params, socket) do
    case Common.handle_event(event, params, socket) do
      {:halt, socket} -> {:noreply, socket}
      :cont -> {:noreply, event(event, params, socket)}
    end
  end

  # The mode's choices: opened by Change mode (or `?confirm=enforce`, with Enforce picked),
  # a pick only selects, and one button saves the pick; Cancel and Escape close them. Each
  # asks again whether the reader may set a mode and whether the level above fixes it.
  # `mode_pick` alone says the choices are open, and what is picked.
  defp event("mode_open", params, socket) do
    cond do
      required_mode(socket.assigns.effective) != nil ->
        socket

      not Common.may?(socket, :"security_policy.set_mode") ->
        assign(socket, :write_error, only_admins_set_mode(socket))

      true ->
        pick =
          case params do
            %{"mode" => mode} when mode in ~w(observe enforce) -> mode
            _ -> socket.assigns.mode
          end

        socket |> pick_mode(pick) |> Common.focus("policy-mode-opt-#{pick}")
    end
  end

  defp event("mode_pick", %{"mode" => mode}, socket) when mode in ~w(observe enforce) do
    cond do
      required_mode(socket.assigns.effective) != nil or is_nil(socket.assigns.mode_pick) ->
        socket

      not Common.may?(socket, :"security_policy.set_mode") ->
        assign(socket, :write_error, only_admins_set_mode(socket))

      true ->
        pick_mode(socket, mode)
    end
  end

  defp event("mode_set", _params, socket) do
    pick = socket.assigns.mode_pick

    cond do
      required_mode(socket.assigns.effective) != nil ->
        socket

      not Common.may?(socket, :"security_policy.set_mode") ->
        assign(socket, :write_error, only_admins_set_mode(socket))

      is_nil(pick) ->
        socket

      pick == socket.assigns.mode ->
        close_mode(socket)

      true ->
        socket |> assign(mode_pick: nil, would: nil) |> set_mode(pick)
    end
  end

  defp event("mode_cancel", _params, socket), do: close_mode(socket)

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
            would = Common.would(scope, nil, would)

            socket
            |> load()
            |> assign(:would, would)
            |> assign(
              :announce,
              gettext("%{host} is allowed for the workspace.", host: destination.host)
            )
            |> Common.focus_next_allow(would, key, "policy-mode-set")

          {:error, error} ->
            assign(socket, :would, Map.put(would, :error, error.message))
        end
    end
  end

  defp event("lock_toggle", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with true <- Common.may?(scope, :"security_policy.lock"),
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
          ApiaryWeb.Access.who_may(
            scope,
            :"security_policy.lock",
            gettext("Only an owner can lock, unlock or change a locked rule.")
          )
        )

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  # A confirm acts on the rule as it is now, not as it was when the confirm showed: one
  # that is gone, or is not what the confirm named any more, is refused and the list re-read.
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
            do: gettext("%{rule} is locked. No target can override it.", rule: rule.host),
            else: gettext("%{rule} is unlocked. A target can override it again.", rule: rule.host)

        announce = if locked, do: gettext("Rule locked."), else: gettext("Rule unlocked.")

        # Locked, the row's lock takes the focus; unlocked, the lock is gone: its menu.
        socket
        |> Common.wrote(nil, sentence, announce)
        |> focus_row(rule.host, if(locked, do: "lock", else: "menu-button"))

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  # The page is the workspace's: the rule is the workspace's, never a target's.
  defp changed(socket, {:ok, rule}, host, action) do
    sentence =
      if action == "deny",
        do: gettext("%{host} is denied for the workspace.", host: host),
        else: gettext("%{host} is allowed for the workspace.", host: host)

    socket
    |> Common.wrote(rule, sentence, gettext("Rule changed."))
    |> focus_row(host)
  end

  defp changed(socket, {:error, error}, _host, _action), do: Common.refused(socket, error)

  defp remove(socket, rule) do
    rows = Common.listing(socket.assigns).rows |> Enum.filter(&(&1.id == rule.id or menu?(&1)))
    index = Enum.find_index(rows, &(&1.id == rule.id))
    next = index && (Enum.at(rows, index + 1) || (index > 0 && Enum.at(rows, index - 1)))

    case Policy.remove_rule(socket.assigns.current_scope, rule) do
      {:ok, rule} ->
        socket =
          Common.wrote(
            socket,
            nil,
            gettext("The rule %{host} is removed.", host: rule.host),
            gettext("Rule removed.")
          )

        Common.focus(socket, if(next, do: "rule-#{next.id}-menu-button", else: add_rule(socket)))

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  # After an act on a row, the focus stays on the row, `part` of it (its menu, or its lock
  # once locked), when the row is on the page; else it goes to adding a rule.
  defp focus_row(socket, host, part \\ "menu-button") do
    case Enum.find(Common.listing(socket.assigns).rows, &(&1.own and &1.host == host)) do
      %{id: id} -> Common.focus(socket, "rule-#{id}-#{part}")
      nil -> Common.focus(socket, add_rule(socket))
    end
  end

  # A row's ⋯ menu is drawn for the page's own rule the reader may change, and for a rule
  # written elsewhere that has a page to change it on (`rule_line/1`).
  defp menu?(row), do: (row.own and row.can_change) or (not row.own and row.view != nil)

  # Adding a rule: Add rule over the list, or the first rule of a page with none, which
  # shows no list (`rules_tab/1`'s `empty?`).
  defp add_rule(%{assigns: %{own: [], effective: %{above: nil}, composer_open: false}}),
    do: "policy-first-rule"

  defp add_rule(_socket), do: "policy-rules-add"

  # A pick of the mode's choices: what enforce would deny is read when it is picked over
  # observe, and kept while it stays picked.
  defp pick_mode(socket, mode) do
    would =
      if mode == "enforce" and socket.assigns.mode != "enforce",
        do: socket.assigns.would || Common.would(socket.assigns.current_scope, nil),
        else: nil

    assign(socket, mode_pick: mode, would: would)
  end

  # The choices close, nothing saved; the focus goes back to Change mode.
  defp close_mode(socket) do
    socket |> assign(mode_pick: nil, would: nil) |> Common.focus("policy-mode-change")
  end

  defp set_mode(socket, mode) do
    case Policy.set_mode(socket.assigns.current_scope, mode) do
      {:ok, mode} ->
        following = socket.assigns.following
        default = default_sentence(mode)

        socket
        |> Common.wrote(
          nil,
          default <>
            " " <>
            ngettext(
              "%{number} target follows it.",
              "%{number} targets follow it.",
              following,
              number: Format.number(following)
            ),
          default
        )
        |> Common.focus("policy-mode-change")

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  defp default_sentence("enforce"), do: gettext("The workspace's default is enforce.")
  defp default_sentence(_observe), do: gettext("The workspace's default is observe.")

  # The targets' own rules a lock of this rule would put out of force: a rule on the
  # same host, or an allow below a locked `*.` deny. Read for the targets that have
  # rules of their own, at most fifty of them. Each is named as it is addressed (`name`):
  # one read of the paths it names.
  defp held_by_lock(scope, rule) do
    held =
      for {target, own} <- target_rules(scope),
          other <- own,
          other.kind == "host",
          other.host == rule.host or
            (rule.action == "deny" and other.action == "allow" and
               Grammar.covers?(rule.host, other.host)),
          do: %{target: target, rule: other}

    shared = Apiary.Runs.shared_paths(scope, Enum.map(held, & &1.target.path))

    for %{target: target} = one <- held,
        do:
          Map.put(
            one,
            :name,
            ApiaryWeb.TargetComponents.target_label(target.system, target.path, shared)
          )
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
  def handle_info(:drop_confirm, socket) do
    scope = socket.assigns.current_scope
    {:noreply, push_patch(socket, to: ~p"/#{scope.organisation}/#{scope.workspace}/policy")}
  end

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
      width="list"
    >
      <:crumb>{gettext("Policy")}</:crumb>
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
      width="list"
    >
      <:crumb
        :if={@live_action in [:version, :export] && @v}
        navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy"}
      >
        {gettext("Policy")}
      </:crumb>
      <:crumb
        :if={@live_action in [:version, :export] && @v}
        navigate={
          @live_action == :export &&
            ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy/versions/#{@v.configuration.version}"
        }
      >
        {gettext("Version %{version}", version: @v.configuration.version)}
      </:crumb>
      <:crumb :if={@live_action == :export && @v}>{gettext("Export")}</:crumb>
      <:crumb :if={!(@live_action in [:version, :export] && @v)}>{gettext("Policy")}</:crumb>

      <div
        id="policy-page"
        phx-hook="PolicyPage"
        class="q-policy grid grid-cols-[minmax(0,1fr)] gap-6"
      >
        <.version_head :if={@live_action == :version && @v} v={@v} base={@base} />

        <.page_header
          :if={!(@live_action in [:version, :export] && @v)}
          id="policy-header"
          title={gettext("Policy")}
        >
          <:description>
            {gettext("What the runs of this workspace may reach through the gateway.")}
          </:description>
          <:actions>
            <div :if={@managed? && @version} class="q-head-side">
              <.version_pill
                id="policy-version-pill"
                version={@version.version}
                digest={@version.digest}
                navigate={
                  ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy/history"
                }
                copy
              />
              <%!-- On the Document tab the document's own bar is the one place: Copy, Download. --%>
              <.button
                :if={@live_action != :document}
                id="policy-export-button"
                navigate={
                  ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy/versions/#{@version.version}/export"
                }
              >
                <.icon name="hero-arrow-up-tray" class="size-4" />{gettext("Export")}
              </.button>
            </div>
            <div :if={!(@managed? && @version)} class="q-head-side">
              <.version_pill id="policy-version-pill" />
              <%!-- Off but focusable, so its reason is met by keyboard too: it does nothing. --%>
              <.tooltip
                tip={gettext("Nothing to export yet: the first change here renders version 1.")}
                placement="left"
                class="q-tip-wide"
              >
                <.button
                  id="policy-export-button"
                  type="button"
                  class="btn-disabled"
                  aria-disabled="true"
                  aria-describedby="policy-export-why"
                >
                  <.icon name="hero-arrow-up-tray" class="size-4" />{gettext("Export")}
                </.button>
              </.tooltip>
              <span id="policy-export-why" class="sr-only">
                {gettext("Nothing to export yet: the first change here renders version 1.")}
              </span>
            </div>
          </:actions>
          <.above_line :if={@loaded} above={@effective.above} link={@above_link} />
        </.page_header>

        <.mode_card
          :if={!(@live_action in [:version, :export] && @v)}
          level={:workspace}
          scope={@current_scope}
          mode={@mode}
          can_edit={Common.may?(@current_scope, :"security_policy.set_mode")}
          served={@managed?}
          following={@following}
          own={@own_modes}
          fact={with :unavailable <- async_value(@fact, :loading), do: nil}
          floor={required_mode(@effective)}
          pick={@mode_pick}
        >
          <:effect>
            <.mode_ask_effect
              :if={@mode_pick}
              mode={@mode_pick}
              alive={if @own_modes == [], do: (@nav_counts && @nav_counts[:alive]) || 0, else: 0}
              started={@managed?}
              following={@following}
              own={length(@own_modes)}
            />
          </:effect>
          <.mode_would :if={@mode_pick == "enforce"} would={@would} scope={@current_scope} />
        </.mode_card>

        <.policy_tabs
          :if={!(@live_action == :export && @v)}
          scope={@current_scope}
          live_action={@live_action}
          rules={length(@rows)}
          targets={@target_total}
          changes={@change_total}
          document={@managed? && @version != nil}
        />

        <div id="policy-announce" class="sr-only" role="status" aria-live="polite">{@announce}</div>
        <.keys_panel />

        <ApiaryWeb.Extension.slot
          name={:policy_notices}
          scope={@current_scope}
          changes={@change_total}
        />

        <.notice :if={@write_error} kind={:error} class="max-w-[80ch]">
          <span id="policy-write-error" role="alert">{@write_error}</span>
        </.notice>

        <.rules_tab :if={@live_action == :rules} {assigns} />
        <.targets_tab
          :if={@live_action == :targets}
          scope={@current_scope}
          rows={target_rows(@target_list, @target_details, @target_suggestions)}
          own_only={@own_only}
        />
        <.history_view
          :if={@live_action == :history && @history}
          history={@history}
          open={@open_change}
          diff={@diff}
          base={@base}
          scope={:workspace}
          summary={@summary}
          now={@now}
        />
        <.version_head
          :if={@live_action == :document && @v}
          v={@v}
          base={@base}
          heading="h2"
          export={false}
        />
        <.version_view
          :if={@live_action in [:version, :document] && @v}
          v={@v}
          base={@base}
          now={@now}
        />
        <.export_page
          :if={@live_action == :export && @v && @export}
          export={@export}
          done={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy/document"}
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
          <span :if={!@missing.latest}>{gettext("This workspace has no version yet.")}</span>
          <:actions>
            <.button
              :if={@missing.latest}
              navigate={
                ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy/versions/#{@missing.latest.version}"
              }
            >
              {gettext("Open version %{version}", version: @missing.latest.version)}
            </.button>
            <.button
              :if={!@missing.latest}
              navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/policy"}
            >
              {gettext("Back to policy")}
            </.button>
          </:actions>
        </.empty_state>
      </div>
    </Layouts.app>
    """
  end

  attr :v, :map, required: true
  attr :base, :string, required: true

  attr :heading, :string,
    default: "h1",
    values: ~w(h1 h2),
    doc: "h2 under a page's own title, as a target's Policy tab and the Document tab have"

  attr :away, :boolean,
    default: false,
    doc: "the version is another page's (the workspace's, on a target served it): Export leaves"

  attr :export, :boolean,
    default: true,
    doc: "false on the Document view, whose document's bar has Copy and Download instead"

  # The heading takes the focus a page sends it (`policy-version-h`) when the version is
  # reached by a patch, as Done from its export is.
  def version_head(assigns) do
    ~H"""
    <header class="flex flex-wrap items-start justify-between gap-4">
      <div class="q-run-title">
        <.dynamic_tag
          tag_name={@heading}
          id="policy-version-h"
          class="text-xl/7 font-semibold tracking-[-0.017em] outline-none"
          tabindex="-1"
        >
          {gettext("Version %{version}", version: @v.configuration.version)}
        </.dynamic_tag>
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
      <div :if={@export} class="q-head-side">
        <.button
          id="version-export"
          patch={!@away && "#{@base}/versions/#{@v.latest}/export"}
          navigate={@away && "#{@base}/versions/#{@v.latest}/export"}
        >
          <.icon name="hero-arrow-up-tray" class="size-4" />{if @v.current?,
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

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  defp policy_tabs(assigns) do
    ~H"""
    <.page_tabs id="policy-tabs" label={gettext("Policy")} current={tab_key(@live_action)}>
      <:tab
        key={:rules}
        patch={~p"/#{@scope.organisation}/#{@scope.workspace}/policy"}
        icon="hero-shield-check"
        count={if @rules > 0, do: @rules}
      >
        {gettext("Rules")}
      </:tab>
      <:tab
        key={:targets}
        patch={~p"/#{@scope.organisation}/#{@scope.workspace}/policy/targets"}
        icon="hero-book-open"
        count={if @targets > 0, do: @targets}
      >
        {gettext("Targets")}
      </:tab>
      <:tab
        key={:history}
        patch={~p"/#{@scope.organisation}/#{@scope.workspace}/policy/history"}
        icon="hero-clock"
        count={if @changes > 0, do: @changes}
      >
        {gettext("History")}
      </:tab>
      <:tab
        :if={@document}
        key={:document}
        patch={~p"/#{@scope.organisation}/#{@scope.workspace}/policy/document"}
        icon="hero-document-text"
      >
        {gettext("Document")}
      </:tab>
    </.page_tabs>
    """
  end

  # The tab a live action is under: a version and its export are the Document's too.
  defp tab_key(action) when action in [:version, :export, :document], do: :document
  defp tab_key(action), do: action

  defp rules_tab(assigns) do
    edit? = Common.may?(assigns.current_scope, :"security_policy.edit")

    above = assigns.effective.above

    assigns =
      assigns
      |> assign(:edit?, edit?)
      |> assign(:above, above)
      |> assign(
        :empty?,
        assigns.own == [] and is_nil(above) and not (assigns.composer_open and edit?)
      )
      |> assign(:activity_now, async_value(assigns.activity, :loading))
      |> assign(:listing, Common.listing(assigns))

    ~H"""
    <div :if={@empty?} id="policy-empty" class="grid gap-4">
      <.empty_state
        icon="hero-shield-check"
        title={
          if @managed?, do: gettext("No rules yet"), else: gettext("Qory Apiary serves no policy yet")
        }
      >
        <span :if={!@managed?} id="policy-unmanaged">
          {pgettext(
            "plain",
            "Until the first change here, every machine of this workspace runs under its own policy, the one in its Forager file. The first rule you add, or a mode you set, renders version 1, and from then on each machine applies it, narrowed by its own. You can also let a run reach out first and allow its hosts from the Network access page, one row at a time."
          )}
        </span>
        <span :if={@managed?}>
          {if @mode == "observe",
            do: gettext("With no rules, runs reach everything and every connection is recorded."),
            else: gettext("With no rules, a run under enforce reaches nothing.")}
          {gettext(
            "Add the hosts your runs need here, or let a run reach out first and allow its hosts from the Network access page, one row at a time."
          )}
        </span>
        <:actions>
          <.button
            :if={@edit?}
            id="policy-first-rule"
            variant="primary"
            phx-click="composer_open"
          >
            <.icon name="hero-plus-micro" class="size-4" />{gettext("Add a host rule")}
          </.button>
          <.button navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/network"}>{gettext(
            "Go to Network access"
          )}</.button>
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

    <section :if={!@empty?} id="policy-hosts" class="q-psec" aria-labelledby="policy-hosts-h">
      <div class="q-psec-h">
        <h2 id="policy-hosts-h">{gettext("Network access")}</h2>
        <span class="grow"></span>
        <.link
          id="policy-hosts-network"
          navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/network"}
          class="q-sect-link"
        >
          {gettext("See what the runs reached")}<.icon
            name="hero-arrow-right-micro"
            class="size-3.5"
          />
        </.link>
      </div>
      <.rule_list
        id="policy-rules"
        label={gettext("Network access rules of the workspace")}
        listing={@listing}
        query={@list_query}
        path={&Common.list_path(@base, &1)}
        sections={RuleList.sections(@rows, @activity_now)}
        default_sort={
          if @above,
            do: gettext("%{name}'s first", name: @above.name),
            else: gettext("Locked first")
        }
        activity={@activity_now}
        source={@above != nil}
        can_add={@edit?}
        adding={@composer_open}
        can_lock={Common.may?(@current_scope, :"security_policy.lock")}
        fresh={@fresh}
        ruled_host={@ruled_host}
        empty={gettext("No host rules yet. Add the first above.")}
        confirming={confirming(@dialog)}
      >
        <:confirm>
          <.lock_ask
            :if={match?({:lock, _, _}, @dialog)}
            rule={elem(@dialog, 1)}
            held={elem(@dialog, 2)}
          />
          <.remove_ask
            :if={match?({:remove, _, _}, @dialog)}
            rule={elem(@dialog, 1)}
            overriders={elem(@dialog, 2)}
          />
        </:confirm>
        <:composer>
          <.rule_composer
            :if={@composer_open && @edit?}
            id="policy-composer"
            class="q-composer-line"
            form={@composer}
            scope={:workspace}
            reading={@reading}
            queued={length(@queue)}
          />
        </:composer>
      </.rule_list>
      <p id="policy-hosts-note" class="q-psec-note">
        {if @above,
          do:
            gettext(
              "%{name}'s rules come first and hold in every workspace and target; %{workspace}'s own may only narrow them. A deny holds in either mode.",
              name: @above.name,
              workspace: @current_scope.workspace.name
            ),
          else:
            gettext(
              "Locked rules come first, then deny, then allow, each by host read from the right, so a suffix sits beside the hosts below it. A locked rule holds in every target; a deny holds in either mode."
            )}
      </p>
    </section>
    """
  end

  defp async_value(%Phoenix.LiveView.AsyncResult{ok?: true, result: result}, _loading), do: result
  defp async_value(%Phoenix.LiveView.AsyncResult{loading: nil}, _loading), do: :unavailable
  defp async_value(_async, loading), do: loading

  attr :rows, :any, required: true
  attr :own_only, :boolean, default: false

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  defp targets_tab(%{rows: []} = assigns) do
    ~H"""
    <.empty_state tone="neutral" icon="hero-book-open" title={gettext("No targets yet")}>
      {gettext("A target appears here once a run names it with its system and target labels.")}
    </.empty_state>
    """
  end

  defp targets_tab(assigns) do
    # A target is its path; its system is said only where the path is on more than one.
    shared =
      assigns.rows
      |> Enum.frequencies_by(& &1.path)
      |> Enum.filter(fn {_path, n} -> n > 1 end)
      |> MapSet.new(&elem(&1, 0))

    assigns =
      assign(
        assigns,
        shown:
          if(assigns.own_only, do: Enum.filter(assigns.rows, & &1.own_mode), else: assigns.rows),
        shared: shared
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
              number: {:b, Format.number(length(@rows))}
            )
          } />
        </span>
        <span>
          <.rich text={
            rich_ngettext(
              "%{number} with rules of their own",
              "%{number} with rules of their own",
              Enum.count(@rows, &(&1.own > 0)),
              number: {:b, Format.number(Enum.count(@rows, &(&1.own > 0)))}
            )
          } />
        </span>
        <span>
          <.rich text={
            rich_ngettext(
              "%{number} sets its own mode",
              "%{number} set their own mode",
              Enum.count(@rows, & &1.own_mode),
              number: {:b, Format.number(Enum.count(@rows, & &1.own_mode))}
            )
          } />
        </span>
        <span>
          <.rich text={
            rich_ngettext(
              "%{number} with suggestions",
              "%{number} with suggestions",
              Enum.count(@rows, &suggested?/1),
              number: {:b, Format.number(Enum.count(@rows, &suggested?/1))}
            )
          } />
        </span>
        <span :if={@own_only} id="targets-own-only">
          {gettext("Showing those that set their own mode.")}
          <.link patch={~p"/#{@scope.organisation}/#{@scope.workspace}/policy/targets"} class="q-link">{gettext(
            "Show all"
          )}</.link>
        </span>
      </div>
      <div
        class="q-tbl overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs"
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
                {gettext("No target sets its own mode. Every one follows the workspace's default.")}
              </td>
            </tr>
            <tr :for={row <- @shown} id={"target-#{row.id}"} role="row" class="q-target-row">
              <td role="cell" class="q-c-target">
                <.link
                  navigate={
                    ApiaryWeb.TargetComponents.target_path(
                      @scope,
                      row.system,
                      row.path,
                      ["policy"],
                      @shared
                    )
                  }
                  class="q-target-name q-rowlink"
                  title={"#{row.system}/#{row.path}"}
                >
                  <span :if={MapSet.member?(@shared, row.path)} class="q-target-system">{row.system}/</span><span class="q-target-path">{row.path}</span>
                </.link>
              </td>
              <td role="cell" class="q-c-mode">
                <span :if={row.own_mode} class="q-hot">{row.mode}</span>
                <span :if={row.own_mode} class="q-faint">{gettext("its own")}</span>
                <span :if={!row.own_mode}>{row.mode}</span>
              </td>
              <td role="cell">
                <span :if={row.own > 0}>{gettext("Own rules")}</span>
                <span :if={row.own == 0 && row.own_mode}>{gettext("Own mode")}</span>
                <span :if={row.own == 0 && !row.own_mode} class="q-faint">
                  {gettext("Follows the workspace")}
                </span>
              </td>
              <td role="cell" class={["q-num q-opt", row.own == 0 && "q-zero"]}>{row.own}</td>
              <td role="cell" class="q-num q-opt">
                <.cell value={row.detail} none={gettext("n/a")}>
                  <span class={row.detail.overrides == 0 && "q-zero"}>{row.detail.overrides}</span>
                </.cell>
              </td>
              <td role="cell" class="q-num">
                <.cell value={row.suggestions} none={gettext("n/a")}>
                  <span :if={row.suggestions > 0} class="q-hot">
                    {gettext("%{number} to review", number: Format.number(row.suggestions))}
                  </span>
                  <span :if={row.suggestions == 0} class="q-zero">
                    <span class="sr-only">{gettext("none")}</span><span aria-hidden="true">–</span>
                  </span>
                </.cell>
              </td>
              <td role="cell" class="q-opt q-c-version">
                <.cell value={row.detail} none={gettext("n/a")}>
                  <span :if={row.detail.version} title={row.detail.version.digest}>
                    <.link
                      navigate={
                        if is_nil(row.detail.version.target_id),
                          do:
                            ~p"/#{@scope.organisation}/#{@scope.workspace}/policy/versions/#{row.detail.version.version}",
                          else:
                            ApiaryWeb.TargetComponents.target_path(
                              @scope,
                              row.system,
                              row.path,
                              ["policy", "versions", to_string(row.detail.version.version)],
                              @shared
                            )
                      }
                      class="q-mono hover:underline"
                    >
                      <span class="sr-only">{gettext("Version")} </span>v{row.detail.version.version}
                    </.link>
                    <span :if={is_nil(row.detail.version.target_id)} class="q-faint">
                      {gettext("of the workspace's policy")}
                    </span>
                  </span>
                  <span :if={!row.detail.version} class="q-faint">
                    {gettext("no version yet")}
                  </span>
                </.cell>
              </td>
              <td role="cell" class="q-opt tabular-nums">
                <.relative_time :if={row.changed} at={row.changed} />
                <span :if={!row.changed} class="q-faint">{gettext("n/a")}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="max-w-[80ch] text-[12.5px]/[18px] text-faint">
        {gettext(
          "A target appears here once a run names it. A target with neither rules nor a mode of its own is served the workspace baseline, and so is a run that names no target."
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

  ## The mode's question, in its card; a rule's confirm is on its row

  attr :mode, :string, required: true, doc: "the mode picked"
  attr :alive, :integer, required: true
  attr :started, :boolean, required: true
  attr :following, :integer, required: true
  attr :own, :integer, required: true

  # What the picked mode does, the question's sentence (`PolicyComponents.mode_card/1`).
  defp mode_ask_effect(%{mode: "enforce"} = assigns) do
    ~H"""
    <%= for part <- effect_words("enforce", @following, @alive) do %>
      <b :if={part == :effect} class="font-medium text-base-content">{effect_phrase("enforce")}</b>{if part !=
                                                                                                         :effect,
                                                                                                       do:
                                                                                                         part}
    <% end %>
    {own_words(@own)}
    {gettext("You can switch back at any time.")}
    <span :if={!@started}>
      {pgettext(
        "plain",
        "This is the workspace's first change: it renders version 1, and from then on each machine applies it, narrowed by its own."
      )}
    </span>
    """
  end

  defp mode_ask_effect(assigns) do
    ~H"""
    <%= for part <- effect_words("observe", @following, @alive) do %>
      <b :if={part == :effect} class="font-medium text-base-content">{effect_phrase("observe")}</b>{if part !=
                                                                                                         :effect,
                                                                                                       do:
                                                                                                         part}
    <% end %>
    {gettext(
      "A target that sets its own mode does not change. The rules stay as they are, locked ones too: a deny holds in either mode."
    )}
    """
  end

  attr :would, :any, required: true

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  # What enforce would deny, under the question of enforce: what the last 14 days let
  # through with no rule, each with its Allow.
  defp mode_would(assigns) do
    shown = if assigns.would, do: Common.would_shown(assigns.would), else: []
    left = if assigns.would, do: MapSet.size(assigns.would.open), else: 0
    assigns = assign(assigns, shown: shown, left: left)

    ~H"""
    <div :if={@would && @would.destinations != []} id="mode-would" class="q-would">
      <div>
        <span>
          {gettext("Let through in the last 14 days with no rule matching, in those targets")}
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
        <li :for={destination <- @shown} id={"would-#{would_key(destination)}"}>
          <.rule_mark action={
            if !MapSet.member?(@would.open, would_key(destination)), do: "allow", else: "pending"
          } />
          <span :if={destination[:tool]} class="q-dest q-dest-tool">
            <.tool_mark name={destination.tool} /><span
              :if={destination.path}
              class="text-muted"
            >{destination.path}</span><span class="text-faint">{destination.host}</span>
          </span>
          <span :if={!destination[:tool]} class="q-dest">
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
          <button
            :if={MapSet.member?(@would.open, would_key(destination))}
            id={"would-#{would_key(destination)}-allow"}
            type="button"
            class="btn btn-xs"
            phx-click={JS.push("would_allow", value: %{key: would_key(destination)})}
          >
            {gettext("Allow for the workspace")}<span class="sr-only">: {Common.would_name(
              destination
            )}</span>
          </button>
          <span :if={!MapSet.member?(@would.open, would_key(destination))} class="q-done">
            <.icon name="hero-check-micro" class="size-3" />{gettext("Allowed")}
          </span>
        </li>
      </ul>
      <p :if={length(@would.destinations) > 8} class="q-would-more">
        <%= for part <- more_words(length(@would.destinations) - 8) do %>
          <.link
            :if={part == :link}
            navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/network"}
            class="q-link"
          >
            {gettext("Network access page")}
          </.link>{if part != :link, do: part}
        <% end %>
      </p>
    </div>
    <p :if={@would && @would[:error]} class="text-error-soft-content" role="alert">
      {@would[:error]}
    </p>
    <p :if={@would && @would.destinations == []} id="mode-would-none" class="text-muted">
      {gettext("Every destination your runs reached in the last 14 days is covered by a rule.")}
    </p>
    <p :if={@would && @would.destinations != []} class="text-[12.5px]/[18px] text-muted">
      {gettext(
        "Counted from recorded connections that today's rules still do not cover. Enforce will deny these. A destination no run has reached yet is not in this list."
      )}
    </p>
    """
  end

  # The first sentence of a mode's confirm: what the mode denies, in whose runs. Each
  # case is a whole sentence; the effect is a bold phrase of its own, `:effect` here.
  defp effect_words(mode, following, alive) do
    effect = :effect
    runs = ngettext("%{number} run", "%{number} runs", alive, number: Format.number(alive))

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
          "From the next heartbeat, about 30 s, %{effect} in the %{number} target that follows the workspace's default.",
          "From the next heartbeat, about 30 s, %{effect} in the %{number} targets that follow the workspace's default.",
          following,
          effect: effect,
          number: Format.number(following)
        )

      {"enforce", _following, _alive} ->
        rich_ngettext(
          "From the next heartbeat, about 30 s, %{effect} in the %{number} target that follows the workspace's default, and among the %{runs} alive now.",
          "From the next heartbeat, about 30 s, %{effect} in the %{number} targets that follow the workspace's default, and among the %{runs} alive now.",
          following,
          effect: effect,
          runs: runs,
          number: Format.number(following)
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
          "From the next heartbeat, about 30 s, %{effect} in the %{number} target that follows the workspace's default: every other connection is let through and recorded.",
          "From the next heartbeat, about 30 s, %{effect} in the %{number} targets that follow the workspace's default: every other connection is let through and recorded.",
          following,
          effect: effect,
          number: Format.number(following)
        )

      {_observe, _following, _alive} ->
        rich_ngettext(
          "From the next heartbeat, about 30 s, %{effect} in the %{number} target that follows the workspace's default, and among the %{runs} alive now: every other connection is let through and recorded.",
          "From the next heartbeat, about 30 s, %{effect} in the %{number} targets that follow the workspace's default, and among the %{runs} alive now: every other connection is let through and recorded.",
          following,
          effect: effect,
          runs: runs,
          number: Format.number(following)
        )
    end
  end

  defp effect_phrase("enforce"), do: gettext("a connection no rule allows is denied")
  defp effect_phrase(_observe), do: gettext("only what a deny rule names is denied")

  defp own_words(0), do: ""

  defp own_words(n),
    do:
      ngettext(
        "%{number} target sets its own mode and does not change.",
        "%{number} targets set their own mode and do not change.",
        n,
        number: Format.number(n)
      )

  # "and 4 more on the Network access page", with the page a link.
  defp more_words(more),
    do: rich_gettext("and %{more} more on the %{link}", more: Format.number(more), link: :link)

  @doc false
  def would_key(destination), do: Common.would_key(destination)

  # The row a Lock or a Remove asks to confirm on, in place of its cells.
  defp confirming({kind, %{id: id}, _}) when kind in [:lock, :remove], do: id
  defp confirming(_dialog), do: nil

  attr :rule, :map, required: true
  attr :held, :list, required: true

  defp lock_ask(assigns) do
    assigns = assign(assigns, shown: Enum.take(assigns.held, 4), more: length(assigns.held) - 4)

    ~H"""
    <.inline_confirm
      id="lock-confirm"
      question={lock_title(@rule)}
      cancel={confirm_cancel("rule-#{@rule.id}-menu-button")}
    >
      {gettext("A locked rule holds against every target.")}
      <b class="font-medium text-base-content">{ngettext(
          "%{number} target rule stops being in force",
          "%{number} target rules stop being in force",
          length(@held), number: Format.number(length(@held))
        )}</b>: <span
        :for={{held, i} <- Enum.with_index(@shown)}
        phx-no-format
      >{if i > 0, do: "; "}<span class="font-mono text-[12.5px]">{held.name}</span> ({held.rule.host})</span><span
        :if={@more > 0}
        phx-no-format
      >; {ngettext("and %{number} more", "and %{number} more", @more, number: Format.number(@more))}</span>. {gettext(
        "The target's rule is kept and shown as held. Only an owner can unlock."
      )}
      <:action>
        <.button id="lock-confirm-button" variant="primary" size="xs" phx-click="lock_confirm">
          {gettext("Yes, lock")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  attr :rule, :map, required: true
  attr :overriders, :list, required: true

  defp remove_ask(assigns) do
    ~H"""
    <.inline_confirm
      id="remove-confirm"
      question={remove_title(@rule)}
      cancel={confirm_cancel("rule-#{@rule.id}-menu-button")}
    >
      <span :if={@rule.locked}>
        {gettext(
          "This rule is locked: it holds against every target, and removing it lets their own rules decide again."
        )}
      </span>
      <span :if={@overriders != []}>
        {ngettext(
          "%{number} target has a rule of its own on this host; it then has nothing to override and is kept.",
          "%{number} targets have a rule of their own on this host; it then has nothing to override and is kept.",
          length(@overriders),
          number: Format.number(length(@overriders))
        )}
      </span>
      {gettext("This takes effect within a heartbeat.")}
      <:action>
        <.button
          id="remove-confirm-button"
          variant="danger"
          size="xs"
          phx-click="remove_confirm"
          loading_text={gettext("Removing")}
        >
          {gettext("Yes, remove")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  defp lock_title(%{action: "deny", host: host}),
    do: gettext("Lock the deny rule %{host}?", host: host)

  defp lock_title(%{host: host}), do: gettext("Lock the allow rule %{host}?", host: host)

  defp remove_title(%{action: "deny", host: host}),
    do: gettext("Remove the deny rule %{host}?", host: host)

  defp remove_title(%{host: host}), do: gettext("Remove the allow rule %{host}?", host: host)

  # Who may set a mode, in the edition's words where it has some.
  defp only_admins_set_mode(socket),
    do:
      ApiaryWeb.Access.who_may(
        socket.assigns.current_scope,
        :"security_policy.set_mode",
        gettext("Only an owner or an admin sets a mode.")
      )
end
