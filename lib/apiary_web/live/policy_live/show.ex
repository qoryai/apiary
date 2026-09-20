defmodule ApiaryWeb.PolicyLive.Show do
  @moduledoc """
  The hive's security policy (`docs/design/brief-policy.md`, pe1, pe2, pe4, pe5): the mode
  with its two confirms, the host rules with the composer that reads a rule back before it
  is saved, the credentials, the repositories and their policy, the history with diffs,
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
      |> assign(reload: &load/1, show: nil, rule_target: nil, repositories: nil)
      |> assign(history: nil, open_change: nil, diff: nil, v: nil, export: nil, missing: nil)
      |> assign(would: nil, composer_open: false)
      |> load()

    {:ok, socket}
  end

  # Everything the rules tab and the page head show, read again after a write and on a
  # change from elsewhere.
  defp load(socket) do
    scope = socket.assigns.current_scope
    managed? = Policy.managed?(scope)
    own = Policy.list_rules(scope, nil)
    changes = Policy.list_changes(scope, nil, 1)
    locks = Common.locks(scope)

    socket
    |> assign(
      managed?: managed?,
      mode: Policy.get_mode(scope),
      own: own,
      effective: Policy.effective(scope, nil),
      locks: locks,
      version: managed? && Common.newest_version(scope, nil),
      change_total: changes.total,
      repository_total: length(Policy.list_repositories(scope)),
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
  def handle_params(params, _uri, socket) do
    socket = assign(socket, missing: nil, export: nil, now: DateTime.utc_now())
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :rules, params) do
    show = if params["show"] in @shows, do: params["show"]
    target = Common.rule_param(params["rule"])

    socket
    |> assign(show: show, rule_target: target, page_title: "Policy")
    |> then(&if(target, do: push_event(&1, "policy:target", %{host: target}), else: &1))
  end

  defp apply_action(socket, :repositories, _params) do
    socket |> assign(:page_title, "Repositories · Policy") |> load_repositories()
  end

  defp apply_action(socket, :history, params) do
    socket = assign(socket, :page_title, "History · Policy")
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
        socket = assign(socket, v: v, page_title: "Version #{v.configuration.version} · Policy")

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
          page_title: "Policy"
        )
    end
  end

  defp summary(socket) do
    scope = socket.assigns.current_scope
    versions = Policy.list_configurations(scope, nil, 1).total

    since =
      case Policy.get_configuration(scope, nil, 1) do
        {:ok, first} -> first.rendered_at
        _ -> nil
      end

    %{versions: versions, since: since}
  end

  # One row per repository. The counts that cost a read per repository (overrides,
  # suggestions, the version) are made for the first fifty, the ones with rules first.
  @detailed 50
  defp load_repositories(socket) do
    scope = socket.assigns.current_scope
    baseline = socket.assigns.version

    rows =
      Policy.list_repositories(scope)
      |> Enum.sort_by(&(&1.rule_count == 0))
      |> Enum.with_index()
      |> Enum.map(fn {%{repository: repository, rule_count: count}, index} ->
        detailed? = index < @detailed
        effective = detailed? && count > 0 && Policy.effective(scope, repository)
        own_version = detailed? && Common.newest_version(scope, repository)

        last_change =
          if detailed? && count > 0 do
            case Policy.list_changes(scope, repository, 1).items do
              [change | _] -> change.inserted_at
              [] -> nil
            end
          end

        %{
          id: repository.id,
          forge: repository.forge,
          path: repository.path,
          own: count,
          overrides:
            if(effective,
              do:
                Enum.count(
                  effective.entries,
                  &(&1.source == :repository and &1.in_force and &1.overrides != [])
                ),
              else: 0
            ),
          suggestions: if(detailed?, do: length(Policy.suggestions(scope, repository))),
          version: own_version || baseline,
          baseline?: !own_version,
          last_change: last_change
        }
      end)
      |> Enum.sort_by(fn row ->
        {-(row.suggestions || 0), -((row.last_change && DateTime.to_unix(row.last_change)) || 0),
         row.forge, row.path}
      end)

    assign(socket, :repositories, rows)
  end

  ## Events

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
        assign(socket, :write_error, "Only an owner can change the mode.")

      mode == socket.assigns.mode ->
        socket

      mode == "enforce" ->
        would =
          case Policy.uncovered(socket.assigns.current_scope, Common.since()) do
            {:ok, destinations} -> %{destinations: destinations, allowed: MapSet.new()}
            _ -> nil
          end

        assign(socket, dialog: {:mode, "enforce"}, would: would)

      true ->
        assign(socket, dialog: {:mode, "observe"}, would: nil)
    end
  end

  defp event("mode_confirm", _params, %{assigns: %{dialog: {:mode, mode}}} = socket) do
    case Policy.set_mode(socket.assigns.current_scope, mode) do
      {:ok, mode} ->
        socket
        |> assign(:dialog, nil)
        |> Common.wrote(nil, "The hive is in #{mode} mode.", "The hive is in #{mode} mode.")
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
            |> assign(:would, %{would | allowed: MapSet.put(would.allowed, key)})
            |> assign(:announce, "#{destination.host} is allowed for the hive.")

          {:error, error} ->
            assign(socket, :would, Map.put(would, :error, error.message))
        end
    end
  end

  defp event("lock_toggle", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with true <- socket.assigns.owner?,
         {:ok, rule} <- Policy.get_rule(scope, id),
         true <- is_nil(rule.repository_id) do
      held = if rule.locked, do: [], else: held_by_lock(scope, rule)

      if held == [] do
        set_lock(socket, rule, !rule.locked)
      else
        assign(socket, :dialog, {:lock, rule, held})
      end
    else
      false ->
        assign(socket, :write_error, "Only an owner can lock, unlock or change a locked rule.")

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  defp event("lock_confirm", _params, %{assigns: %{dialog: {:lock, rule, _held}}} = socket) do
    socket |> assign(:dialog, nil) |> set_lock(rule, true)
  end

  defp event("edit_paths", %{"id" => id}, socket) do
    case Policy.get_rule(socket.assigns.current_scope, id) do
      {:ok, %{kind: "host", repository_id: nil} = rule} ->
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

  defp event("remove", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Policy.get_rule(scope, id) do
      {:ok, %{repository_id: nil, kind: "host"} = rule} ->
        overriders = overriders(scope, rule)

        if overriders != [] or rule.locked,
          do: assign(socket, :dialog, {:remove, rule, overriders}),
          else: remove(socket, rule)

      {:ok, %{repository_id: nil} = rule} ->
        remove(socket, rule)

      _ ->
        load(socket)
    end
  end

  defp event("remove_confirm", _params, %{assigns: %{dialog: {:remove, rule, _}}} = socket) do
    socket |> assign(:dialog, nil) |> remove(rule)
  end

  defp event("compare", %{"compare" => compare}, %{assigns: %{v: %{} = v}} = socket) do
    push_patch(socket,
      to: version_path(socket.assigns.base, v, compare: Common.page_param(compare))
    )
  end

  defp event(_event, _params, socket), do: socket

  defp set_lock(socket, rule, locked) do
    scope = socket.assigns.current_scope
    result = if locked, do: Policy.lock(scope, rule), else: Policy.unlock(scope, rule)

    case result do
      {:ok, rule} ->
        sentence =
          if locked,
            do: "#{subject(rule)} is locked. No repository can override it.",
            else: "#{subject(rule)} is unlocked. A repository can override it again."

        socket
        |> Common.wrote(nil, sentence, if(locked, do: "Rule locked.", else: "Rule unlocked."))
        |> Common.focus("rule-#{rule.id}-lock")

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  defp remove(socket, rule) do
    rows = socket.assigns.rows
    index = Enum.find_index(rows, &(&1.id == rule.id))
    next = index && (Enum.at(rows, index + 1) || (index > 0 && Enum.at(rows, index - 1)))

    case Policy.remove_rule(socket.assigns.current_scope, rule) do
      {:ok, rule} ->
        words =
          if rule.kind == "credential",
            do: "The credential #{rule.name} is removed.",
            else: "The rule #{rule.host} is removed."

        socket
        |> Common.wrote(nil, words, "Rule removed.")
        |> Common.focus(if(next, do: "rule-#{next.id}-menu-button", else: "policy-composer-host"))

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  defp subject(%{kind: "credential", name: name}), do: name
  defp subject(%{host: host}), do: host

  # The repositories' own rules a lock of this rule would put out of force: a rule on the
  # same host, or an allow below a locked `*.` deny. Read for the repositories that have
  # rules of their own, at most fifty of them.
  defp held_by_lock(scope, rule) do
    for {repository, own} <- repository_rules(scope),
        other <- own,
        other.kind == "host",
        other.host == rule.host or
          (rule.action == "deny" and other.action == "allow" and
             Grammar.covers?(rule.host, other.host)),
        do: %{repository: repository, rule: other}
  end

  defp overriders(scope, rule) do
    for {repository, own} <- repository_rules(scope),
        other <- own,
        other.kind == "host" and other.host == rule.host,
        do: %{repository: repository, rule: other}
  end

  defp repository_rules(scope) do
    for %{repository: repository, rule_count: count} <- Policy.list_repositories(scope),
        count > 0 do
      repository
    end
    |> Enum.take(50)
    |> Enum.map(&{&1, Policy.list_rules(scope, &1)})
  end

  ## Messages

  @impl true
  def handle_info({:policy_changed, _change}, socket),
    do: {:noreply, Common.schedule_reload(socket)}

  def handle_info(:policy_reload, socket) do
    socket = load(socket)

    socket =
      case socket.assigns.live_action do
        :repositories ->
          load_repositories(socket)

        :history ->
          assign(socket,
            history: Common.history(socket, socket.assigns.history.page),
            summary: summary(socket)
          )

        _ ->
          socket
      end

    socket =
      if socket.assigns.composer_params["host"] != "", do: Common.read(socket, %{}), else: socket

    {:noreply, socket}
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
      nav={:policy}
      width="full"
    >
      <div id="policy-page" phx-hook="PolicyPage" class="grid grid-cols-[minmax(0,1fr)] gap-6">
        <div :if={@live_action in [:version, :export] && @v} class="grid gap-3">
          <nav class="q-crumbs" aria-label="Breadcrumb">
            <.link navigate={~p"/hive/policy"}>Policy</.link>
            <.icon name="hero-chevron-right-micro" class="size-3" />
            <span class="q-here" aria-current="page">Version {@v.configuration.version}</span>
          </nav>
          <.version_head v={@v} base={@base} />
        </div>

        <.header :if={!(@live_action in [:version, :export] && @v)}>
          Policy
          <:subtitle>
            What the runs of this <.term word="hive" />
            may reach through the runner's proxy. The policy can only allow: what no rule names is denied under enforce, and let through and recorded under observe.
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
                <.icon name="hero-arrow-up-tray-micro" class="size-4" />Export
              </.button>
            </div>
          </:actions>
        </.header>

        <.policy_tabs
          live_action={@live_action}
          rules={length(@own)}
          repositories={@repository_total}
          changes={@change_total}
          document={@managed? && @version != nil}
        />

        <div id="policy-announce" class="sr-only" role="status" aria-live="polite">{@announce}</div>

        <.notice :if={@write_error} kind={:error} class="max-w-[80ch]">
          <span id="policy-write-error" role="alert">{@write_error}</span>
        </.notice>

        <.rules_tab :if={@live_action == :rules} {assigns} />
        <.repositories_tab :if={@live_action == :repositories} rows={@repositories} />
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
          title={"There is no version #{String.slice(@missing.n, 0, 12)}"}
        >
          <span :if={@missing.latest}>The latest is version {@missing.latest.version}.</span>
          <span :if={!@missing.latest}>This hive has no version yet.</span>
          <:actions>
            <.button
              :if={@missing.latest}
              navigate={~p"/hive/policy/versions/#{@missing.latest.version}"}
            >
              Open version {@missing.latest.version}
            </.button>
            <.button :if={!@missing.latest} navigate={~p"/hive/policy"}>Back to policy</.button>
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
        alive={(@nav_counts && @nav_counts[:alive]) || 0}
        started={@managed?}
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
          Version {@v.configuration.version}
        </h1>
        <.badge :if={@v.current?} color="success">
          <.icon name="hero-check-micro" class="size-3" />In force
        </.badge>
        <.badge :if={!@v.current?}>Superseded</.badge>
        <span :if={@v.superseded_by} id="version-superseded" class="text-[13px] text-muted">
          by
          <.version_link
            version={@v.superseded_by.version}
            navigate={"#{@base}/versions/#{@v.superseded_by.version}"}
          />
          after {format_seconds(
            max(DateTime.diff(@v.superseded_by.rendered_at, @v.configuration.rendered_at), 0)
          )}
        </span>
      </div>
      <div class="q-head-side">
        <.button id="version-export" patch={"#{@base}/versions/#{@v.latest}/export"}>
          <.icon name="hero-arrow-up-tray-micro" class="size-4" />{if @v.current?,
            do: "Export",
            else: "Export the version in force"}
        </.button>
      </div>
    </header>
    """
  end

  attr :live_action, :atom, required: true
  attr :rules, :integer, required: true
  attr :repositories, :integer, required: true
  attr :changes, :integer, required: true
  attr :document, :boolean, required: true

  defp policy_tabs(assigns) do
    ~H"""
    <.tabs id="policy-tabs" label="Policy">
      <:tab
        patch={~p"/hive/policy"}
        icon="hero-shield-check-micro"
        current={@live_action == :rules}
        count={@rules > 0 && @rules}
      >
        Rules
      </:tab>
      <:tab
        patch={~p"/hive/policy/repositories"}
        icon="hero-book-open-micro"
        current={@live_action == :repositories}
        count={@repositories > 0 && @repositories}
      >
        Repositories
      </:tab>
      <:tab
        patch={~p"/hive/policy/history"}
        icon="hero-clock-micro"
        current={@live_action == :history}
        count={@changes > 0 && @changes}
      >
        History
      </:tab>
      <:tab
        :if={@document}
        patch={~p"/hive/policy/document"}
        icon="hero-document-text-micro"
        current={@live_action in [:version, :export, :document]}
      >
        Document
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
      started={@managed?}
      fact={async_value(@fact, :loading)}
    />

    <div :if={@empty?} id="policy-empty" class="grid gap-4">
      <.empty_state icon="hero-shield-check" title="No rules yet">
        <span :if={!@managed?} id="policy-unmanaged">
          Runs use each machine's own policy until the first change here. The first rule, or the first change of mode, starts the hive's policy, and from then on every run of the hive takes it.
        </span>
        <span :if={@managed?}>
          In {@mode} mode with no rules, {if @mode == "observe",
            do: "runs reach everything and every connection is recorded.",
            else: "runs reach nothing."}
        </span>
        Add the hosts your runs need here, or let a run reach out first and allow its hosts from the Connections page, one row at a time.
        <:actions>
          <.button id="policy-first-rule" variant="primary" phx-click="composer_open">
            <.icon name="hero-plus-micro" class="size-4" />Add a host rule
          </.button>
          <.button navigate={~p"/hive/connections"}>Go to connections</.button>
        </:actions>
      </.empty_state>
      <p class="max-w-[80ch] text-[12.5px]/[18px] text-faint">
        The first version is rendered when the first rule is added or the mode is first set. Until then no machine is served a run configuration by this hive.
      </p>
    </div>

    <.sect :if={!@empty?} id="policy-hosts" title="Host rules" count={length(@rows)}>
      <:trailing>
        <.segments id="policy-show" label="Show">
          <:segment patch={~p"/hive/policy"} pressed={@show == nil}>All</:segment>
          <:segment
            patch={~p"/hive/policy?show=allow"}
            pressed={@show == "allow"}
            count={@counts.allow}
          >
            Allow
          </:segment>
          <:segment patch={~p"/hive/policy?show=deny"} pressed={@show == "deny"} count={@counts.deny}>
            Deny
          </:segment>
          <:segment
            patch={~p"/hive/policy?show=locked"}
            pressed={@show == "locked"}
            count={@counts.locked}
          >
            Locked
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
        label="Host rules of the hive"
        rows={@shown}
        scope={:hive}
        can_lock={@owner?}
        activity={async_value(@activity, :loading)}
        fresh={@fresh}
        target={@rule_target}
        empty={empty_words(@show, @rows)}
      />
      <:footer>
        Locked rules come first, then deny, then allow, each by host read from the right, so a suffix sits beside the hosts below it. A deny takes allowed hosts out of the document; the document itself can only allow.
      </:footer>
    </.sect>

    <.sect :if={!@empty?} id="policy-credentials" title="Credentials" count={length(@credentials)}>
      <:description>
        Credentials a run may use, by name. The policy names one; it never holds one. Each machine defines its credentials in its runner file, and a name a machine does not define is no run.
      </:description>
      <.credential_composer id="policy-credential" form={@credential} reading={@credential_reading} />
      <.credentials_table
        id="policy-credential-rows"
        label="Credentials of the hive"
        rows={@credentials}
        scope={:hive}
        activity={async_value(@activity, :loading)}
      />
    </.sect>
    """
  end

  defp empty_words(_show, []), do: "No host rules yet. Add the first above."
  defp empty_words("locked", _rows), do: "No locked rules."
  defp empty_words("deny", _rows), do: "No deny rules."
  defp empty_words("allow", _rows), do: "No allow rules."
  defp empty_words(_show, _rows), do: nil

  defp async_value(%Phoenix.LiveView.AsyncResult{ok?: true, result: result}, _loading), do: result
  defp async_value(%Phoenix.LiveView.AsyncResult{loading: nil}, _loading), do: :unavailable
  defp async_value(_async, loading), do: loading

  attr :rows, :any, required: true

  defp repositories_tab(%{rows: []} = assigns) do
    ~H"""
    <.empty_state tone="neutral" icon="hero-book-open" title="No repositories yet">
      A repository appears here once a run names it with its forge and repository labels.
    </.empty_state>
    """
  end

  defp repositories_tab(assigns) do
    ~H"""
    <div id="policy-repositories" class="grid grid-cols-[minmax(0,1fr)] gap-6">
      <div id="repositories-summary" class="q-summary">
        <span>
          <b>{length(@rows)}</b> {if length(@rows) == 1,
            do: "repository has posted runs",
            else: "repositories have posted runs"}
        </span>
        <span><b>{Enum.count(@rows, &(&1.own > 0))}</b> with rules of their own</span>
        <span><b>{Enum.count(@rows, &((&1.suggestions || 0) > 0))}</b> with suggestions</span>
      </div>
      <div
        class="overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs"
        tabindex="0"
        role="region"
        aria-label="Repositories and their policy"
      >
        <table class="table q-repos" role="table">
          <thead>
            <tr role="row">
              <th role="columnheader">Repository</th>
              <th role="columnheader">Policy</th>
              <th role="columnheader" class="q-num">Own rules</th>
              <th role="columnheader" class="q-num">Overrides</th>
              <th role="columnheader" class="q-num">Suggestions</th>
              <th role="columnheader">Version</th>
              <th role="columnheader">Last change</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} id={"repo-#{row.id}"} role="row" class="q-repo-row">
              <td role="cell" class="q-c-repo">
                <.link
                  navigate={~p"/hive/policy/repositories/#{row.id}"}
                  class="q-repo-name q-rowlink"
                >
                  <span class="q-repo-f">{row.forge}/</span><span class="q-repo-p">{row.path}</span>
                </.link>
              </td>
              <td role="cell">
                <.source_chip :if={!row.baseline?} source={:repository} label="Own rules" />
                <.source_chip :if={row.baseline?} source={:hive} label="Hive baseline" />
              </td>
              <td role="cell" class={["q-num q-opt", row.own == 0 && "q-zero"]}>{row.own}</td>
              <td role="cell" class={["q-num q-opt", row.overrides == 0 && "q-zero"]}>
                {row.overrides}
              </td>
              <td role="cell" class="q-num">
                <span :if={(row.suggestions || 0) > 0} class="q-newdot">
                  {row.suggestions} to review
                </span>
                <span :if={row.suggestions == 0} class="q-zero">0</span>
                <span
                  :if={row.suggestions == nil}
                  class="q-zero"
                  title="Open the repository to see them"
                >
                  n/a
                </span>
              </td>
              <td role="cell" class="q-opt font-mono text-[12.5px]">
                <span :if={row.version}>
                  v{row.version.version}
                  <span class="text-faint">{short_digest(row.version.digest)}</span>
                </span>
                <span :if={!row.version} class="text-faint font-sans text-[13px]">no version yet</span>
              </td>
              <td role="cell" class="q-opt text-muted tabular-nums">
                <.relative_time :if={row.last_change} at={row.last_change} />
                <span :if={!row.last_change} class="text-faint">n/a</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="max-w-[80ch] text-[12.5px]/[18px] text-faint">
        A repository appears here once a run names it. A repository without rules of its own is served the hive baseline, and so is a run that names no repository.
      </p>
    </div>
    """
  end

  ## Dialogs

  attr :mode, :string, required: true
  attr :would, :any, required: true
  attr :alive, :integer, required: true
  attr :started, :boolean, required: true

  defp mode_dialog(%{mode: "enforce"} = assigns) do
    shown = if assigns.would, do: Enum.take(assigns.would.destinations, 8), else: []

    left =
      if assigns.would,
        do:
          Enum.count(
            assigns.would.destinations,
            &(!MapSet.member?(assigns.would.allowed, would_key(&1)))
          ),
        else: 0

    assigns = assign(assigns, shown: shown, left: left)

    ~H"""
    <.modal
      id="mode-enforce"
      title="Switch the hive to enforce"
      size="lg"
      on_cancel={JS.push("dialog_cancel")}
    >
      <p class="text-muted">
        From the next heartbeat, about 30 s, <b class="font-medium text-base-content">a connection no rule allows is denied</b>, in every repository{alive_words(
          @alive
        )}. You can switch back at any time.
        <span :if={!@started}>
          This is the hive's first change: from it on, every run takes the hive's policy in place of its machine's own.
        </span>
      </p>
      <div :if={@would && @would.destinations != []} id="mode-would" class="q-would">
        <div>
          <span>Let through in the last 7 days with no rule matching</span>
          <span id="mode-would-n" class="tabular-nums">
            {if @left == 0, do: "none left", else: Common.plural(@left, "destination")}
          </span>
        </div>
        <ul>
          <li :for={destination <- @shown} id={"would-#{would_key(destination)}"}>
            <.rule_mark action={
              if MapSet.member?(@would.allowed, would_key(destination)), do: "allow", else: "pending"
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
            <button
              :if={!MapSet.member?(@would.allowed, would_key(destination))}
              type="button"
              class="btn btn-xs"
              phx-click={JS.push("would_allow", value: %{key: would_key(destination)})}
            >
              Allow for the hive
            </button>
            <span :if={MapSet.member?(@would.allowed, would_key(destination))} class="q-done">
              <.icon name="hero-check-micro" class="size-3" />Allowed
            </span>
          </li>
        </ul>
        <p :if={length(@would.destinations) > 8} class="q-would-more">
          and {length(@would.destinations) - 8} more on the
          <.link navigate={~p"/hive/connections?since=7d"} class="q-link">connections page</.link>
        </p>
      </div>
      <p :if={@would && @would[:error]} class="text-error-soft-content" role="alert">
        {@would[:error]}
      </p>
      <p :if={@would && @would.destinations == []} id="mode-would-none" class="text-muted">
        Every destination your runs reached in the last 7 days is covered by a rule.
      </p>
      <p :if={@would && @would.destinations != []} class="text-[12.5px]/[18px] text-muted">
        Counted from recorded connections that today's rules still do not cover. Enforce will deny these. A destination no run has reached yet is not in this list.
      </p>
      <:footer>
        <.button phx-click="dialog_cancel" data-autofocus>Cancel</.button>
        <.button id="mode-confirm" variant="primary" phx-click="mode_confirm" loading_text="Switching">
          Switch to enforce
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp mode_dialog(assigns) do
    ~H"""
    <.modal
      id="mode-observe"
      title="Switch the hive to observe"
      size="sm"
      on_cancel={JS.push("dialog_cancel")}
    >
      <p class="text-muted">
        From the next heartbeat, about 30 s, <b class="font-medium text-base-content">nothing is denied</b>: every connection is let through and recorded, in every repository{alive_words(
          @alive
        )}. The rules stay as they are. Locked rules do not hold in observe mode either.
      </p>
      <:footer>
        <.button phx-click="dialog_cancel" data-autofocus>Cancel</.button>
        <.button id="mode-confirm" variant="danger" phx-click="mode_confirm" loading_text="Switching">
          Switch to observe
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp alive_words(0), do: ""
  defp alive_words(1), do: " and in the 1 run alive now"
  defp alive_words(n), do: " and in the #{n} runs alive now"

  @doc false
  def would_key(%{host: host, path: path}), do: dom_token({host, path})

  attr :rule, :map, required: true
  attr :held, :list, required: true

  defp lock_dialog(assigns) do
    ~H"""
    <.modal
      id="lock-confirm"
      title={"Lock the #{@rule.action} rule #{@rule.host}"}
      size="sm"
      on_cancel={JS.push("dialog_cancel")}
    >
      <p class="text-muted">
        A locked rule holds against every repository. <b class="font-medium text-base-content">
          {Common.plural(length(@held), "repository rule")} {if length(@held) == 1,
            do: "stops",
            else: "stop"} being in force
        </b>:
      </p>
      <div class="q-would">
        <ul>
          <li :for={held <- @held} class="!grid-cols-[18px_minmax(0,1fr)_auto]">
            <.rule_mark action={held.rule.action} />
            <span class="q-dest">{held.rule.host}</span>
            <small class="font-mono">{held.repository.forge}/{held.repository.path}</small>
          </li>
        </ul>
      </div>
      <p class="text-muted">
        The repository's rule is kept and shown as held. Only an owner can unlock.
      </p>
      <:footer>
        <.button phx-click="dialog_cancel" data-autofocus>Cancel</.button>
        <.button id="lock-confirm-button" variant="primary" phx-click="lock_confirm">
          Lock the rule
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
      title={"Remove the #{@rule.action} rule #{@rule.host}"}
      size="sm"
      on_cancel={JS.push("dialog_cancel")}
    >
      <p class="text-muted">
        <span :if={@rule.locked}>
          This rule is locked: it holds against every repository, and removing it lets their own rules decide again.
        </span>
        <span :if={@overriders != []}>
          {Common.plural(length(@overriders), "repository")} {if length(@overriders) == 1,
            do: "has",
            else: "have"} a rule of {if length(@overriders) == 1, do: "its", else: "their"} own on this host; it then has nothing to override and is kept.
        </span>
        This takes effect within a heartbeat.
      </p>
      <:footer>
        <.button phx-click="dialog_cancel" data-autofocus>Cancel</.button>
        <.button id="remove-confirm-button" variant="danger" phx-click="remove_confirm">
          Remove the rule
        </.button>
      </:footer>
    </.modal>
    """
  end
end
